const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// set_agent_properties tool - placeholder stub for compilation
/// The actual implementation needs to be completed

pub const SetAgentPropertiesInput = struct {
    temperature: ?f32 = null,
    is_thinking: ?bool = null,
};

pub const SetAgentPropertiesResult = struct {
    temperature: ?f32,
    is_thinking: ?bool,
};

pub const SetAgentPropertiesTool = AgentTool{
    .type = "function",
    .function = AgentToolFunction{
        .name = "set_agent_properties",
        .description = "Set agent properties like temperature and thinking mode",
        .parameters = ToolParameters{
            .type = "object",
            .properties = &.{
                ToolProperty{
                    .name = "temperature",
                    .type = "number",
                    .description = "Temperature for the agent (0.0 to 1.0)",
                },
                ToolProperty{
                    .name = "is_thinking",
                    .type = "boolean",
                    .description = "Enable or disable thinking mode",
                },
            },
            .required = &.{},
        },
    },
};
