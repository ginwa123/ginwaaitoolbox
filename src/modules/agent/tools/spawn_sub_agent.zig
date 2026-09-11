const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const inherited_context_helper = @import("../../../ai_workflow/tui/agentic_loop/inherited_context.zig");

pub const SubAgentInput = struct {
    instruction: []const u8,
    tools: ?[]const []const u8 = null, // optional list of tool names to allow
    timeout_seconds: ?u32 = null, // optional timeout for this sub-agent (0 = no timeout)
    inherited_context: ?[]const u8 = null, // optional mode string for parent history inheritance
    agent_name: []const u8,
};

pub const SubAgentsInput = struct {
    sub_agents: []const SubAgentInput,

    pub fn deinit(self: *const SubAgentsInput, allocator: std.mem.Allocator) void {
        for (self.sub_agents) |sa| {
            allocator.free(sa.instruction);
            if (sa.tools) |t| {
                for (t) |tool_name| {
                    allocator.free(tool_name);
                }
                allocator.free(t);
            }
            // Note: timeout_seconds doesn't need freeing (it's an optional primitive)
            if (sa.inherited_context) |ctx| allocator.free(ctx);
            allocator.free(sa.agent_name);
        }
        allocator.free(self.sub_agents);
    }
};

pub const spawn_sub_agent_tool_system_prompt =
    \\## Spawn Sub Agent Tool — Behavior
    \\Use `spawn_sub_agent` to delegate independent sub-tasks in parallel.
    \\- Provide `instruction` (full task details) and `agent_name` (from available sub-agents). The sub-agent runs isolated and returns a result.
    \\- Use for parallel research or multi-file work, not for trivial single-step tasks. Up to 20 sub-agents in parallel.
    \\
;

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
        \\- Each sub-agent MUST include an "agent_name" field. This is
        \\  the name of a pre-configured sub-agent to load from
        \\  `~/.config/nalar/config.json`. The sub-agent uses that
        \\  sub-agent's:
        \\    - model, base_url, api_key, url_style (overlay on orchestrator defaults)
        \\    - thinking ("auto" | "true" | "false")
        \\    - temperature ("auto" or a numeric value)
        \\    - system_prompt (injected as the sub-agent's
        \\      "## Your Active Agent Configuration" block in the system prompt)
        \\- The agent_name is also used as the sub-agent's label in
        \\  the result XML (the <agent name="..."> attribute).
        \\- Resolution: the name is looked up in the parent session's
        \\  profile (`selected_profile_model`) and its `sub_agents` list
        \\  only (per-profile-only — there is no top-level fallback).
        \\- If you are unsure which agent_name values exist or which fits
        \\  the job, call list_sub_agent first — it shows full specs
        \\  (model, tuning, system prompt); absent optional tags mean
        \\  'inherits the profile default'.
        \\- If the name is NOT found, a random name of the form
        \\  "agent-{16 hex chars}" is generated for tracking, and the
        \\  orchestrator's default model / api_key / base_url / url_style
        \\  is used. The system prompt is the default (no specialized
        \\  system_prompt injection). The result XML will carry
        \\  `random_fallback="true"` on the affected <agent> tag.
        \\- Example: { "instruction": "Review the diff in src/foo.zig",
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
                    \\      "instruction": "Full task details", // Required. Must be self-contained —
                    \\                                          //   include ALL context the agent needs.
                    \\      "agent_name": "code-reviewer"       // Required. Name of a pre-configured sub-agent
                    \\                                          //   (looked up in the active profile's sub_agents
                    \\                                          //   only). Also used as the
                    \\                                          //   sub-agent's label in the result XML.
                    \\      "tools": ["bash", "web_browse"],    // Optional. Omit for all tools.
                    \\      "timeout_seconds": 300,             // Optional. Timeout in seconds (0 = no limit).
                    \\      "inherited_context": "last:5"        // Optional. Mode for parent history inheritance.
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
        .system_prompt = spawn_sub_agent_tool_system_prompt,
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
            allocator.free(sa.instruction);
            allocator.free(sa.agent_name);
        }
        sub_agents_list.deinit(allocator);
    }

    for (agents_array.items) |agent_val| {
        const agent_obj = agent_val.object;
        const instr_val = agent_obj.get("instruction") orelse {
            return error.MissingSubAgentInstruction;
        };

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

        // Parse required "agent_name" field — name of a sub-agent
        // from `LlmConfig.sub_agents` to apply as an overlay on the
        // orchestrator's defaults. Also used as the sub-agent's label
        // in the result XML. Must be a non-empty string. Length is
        // capped at 256 chars as a parse-time guard against
        // absurdly long input. Resolution (and "not found" detection)
        // is deferred to `LlmConfig.resolveSubAgent` at spawn time.
        const an_val = agent_obj.get("agent_name") orelse {
            return error.MissingSubAgentAgentName;
        };
        if (an_val != .string or an_val.string.len == 0) {
            return error.MissingSubAgentAgentName;
        }
        if (an_val.string.len > 256) {
            return error.AgentNameTooLong;
        }
        const agent_name = try allocator.dupe(u8, an_val.string);
        errdefer allocator.free(agent_name);

        try sub_agents_list.append(allocator, .{
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
    // Tests live in spawn_sub_agent_test.zig.
}

const spawn = @import("spawn_sub_agent.zig");

test "parse_sub_agents - inherited_context 'last:3' is parsed into SubAgentInput" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x","inherited_context":"last:3"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents.len == 1);
    try std.testing.expect(parsed.sub_agents[0].inherited_context != null);
    try std.testing.expectEqualStrings("last:3", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - omitted inherited_context is null" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents[0].inherited_context == null);
}

test "parse_sub_agents - inherited_context 'none' is parsed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","inherited_context":"none"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("none", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - inherited_context 'all' is parsed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","inherited_context":"all"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("all", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - inherited_context is freed by deinit (ASan-safe)" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","inherited_context":"last:5"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    parsed.deinit(alloc); // Must not leak; testing.allocator will assert.
    // No explicit expect — if it leaks, testing.allocator fails the test on deinit.
}

test "parse_sub_agents - invalid inherited_context mode returns InvalidInheritedContextMode" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","inherited_context":"last:5x"}]}
    ;
    try std.testing.expectError(error.InvalidInheritedContextMode, spawn.parse_sub_agents(alloc, input_json, 20));
}

// -------------------------------------------------------------------------
// parse_sub_agents — agent_name (REQUIRED, label + config-driven selection)
// -------------------------------------------------------------------------
//
// Tests the required `agent_name` field. It serves two purposes:
//   1. The label that appears in the result XML's <agent name="..."> tag.
//   2. The name looked up in LlmConfig.sub_agents to apply as an
//      overlay on the orchestrator's defaults.

test "parse_sub_agents - agent_name is parsed into SubAgentInput" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"code-reviewer","instruction":"do x"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents.len == 1);
    try std.testing.expectEqualStrings("code-reviewer", parsed.sub_agents[0].agent_name);
}

