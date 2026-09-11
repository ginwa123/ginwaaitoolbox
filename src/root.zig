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
    previous: ?*const config.LlmConfig = null,
    lock: std.Io.Mutex = .init,
};

/// Input to `ContextIPCTui.emit_run_agent`.
///
/// The string fields are PASSED-THROUGH — `emit_run_agent` does not dupe
/// them. Callers can pass borrowed slices if those slices outlive the
/// synchronous `emit_run_agent` call (which they almost always do — most
/// call sites use literals or stable config strings).
///
/// If a caller has borrowed slices that will be freed before the
/// concurrent task runs, they MUST dup into a long-lived allocator first
/// (see `useCase` in `session_create.zig` for the safe pattern that dups
/// via `di.allocator`).
pub const EmitRunAgentInput = struct {
    session_id: []const u8,
    session_name: []const u8,
    queue_message: []const u8,
    cwd: []const u8,
    body_message: []const u8,
    allowed_tools: []const u8,
    image_urls: []const u8,
    selected_profile_model: []const u8,
    is_auto_retry_until_stop: []const u8,
    // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). When
    // true, the worker skips the initial insertQueueMessage call —
    // used by the start_agent endpoint to trigger a worker on an
    // existing session without queueing a new user message. Default
    // `false` preserves the existing create-session behaviour.
    skip_initial_queue_message: bool = false,
};

