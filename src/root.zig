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
// it should import from folder modules only
pub const agent = @import("modules/agent/Agent.zig");
pub const llm_models = @import("modules/agent/LLMModels.zig");
pub const prompt = @import("modules/agent/prompts.zig");
pub const sqlite = @import("modules/databases/sqlite/Sqlite.zig");
pub const bash_tool = @import("modules/agent/tools/bash.zig");
pub const tool_models = @import("modules/agent/tools/schemas.zig");
pub const lsp_types = @import("modules/agent/tools/lsp_types.zig");
pub const tools = @import("modules/agent/tools/tools.zig");
pub const change_agent = @import("modules/agent/tools/change_agent.zig");

pub const get_skill_tool = @import("modules/agent/tools/get_skill.zig");
pub const remove_skill_tool = @import("modules/agent/tools/remove_skill.zig");
pub const list_skills_tool = @import("modules/agent/tools/list_skills.zig");
pub const agents = @import("modules/agent/tools/agents.zig");
pub const list_agents = @import("modules/agent/tools/list_agents.zig");

pub const set_agent_properties = @import("modules/agent/tools/set_agent_properties.zig");

pub const http_server = @import("modules/http_server/HttpServer.zig");
pub const http_client = @import("modules/http/HttpClient.zig");
pub const logger = @import("modules/logger/Logger.zig");
pub const migrations = @import("modules/databases/sqlite/Migrations.zig");
pub const ai_workflow = @import("ai_workflow/tui/workflow.zig");
pub const session_monitor = @import("modules/session/SessionMonitor.zig");
pub const loop_detector = @import("modules/agent/tools/loop_detector.zig");
pub const skills = @import("modules/agent/tools/skills.zig");
pub const add_skill = @import("modules/agent/tools/add_skill.zig");
pub const add_agent = @import("modules/agent/tools/add_agent.zig");
pub const remove_agent = @import("modules/agent/tools/remove_agent.zig");

pub const config = @import("modules/config/Config.zig");
pub const helperTool = @import("modules/agent/tools/helper.zig");
pub const read_file = @import("modules/agent/tools/read_file.zig");
pub const write_file = @import("modules/agent/tools/write_file.zig");
pub const remove_file = @import("modules/agent/tools/remove_file.zig");
pub const system_folder = @import("modules/system_folder/system_folder.zig");


pub const web_search = @import("modules/agent/tools/web_search.zig");
pub const glob_tool = @import("modules/agent/tools/glob.zig");
pub const search_tool = @import("modules/agent/tools/search.zig");
pub const session = @import("modules/session/mod.zig");
pub const text_replace_tool = @import("modules/agent/tools/text_replace.zig");
pub const cronjob = @import("modules/cronjob/mod.zig");
pub const helpers = @import("helpers/mod.zig");
pub const kerjabot_get_session = @import("ai_workflow/tui/llm_history.zig");
pub const kerjabot_create_session = @import("ai_workflow/tui/llm_history.zig");
pub const kerjabot_get_list_session = @import("ai_workflow/tui/llm_history.zig");
pub const tui_check_session_exists = @import("ai_workflow/tui/llm_history.zig");
pub const session_helpers = @import("ai_workflow/tui/llm_history.zig");
pub const session_db = @import("ai_workflow/tui/llm_history.zig");
pub const llm_history = @import("ai_workflow/tui/llm_history.zig");
pub const session_table = @import("ai_workflow/tui/session_table.zig");
pub const spawn_sub_agent = @import("modules/agent/tools/spawn_sub_agent.zig");
pub const http_handlers = @import("ai_workflow/tui/http_handlers/mod.zig");

test {
    _ = @import("ai_workflow/tui/test_runner.zig");
    _ = @import("modules/agent/test_runner.zig");
    _ = @import("apps/tui/test_runner.zig");
    _ = @import("modules/session/test_runner.zig");
}
