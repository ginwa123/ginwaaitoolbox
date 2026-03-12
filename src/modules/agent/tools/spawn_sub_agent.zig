const std = @import("std");
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

pub const SubAgentInput = struct {
    name: []const u8,
    instruction: []const u8,
};

pub const SubAgentsInput = struct {
    sub_agents: []const SubAgentInput,

    pub fn deinit(self: *const SubAgentsInput, allocator: std.mem.Allocator) void {
        for (self.sub_agents) |sa| {
            allocator.free(sa.name);
            allocator.free(sa.instruction);
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
        \\Input format (XML):
        \\<sub_agents>
        \\  <sub_agent>
        \\    <name>agent1</name>
        \\    <instruction>task description</instruction>
        \\  </sub_agent>
        \\</sub_agents>
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "xml_input",
                    .type = "string",
                    .description =
                    \\XML-formatted sub-agent specifications.
                    \\Max 20 sub-agents allowed.
                    \\Format: <sub_agents><sub_agent><name>...</name><instruction>...</instruction></sub_agent></sub_agents>
                    ,
                },
            },
            .required = &.{"xml_input"},
        },
    },
};

/// Parse XML input to extract sub-agents
/// Returns error if XML is invalid or more than max_agents
pub fn parseSubAgents(
    allocator: std.mem.Allocator,
    xml_input: []const u8,
    max_agents: usize,
) !SubAgentsInput {
    var sub_agents_list = std.ArrayList(SubAgentInput).empty;

    // Find all <sub_agent> blocks
    var remaining = xml_input;
    var count: usize = 0;
    while (true) {
        // Check max limit before parsing
        if (count >= max_agents) {
            sub_agents_list.deinit(allocator);
            return error.TooManySubAgents;
        }
        
        const agent_start = std.mem.indexOf(u8, remaining, "<sub_agent>") orelse break;
        const agent_content_start = agent_start + "<sub_agent>".len;
        const agent_end = std.mem.indexOf(u8, remaining[agent_content_start..], "</sub_agent>") orelse {
            sub_agents_list.deinit(allocator);
            return error.InvalidSubAgentFormat;
        };
        const agent_content = remaining[agent_content_start..agent_content_start + agent_end];

        // Extract name
        const name_start = std.mem.indexOf(u8, agent_content, "<name>") orelse {
            sub_agents_list.deinit(allocator);
            return error.MissingSubAgentName;
        };
        const name_content_start = name_start + "<name>".len;
        const name_end = std.mem.indexOf(u8, agent_content[name_content_start..], "</name>") orelse {
            sub_agents_list.deinit(allocator);
            return error.MissingSubAgentName;
        };
        const name = try allocator.dupe(u8, agent_content[name_content_start..name_content_start + name_end]);

        // Extract instruction
        const instr_start = std.mem.indexOf(u8, agent_content, "<instruction>") orelse {
            sub_agents_list.deinit(allocator);
            return error.MissingSubAgentInstruction;
        };
        const instr_content_start = instr_start + "<instruction>".len;
        const instr_end = std.mem.indexOf(u8, agent_content[instr_content_start..], "</instruction>") orelse {
            sub_agents_list.deinit(allocator);
            return error.MissingSubAgentInstruction;
        };
        const instruction = try allocator.dupe(u8, agent_content[instr_content_start..instr_content_start + instr_end]);

        try sub_agents_list.append(allocator, .{
            .name = name,
            .instruction = instruction,
        });
        
        count += 1;
        remaining = remaining[agent_content_start + agent_end + "</sub_agent>".len..];
    }

    if (count == 0) {
        return error.NoSubAgents;
    }

    return SubAgentsInput{
        .sub_agents = try sub_agents_list.toOwnedSlice(allocator),
    };
}

test {
    _ = @import("spawn_sub_agent_test.zig");
}
