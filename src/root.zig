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

pub const std_options: std.Options = .{
    .http_disable_tls = false,
};

var global_ctx: ?*ContextIPCTui = null;

pub fn getSingleton() anyerror!*ContextIPCTui {
    return global_ctx orelse error.GlobalContextNotInitialized;
}

pub fn setSingleton(ctx: *ContextIPCTui) !void {
    global_ctx = ctx;
}

/// Holds the live `LlmConfig` pointer plus the previously-installed one so
/// that in-flight workflows (which captured the old `*const LlmConfig` into a
/// local) keep dereferencing valid memory until the next swap — or until
/// shutdown if no further swap happens.
///
/// The hot-path read (`getLlmConfig`) is a single aligned pointer load and
/// is therefore atomic on all supported platforms. The mutex only protects
/// the swap-and-promote sequence inside `setLlmConfig`.
pub const LlmConfigHolder = struct {
    current: *config.LlmConfig,
    /// Previous pointer, kept alive until the next swap (or shutdown) so
    /// any in-flight workflow that captured the old `*const LlmConfig` does
    /// not dereference freed memory. `null` until the first live reload.
    previous: ?*const config.LlmConfig = null,
    lock: std.Io.Mutex = .init,
};

pub const ContextIPCTui = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    llm_config_holder: LlmConfigHolder,
    logger: *loggermod.Logger,
    environment: ?*const std.process.Environ.Map,
    active_loops: *ai_mod.active_loops,
    event_bus: *event_bus.EventBus,
    server: *gserverz.GinwaServer,

    session_to_client_ids: std.StringHashMapUnmanaged(std.ArrayList([16]u8)) = .empty,
    session_map_lock: std.Io.Mutex = .init,

    on_disconnect_cb: ?*fn (client_id: [16]u8) void = null,
    on_disconnect_lock: std.Io.Mutex = .init,
    group_emit_session_create: std.Io.Group,

    static_dir_path: ?[]const u8 = null,
};

/// Hot-path read. Returns the currently-installed `LlmConfig` pointer.
/// No lock needed — single-word aligned pointer load is atomic on all
/// supported platforms; the lock only protects the swap-and-promote
/// sequence in `setLlmConfig`.
pub fn getLlmConfig(di: *ContextIPCTui) *config.LlmConfig {
    return di.llm_config_holder.current;
}

/// Atomic install. The new pointer must remain valid for the lifetime of
/// the install (typically: until the next call to `setLlmConfig`, or until
/// `freeAllLlmConfigs` runs at shutdown).
///
/// The previously-current pointer is moved into the `previous` slot, and
/// the *previous-previous* pointer (if any) is `deinit`-ed and the
/// allocation freed before this returns. This caps the "pending free"
/// window at exactly one stale `LlmConfig`.
pub fn setLlmConfig(
    di: *ContextIPCTui,
    new_ptr: *config.LlmConfig,
) void {
    const io = di.io;
    di.llm_config_holder.lock.lock(io) catch return;
    defer di.llm_config_holder.lock.unlock(io);

    const pending_previous = di.llm_config_holder.previous;
    di.llm_config_holder.previous = di.llm_config_holder.current;
    di.llm_config_holder.current = new_ptr;

    if (pending_previous) |p| freeLlmConfig(di.allocator, p);
}

/// Free both `current` and `previous` (if any). Called once at shutdown
/// from `main.zig` after the HTTP server has stopped accepting requests.
pub fn freeAllLlmConfigs(di: *ContextIPCTui) void {
    freeLlmConfig(di.allocator, di.llm_config_holder.current);
    if (di.llm_config_holder.previous) |p| freeLlmConfig(di.allocator, p);
    di.llm_config_holder.current = undefined;
    di.llm_config_holder.previous = null;
}

/// Free a single `LlmConfig`: deinit all owned strings/maps then destroy
/// the heap allocation. The `const`-cast is safe because we own the
/// memory — this is the only place we drop the `const`.
fn freeLlmConfig(allocator: std.mem.Allocator, ptr: *const config.LlmConfig) void {
    var mut: *config.LlmConfig = @constCast(ptr);
    mut.deinit();
    allocator.destroy(mut);
}

