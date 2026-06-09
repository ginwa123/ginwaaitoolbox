const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

pub const SubAgentInput = struct {
    name: []const u8,
    instruction: []const u8,
    tools: ?[]const []const u8 = null, // optional list of tool names to allow
    timeout_seconds: ?u32 = null, // optional timeout for this sub-agent (0 = no timeout)
    inherited_context: ?[]const u8 = null, // optional mode string for parent history inheritance
};

pub const SubAgentsInput = struct {
    sub_agents: []const SubAgentInput,

    pub fn deinit(self: *const SubAgentsInput, allocator: std.mem.Allocator) void {
        for (self.sub_agents) |sa| {
            allocator.free(sa.name);
            allocator.free(sa.instruction);
            if (sa.tools) |t| {
                for (t) |tool_name| {
                    allocator.free(tool_name);
                }
                allocator.free(t);
            }
            // Note: timeout_seconds doesn't need freeing (it's an optional primitive)
            if (sa.inherited_context) |ctx| allocator.free(ctx);
        }
        allocator.free(self.sub_agents);
    }
};

pub const spawn_sub_agent_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "spawn_sub_agent",
        .description =
        \\Spawn 1 to 20 parallel sub-agents to complete tasks concurrently.
        \\
        \\HOW IT WORKS:
        \\- You MUST include all necessary context, background, and instructions
        \\  directly inside each sub-agent's "instruction" field.
        \\- All sub-agents run in parallel and return results separately.
        \\
        \\WHEN TO USE:
        \\- Use when tasks can be broken down into independent parallel workloads.
        \\- Use when you need to research multiple topics simultaneously.
        \\- Use when processing multiple files, URLs, or data sources at once.
        \\
        \\TOOL SELECTION GUIDE (optional "tools" field):
        \\- Omit "tools" to give the sub-agent access to ALL default tools.
        \\- Specify "tools" to restrict the sub-agent to only those tools (saves tokens, improves focus).
        \\- Unknown tools will return an error message explaining why they can't be used.
        \\
        \\TIMEOUT OPTION:
        \\- Each sub-agent can have an optional "timeout_seconds" field.
        \\- If a sub-agent exceeds its timeout, it will be terminated and return an error.
        \\- Default: no timeout (sub-agent runs until completion).
        \\
        \\INHERITED CONTEXT:
        \\- Each sub-agent can have an optional "inherited_context" mode string
        \\  that controls whether the parent's recent conversation history is
        \\  injected into the sub-agent's system prompt as a labelled read-only
        \\  block ("## Conversation History From Parent Agent").
        \\- Valid values:
        \\    - "none"        — no inheritance (default when omitted)
        \\    - "last:N"      — last N user/assistant turns from the parent (N: 1-50, default 10)
        \\    - "all"         — all user/assistant turns (capped at 50)
        \\    - "since_last_user" — from the parent's last user message onwards
        \\- Only user and assistant text turns are inherited. Tool calls and
        \\  tool results from the parent are NOT included — the sub-agent has
        \\  its own tool set and shouldn't assume the parent's tool state.
        \\
        \\EXAMPLE USE CASES:
        \\  - Spawn 3 agents: one to browse URL A, one to browse URL B, one to browse URL C
        \\  - Spawn 5 agents to process 5 different files in parallel
        \\  - Spawn agents with ["web_browse"] to research multiple topics at once
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "json_input",
                    .type = "string",
                    .description =
                    \\A JSON string defining the sub-agents to spawn. Maximum 20 sub-agents.
                    \\
                    \\SCHEMA:
                    \\{
                    \\  "sub_agents": [
                    \\    {
                    \\      "name": "descriptive-agent-name",   // Required. Used to label results.
                    \\      "instruction": "Full task details", // Required. Must be self-contained —
                    \\                                          //   include ALL context the agent needs.
                    \\      "tools": ["bash", "web_browse"],    // Optional. Omit for all tools.
                    \\      "timeout_seconds": 300              // Optional. Timeout in seconds (0 = no limit).
                    \\    }
                    \\  ]
                    \\}
                    \\
                    \\GOOD INSTRUCTION EXAMPLE:
                    \\  "instruction": "Browse https://example.com/pricing and extract all pricing
                    \\   tiers, their names, prices, and included features. Return as a markdown table."
                    \\
                    \\BAD INSTRUCTION EXAMPLE (too vague, no context):
                    \\  "instruction": "Check the pricing page"  ← agent won't know what site or goal
                    ,
                },
            },
            .required = &.{"json_input"},
        },
    },
};

