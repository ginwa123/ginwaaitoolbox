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
        .description = "Transfer the current task to another specialized agent. Available agents: GeneralAgent - understands and routes user requests and clarifies ambiguities. ExplorationAgent - read-only discovery, lists files, searches codebase, browses the internet. PlanningAgent - designs solutions and creates structured step-by-step plans. ExecutingAgent - implements and delivers the final output based on a plan. Return agent and message.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "agent",
                    .type = "string",
                    .description = "Name of the agent to transfer to. Must be one of: GeneralAgent, ExplorationAgent, PlanningAgent, ExecutingAgent",
                },
                .{
                    .name = "message",
                    .type = "string",
                    .description = "Full context, findings, or task description to pass to the target agent. Be as detailed as possible.",
                },
            },
            .required = &.{ "agent", "message" },
        },
    },
};