/// Register a session -> client_id mapping (appends to list)
pub fn registerSessionClient(session_id: []const u8, client_id: [16]u8, is_use_lock: bool) !void {
    _ = is_use_lock;
    var di = try getSingleton();
    const allocator = di.allocator;
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);

    if (di.session_to_client_ids.getPtr(session_id)) |list| {
        // Session already exists — just append if not duplicate
        for (list.items) |existing_id| {
            if (std.mem.eql(u8, &existing_id, &client_id)) return;
        }
        try list.append(allocator, client_id);
        return;
    }

    // New session — build list first
    var list = std.ArrayListUnmanaged([16]u8).empty;
    try list.append(allocator, client_id);

    const result = try di.session_to_client_ids.getOrPut(allocator, session_id);
    if (result.found_existing) {
        // Another thread beat us — discard our list, append to existing
        list.deinit(allocator);
        for (result.value_ptr.items) |existing_id| {
            if (std.mem.eql(u8, &existing_id, &client_id)) return;
        }
        try result.value_ptr.append(allocator, client_id);
    } else {
        // We own the new entry — dupe the key so we can free it later
        const owned_key = try allocator.dupe(u8, session_id);
        result.key_ptr.* = owned_key;
        result.value_ptr.* = list;
    }
}

/// Unregister a session -> client_id mapping (removes all clients for session)
pub fn unregisterSessionClient(session_id: []const u8, is_use_lock: bool) void {
    _ = is_use_lock;
    const di = getSingleton() catch return;
    const allocator = di.allocator;
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);
    if (di.session_to_client_ids.fetchRemove(session_id)) |kv| {
        var list = kv.value;
        list.deinit(allocator);
        allocator.free(kv.key); // safe — we duped this with allocator in register
    }
}

/// Get client_id for a session, if registered (returns first client if multiple)
pub fn getClientIdForSession(session_id: []const u8, is_use_lock: bool) ?[16]u8 {
    _ = is_use_lock;
    const di = getSingleton() catch return null;
    // const io = di.io;
    // di.session_map_lock.lock(io) catch {};
    // defer di.session_map_lock.unlock(io);

    if (di.session_to_client_ids.getPtr(session_id)) |list| {
        if (list.items.len > 0) {
            return list.items[0];
        }
    }
    return null;
}

/// Get list of client_ids for a session
/// Returns an owned copy that the caller MUST free with `allocator.free`.
/// Returns null if the session has no registered clients (or does not exist).
///
/// IMPORTANT: This function used to return a borrowed slice (`list.items`)
/// directly. That was a use‑after‑free waiting to happen — the slice's
/// backing buffer is owned by the `session_to_client_ids` map entry, and
/// the map's `unregisterSessionClient` / `fetchRemove` will `deinit` it
/// the moment any concurrent caller (e.g. the SSE event loop on a
/// POLL.HUP) decides to drop the session. The LLM streaming callback
/// iterated that borrowed slice after `session_map_lock` had been
/// released, hence the segfault. We now copy into a fresh buffer that
/// survives lock release and any concurrent map mutation.
pub fn getListClientsForSession(session_id: []const u8, allocator: std.mem.Allocator, is_use_lock: bool) !?[][16]u8 {
    _ = is_use_lock;
    const di = try getSingleton();
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);

    const list = di.session_to_client_ids.get(session_id) orelse return null;
    if (list.items.len == 0) return null;

    const copy = try allocator.alloc([16]u8, list.items.len);
    @memcpy(copy, list.items);
    return copy;
}

/// Find session_id by client_id (reverse lookup)
pub fn getSessionIdForClient(client_id: [16]u8, is_use_lock: bool) ?[]const u8 {
    _ = is_use_lock;
    const di = getSingleton() catch return null;
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);
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
            if (equal) {
                // ✅ return an owned copy, caller must free
                return di.allocator.dupe(u8, entry.key_ptr.*) catch null;
            }
        }
    }
    return null;
}