pub const ContextIPCTui = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
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
    /// Fire-and-forget group for background-command completion watchers
    /// (background_watcher.zig). Same lifecycle as
    /// `group_emit_session_create`: process-lifetime, never awaited or
    /// cancelled. Field default keeps existing struct literals compiling.
    group_bg_watchers: std.Io.Group = .init,

    static_dir_path: ?[]const u8 = null,

    /// Process-global MCP stdio registry, cached here so every call site
    /// goes through the singleton struct (`di.mcp_stdio_registry`) instead
    /// of calling `StdioRegistry.global(allocator)` with its own allocator
    /// choice. Eagerly set in main.zig after `setSingleton`; lazily filled
    /// by `mcpStdioRegistry()` on first use when main didn't (unit tests).
    /// Nullable + default null so existing struct literals keep compiling.
    mcp_stdio_registry: ?*mcp_stdio.StdioRegistry = null,
    mcp_http_registry: ?*mcp_http.HttpRegistry = null,

    /// Fetch-once MCP tools cache (plan: mcp-fetch-once-cache).
    /// First workflow run fetches via `buildMCPToolsRun` and publishes
    /// here; every later run (new session, queued message, retry) reads
    /// the snapshot instead of doing `tools/list` I/O again.
    /// `mcp_tools_init=false` means never-fetched-or-cleared → the next
    /// workflow run must fetch. Mutation sites (PUT /api/config/nalar,
    /// add_mcp_server) only `clearMcpToolsCache()` — the next workflow
    /// run pays the one fetch. Guarded by a spinlock (Zig 0.16 has no
    /// `std.Thread.Mutex`); helpers are io-free so workflow + HTTP
    /// handlers can call them without threading `io` through.
    mcp_tools_cache: ?[]tool_models.AgentTool = null,
    mcp_tools_init: bool = false,
    mcp_tools_lock: std.atomic.Mutex = .unlocked,

    /// Schedule an async session-create task on the Io group.
    ///
    /// Lifetime contract: the string fields of `obj` are duped into
    /// `self.allocator` (long-lived) **synchronously**, before the
    /// concurrent task is scheduled. The concurrent task then consumes
    /// the duped slices directly and frees them via `defer` when done.
    /// This is the safe pattern: the source slices (typically borrowed
    /// from `req.body` via `parseFromSliceLeaky` in the HTTP handler)
    /// are freed when the handler returns, but our dupes live in
    /// `self.allocator` which outlives the request arena. The earlier
    /// implementation duped INSIDE the concurrent task, which was a
    /// use-after-free because the source was already gone by then —
    /// SEGV in `local.dupe(u8, qmsg)` at root.zig:101.
    ///
    /// Mirrors the `fireWorkspaceRoutine` pattern in `routines/fire.zig` which
    /// has been working correctly since the async rewrite.
    pub fn emit_run_agent(self: *ContextIPCTui, obj: EmitRunAgentInput) !void {
        // Heap-dupe each string synchronously into the long-lived
        // `self.allocator`. Each dupe is owned by us and will be freed
        // by the concurrent task once it has used them. `errdefer`
        // chains unwind cleanly on mid-allocation failure — the caller
        // still hasn't seen the concurrent() error.
        const owned_session_id = try self.allocator.dupe(u8, obj.session_id);
        errdefer self.allocator.free(owned_session_id);
        const owned_session_name = try self.allocator.dupe(u8, obj.session_name);
        errdefer self.allocator.free(owned_session_name);
        const owned_queue_message = try self.allocator.dupe(u8, obj.queue_message);
        errdefer self.allocator.free(owned_queue_message);
        const owned_cwd = try self.allocator.dupe(u8, obj.cwd);
        errdefer self.allocator.free(owned_cwd);
        const owned_body_message = try self.allocator.dupe(u8, obj.body_message);
        errdefer self.allocator.free(owned_body_message);
        const owned_allowed_tools = try self.allocator.dupe(u8, obj.allowed_tools);
        errdefer self.allocator.free(owned_allowed_tools);
        const owned_image_urls = try self.allocator.dupe(u8, obj.image_urls);
        errdefer self.allocator.free(owned_image_urls);
        const owned_selected_profile_model = try self.allocator.dupe(u8, obj.selected_profile_model);
        errdefer self.allocator.free(owned_selected_profile_model);
        const owned_is_auto_retry_until_stop = try self.allocator.dupe(u8, obj.is_auto_retry_until_stop);
        errdefer self.allocator.free(owned_is_auto_retry_until_stop);
        // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). The
        // flag is a `bool` (no string dupe needed) — pass through the
        // Io group directly.

        // NEW (plan 2026-08-29-chat-sidebar-last-human-touched, Task 3):
        // Stamp `sessions.last_human_touched_at_nano` BEFORE the concurrent
        // task spawns — this is the single funnel for every user-sends-a-
        // message path (chat send button, kanban "create & run", kanban
        // "Start agent", `+ Chat`). `session_create.useCase` calls into
        // here (line 229) so this stamp covers BOTH create + send in one
        // site, with no duplicate in the chat-create handler. The stamp
        // is best-effort (log + continue on transient DB blip) so a stamp
        // failure can't block message delivery. Plan D1.
        ai_mod.llm_history.updateSessionLastHumanTouchedAt(
            self.allocator,
            self.db,
            owned_session_id,
            null,
        ) catch |stamp_err| {
            std.log.warn(
                "emit_run_agent: stamp session last_human_touched_at failed (non-fatal): {s}",
                .{@errorName(stamp_err)},
            );
        };

        try self.group_emit_session_create.concurrent(
            self.io,
            struct {
                fn run(
                    di_inner: *ContextIPCTui,
                    sid: []const u8,
                    sname: []const u8,
                    qmsg: []const u8,
                    cwd: []const u8,
                    bmsg: []const u8,
                    atools: []const u8,
                    iurls: []const u8,
                    spm: []const u8,
                    iaur: []const u8,
                    siqm: bool,
                ) void {
                    // These slices are owned by the Io task lifetime —
                    // they were duped synchronously by `emit_run_agent`
                    // into `di_inner.allocator` (which lives forever).
                    // Free them all on the way out, in reverse order.
                    defer di_inner.allocator.free(iaur);
                    defer di_inner.allocator.free(spm);
                    defer di_inner.allocator.free(iurls);
                    defer di_inner.allocator.free(atools);
                    defer di_inner.allocator.free(bmsg);
                    defer di_inner.allocator.free(cwd);
                    defer di_inner.allocator.free(qmsg);
                    defer di_inner.allocator.free(sname);
                    defer di_inner.allocator.free(sid);

                    const event_buss = di_inner.event_bus;

                    di_inner.insert_worker(di_inner.allocator, .{
                        .session_id = sid,
                        .session_name = sname,
                        .queue_message = qmsg,
                        .cwd = cwd,
                        .body_message = bmsg,
                        .allowed_tools = atools,
                        .image_urls = iurls,
                        .selected_profile_model = spm,
                        .is_auto_retry_until_stop = iaur,
                    }) catch unreachable;

                    event_buss.emit(agentic_loop_mod.RunParamsNew, "ai_worker_flow", .{
                        .parent_session_id = sid,
                        .session_id = sid,
                        .message = qmsg,
                        .cwd = cwd,
                        .body = bmsg,
                        .allowed_tools = atools,
                        .is_sub_agent = false,
                        .image_urls = iurls,
                        .selected_profile_model = spm,
                        .is_auto_retry_until_stop = iaur,
                        // NEW (plan: 2026-08-18-kanban-task-detail-start-agent)
                        .skip_initial_queue_message = siqm,
                    });
                }
            }.run,
            .{ self, owned_session_id, owned_session_name, owned_queue_message, owned_cwd, owned_body_message, owned_allowed_tools, owned_image_urls, owned_selected_profile_model, owned_is_auto_retry_until_stop, obj.skip_initial_queue_message },
        );
    }

    fn insert_worker(self: *ContextIPCTui, allocator: std.mem.Allocator, parsed: EmitRunAgentInput) !void {
        const session_id = parsed.session_id;
        const session_name = parsed.session_name;
        const effective_cwd = parsed.cwd;
        const effective_profile = parsed.selected_profile_model;
        const effective_auto_retry: []const u8 = blk: {
            if (std.mem.eql(u8, parsed.is_auto_retry_until_stop, "1")) break :blk "1";
            break :blk "0";
        };

        // (no debug log — production code)

        const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status, cwd, created_at, updated_at, selected_profile_model, is_auto_retry_until_stop) " ++
            "VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?)";
        const copy_session_name = try allocator.dupe(u8, session_name);
        const copy_cwd = try allocator.dupe(u8, effective_cwd);
        const copy_profile = if (effective_profile.len > 0) try allocator.dupe(u8, effective_profile) else "";
        try self.db.exec(
            allocator,
            session_sql,
            &.{ session_id, copy_session_name, copy_cwd, copy_profile, effective_auto_retry },
        );

        // Broadcast session created event
        try agentic_loop_mod.on_event_sent.onEventSendSessions(allocator, .{
            .action = "created",
            .id = session_id,
            .name = session_name,
            .status = "active",
            .cwd = effective_cwd,
            .created_at = "",
            .updated_at = "",
            .selected_profile_model = effective_profile,
            .is_auto_retry_until_stop = effective_auto_retry,
            .last_finish_reason = "",
        });
    }

    /// Fetch-once cache readers/writers (plan: mcp-fetch-once-cache).
    /// All three are io-free (spinlock) so workflow + HTTP handlers share them.

    pub fn isMcpToolsInit(self: *ContextIPCTui) bool {
        mcpToolsLock(&self.mcp_tools_lock);
        defer mcpToolsUnlock(&self.mcp_tools_lock);
        return self.mcp_tools_init;
    }

    /// Snapshot the cache onto `run_allocator`. Returns `null` when the
    /// cache is uninitialized OR when it was initialized with `null`
    /// (no `mcp_servers` object). The caller owns the returned slice.
    pub fn getMcpToolsCached(self: *ContextIPCTui, run_allocator: std.mem.Allocator) ?[]tool_models.AgentTool {
        mcpToolsLock(&self.mcp_tools_lock);
        defer mcpToolsUnlock(&self.mcp_tools_lock);
        if (!self.mcp_tools_init) return null;
        const cached = self.mcp_tools_cache orelse return null;
        return dupeAgentTools(run_allocator, cached) catch null;
    }

    /// Publish a fresh fetch. Deep-dupes `tools` onto `self.allocator`
    /// (process lifetime), frees the previous cache, marks initialized.
    /// `tools=null` (no servers / fetch failed) is a valid publish and
    /// marks initialized ONLY when `mark_init=true` — workflow passes
    /// `false` on error so the next run retries instead of poisoning.
    pub fn storeMcpToolsCache(self: *ContextIPCTui, tools_in: ?[]tool_models.AgentTool, mark_init: bool) void {
        mcpToolsLock(&self.mcp_tools_lock);
        defer mcpToolsUnlock(&self.mcp_tools_lock);
        if (self.mcp_tools_cache) |old| {
            freeAgentTools(self.allocator, old);
            self.mcp_tools_cache = null;
        }
        if (tools_in) |t| {
            self.mcp_tools_cache = dupeAgentTools(self.allocator, t) catch null;
        } else {
            self.mcp_tools_cache = null;
        }
        if (mark_init) self.mcp_tools_init = true;
    }

    /// Lazy-invalidate: free + mark uninitialized. The next workflow run
    /// does the one refetch. Called from PUT /api/config/nalar and
    /// add_mcp_server after their `setLlmConfig` swap.
    pub fn clearMcpToolsCache(self: *ContextIPCTui) void {
        mcpToolsLock(&self.mcp_tools_lock);
        defer mcpToolsUnlock(&self.mcp_tools_lock);
        if (self.mcp_tools_cache) |old| {
            freeAgentTools(self.allocator, old);
            self.mcp_tools_cache = null;
        }
        self.mcp_tools_init = false;
    }
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

