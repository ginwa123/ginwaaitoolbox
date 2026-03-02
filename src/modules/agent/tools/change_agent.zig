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

// pub fn change_agent_tool(tool: ChangeAgentTool, input: ChangeAgentToolResult) !BashResult {
//     const result = try std.ChildProcess.exec(.{
//         .allocator = tool.allocator,
//         .argv = &.{ "python3", "-m", "agentic.tools.change_agent" },
//         .stdin_behavior = .Ignore,
//         .stdout_behavior = .Inherit,
//         .stderr_behavior = .Inherit,
//     });
//     defer result.deinit();
//
//     return BashResult{
//         .stdout = result.stdout,
//         .stderr = result.stderr,
//         .exit_code = result.exit_code,
//     };
// }

pub const ChangeAgentTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "change_agent_tool",
        .description = "Transfer the current task to another specialized agent. Available agents: GeneralAgent, ExplorationAgent, PlanningAgent, ExecutingAgent. Set temperature based on your confidence — low confidence = higher temperature. return agent, message, temperature, is_thinking",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "agent",
                    .type = "string",
                    .description = "Target agent. Must be one of: GeneralAgent, ExplorationAgent, PlanningAgent, ExecutingAgent",
                },
                .{
                    .name = "message",
                    .type = "string",
                    .description = "Full context and handoff payload to pass to the target agent.",
                },
                .{
                    .name = "temperature",
                    .type = "number",
                    .description = "Temperature for the next agent (0.0 - 1.0). " ++
                        "Use LOW (0.0-0.2) when the task is factual or deterministic, you have high confidence, or the agent is routing or verifying — precision matters more than creativity. " ++
                        "Use MEDIUM (0.3-0.5) when the task requires reasoning or judgment, you have medium confidence, or the agent is planning a solution. " ++
                        "Use HIGH (0.6-1.0) when you have low confidence, the current approach is not working, a previous attempt failed, or the problem is ambiguous with no clear single solution.",
                },
                .{
                    .name = "is_thinking",
                    .type = "boolean",
                    .description = "Enable adaptive deep reasoning for this agent call. " ++
                        "Use true when the task requires multi-step logic, architectural decisions, " ++
                        "tradeoff analysis, ambiguity resolution, or multi-file changes. " ++
                        "Use false for simple routing, direct lookups, mechanical transformations, " ++
                        "file reading, or straightforward single-step execution. " ++
                        "PlanningAgent: always true. " ++
                        "GeneralAgent and ExplorationAgent: always false. " ++
                        "ExecutingAgent: always false. " ++
                        "Default: false.",
                },
            },
            .required = &.{ "agent", "message", "temperature" },
        },
    },
};