/// Handle client disconnect - called by SseManager on_disconnect callback
pub fn handleClientDisconnect(client_id: [16]u8) void {
    const di = getSingleton() catch return;
    const io = di.io;
    const ev_bus = di.event_bus;

    di.on_disconnect_lock.lock(io) catch {};
    defer di.on_disconnect_lock.unlock(io);

    if (di.on_disconnect_cb) |cb| {
        // di.session_map_lock.lock(io) catch {};
        // defer di.session_map_lock.unlock(io);
        cb(client_id);
    }

    // Collect EVERY routing_key that contains this client_id, then
    // unregister each one and drop its event_bus subscription.
    //
    // The previous implementation called `getSessionIdForClient`
    // which returns the FIRST match — for clients connected via the
    // unified SSE endpoint (`unified_events_sse.zig:248-250`), the
    // same client_id is registered under N routing_keys (one per
    // channel: llm, workers, sessions, kanban_column, kanban_task,
    // queue). Unregistering only the first match left the other
    // (N-1) routing_keys as orphans in `session_to_client_ids`,
    // each holding an owned key + a non-empty ArrayList — a slow
    // memory leak across reconnects. See the audit in
    // docs/superpowers/plans/2026-07-01-fix-remaining-fd-leak-risks.md.
    var routing_keys_to_drop: std.ArrayList([]const u8) = .empty;
    defer routing_keys_to_drop.deinit(di.allocator);

    {
        di.session_map_lock.lock(io) catch {};
        defer di.session_map_lock.unlock(io);
        var it = di.session_to_client_ids.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |v| {
                if (std.mem.eql(u8, &v, &client_id)) {
                    // Each routing_key's map entry owns its key string
                    // (registered via `registerSessionClient` → result.key_ptr.*
                    // = owned_key). Dupe it here so the unregister loop
                    // can pass a stable pointer; `unregisterSessionClient`
                    // owns the key and frees it.
                    if (di.allocator.dupe(u8, entry.key_ptr.*)) |duped| {
                        routing_keys_to_drop.append(di.allocator, duped) catch continue;
                    } else |_| {
                        continue;
                    }
                    break;
                }
            }
        }
    }

    for (routing_keys_to_drop.items) |rk| {
        defer di.allocator.free(rk);
        unregisterSessionClient(rk, false);
        ev_bus.unsubscribe(rk);
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
pub const memories = @import("modules/agent/tools/memories.zig");
pub const list_memory_tool = @import("modules/agent/tools/list_memory.zig");
pub const search_history_tool = @import("modules/agent/tools/search_history.zig");
pub const view_skill_tool = @import("modules/agent/tools/view_skill.zig");
pub const agents = @import("modules/agent/tools/agents.zig");
pub const list_agents = @import("modules/agent/tools/list_agents.zig");

pub const set_agent_properties = @import("modules/agent/tools/set_agent_properties.zig");

pub const http_client = @import("modules/http/HttpClient.zig");
pub const loggermod = @import("modules/logger/Logger.zig");
pub const skill_mod = @import("modules/agent/tools/skills.zig");
pub const add_skill = @import("modules/agent/tools/add_skill.zig");
pub const edit_skill = @import("modules/agent/tools/edit_skill.zig");
pub const remove_agent = @import("modules/agent/tools/remove_agent.zig");
pub const set_git_worktree = @import("modules/agent/tools/set_git_worktree.zig");
pub const kanban_list = @import("modules/agent/tools/kanban_list.zig");
pub const kanban_move_task = @import("modules/agent/tools/kanban_move_task.zig");
pub const create_kanban_task = @import("modules/agent/tools/create_kanban_task.zig");
pub const set_design_page = @import("modules/agent/tools/set_design_page.zig");
pub const add_design_element = @import("modules/agent/tools/add_design_element.zig");
pub const update_design_element = @import("modules/agent/tools/update_design_element.zig");
pub const group_design_elements = @import("modules/agent/tools/group_design_elements.zig");
pub const set_element_parent = @import("modules/agent/tools/set_element_parent.zig");
pub const move_design_element = @import("modules/agent/tools/move_design_element.zig");
pub const get_design_context = @import("modules/agent/tools/get_design_context.zig");
pub const preview_design_page = @import("modules/agent/tools/preview_design_page.zig");

pub const config = @import("modules/config/Config.zig");
pub const helperTool = @import("modules/agent/tools/helper.zig");
pub const read_file = @import("modules/agent/tools/read_file.zig");
pub const write_file = @import("modules/agent/tools/write_file.zig");
pub const remove_file = @import("modules/agent/tools/remove_file.zig");
pub const system_folder = @import("modules/system_folder/system_folder.zig");

pub const update_activity = @import("modules/agent/tools/update_activity.zig");

pub const web_search = @import("modules/agent/tools/web_search.zig");
pub const nalar_browser = @import("modules/agent/tools/nalar_browser.zig");
pub const glob_tool = @import("modules/agent/tools/glob.zig");
pub const search_tool = @import("modules/agent/tools/search.zig");
pub const semantic_search = @import("modules/agent/tools/semantic_search.zig");
pub const text_replace_tool = @import("modules/agent/tools/text_replace.zig");
pub const cronjob = @import("modules/cronjob/mod.zig");

// Decoupled nalar-service (Chunk 3) — re-export the service plumbing so
// main.zig and other internal callers can `@import("nalarcore").service_*`.
// Each of these is the same module surfaced under `nalarcore.service.*`
// (see `src/service/mod.zig`); the top-level aliases here are kept for
// backward compat with existing call sites that reach through
// `nalarcore.state_file`, etc. directly.
pub const service = @import("service/mod.zig");
pub const state_file = service.state_file;
pub const daemon = service.daemon;
pub const signal_handlers = service.signal_handlers;
pub const crash_handler = service.crash_handler;
pub const main_service = service.main_service;
pub const helpers = @import("helpers/mod.zig");
pub const kerjabot_get_session = @import("ai_workflow/tui/llm_history.zig");
pub const kerjabot_create_session = @import("ai_workflow/tui/llm_history.zig");
pub const kerjabot_get_list_session = @import("ai_workflow/tui/llm_history.zig");
pub const tui_check_session_exists = @import("ai_workflow/tui/llm_history.zig");
pub const session_helpers = @import("ai_workflow/tui/llm_history.zig");
pub const session_db = @import("ai_workflow/tui/llm_history.zig");
pub const llm_history = @import("ai_workflow/tui/llm_history.zig");
pub const workspace_items = @import("ai_workflow/tui/llm_history.zig");
pub const workspace_item_tasks = @import("ai_workflow/tui/llm_history.zig");
pub const http_response = @import("ai_workflow/tui/http_handlers/http_response.zig");
pub const spawn_sub_agent = @import("modules/agent/tools/spawn_sub_agent.zig");
pub const http_handlers = @import("ai_workflow/tui/http_handlers/mod.zig");
pub const gserverz = @import("modules/custom_http_server/src/http_server.zig");
pub const ai_mod = @import("ai_workflow/tui/mod.zig");
pub const event_bus = @import("modules/event_bus/src/event.zig");
pub const static_files = @import("modules/static_files.zig");

pub const startup = @import("startup.zig");
pub const agentic_loop_mod = @import("ai_workflow/tui/agentic_loop/mod.zig");

pub const notifications_mod = @import("modules/notification/notifications.zig");
pub const migrations_mod = @import("migrations/mod.zig");

test {
    _ = @import("ai_workflow/tui/test_runner.zig");
    _ = @import("modules/agent/test_runner.zig");
    _ = @import("modules/databases/test_runner.zig");
    _ = @import("modules/event_bus/src/test_runner.zig");
    _ = @import("modules/http/test_runner.zig");
    _ = @import("modules/logger/test_runner.zig"); // needs Zig 0.16 API updates
    _ = @import("modules/custom_http_server/src/test_session_lifecycle.zig");
    _ = @import("modules/custom_http_server/src/sse_chunked_test.zig");
    _ = @import("modules/custom_http_server/src/sse_keepalive_test.zig"); // 60s SSE soak test
    _ = @import("modules/test_runner.zig");
    _ = @import("modules/notification/test_runner.zig");
    _ = @import("migrations/test_runner.zig");
    _ = @import("service/crash_handler_test.zig"); // crash signal/exception handler contracts
}
