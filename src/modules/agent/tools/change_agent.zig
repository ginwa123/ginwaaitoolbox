const std = @import("std");
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

pub const ChangeAgentToolResult = struct {
    agent: []const u8,
    message: []const u8,
    temperature: ?f32 = null, // default null if omitted
    is_thinking: ?bool = null, // default null if omitted

};

pub const ChangeAgentTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "change_agent_tool",
        .description = "Transfer the current task to another agent and dynamically configure its runtime behavior — including reasoning depth (is_thinking) and output temperature. Use this to hand off work and tune how the next agent thinks.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "agent",
                    .type = "string",
                    .description = "The agent to hand off to. One of: ExplorationAgent, PlanningAgent, ExecutingAgent.",
                },
                .{
                    .name = "message",
                    .type = "string",
                    .description = "Full context, state, and instructions to pass to the next agent. Include everything it needs — do not assume shared memory.",
                },
                .{
                    .name = "temperature",
                    .type = "number",
                    .description = "Dynamically sets output randomness for the next agent (0.0–1.0). " ++
                        "LOW (0.0–0.2): high confidence, deterministic task, routing or verification. " ++
                        "MEDIUM (0.3–0.5): moderate confidence, planning or judgment required. " ++
                        "HIGH (0.6–1.0): low confidence, prior attempt failed, problem is ambiguous or open-ended.",
                },
                .{
                    .name = "is_thinking",
                    .type = "boolean",
                    .description = "Dynamically enables or disables deep reasoning for the next agent. " ++
                        "true: multi-step logic, architecture decisions, tradeoff analysis, ambiguity resolution, multi-file changes. " ++
                        "false: simple routing, direct lookups, mechanical or single-step execution. " ++
                        "PlanningAgent: always true. Default: false.",
                },
            },
            .required = &.{ "agent", "message", "temperature" },
        },
    },
};

test {
    _ = @import("change_agent_test.zig");
}
