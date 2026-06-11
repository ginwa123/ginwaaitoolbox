const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const inherited_context_helper = @import("../../../ai_workflow/tui/inherited_context.zig");

pub const SubAgentInput = struct {
    name: []const u8,
    instruction: []const u8,
    tools: ?[]const []const u8 = null, // optional list of tool names to allow
    timeout_seconds: ?u32 = null, // optional timeout for this sub-agent (0 = no timeout)
    inherited_context: ?[]const u8 = null, // optional mode string for parent history inheritance
    /// Optional: name of a sub-agent from `LlmConfig.sub_agents` to
    /// load this sub-agent's specialized config (model, base_url,
    /// api_key, url_style, thinking, temperature, system_prompt).
    /// `null` = use the orchestrator's defaults (existing behavior).
    /// Empty string at the JSON level is treated as `null`.
    /// `SubAgentsInput.deinit` frees this dupe.
    agent_name: ?[]const u8 = null,
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
            if (sa.agent_name) |an| allocator.free(an);
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
        \\AGENT_NAME (sub-agent from config):
        \\- Each sub-agent may include an optional "agent_name" field to load a
        \\  pre-configured sub-agent from `~/.config/nalar/config.json`'s
        \\  top-level `sub_agents` array.
        \\- Resolution: the name is looked up in the top-level
        \\  `sub_agents` list. (v1: per-profile sub_agents lookup is
        \\  wired in a follow-up — only the top-level list is consulted
        \\  because `ToolExecContext` doesn't yet carry the parent's
        \\  `selected_profile_model`.)
        \\- If the name is found, the sub-agent uses that sub-agent's:
        \\    - model, base_url, api_key, url_style (overlay on orchestrator defaults)
        \\    - thinking ("auto" | "true" | "false")
        \\    - temperature ("auto" or a numeric value)
        \\    - system_prompt (injected as the sub-agent's
        \\      "## Your Active Agent Configuration" block in the system prompt)
        \\- If the name is NOT found, a random name of the form
        \\  "agent-{16 hex chars}" is generated for tracking, and the
        \\  orchestrator's default model / api_key / base_url / url_style
        \\  is used. The system prompt is the default (no specialized
        \\  system_prompt injection). The result XML will carry
        \\  `random_fallback="true"` on the affected <agent> tag.
        \\- Example: { "name": "reviewer-a", "instruction": "...",
        \\             "agent_name": "code-reviewer" }
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
                    \\      "timeout_seconds": 300,             // Optional. Timeout in seconds (0 = no limit).
                    \\      "inherited_context": "last:5"        // Optional. Mode for parent history inheritance.
                    \\      "agent_name": "code-reviewer"       // Optional. Name of a pre-configured sub-agent in config.
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
        errdefer allocator.free(name);
        const instruction = try allocator.dupe(u8, instr_val.string);
        errdefer allocator.free(instruction);

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
                // Validate the mode string at parse time so the LLM gets a clear
                // error for typo'd modes (e.g. "last:5x" instead of "last:5").
                // The raw string is still stored; the formatter re-parses it.
                _ = inherited_context_helper.parseMode(ctx_val.string) catch {
                    return error.InvalidInheritedContextMode;
                };
                inherited_context = try allocator.dupe(u8, ctx_val.string);
            }
        }

        // Parse optional "agent_name" field — name of a sub-agent
        // from `LlmConfig.sub_agents` to apply as an overlay on the
        // orchestrator's defaults. Empty string is treated as "not
        // specified" (null). Length is capped at 256 chars as a
        // parse-time guard against absurdly long input. Resolution
        // (and "not found" detection) is deferred to
        // `LlmConfig.resolveSubAgent` at spawn time.
        var agent_name: ?[]const u8 = null;
        if (agent_obj.get("agent_name")) |an_val| {
            if (an_val == .string) {
                if (an_val.string.len > 0) {
                    if (an_val.string.len > 256) {
                        return error.AgentNameTooLong;
                    }
                    agent_name = try allocator.dupe(u8, an_val.string);
                }
            }
        }

        try sub_agents_list.append(allocator, .{
            .name = name,
            .instruction = instruction,
            .tools = tools,
            .timeout_seconds = timeout_seconds,
            .inherited_context = inherited_context,
            .agent_name = agent_name,
        });
    }

    return SubAgentsInput{
        .sub_agents = try sub_agents_list.toOwnedSlice(allocator),
    };
}

test {
    // Tests removed - spawn_sub_agent_test.zig removed due to API changes
}