/// Remove ONE client_id from a routing key's list (disconnect path).
/// Drops the map entry only when its list becomes empty. Unlike
/// `unregisterSessionClient` (which removes ALL clients under the key),
/// surviving connections sharing the key keep receiving broadcasts --
/// a single flaky connection must never black out every other client.
/// Callers must NOT unsubscribe the shared event_bus callback here: it is
/// one static fn per key shared by all connections, and resubscribe on
/// (re)connect is idempotent (first-wins), so leaving it registered is
/// always safe -- forwardToClients early-returns on an empty list.
pub fn unregisterSessionClientId(routing_key: []const u8, client_id: [16]u8, is_use_lock: bool) void {
    _ = is_use_lock;
    const di = getSingleton() catch return;
    const allocator = di.allocator;
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);
    const list = di.session_to_client_ids.getPtr(routing_key) orelse return;
    var idx: ?usize = null;
    for (list.items, 0..) |existing_id, i| {
        if (std.mem.eql(u8, &existing_id, &client_id)) {
            idx = i;
            break;
        }
    }
    _ = list.orderedRemove(idx orelse return);
    if (list.items.len == 0) {
        list.deinit(allocator);
        if (di.session_to_client_ids.fetchRemove(routing_key)) |kv| {
            allocator.free(kv.key);
        }
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
        unregisterSessionClientId(rk, client_id, false);
        std.log.info("sse disconnect: client {x} dropped from routing key '{s}'", .{ client_id, rk });
    }
}

