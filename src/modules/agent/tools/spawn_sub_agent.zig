const std = @import("std");
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

pub const SubAgentInput = struct {
    name: []const u8,
    instruction: []const u8,
    tools: ?[]const []const u8 = null, // optional list of tool names to allow
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
        }
        allocator.free(self.sub_agents);
    }
};

pub const spawnSubAgentTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "spawn_sub_agent",
        .description =
        \\Spawn up to 20 parallel sub-agents, each with its own fresh context.
        \\Each sub-agent receives only its specific instruction (no parent context).
        \\Results are returned as separate tool result messages.
        \\
        \\Input format (JSON string):
        \\{"sub_agents": [{"name": "agent1", "instruction": "task", "tools": ["bash", "read_file", ...]}, ...]}
        \\- "tools" field is optional. If omitted, all default tools are available.
        \\- If specified, only the listed tools will be available to that sub-agent.
        \\- Available tools: bash, read_file, write_file, text_replace, search, list_skills, get_skill, remove_skill
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "json_input",
                    .type = "string",
                    .description =
                    \\JSON-formatted sub-agent specifications as a string.
                    \\Max 20 sub-agents allowed.
                    \\Format: {"sub_agents": [{"name": "...", "instruction": "...", "tools": ["bash", "read_file", ...]}, ...]}
                    \\- "tools" is optional. If omitted, all default tools are available.
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
pub fn parseSubAgents(
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
                return parseSubAgents(allocator, json_input_val.string, max_agents);
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
    const agents_array = agents_val.array;

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

        try sub_agents_list.append(allocator, .{
            .name = name,
            .instruction = instruction,
            .tools = tools,
        });
    }

    return SubAgentsInput{
        .sub_agents = try sub_agents_list.toOwnedSlice(allocator),
    };
}

test {
    _ = @import("spawn_sub_agent_test.zig");
}
