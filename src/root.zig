//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

// Module exports - these are available via @import("tree1")
pub const agent = @import("modules/agent/agent.zig");
pub const prompt = @import("modules/agent/prompt.zig");
pub const sqlite = @import("modules/databases/sqlite/sqlite.zig");
pub const bash_tool = @import("modules/agent/tools/bash.zig");
pub const tool_models = @import("modules/agent/tools/models.zig");
pub const change_agent_tool = @import("modules/agent/tools/change_agent.zig");
pub const get_skill_tool = @import("modules/agent/tools/get_skill.zig");
pub const list_skills_tool = @import("modules/agent/tools/list_skills.zig");
pub const ipc = @import("modules/ipc/ipc.zig");
pub const logger = @import("modules/logger/logger.zig");
pub const migrations = @import("modules/databases/sqlite/migrations.zig");
pub const ai_workflow = @import("ai_workflow/tui_workflow.zig");
pub const ai_workflow_models = @import("ai_workflow/models.zig");
pub const loop_detector = @import("modules/agent/tools/loop_detector.zig");
pub const skills = @import("modules/agent/tools/skills.zig");
pub const config = @import("modules/config/config.zig");
pub const helperTool = @import("modules/agent/tools/helper.zig");

pub fn bufferedPrint() !void {
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test {
    // Import all ai_workflow modules to ensure their tests run
    _ = @import("ai_workflow/build_messages_for_agent.zig");
    _ = @import("ai_workflow/cancellation_registry.zig");
    _ = @import("ai_workflow/get_current_agent_by_session_id.zig");
    _ = @import("ai_workflow/get_messages.zig");
    _ = @import("ai_workflow/get_session_by_dir.zig");
    _ = @import("ai_workflow/get_tree_dir.zig");
    _ = @import("ai_workflow/handle_bash_tool.zig");
    _ = @import("ai_workflow/handle_change_agent_tool.zig");
    _ = @import("ai_workflow/handle_content_filter.zig");
    _ = @import("ai_workflow/handle_tool.zig");
    _ = @import("ai_workflow/mark_message_not_for_llm.zig");
    _ = @import("ai_workflow/models.zig");
    _ = @import("ai_workflow/run_agentic_loop.zig");
    _ = @import("ai_workflow/save_message.zig");
    _ = @import("ai_workflow/send_error.zig");
    _ = @import("ai_workflow/send_response.zig");
    _ = @import("ai_workflow/send_tool_result.zig");
    _ = @import("ai_workflow/transform_llm_history_to_agent_messages.zig");
    _ = @import("ai_workflow/tui_workflow.zig");
}
