const std = @import("std");
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

/// Result of set_agent_properties tool - dynamically changes current agent's runtime behavior
pub const SetAgentPropertiesResult = struct {
    temperature: ?f32 = null, // null means no change
    is_thinking: ?bool = null, // null means no change
};

pub const SetAgentPropertiesTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_agent_properties",
        .description = "Dynamically change the current agent's runtime behavior - adjust temperature (randomness) and toggle deep reasoning mode (is_thinking). Use this to fine-tune how the agent thinks during this conversation.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "temperature",
                    .type = "number",
                    .description = "Set output randomness for the current agent (0.0–1.0). " ++
                        "LOW (0.0–0.4): high confidence, deterministic, factual responses. " ++
                        "MEDIUM (0.5–0.7): balanced creativity and accuracy. " ++
                        "HIGH (0.8–1.0): high creativity, more varied outputs. " ++
                        "Omit or null to keep current value.",
                },
                .{
                    .name = "is_thinking",
                    .type = "boolean",
                    .description = "Toggle deep reasoning mode for the current agent. " ++
                        "true: enables multi-step logic, architecture decisions, tradeoff analysis. " ++
                        "false: disables deep reasoning for simple routing or mechanical tasks. " ++
                        "Omit or null to keep current value.",
                },
            },
            .required = &.{},
        },
    },
};