// Module exports - these are available via @import("nalarcore")
// it should import from folder modules only
pub const agent = @import("modules/agent/Agent.zig");
pub const llm_models = @import("modules/agent/LLMModels.zig");
pub const prompt = @import("modules/agent/prompts.zig");
// `databases` is the self-contained sqlite3 + libpq package — see
// src/modules/databases/build.zig. Imported via the build-graph
// dependency declared in build.zig (mod.addImport("databases", databases_mod)).
pub const sqlite = @import("databases").sqlite;
// Unified interface — prefer this over `sqlite` in new code:
//   const database = nalarcore.database; var db: database.Db = .{};
// App-controlled via root `-Ddb_used` (default sqlite).
// `Db` IS `SqliteBackend` when sqlite-only, so existing
// `*sqlite.SqliteBackend` signatures keep compiling during migration.
pub const database = @import("databases").database;
pub const bash_tool = @import("modules/agent/tools/bash.zig");
pub const pwsh_tool = @import("modules/agent/tools/pwsh.zig");
pub const command_tool = @import("modules/agent/tools/command.zig");
pub const tool_models = @import("modules/agent/tools/schemas.zig");
pub const tools = @import("modules/agent/tools/tools.zig");
pub const change_agent = @import("modules/agent/tools/change_agent.zig");

pub const use_skill_tool = @import("modules/agent/tools/use_skill.zig");
pub const remove_skill_tool = @import("modules/agent/tools/remove_skill.zig");
pub const list_skills_tool = @import("modules/agent/tools/list_skills.zig");
// 2026-08-14 — first-level directory listing tool (Task 5 of the same plan).
pub const list_directory = @import("modules/agent/tools/list_directory.zig");
pub const memories = @import("modules/agent/tools/memories.zig");
pub const list_memory_tool = @import("modules/agent/tools/list_memory.zig");
pub const save_memory = @import("modules/agent/tools/save_memory.zig");
pub const load_memory = @import("modules/agent/tools/load_memory.zig");
pub const delete_memory = @import("modules/agent/tools/delete_memory.zig"); // 2026-08-24-delete-memory-agent-tool
pub const add_mcp_server = @import("modules/agent/tools/add_mcp_server.zig"); // 2026-08-28-add-mcp-server-agent-tool
pub const search_history_tool = @import("modules/agent/tools/search_history.zig");
pub const agents = @import("modules/agent/tools/agents.zig");
pub const list_agents = @import("modules/agent/tools/list_agents.zig");


// `modules/http/HttpClient.zig` was removed — the project uses the
// libcurl-backed `custom_http_client` module (imported directly via
// `@import("custom_http_client")`; the dep is added in build.zig).
// The MCP call sites in `handle_mcp_tool.zig` and
// `prompts_build_messages_for_agent_prompt.zig` were migrated to it.
pub const loggermod = @import("modules/logger/Logger.zig");
pub const mcp_stdio = @import("modules/agent/mcp/mcp/mcp_stdio.zig");
pub const mcp_http = @import("modules/agent/mcp/mcp/mcp_http.zig");
pub const mcp_types = @import("modules/agent/mcp/mcp/mcp_types.zig");

