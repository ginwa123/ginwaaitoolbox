const std = @import("std");

/// Kerjabot-specific configuration
pub const KerjabotConfig = struct {
    model: []const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: ?[]const u8 = null,
};

/// Workflow state for tracking progress
pub const WorkflowState = struct {
    current_step: u32 = 0,
    total_steps: u32 = 1,
    step_name: []const u8 = "init",
};

/// Extended message with kerjabot metadata
pub const KerjabotMessage = struct {
    role: []const u8,
    content: []const u8,
    timestamp: i64,
    metadata: ?[]const u8 = null,
};

/// Full kerjabot session structure
pub const KerjabotSession = struct {
    session_id: []const u8,
    created_at: i64,
    agent_type: []const u8,
    config: KerjabotConfig,
    workflow_state: WorkflowState,
    messages: []KerjabotMessage,
};
