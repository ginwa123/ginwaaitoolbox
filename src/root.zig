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
    gserverz.broadcastPanic(panic_log);

    // Exit with error code
    std.process.exit(1);
}

pub const std_options: std.Options = .{
    .http_disable_tls = false,
    .panic = panicHandler,
};

var global_ctx: ?*ContextIPCTui = null;

pub fn getSingleton() anyerror!*ContextIPCTui {
    return global_ctx orelse error.GlobalContextNotInitialized;
}

pub fn setSingleton(ctx: *ContextIPCTui) !void {
    global_ctx = ctx;
}

pub const ContextIPCTui = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    llm_config: *const config.LlmConfig,
    logger: *logger.Logger,
    environment: ?*const std.process.Environ.Map,
    active_loops: *ai_mod.active_loops,
    event_bus: *event_bus.EventBus,
    server: *gserverz.GinwaServer,
    session_to_client_ids: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([16]u8)) = .empty,
    session_map_lock: SpinMutex = .{},
    on_disconnect_cb: ?*const fn (client_id: [16]u8) void = null,
    group_emit_session_create: std.Io.Group,
};

/// Simple spinlock mutex for thread safety
const SpinMutex = struct {
    state: u8 = 0,
    pub fn init() SpinMutex {
        return .{ .state = 0 };
    }
    pub fn lock(self: *SpinMutex) void {
        while (@cmpxchgStrong(u8, &self.state, 0, 1, .acquire, .acquire) != null) {}
    }
    pub fn unlock(self: *SpinMutex) void {
        @atomicStore(u8, &self.state, 0, .release);
    }
};

/// Register a session -> client_id mapping (appends to list)
pub fn registerSessionClient(session_id: []const u8, client_id: [16]u8) !void {
    const di = try getSingleton();

    di.session_map_lock.lock();
    defer di.session_map_lock.unlock();

    // Check if session already has a client list
    if (di.session_to_client_ids.getPtr(session_id)) |list| {
        // Check if client already registered
        for (list.items) |existing_id| {
            var equal = true;
            for (existing_id, client_id) |a, b| {
                if (a != b) {
                    equal = false;
                    break;
                }
            }
            if (equal) return; // already registered
        }
        // Append new client to existing list
        try list.append(di.allocator, client_id);
    } else {
        // Create new list for this session
        var list = std.ArrayListUnmanaged([16]u8).empty;
        try list.append(di.allocator, client_id);
        try di.session_to_client_ids.put(di.allocator, session_id, list);
    }
}

/// Unregister a session -> client_id mapping (removes all clients for session)
pub fn unregisterSessionClient(session_id: []const u8) void {
    const di = getSingleton() catch return;

    di.session_map_lock.lock();
    defer di.session_map_lock.unlock();

    if (di.session_to_client_ids.getPtr(session_id)) |list| {
        // Clear the entire session entry
        list.deinit(di.allocator);
        _ = di.session_to_client_ids.remove(session_id);
    }
}

/// Get client_id for a session, if registered (returns first client if multiple)
pub fn getClientIdForSession(session_id: []const u8) ?[16]u8 {
    const di = getSingleton() catch return null;

    di.session_map_lock.lock();
    defer di.session_map_lock.unlock();

    if (di.session_to_client_ids.getPtr(session_id)) |list| {
        if (list.items.len > 0) {
            return list.items[0];
        }
    }
    return null;
}

/// Get list of client_ids for a session
/// Returns owned memory that caller must free, or null if session not found
pub fn getListClientsForSession(session_id: []const u8, allocator: std.mem.Allocator) !?[][16]u8 {
    const di = try getSingleton();

    di.session_map_lock.lock();
    defer di.session_map_lock.unlock();

    const list = di.session_to_client_ids.get(session_id) orelse return null;
    if (list.items.len == 0) return null;

    const copy = try allocator.alloc([16]u8, list.items.len);
    for (list.items, 0..) |client_id, i| {
        copy[i] = client_id;
    }
    return copy;
}

/// Find session_id by client_id (reverse lookup)
pub fn getSessionIdForClient(client_id: [16]u8) ?[]const u8 {
    const di = getSingleton() catch return null;

    di.session_map_lock.lock();
    defer di.session_map_lock.unlock();

    var it = di.session_to_client_ids.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.items) |v| {
            var equal = true;
            for (v, client_id) |a, b| {
                if (a != b) {
                    equal = false;
                    break;
                }
            }
            if (equal) return entry.key_ptr.*;
        }
    }
    return null;
}

/// Handle client disconnect - called by SseManager on_disconnect callback
pub fn handleClientDisconnect(client_id: [16]u8) void {
    const di = getSingleton() catch return;
    const ev_bus = di.event_bus;

    if (di.on_disconnect_cb) |cb| {
        cb(client_id);
    }
    // Also clean up session mapping
    if (getSessionIdForClient(client_id)) |session_id| {
        unregisterSessionClient(session_id);

        const listClients = getListClientsForSession(session_id, di.allocator) catch |err| {
            std.debug.print("SSE_DEBUG: Failed to get list of clients for session {s}: {any}\n", .{ session_id, err });
            return;
        };

        if (listClients) |clients| {
            if (clients.len == 0) {
                std.debug.print("SSE_DEBUG: No clients left for session {s}\n", .{session_id});
                ev_bus.unsubscribe(session_id);
            }
        } else {
            std.debug.print("SSE_DEBUG: Failed to get list of clients for session {s}\n", .{session_id});
            ev_bus.unsubscribe(session_id);
        }
    }
}

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

pub const http_client = @import("modules/http/HttpClient.zig");
pub const logger = @import("modules/logger/Logger.zig");
pub const migrations = @import("ai_workflow/tui/migration.zig");
pub const session_monitor = @import("modules/session/SessionMonitor.zig");
pub const skill_mod = @import("modules/agent/tools/skills.zig");
pub const add_skill = @import("modules/agent/tools/add_skill.zig");
pub const edit_skill = @import("modules/agent/tools/edit_skill.zig");
pub const add_agent = @import("modules/agent/tools/add_agent.zig");
pub const remove_agent = @import("modules/agent/tools/remove_agent.zig");

pub const config = @import("modules/config/Config.zig");
pub const helperTool = @import("modules/agent/tools/helper.zig");
pub const read_file = @import("modules/agent/tools/read_file.zig");
pub const write_file = @import("modules/agent/tools/write_file.zig");
pub const remove_file = @import("modules/agent/tools/remove_file.zig");
pub const system_folder = @import("modules/system_folder/system_folder.zig");

pub const update_activity = @import("modules/agent/tools/update_activity.zig");

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
pub const workspace_items = @import("ai_workflow/tui/workspace_items_table.zig");
pub const workspace_item_tasks = @import("ai_workflow/tui/workspace_item_tasks_table.zig");
pub const http_response = @import("ai_workflow/tui/http_handlers/http_response.zig");
pub const spawn_sub_agent = @import("modules/agent/tools/spawn_sub_agent.zig");
pub const http_handlers = @import("ai_workflow/tui/http_handlers/mod.zig");
pub const gserverz = @import("modules/custom_http_server/src/http_server.zig");
pub const ai_mod = @import("ai_workflow/tui/mod.zig");
pub const event_bus = @import("modules/event_bus/src/event.zig");

pub const startup = @import("startup.zig");

test {
    _ = @import("ai_workflow/tui/test_runner.zig");
    _ = @import("modules/agent/test_runner.zig");
    _ = @import("modules/http/test_runner.zig");
    _ = @import("modules/session/test_runner.zig");
    _ = @import("modules/logger/test_runner.zig"); // needs Zig 0.16 API updates
}