/// Parse JSON input to extract sub-agents
/// Returns error if JSON is invalid or more than max_agents
/// Handles both correct format (json_input as string) and LLM mistake (json_input as object)
pub fn parse_sub_agents(
    allocator: std.mem.Allocator,
    input_json: []const u8,
    max_agents: usize,
) !SubAgentsInput {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const root = parsed.value;
    const root_obj = root.object;

    // Try to get sub_agents - either directly from root or from json_input field
    if (root_obj.get("sub_agents")) |_| {
        return parseSubAgentsFromValue(allocator, root_obj, max_agents);
    } else {
        // Check if json_input is present
        if (root_obj.get("json_input")) |json_input_val| {
            // Case 1: json_input is an object (LLM mistake) containing sub_agents
            if (json_input_val == .object) {
                return parseSubAgentsFromValue(allocator, json_input_val.object, max_agents);
            }
            // Case 2: json_input is a string (correct format) - parse it recursively
            if (json_input_val == .string) {
                // Recursively parse the string content
                return parse_sub_agents(allocator, json_input_val.string, max_agents);
            }
        }
        return error.MissingSubAgentsField;
    }
}

/// Parse sub_agents from an already-parsed object
fn parseSubAgentsFromValue(
    allocator: std.mem.Allocator,
    root_obj: std.json.ObjectMap,
    max_agents: usize,
) !SubAgentsInput {
    const agents_val = root_obj.get("sub_agents") orelse {
        return error.MissingSubAgentsField;
    };
    // Check if sub_agents is an array or a string (handle LLM mistakes)
    const agents_array: std.json.Array = if (agents_val == .array)
        agents_val.array
    else if (agents_val == .string)
        // Parse the string as JSON to get the actual array
        blk: {
            const parsed_str = try std.json.parseFromSlice(std.json.Value, allocator, agents_val.string, .{
                .ignore_unknown_fields = true,
            });
            defer parsed_str.deinit();
            if (parsed_str.value != .array) {
                return error.InvalidSubAgentsFormat;
            }
            break :blk parsed_str.value.array;
        }
    else
        return error.InvalidSubAgentsFormat;

    if (agents_array.items.len == 0) {
        return error.NoSubAgents;
    }
    if (agents_array.items.len > max_agents) {
        return error.TooManySubAgents;
    }

    var sub_agents_list = std.ArrayList(SubAgentInput).empty;
    errdefer {
        for (sub_agents_list.items) |sa| {
            allocator.free(sa.name);
            allocator.free(sa.instruction);
        }
        sub_agents_list.deinit(allocator);
    }

    for (agents_array.items) |agent_val| {
        const agent_obj = agent_val.object;
        const name_val = agent_obj.get("name") orelse {
            return error.MissingSubAgentName;
        };
        const instr_val = agent_obj.get("instruction") orelse {
            return error.MissingSubAgentInstruction;
        };

        const name = try allocator.dupe(u8, name_val.string);
        const instruction = try allocator.dupe(u8, instr_val.string);

        // Parse optional "tools" field
        var tools: ?[]const []const u8 = null;
        if (agent_obj.get("tools")) |tools_val| {
            const tools_array = tools_val.array;
            var tools_list = std.ArrayList([]const u8).empty;
            errdefer {
                for (tools_list.items) |t| allocator.free(t);
                tools_list.deinit(allocator);
            }
            for (tools_array.items) |tool_val| {
                const tool_name = try allocator.dupe(u8, tool_val.string);
                try tools_list.append(allocator, tool_name);
            }
            tools = try tools_list.toOwnedSlice(allocator);
        }

        // Parse optional "timeout_seconds" field
        var timeout_seconds: ?u32 = null;
        if (agent_obj.get("timeout_seconds")) |timeout_val| {
            timeout_seconds = @intCast(timeout_val.integer);
        }

        // Parse optional "inherited_context" field
        var inherited_context: ?[]const u8 = null;
        if (agent_obj.get("inherited_context")) |ctx_val| {
            if (ctx_val == .string) {
                inherited_context = try allocator.dupe(u8, ctx_val.string);
            }
        }

        try sub_agents_list.append(allocator, .{
            .name = name,
            .instruction = instruction,
            .tools = tools,
            .timeout_seconds = timeout_seconds,
            .inherited_context = inherited_context,
        });
    }

    return SubAgentsInput{
        .sub_agents = try sub_agents_list.toOwnedSlice(allocator),
    };
}

test {
    // Tests removed - spawn_sub_agent_test.zig removed due to API changes
}