/// Process-global MCP stdio registry accessor (lives in root so every
/// call site shares one `long_lived` allocator choice).
///
/// Picks the DI allocator (process lifetime, via `getSingleton`) when the
/// server is up, else falls back to the caller-provided allocator (unit
/// tests / pre-singleton startup). Replaces the repeated two-liner:
/// `const long_lived = if (getSingleton()) |di| di.allocator else |_| alloc;`
/// `const reg = mcp_stdio.StdioRegistry.global(long_lived);`
///
/// Prefers the cached `di.mcp_stdio_registry` (eagerly set in main.zig) so
/// every call site goes through the singleton struct; lazily fills the
/// cache when main didn't (unit tests). The lazy fill is benign under
/// concurrency: `global()` itself is mutex-protected and every thread
/// computes the same pointer value.
pub fn mcpStdioRegistry(fallback: std.mem.Allocator) *mcp_stdio.StdioRegistry {
    if (getSingleton()) |di| {
        if (di.mcp_stdio_registry) |cached| return cached;
        const reg = mcp_stdio.StdioRegistry.global(di.allocator);
        di.mcp_stdio_registry = reg;
        return reg;
    } else |_| {}
    return mcp_stdio.StdioRegistry.global(fallback);
}

/// Same shape for the HTTP transport registry.
pub fn mcpHttpRegistry(fallback: std.mem.Allocator) *mcp_http.HttpRegistry {
    if (getSingleton()) |di| {
        if (di.mcp_http_registry) |cached| return cached;
        const reg = mcp_http.HttpRegistry.global(di.allocator);
        di.mcp_http_registry = reg;
        return reg;
    } else |_| {}
    return mcp_http.HttpRegistry.global(fallback);
}

/// Spinlock helper for the fetch-once tools cache (same pattern as
/// `mcp_stdio.StdioRegistry` / `mcp_http.HttpRegistry` — Zig 0.16 has
/// no `std.Thread.Mutex` in the public surface).
fn mcpToolsLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

fn mcpToolsUnlock(m: *std.atomic.Mutex) void {
    m.unlock();
}

/// Deep-dupe one `AgentTool` (all strings + nested slices) onto
/// `allocator`. Mirrors the ownership contract of
/// `buildMCPToolsRun` (caller owns everything).
fn dupeAgentTool(allocator: std.mem.Allocator, src: tool_models.AgentTool) !tool_models.AgentTool {
    const props = try allocator.alloc(tool_models.ToolProperty, src.function.parameters.properties.len);
    errdefer allocator.free(props);
    for (src.function.parameters.properties, 0..) |p, i| {
        props[i] = .{
            .name = try allocator.dupe(u8, p.name),
            .type = try allocator.dupe(u8, p.type),
            .description = try allocator.dupe(u8, p.description),
        };
    }
    errdefer {
        for (props) |p| {
            allocator.free(p.name);
            allocator.free(p.type);
            allocator.free(p.description);
        }
        allocator.free(props);
    }
    const required = try allocator.alloc([]const u8, src.function.parameters.required.len);
    errdefer allocator.free(required);
    for (src.function.parameters.required, 0..) |r, i| {
        required[i] = try allocator.dupe(u8, r);
    }
    errdefer for (required) |r| allocator.free(r);
    return .{
        .type = try allocator.dupe(u8, src.type),
        .function = .{
            .name = try allocator.dupe(u8, src.function.name),
            .description = try allocator.dupe(u8, src.function.description),
            .parameters = .{
                .type = try allocator.dupe(u8, src.function.parameters.type),
                .properties = props,
                .required = required,
            },
            .system_prompt = try allocator.dupe(u8, src.function.system_prompt),
        },
    };
}

/// Free one `AgentTool` previously duped with `dupeAgentTool`.
fn freeAgentTool(allocator: std.mem.Allocator, tool: tool_models.AgentTool) void {
    allocator.free(tool.type);
    allocator.free(tool.function.name);
    allocator.free(tool.function.description);
    allocator.free(tool.function.parameters.type);
    for (tool.function.parameters.properties) |p| {
        allocator.free(p.name);
        allocator.free(p.type);
        allocator.free(p.description);
    }
    allocator.free(tool.function.parameters.properties);
    for (tool.function.parameters.required) |r| allocator.free(r);
    allocator.free(tool.function.parameters.required);
    allocator.free(tool.function.system_prompt);
}

/// Free a whole cached slice.
fn freeAgentTools(allocator: std.mem.Allocator, list: []tool_models.AgentTool) void {
    for (list) |t| freeAgentTool(allocator, t);
    allocator.free(list);
}

/// Dupe a whole slice (used for both store + snapshot paths).
fn dupeAgentTools(allocator: std.mem.Allocator, src: []tool_models.AgentTool) ![]tool_models.AgentTool {
    const out = try allocator.alloc(tool_models.AgentTool, src.len);
    errdefer allocator.free(out);
    for (src, 0..) |t, i| {
        out[i] = try dupeAgentTool(allocator, t);
    }
    return out;
}

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
pub const move_element_to_page = @import("modules/agent/tools/move_element_to_page.zig");
pub const get_design_context = @import("modules/agent/tools/get_design_context.zig");
pub const preview_design_page = @import("modules/agent/tools/preview_design_page.zig");

