//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

// Enable TLS support for HTTP client
/// Early panic log file path - set before main() runs
/// This allows panic handler to write to log file even before logger is initialized
var panic_log_path: ?[]const u8 = null;

pub fn getPanicLogPath() ?[]const u8 {
    return panic_log_path;
}

pub fn setPanicLogPath(path: []const u8) void {
    panic_log_path = path;
}

/// Panic handler that logs to file and notifies SSE clients
fn panicHandler(comptime message: []const u8, _: ?*std.builtin.StackTrace) noreturn {
    // Get stack trace if available
    var stack_buffer: [64]std.builtin.StackTrace = undefined;
    var captured_stack: ?*std.builtin.StackTrace = null;

    // Try to capture current stack trace
    if (std.debug.getStackTrace(&stack_buffer)) |stack| {
        captured_stack = stack;
    }

    // Build panic log message
    var panic_buf: std.ArrayList(u8) = std.ArrayList(u8).init(std.heap.page_allocator);
    defer panic_buf.deinit();

    panic_buf.writer().print("=== PANIC ===\n", .{}) catch {};
    panic_buf.writer().print("Message: {s}\n", .{message}) catch {};

    if (captured_stack) |stack| {
        panic_buf.writer().print("Stack trace:\n", .{}) catch {};
        std.debug.formatStackTrace(stack, std.heap.page_allocator, panic_buf.writer()) catch {};
    }
    panic_buf.writer().print("=============\n", .{}) catch {};

    const panic_log: []const u8 = panic_buf.items;

    // Write to panic log file if path is set
    if (panic_log_path) |path| {
        const file = std.fs.openFileAbsolute(path, .{ .mode = .append_to_file }) catch null;
        if (file) |f| {
            f.writeAll(panic_log) catch {};
            f.close();
        }
    }

    // Also write to stderr for visibility
    std.debug.print("{s}", .{panic_log});

    // Broadcast panic to all connected TUI clients via SSE
    http_server.broadcastPanic(panic_log);

    // Exit with error code
    std.process.exit(1);
}

pub const std_options: std.Options = .{
    .http_disable_tls = false,
    .panic = panicHandler,
};

// Module exports - these are available via @import("nalarcore")
pub const agent = @import("modules/agent/agent.zig");
pub const prompt = @import("modules/agent/prompt.zig");
pub const sqlite = @import("modules/databases/sqlite/sqlite.zig");
pub const bash_tool = @import("modules/agent/tools/bash.zig");
pub const tool_models = @import("modules/agent/tools/models.zig");
pub const set_agent_properties = @import("modules/agent/tools/change_agent.zig");
pub const get_skill_tool = @import("modules/agent/tools/get_skill.zig");
pub const remove_skill_tool = @import("modules/agent/tools/remove_skill.zig");
pub const list_skills_tool = @import("modules/agent/tools/list_skills.zig");
pub const http_server = @import("modules/http_server/http_server.zig");
pub const logger = @import("modules/logger/logger.zig");
pub const migrations = @import("modules/databases/sqlite/migrations.zig");
pub const ai_workflow = @import("ai_workflow/tui/tui_workflow.zig");
pub const session_monitor = @import("modules/session/session_monitor.zig");
pub const ai_workflow_models = @import("ai_workflow/tui/models.zig");
pub const loop_detector = @import("modules/agent/tools/loop_detector.zig");
pub const skills = @import("modules/agent/tools/skills.zig");
pub const config = @import("modules/config/config.zig");
pub const helperTool = @import("modules/agent/tools/helper.zig");
pub const read_file = @import("modules/agent/tools/read_file.zig");
pub const write_file = @import("modules/agent/tools/write_file.zig");
pub const text_replace = @import("modules/agent/tools/text_replace.zig");
pub const search_tool = @import("modules/agent/tools/search.zig");
pub const session = @import("modules/session/mod.zig");
pub const text_replace_tool = @import("modules/agent/tools/text_replace.zig");
pub const lsp_client = @import("modules/agent/tools/lsp_client.zig");



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
    _ = @import("ai_workflow/tui/build_messages_for_agent.zig");
    _ = @import("modules/session/cancellation_registry.zig");
    _ = @import("ai_workflow/tui/get_current_agent_by_session_id.zig");
    _ = @import("ai_workflow/tui/get_messages.zig");
    _ = @import("ai_workflow/tui/get_session_by_dir.zig");
    _ = @import("ai_workflow/tui/get_tree_dir.zig");
    _ = @import("ai_workflow/tui/handle_bash_tool.zig");
    _ = @import("ai_workflow/tui/handle_set_agent_properties.zig");
    _ = @import("ai_workflow/tui/handle_content_filter.zig");
    _ = @import("ai_workflow/tui/handle_tool.zig");
    _ = @import("ai_workflow/tui/handle_search_tool.zig");
    _ = @import("ai_workflow/tui/handle_write_file_tool.zig");
    _ = @import("ai_workflow/tui/handle_text_replace_tool.zig");
    _ = @import("ai_workflow/tui/mark_message_not_for_llm.zig");
    _ = @import("ai_workflow/tui/models.zig");
    _ = @import("ai_workflow/tui/run_agentic_loop.zig");
    _ = @import("ai_workflow/tui/save_message.zig");
    _ = @import("ai_workflow/tui/send_error.zig");
    _ = @import("ai_workflow/tui/send_response.zig");
    _ = @import("ai_workflow/tui/send_tool_result.zig");
    _ = @import("ai_workflow/tui/transform_llm_history_to_agent_messages.zig");
    _ = @import("ai_workflow/tui/tui_workflow.zig");
    _ = @import("modules/session/session_monitor.zig");
    _ = @import("modules/agent/tools/write_file.zig");
    _ = @import("modules/agent/tools/write_file_test.zig");
    _ = @import("modules/agent/tools/text_replace.zig");
    _ = @import("modules/agent/tools/text_replace_test.zig");
    _ = @import("modules/agent/tools/search.zig");
    _ = @import("modules/agent/tools/search_test.zig");
    _ = @import("modules/agent/mcp/mcp/mcp_server.zig");
    _ = @import("modules/http/http_client.zig");
}