test "parse_sub_agents - missing agent_name returns MissingSubAgentAgentName" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"instruction":"do x"}]}
    ;
    try std.testing.expectError(error.MissingSubAgentAgentName, spawn.parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - empty string agent_name returns MissingSubAgentAgentName" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"","instruction":"do x"}]}
    ;
    try std.testing.expectError(error.MissingSubAgentAgentName, spawn.parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - agent_name too long (>256 chars) returns AgentNameTooLong" {
    const alloc = std.testing.allocator;
    // 300-char agent_name value
    var long_name_buf: [310]u8 = undefined;
    @memset(&long_name_buf, 'x');
    const long_name = long_name_buf[0..300];

    var input_buf: [512]u8 = undefined;
    const prefix = "{\"sub_agents\":[{\"agent_name\":\"";
    @memcpy(input_buf[0..prefix.len], prefix);
    @memcpy(input_buf[prefix.len..][0..long_name.len], long_name);
    const suffix = "\",\"instruction\":\"do x\"}]}";
    @memcpy(input_buf[prefix.len + long_name.len ..][0..suffix.len], suffix);
    const input_json = input_buf[0 .. prefix.len + long_name.len + suffix.len];

    try std.testing.expectError(error.AgentNameTooLong, spawn.parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - agent_name is freed by deinit (ASan-safe)" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"code-reviewer","instruction":"do x"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    parsed.deinit(alloc); // Must not leak; testing.allocator fails on deinit if it does.
}

test "parse_sub_agents - multiple sub_agents each carry their own agent_name" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[
        \\  {"agent_name":"reviewer","instruction":"x"},
        \\  {"agent_name":"explorer","instruction":"x"},
        \\  {"agent_name":"writer","instruction":"x"}
        \\]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), parsed.sub_agents.len);
    try std.testing.expectEqualStrings("reviewer", parsed.sub_agents[0].agent_name);
    try std.testing.expectEqualStrings("explorer", parsed.sub_agents[1].agent_name);
    try std.testing.expectEqualStrings("writer", parsed.sub_agents[2].agent_name);
}