pub const config = @import("modules/config/Config.zig");
pub const parse_thinking = @import("modules/config/parse_thinking.zig");
// Plan 2026-09-10-web-launch-toggle: random loopback port picker for
// browser mode (`--port 0` resolution). Re-exported here so the exe
// module (src/main.zig) reaches it via `nalarcore.web_port` instead of
// a direct cross-module @import (which would duplicate the file across
// modules — see the cleanup_stale_worker precedent in main.zig).
pub const web_port = @import("modules/config/web_port.zig");
pub const helperTool = @import("modules/agent/tools/helper.zig");
pub const read_file = @import("modules/agent/tools/read_file.zig");
pub const write_file = @import("modules/agent/tools/write_file.zig");
pub const remove_file = @import("modules/agent/tools/remove_file.zig");
pub const system_folder = @import("modules/system_folder/system_folder.zig");

pub const update_activity = @import("modules/agent/tools/update_activity.zig");
// 2026-08-19 — session_plan agent tools (Task 4 of 2026-08-19-session-plan-agent-tool.md).
// update_plan (UPSERT) + get_plan (fetch) — the agent's persistent markdown task plan.
pub const update_plan = @import("modules/agent/tools/update_plan.zig");
pub const get_plan = @import("modules/agent/tools/get_plan.zig");
pub const list_sub_agent = @import("modules/agent/tools/list_sub_agent.zig");

pub const web_search = @import("modules/agent/tools/web_search.zig");
pub const generate_image = @import("modules/agent/tools/generate_image.zig");
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
// `pub const helpers = ...` was removed: `helpers` is now its own
// Zig module (see `b.createModule` in build.zig) wired in via
// `mod.addImport("helpers", helpers_mod)`. Source files inside
// nalarcore use `@import("helpers")` (not a relative path) to
// reach it.
pub const kerjabot_get_session = @import("agentic_loop/llm_history.zig");
pub const kerjabot_create_session = @import("agentic_loop/llm_history.zig");
pub const kerjabot_get_list_session = @import("agentic_loop/llm_history.zig");
pub const tui_check_session_exists = @import("agentic_loop/llm_history.zig");
pub const session_helpers = @import("agentic_loop/llm_history.zig");
pub const session_db = @import("agentic_loop/llm_history.zig");
pub const llm_history = @import("agentic_loop/llm_history.zig");
pub const agent_memories = @import("agentic_loop/agent_memories.zig");
// 2026-08-19 — session_plan agent tools (Task 4 of 2026-08-19-session-plan-agent-tool.md).
// Storage layer for the per-session markdown task plan (savePlan / getPlan / getPlanOpt).
pub const session_plan = @import("agentic_loop/session_plan.zig");
// Re-export so the exe module (main.zig) can access
// cleanup_stale_worker.handle for the cron registration WITHOUT
// directly @import'ing the file (which would put it in two modules
// and trigger Zig's "file exists in two modules" error).
pub const cleanup_stale_worker = @import("schedulers/cleanup_stale_worker.zig");
// Re-export cleanup_stale_background_process for the same reason as
// above — see plan 2026-08-19-cleanup-stale-background-process.
pub const cleanup_stale_background_process = @import("schedulers/cleanup_stale_background_process.zig");
pub const workspace_items = @import("agentic_loop/llm_history.zig");
pub const workspace_item_tasks = @import("agentic_loop/llm_history.zig");
pub const http_response = @import("http_handlers/http_response.zig");
pub const spawn_sub_agent = @import("modules/agent/tools/spawn_sub_agent.zig");
pub const http_handlers = @import("http_handlers/mod.zig");
pub const gserverz = @import("modules/custom_http_server/src/http_server.zig");
pub const ai_mod = @import("ai_workflow/tui/mod.zig");
pub const event_bus = @import("modules/event_bus/src/event.zig");
pub const static_files = @import("modules/static_files.zig");

pub const startup = @import("startup.zig");
pub const agentic_loop_mod = @import("agentic_loop/workflow.zig");

pub const notifications_mod = @import("modules/notification/notifications.zig");
pub const migrations_mod = @import("migrations/mod.zig");

