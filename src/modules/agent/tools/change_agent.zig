const std = @import("std");
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

pub const ChangeAgentToolResult = struct {
    agent: []const u8,
    message: []const u8,
};


pub const ChangeAgentTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "change_agent_tool",
        .description = "Transfer the task to another specialized agent",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "agent",
                    .type = "string",
                    .description = "Agent name to transfer to for example: 'coder', 'reviewer', 'tester'",
                },
                .{
                    .name = "message",
                    .type = "string",
                    .description = "Message or task to pass to the target agent",
                },
            },
            .required = &.{ "agent", "message" },
        },
    },
};
