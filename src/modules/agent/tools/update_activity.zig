const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// update_activity tool - Updates the agent's current thinking/thought activity
/// This is used to share internal reasoning with other agents without generating a response
pub const UpdateActivityInput = struct {
    /// The current thought or thinking process to record as activity
    thought: []const u8,
};

pub const update_activity_tool = AgentTool{
    .type = "function",
    .function = AgentToolFunction{
        .name = "update_activity",
        .description = "MANDATORY after every LLM response. Update the agent's current thinking, reasoning, or what the agent is currently working on. Always include: timestamp, session_id, current working directory (cwd). If reading files, include the file paths. If writing files, include the file paths. Include reasoning: analyzing, planning, researching, debugging, implementing, testing, reviewing, searching, or coordinating with other agents.",
        .parameters = ToolParameters{
            .type = "object",
            .properties = &.{
                ToolProperty{
                    .name = "thought",
                    .type = "string",
                    .description = "Current thought/reasoning. Always: timestamp, session_id, cwd. If reading/writing files, include paths. Example: \"[2025-01-15 10:30] session_123 @ /project | Reading main.zig | Planning refactor\"",
                },
            },
            .required = &.{"thought"},
        },
    },
};