test {
    _ = @import("ai_workflow/tui/test_runner.zig");
    _ = @import("modules/agent/test_runner.zig");
    // Agent Mode helpers: impl + tests in one file. Importing these
    // makes their inline `test` blocks discoverable by `zig build test`.
    _ = @import("agentic_loop/agent_tools_allowed.zig");
    _ = @import("agentic_loop/prompts_make_agent_knowledge.zig");
    _ = @import("agentic_loop/prompts_make_agent_system_prompt.zig");
    // Agent-Kanbans mirror (Migration 081): impl + tests in one file.
    _ = @import("agentic_loop/agent_kanban_tools_allowed.zig");
    _ = @import("agentic_loop/prompts_make_agent_kanban_knowledge.zig");
    _ = @import("agentic_loop/prompts_make_agent_kanban_system_prompt.zig");
    // `databases` package tests run via its own `zig build test`
    // (cd src/modules/databases && zig build test) — see the
    // package's build.zig. The main test step doesn't import them
    // here because the package already discovers its own tests via
    // its root.zig's `test { ... }` block.
    _ = @import("modules/event_bus/src/test_runner.zig");
    _ = @import("modules/logger/test_runner.zig"); // needs Zig 0.16 API updates
    // custom_http_server tests run mostly through the module's own
    // `zig build test` (run from src/modules/custom_http_server/). The
    // two exceptions live here because they need the parent project's
    // root + on-disk fixtures:
    //   - test_session_lifecycle.zig + sse_chunked_test.zig — already
    //     discovered by the module's test_runner.zig when that build
    //     runs, but the parent imports them directly too so they're
    //     covered even if the module's own build isn't exercised.
    //   - read_html_test.zig — orphaned from ginwasaas; its fixtures
    //     (`src/handlers/landing.html`) don't exist in ginwaaitoolbox.
    //     Excluded from BOTH the parent and the module's test_runner
    //     until the test is fixed/moved.
    //   - sse_keepalive_test.zig (the 60 s soak) — EXCLUDED here on
    //     purpose. It eats ~120 s of wall-clock and dominates
    //     `zig build test` runtime. Run it via the module's own build:
    //     `cd src/modules/custom_http_server && zig build test`.
    _ = @import("modules/custom_http_server/src/test_session_lifecycle.zig");
    _ = @import("modules/custom_http_server/src/sse_chunked_test.zig");
    // sse_manager_test.zig is std-only + the module's local
    // test_helpers.zig, so it compiles in the parent's module tree
    // without a `custom_http_server` module import. Registered here
    // because the module's OWN `zig build test` currently fails to
    // compile for unrelated reasons (websocket_frames.zig:253), which
    // would otherwise leave the SSE send-timeout regression uncovered
    // in CI.
    _ = @import("modules/custom_http_server/src/sse_manager_test.zig");
    _ = @import("modules/test_runner.zig");
    _ = @import("modules/notification/test_runner.zig");
    _ = @import("migrations/test_runner.zig");
    // schedulers/cleanup_stale_worker.zig has inline tests. The
    // `pub const cleanup_stale_worker = @import(...)` above already
    // pulls the file into the lib module's tree; we re-import here
    // inside the test block so `zig build test` discovers the inline
    // tests (the `pub const` alone doesn't trigger discovery).
    _ = @import("schedulers/cleanup_stale_worker.zig");
    // schedulers/cleanup_stale_background_process.zig has inline tests
    // (mirrors cleanup_stale_worker pattern). Re-imported here for the
    // same reason — see plan 2026-08-19-cleanup-stale-background-process.
    _ = @import("schedulers/cleanup_stale_background_process.zig");
    // modules/agent/mcp/mcp/mcp_http.zig has inline tests for the
    // SSE parser + spec-compliant header builder. The `pub const
    // mcp_http = @import(...)` above re-exports the module, but Zig's
    // lazy compilation doesn't pull the file into the test binary
    // unless something references the namespace. Same workaround as
    // cleanup_stale_worker above — see plan
    // 2026-08-28-mcp-streamable-http.md (Task 2).
    _ = @import("modules/agent/mcp/mcp/mcp_http.zig");
    // Browser-mode (web launch) random port picker (plan
    // 2026-09-10-web-launch-toggle): impl + unit tests in one file.
    // Same discovery workaround as mcp_http above.
    _ = @import("modules/config/web_port.zig");
    // Config struct + config_test.zig (the `test { ... }` block at the
    // bottom of Config.zig pulls in config_test.zig +
    // parse_thinking_test.zig). Registered here so `zig build test`
    // discovers them — the `pub const config` re-export above alone
    // doesn't trigger discovery.
    _ = @import("modules/config/Config.zig");
    _ = @import("service/crash_handler_test.zig"); // crash signal/exception handler contracts

    // HTTP/2 (h2c): frames/HPACK/streams/flow-control + the socket-level server
    // tests and the peekable reader. Registered HERE as well as in the module's
    // own `test_runner.zig` — the CI gate runs this file's test block, and a
    // `pub const` re-export alone does NOT make a test discoverable.
    _ = @import("modules/custom_http_server/src/connection_reader.zig");
    // Transport abstraction + TLS/ALPN (OpenSSL). The root test module already
    // links ssl/crypto transitively via the `databases`/`custom_http_client`
    // modules, so these tests run under the CI gate too.
    _ = @import("modules/custom_http_server/src/stream.zig");
    _ = @import("modules/custom_http_server/src/http2/tls.zig");
    _ = @import("modules/custom_http_server/src/http2/test_runner.zig");
}

// ─── Fetch-once MCP tools cache tests (plan: mcp-fetch-once-cache) ───

fn mcpCacheTestTool(allocator: std.mem.Allocator) !tool_models.AgentTool {
    const props = try allocator.alloc(tool_models.ToolProperty, 1);
    props[0] = .{
        .name = try allocator.dupe(u8, "q"),
        .type = try allocator.dupe(u8, "string"),
        .description = try allocator.dupe(u8, "query"),
    };
    const required = try allocator.alloc([]const u8, 1);
    required[0] = try allocator.dupe(u8, "q");
    return .{
        .type = try allocator.dupe(u8, "function"),
        .function = .{
            .name = try allocator.dupe(u8, "mcp_srv_do"),
            .description = try allocator.dupe(u8, "does things"),
            .parameters = .{
                .type = try allocator.dupe(u8, "object"),
                .properties = props,
                .required = required,
            },
            .system_prompt = try allocator.dupe(u8, ""),
        },
    };
}

fn mcpCacheFreeTestTool(allocator: std.mem.Allocator, tool: tool_models.AgentTool) void {
    freeAgentTool(allocator, tool);
}

fn mcpCacheTestCtx() ContextIPCTui {
    var ctx: ContextIPCTui = undefined;
    ctx.allocator = std.testing.allocator;
    ctx.mcp_tools_cache = null;
    ctx.mcp_tools_init = false;
    ctx.mcp_tools_lock = .unlocked;
    return ctx;
}

test "mcp fetch-once: uninitialized cache returns null snapshot" {
    var ctx = mcpCacheTestCtx();
    try std.testing.expect(!ctx.isMcpToolsInit());
    try std.testing.expect(ctx.getMcpToolsCached(std.testing.allocator) == null);
}

test "mcp fetch-once: store + snapshot roundtrip with deep-dupe isolation" {
    var ctx = mcpCacheTestCtx();
    const src = try std.testing.allocator.alloc(tool_models.AgentTool, 1);
    defer std.testing.allocator.free(src);
    src[0] = try mcpCacheTestTool(std.testing.allocator);
    defer mcpCacheFreeTestTool(std.testing.allocator, src[0]);
    ctx.storeMcpToolsCache(src, true);
    defer ctx.clearMcpToolsCache();
    try std.testing.expect(ctx.isMcpToolsInit());
    const snap = ctx.getMcpToolsCached(std.testing.allocator) orelse return error.SnapshotMiss;
    defer {
        for (snap) |s| freeAgentTool(std.testing.allocator, s);
        std.testing.allocator.free(snap);
    }
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("mcp_srv_do", snap[0].function.name);
    // Snapshots must be independently duped (not aliased to the cache):
    // different backing pointers prove the deep dupe.
    try std.testing.expect(snap[0].function.name.ptr != ctx.mcp_tools_cache.?[0].function.name.ptr);
    try std.testing.expect(snap[0].function.parameters.properties.ptr != ctx.mcp_tools_cache.?[0].function.parameters.properties.ptr);
}

test "mcp fetch-once: clear resets to uninitialized" {
    var ctx = mcpCacheTestCtx();
    const src = try std.testing.allocator.alloc(tool_models.AgentTool, 1);
    defer std.testing.allocator.free(src);
    src[0] = try mcpCacheTestTool(std.testing.allocator);
    defer mcpCacheFreeTestTool(std.testing.allocator, src[0]);
    ctx.storeMcpToolsCache(src, true);
    try std.testing.expect(ctx.isMcpToolsInit());
    ctx.clearMcpToolsCache();
    try std.testing.expect(!ctx.isMcpToolsInit());
    try std.testing.expect(ctx.getMcpToolsCached(std.testing.allocator) == null);
}

test "mcp fetch-once: error publish (mark_init=false) leaves retry open" {
    var ctx = mcpCacheTestCtx();
    ctx.storeMcpToolsCache(null, false);
    try std.testing.expect(!ctx.isMcpToolsInit());
    // A null publish WITH init (no servers configured) is a valid cached state.
    ctx.storeMcpToolsCache(null, true);
    try std.testing.expect(ctx.isMcpToolsInit());
    try std.testing.expect(ctx.getMcpToolsCached(std.testing.allocator) == null);
}
