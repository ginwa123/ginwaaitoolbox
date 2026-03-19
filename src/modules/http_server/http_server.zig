const std = @import("std");
const httpz_import = @import("httpz");
const sqlite = @import("nalarcore").sqlite;
const kerjabot_get_session = @import("nalarcore").kerjabot_get_session;
const kerjabot_create_session = @import("nalarcore").kerjabot_create_session;
const kerjabot_get_list_session = @import("nalarcore").kerjabot_get_list_session;

pub const httpz = httpz_import;

pub const Command = struct {
    command_type: []const u8,
    session_id: []const u8,
    content: []const u8,
    cwd_session: []const u8,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        allocator.free(self.command_type);
        allocator.free(self.session_id);
        allocator.free(self.content);
        allocator.free(self.cwd_session);
    }
};

pub const SseEvent = struct {
    event_type: []const u8,
    data: []const u8,

    /// Maximum size for SSE event formatting (16KB - should be enough for any chunk)
    pub const MAX_SSE_SIZE = 16384;

    /// Format SSE event into a provided buffer (stack-allocated, no heap allocations)
    /// Returns the formatted bytes or error.BufferTooSmall if buffer is insufficient
    pub fn formatInto(self: SseEvent, buf: []u8) error{BufferTooSmall}![]u8 {
        var pos: usize = 0;

        // Write event type: "event: <type>\n"
        const event_prefix = "event: ";
        const needed_for_event = event_prefix.len + self.event_type.len + 1;
        if (pos + needed_for_event > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..event_prefix.len], event_prefix);
        pos += event_prefix.len;
        @memcpy(buf[pos..][0..self.event_type.len], self.event_type);
        pos += self.event_type.len;
        buf[pos] = '\n';
        pos += 1;

        // Write data lines: "data: <line>\n" for each line
        var iter = std.mem.splitScalar(u8, self.data, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue; // Skip empty lines from split
            const data_prefix = "data: ";
            const needed_for_line = data_prefix.len + line.len + 1;
            if (pos + needed_for_line > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos..][0..data_prefix.len], data_prefix);
            pos += data_prefix.len;
            @memcpy(buf[pos..][0..line.len], line);
            pos += line.len;
            buf[pos] = '\n';
            pos += 1;
        }

        // Final newline to end the event
        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = '\n';
        pos += 1;

        return buf[0..pos];
    }

    pub fn format(self: SseEvent, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        try result.writer(allocator).print("event: {s}\n", .{self.event_type});

        // Split data by newlines and prefix each with "data: "
        var iter = std.mem.splitScalar(u8, self.data, '\n');
        while (iter.next()) |line| {
            try result.writer(allocator).print("data: {s}\n", .{line});
        }
        try result.appendSlice(allocator, "\n");

        return result.toOwnedSlice(allocator);
    }
};

/// Thread-safe manager for SSE connections
/// Thread-safe manager for SSE connections using direct stream writing
pub const SseConnectionManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Map from session_id to stream - stream is owned by httpz's startEventStream
    connections: std.StringHashMap(std.net.Stream),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .connections = std.StringHashMap(std.net.Stream).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Note: we don't close the stream here - httpz manages that
        }
        self.connections.deinit();
    }

    /// Register a new SSE connection
    pub fn register(self: *Self, session_id: []const u8, stream: std.net.Stream) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(key);

        try self.connections.put(key, stream);
        std.log.info("SSE registered: session_id={s}", .{session_id});
    }

    /// Remove a connection (called when client disconnects)
    pub fn remove(self: *Self, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connections.fetchRemove(session_id)) |entry| {
            self.allocator.free(entry.key);
            std.log.info("SSE removed: session_id={s}", .{session_id});
        }
    }

    /// Send an event to a specific session (uses stack buffer, falls back to heap for large events)
    /// Includes retry logic for race conditions where session isn't registered yet
    pub fn sendEvent(self: *Self, session_id: []const u8, event: SseEvent) !void {
        // Retry up to 3 times with 50ms delay to handle race condition where
        // SSE stream handler hasn't registered the session yet
        const max_retries = 3;
        const retry_delay_ms = 50;

        for (0..max_retries) |attempt| {
            self.mutex.lock();
            if (self.connections.get(session_id)) |stream| {
                // First try with stack buffer (fast path for small events)
                var stack_buf: [SseEvent.MAX_SSE_SIZE]u8 = undefined;
                const formatted = event.formatInto(&stack_buf) catch |err| {
                    if (err == error.BufferTooSmall) {
                        // Stack buffer too small - fall back to heap allocation for large events
                        const heap_formatted = event.format(self.allocator) catch |heap_err| {
                            self.mutex.unlock();
                            std.log.err("SSE sendEvent: heap allocation failed: {s}", .{@errorName(heap_err)});
                            return error.AllocationFailed;
                        };
                        defer self.allocator.free(heap_formatted);
                        stream.writeAll(heap_formatted) catch |write_err| {
                            self.mutex.unlock();
                            std.log.err("SSE sendEvent: write failed: {s}", .{@errorName(write_err)});
                            return error.WriteFailed;
                        };
                        self.mutex.unlock();
                        return; // Success with heap buffer
                    }
                    self.mutex.unlock();
                    return err;
                };

                // Write directly to stream
                stream.writeAll(formatted) catch |err| {
                    self.mutex.unlock();
                    std.log.err("SSE sendEvent: write failed: {s}", .{@errorName(err)});
                    return error.WriteFailed;
                };
                self.mutex.unlock();
                return; // Success
            }
            self.mutex.unlock();

            // Session not found - retry after short delay
            if (attempt < max_retries - 1) {
                std.log.warn("SSE sendEvent: session {s} not found, retrying ({}/{})...", .{ session_id, attempt + 1, max_retries });
                std.Thread.sleep(retry_delay_ms * 1_000_000);
            }
        }

        // All retries exhausted
        std.log.err("SSE sendEvent: session not found after {} retries: {s}", .{ max_retries, session_id });
        return error.SessionNotFound;
    }

    /// Check if a session exists
    pub fn hasSession(self: *Self, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connections.contains(session_id);
    }

    /// Broadcast an event to ALL connected sessions
    /// Uses heap allocation for large events when stack buffer is too small
    pub fn broadcast(self: *Self, event: SseEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // First try stack buffer, fall back to heap for large events
        const formatted = blk: {
            var stack_buf: [SseEvent.MAX_SSE_SIZE]u8 = undefined;
            break :blk event.formatInto(&stack_buf) catch |err| {
                if (err == error.BufferTooSmall) {
                    // Fall back to heap allocation for large events
                    const heap_result = event.format(self.allocator) catch {
                        std.log.err("SSE broadcast: heap allocation failed", .{});
                        return;
                    };
                    defer self.allocator.free(heap_result);
                    // Write with heap buffer
                    var iter = self.connections.iterator();
                    while (iter.next()) |entry| {
                        entry.value_ptr.writeAll(heap_result) catch {
                            std.log.warn("SSE broadcast: failed to write to session {s}", .{entry.key_ptr.*});
                        };
                    }
                    return;
                }
                std.log.err("SSE broadcast: format failed: {s}", .{@errorName(err)});
                return;
            };
        };

        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.writeAll(formatted) catch {
                std.log.warn("SSE broadcast: failed to write to session {s}", .{entry.key_ptr.*});
            };
        }
    }
};

pub const MessageHandler = *const fn (allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque) void;
pub const SessionHandler = *const fn (allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque, res: *httpz.Response) void;

// Global server instance for handlers to access
pub var global_server: ?*HttpServer = null;

/// Get the global SSE connection manager for sending events to clients
pub fn getGlobalSseManager() ?*SseConnectionManager {
    if (global_server) |server| {
        return &server.sse_manager;
    }
    return null;
}

/// Broadcast a panic event to all connected SSE clients
pub fn broadcastPanic(panic_info: []const u8) void {
    if (global_server) |server| {
        const event = SseEvent{
            .event_type = "panic",
            .data = panic_info,
        };
        server.sse_manager.broadcast(event);
    }
}

pub const HttpServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    port: u16,
    message_handler: ?MessageHandler = null,
    session_handler: ?SessionHandler = null, // NEW: for synchronous session operations
    db: ?*sqlite.SqliteBackend = null, // Database connection for handlers
    ctx: ?*anyopaque = null,
    sse_manager: SseConnectionManager,

    pub fn init(allocator: std.mem.Allocator, ctx: ?*anyopaque, port: u16) Self {
        return .{
            .allocator = allocator,
            .port = if (port == 0) 8080 else port,
            .ctx = ctx,
            .sse_manager = SseConnectionManager.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.sse_manager.deinit();
    }

    pub fn setDb(self: *Self, db: *sqlite.SqliteBackend) void {
        self.db = db;
    }

    pub fn setTUIHandler(self: *Self, handler: MessageHandler) void {
        self.message_handler = handler;
    }

    /// Set the session handler for synchronous session operations (create/get/delete)
    pub fn setSessionHandler(self: *Self, handler: SessionHandler) void {
        self.session_handler = handler;
    }

    pub fn run(self: *Self) !void {
        // Store global reference for handlers
        global_server = self;
        defer global_server = null;

        var server = try httpz.Server(void).init(self.allocator, .{
            .address = .localhost(self.port),
        }, {});
        defer server.deinit();

        std.log.info("HTTP server listening on http://127.0.0.1:{d}/", .{self.port});

        var router = try server.router(.{});

        // Command endpoint
        router.post("/api/command", commandHandler, .{});

        // SSE stream endpoint
        router.get("/api/stream/:session_id", streamHandler, .{});

        // Session management endpoints (synchronous - returns response directly)
        router.post("/api/session/create", sessionCreateHandler, .{});
        router.get("/api/session", sessionListHandler, .{});
        router.get("/api/session/exists/:session_id", sessionExistsHandler, .{});

        // Ping endpoint - checks if session is connected via SSE
        router.get("/api/ping/:session_id", pingHandler, .{});

        // Kerjabot session endpoints
        router.post("/api/kerjabot/session/create", kerjabotSessionCreateHandler, .{});
        router.get("/api/kerjabot/session/:id", kerjabotGetSessionHandler, .{});
        router.get("/api/kerjabot/sessions", kerjabotListSessionsHandler, .{});

        try server.listen();
    }
};

const HandlerArgs = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    handler: *const fn (std.mem.Allocator, []const u8, ?*anyopaque) void,
    ctx: ?*anyopaque,
};

fn commandHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    if (global_server) |server| {
        if (server.message_handler) |msg_handler| {
            const body = req.body() orelse "";

            const args = try server.allocator.create(HandlerArgs);
            args.* = .{
                .allocator = server.allocator,
                .body = try server.allocator.dupe(u8, body),
                .handler = msg_handler,
                .ctx = server.ctx,
            };

            const thread = try std.Thread.spawn(.{}, struct {
                fn run(a: *HandlerArgs) void {
                    defer a.allocator.destroy(a);
                    defer a.allocator.free(a.body);
                    var arena = std.heap.ArenaAllocator.init(a.allocator);
                    defer arena.deinit();
                    a.handler(arena.allocator(), a.body, a.ctx);
                }
            }.run, .{args});
            thread.detach(); // fire and forget
        }
    }

    res.status = 200;
    res.body = "ok";
}

/// Session create handler - synchronous, returns session ID in response
fn sessionCreateHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    if (global_server) |server| {
        if (server.session_handler) |sess_handler| {
            const body = req.body() orelse "";

            // Run synchronously - session creation is quick
            var arena = std.heap.ArenaAllocator.init(server.allocator);
            defer arena.deinit();
            sess_handler(arena.allocator(), body, server.ctx, res);
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"No session handler\"}";
}

/// Session list handler - returns list of sessions
fn sessionListHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    _ = req;
    if (global_server) |server| {
        if (server.session_handler) |_| {
            // For now, return empty sessions list
            // Could be extended to query actual sessions from database
            res.status = 200;
            res.body = "{\"sessions\":[]}";
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"No session handler\"}";
}

/// Session exists handler - checks if a session exists in the database
/// Returns JSON with exists:true/false
fn sessionExistsHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    if (global_server) |server| {
        if (server.db) |db| {
            const tree1 = @import("nalarcore");
            const exists = tree1.tui_check_session_exists.checkSessionExists(server.allocator, db, session_id);

            res.status = 200;
            res.body = try std.fmt.allocPrint(req.arena,
                "{{\"session_id\":\"{s}\",\"exists\":{s}}}",
                .{ session_id, if (exists) "true" else "false" });
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

/// Ping handler - checks if session is connected via SSE
/// Returns JSON indicating whether the session is connected or needs reconnection
fn pingHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };
    if (global_server) |server| {
        res.status = 200;
        if (server.sse_manager.hasSession(session_id)) {
            res.body = try std.fmt.allocPrint(req.arena, "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",\"connected\":true}}", .{session_id});
        } else {
            res.body = try std.fmt.allocPrint(req.arena, "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",\"reconnect\":true}}", .{session_id});
        }
        return;
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

/// Kerjabot session create handler
fn kerjabotSessionCreateHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    if (global_server) |server| {
        const db = server.db orelse {
            res.status = 500;
            res.body = "{\"error\":\"Database not available\"}";
            return;
        };

        const body = req.body() orelse "";

        // Parse request body
        var arena = std.heap.ArenaAllocator.init(server.allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{}) catch {
            res.status = 400;
            res.body = "{\"error\":\"Invalid JSON\"}";
            return;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        // Extract agent_type (default: "general")
        var agent_type: []const u8 = "general";
        if (root.get("agentType")) |v| {
            agent_type = v.string;
        }

        // Extract config
        var model: []const u8 = "gpt-4";
        var temperature: f32 = 0.7;
        var max_tokens: u32 = 4096;

        if (root.get("config")) |config_val| {
            if (config_val == .object) {
                const cfg = config_val.object;
                if (cfg.get("model")) |m| model = m.string;
                if (cfg.get("temperature")) |t| {
                    if (t == .float) temperature = @floatCast(t.float);
                }
                if (cfg.get("maxTokens")) |mt| {
                    if (mt == .integer) max_tokens = @intCast(mt.integer);
                }
            }
        }

        // Create session in database
        const session_id = kerjabot_create_session.createSession(arena.allocator(), db, agent_type, model, temperature) catch {
            res.status = 500;
            res.body = "{\"error\":\"Failed to create session\"}";
            return;
        };

        // Build response
        var response_buf: [512]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf,
            \\{{"sessionId":"{s}","createdAt":{},"agentType":"{s}","config":{{"model":"{s}","temperature":{},"maxTokens":{}}},"workflowState":{{"currentStep":0,"totalSteps":1,"stepName":"init"}}}}
        , .{
            session_id,
            std.time.timestamp(),
            agent_type,
            model,
            temperature,
            max_tokens,
        }) catch "{\"error\":\"Response too large\"}";

        res.status = 201;
        res.body = response;
        return;
    }
    res.status = 500;
    res.body = "{\"error\":\"Server error\"}";
}

/// Kerjabot get session handler
fn kerjabotGetSessionHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    if (global_server) |server| {
        const db = server.db orelse {
            res.status = 500;
            res.body = "{\"error\":\"Database not available\"}";
            return;
        };

        const session_id_param = req.param("id");

        if (session_id_param == null) {
            res.status = 400;
            res.body = "{\"error\":\"Missing session id\"}";
            return;
        }
        const session_id = session_id_param.?;

        // Query session from database
        var arena = std.heap.ArenaAllocator.init(server.allocator);
        defer arena.deinit();

        const session = kerjabot_get_session.getSession(arena.allocator(), db, session_id) catch {
            res.status = 500;
            res.body = "{\"error\":\"Database query failed\"}";
            return;
        };

        if (session) |sess| {
            defer sess.deinit(arena.allocator());

            // Build response
            var response_buf: [512]u8 = undefined;
            const response = std.fmt.bufPrint(&response_buf,
                \\{{"sessionId":"{s}","createdAt":"{s}","agentType":"{s}","config":{{"model":"{s}","temperature":{},"maxTokens":4096}},"workflowState":{{"currentStep":1,"totalSteps":3,"stepName":"processing"}},"messages":[]}}
            , .{
                sess.session_id,
                sess.created_at,
                sess.agent,
                sess.model,
                sess.temperature,
            }) catch "{\"error\":\"Response too large\"}";

            res.status = 200;
            res.body = response;
            return;
        } else {
            res.status = 404;
            res.body = "{\"error\":\"Session not found\"}";
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server error\"}";
}

/// Kerjabot list sessions handler with filtering
fn kerjabotListSessionsHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    if (global_server) |server| {
        const db = server.db orelse {
            res.status = 500;
            res.body = "{\"error\":\"Database not available\"}";
            return;
        };

        // Parse query parameters
        const query = try req.query();
        const limit_str = query.get("limit") orelse "10";
        const offset_str = query.get("offset") orelse "0";

        const limit_val = std.fmt.parseInt(u32, limit_str, 10) catch 10;
        const offset_val = std.fmt.parseInt(u32, offset_str, 10) catch 0;

        var arena = std.heap.ArenaAllocator.init(server.allocator);
        defer arena.deinit();

        // Get sessions from database
        const result = kerjabot_get_list_session.getSessionList(arena.allocator(), db, limit_val, offset_val) catch {
            res.status = 500;
            res.body = "{\"error\":\"Database query failed\"}";
            return;
        };
        defer {
            for (result.sessions) |s| s.deinit(arena.allocator());
            arena.allocator().free(result.sessions);
        }

        // Build JSON response
        var response = std.ArrayList(u8).empty;
        defer response.deinit(server.allocator);

        try response.writer(server.allocator).print("{{\"sessions\":[", .{});

        for (result.sessions, 0..) |sess, i| {
            if (i > 0) {
                try response.writer(server.allocator).print(",", .{});
            }
            try response.writer(server.allocator).print(
                \\{{"sessionId":"{s}","createdAt":"{s}","agentType":"{s}","workflowState":{{"currentStep":1,"totalSteps":3}}}}
            , .{
                sess.session_id,
                sess.created_at,
                sess.agent,
            });
        }

        try response.writer(server.allocator).print("],\"total\":{},\"limit\":{},\"offset\":{}}}", .{
            result.total, limit_val, offset_val,
        });

        res.status = 200;
        res.body = try response.toOwnedSlice(server.allocator);
        return;
    }
    res.status = 500;
    res.body = "{\"error\":\"Server error\"}";
}

/// Context for SSE stream handler
const SseStreamCtx = struct {
    server: *HttpServer,
    session_id: []const u8,
};

/// SSE stream handler - called by httpz on a dedicated thread
fn sseStreamHandler(ctx: SseStreamCtx, stream: std.net.Stream) void {
    std.log.info("SSE stream handler started: session_id={s}", .{ctx.session_id});

    // Register this connection with the stream
    ctx.server.sse_manager.register(ctx.session_id, stream) catch {
        std.log.err("SSE: Failed to register stream for session: {s}", .{ctx.session_id});
        return;
    };

    // Send initial connected event directly
    const connected_data = std.fmt.allocPrint(ctx.server.allocator, "event: connected\ndata: {{\"session_id\":\"{s}\"}}\n\n", .{ctx.session_id}) catch {
        std.log.err("SSE: Failed to format connected event", .{});
        ctx.server.sse_manager.remove(ctx.session_id);
        return;
    };
    defer ctx.server.allocator.free(connected_data);

    stream.writeAll(connected_data) catch |err| {
        std.log.err("SSE: Failed to write connected event: {s}", .{@errorName(err)});
        ctx.server.sse_manager.remove(ctx.session_id);
        return;
    };

    std.log.info("SSE: Connected event sent for session: {s}", .{ctx.session_id});

    // Keep connection alive with periodic keepalives
    // The actual events are sent via sendEvent which writes directly to the stream
    while (ctx.server.sse_manager.hasSession(ctx.session_id)) {
        std.Thread.sleep(30_000_000_000);

        // Send keepalive comment every 30 seconds to prevent timeouts
        stream.writeAll(": keepalive\n\n") catch |err| {
            std.log.warn("SSE keepalive failed for session {s}: {s}", .{ ctx.session_id, @errorName(err) });
            break;
        };

        // Check every 100ms if session still exists
        var i: usize = 0;
        while (i < 300 and ctx.server.sse_manager.hasSession(ctx.session_id)) : (i += 1) {
            // std.debug.print("SSE stream handler: session_id={s}, i={}\n", .{ ctx.session_id, i });
            std.Thread.sleep(100_000_000); // 100ms
        }
    }

    std.log.info("SSE stream handler ending: session_id={s}", .{ctx.session_id});
    ctx.server.sse_manager.remove(ctx.session_id);
    // Free the session_id that was allocated in streamHandler
    ctx.server.allocator.free(ctx.session_id);
}

fn streamHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const session_id_param = req.param("session_id");

    if (session_id_param == null) {
        res.status = 400;
        res.body = "Missing session_id";
        return;
    }

    if (global_server) |server| {
        const session_id = session_id_param.?;
        std.log.info("SSE STREAM CONNECTED: session_id={s}", .{session_id});

        // Duplicate session_id for the context (it must outlive this function)
        const session_id_copy = try server.allocator.dupe(u8, session_id);
        errdefer server.allocator.free(session_id_copy);

        const ctx = SseStreamCtx{
            .server = server,
            .session_id = session_id_copy,
        };

        // startEventStream sets SSE headers and spawns a thread calling sseStreamHandler
        // Note: session_id_copy is now owned by the spawned thread and will be freed in sseStreamHandler
        try res.startEventStream(ctx, sseStreamHandler);
    } else {
        res.status = 500;
        res.body = "Server not available";
    }
}

pub fn parseCommand(allocator: std.mem.Allocator, json: []const u8) !Command {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const command_type = if (root.get("command_type")) |v|
        try allocator.dupe(u8, v.string)
    else
        try allocator.dupe(u8, "");

    const session_id = if (root.get("session_id")) |v|
        try allocator.dupe(u8, v.string)
    else
        try allocator.dupe(u8, "");

    const content = if (root.get("content")) |v|
        try allocator.dupe(u8, v.string)
    else
        try allocator.dupe(u8, "");

    const cwd_session = if (root.get("cwd_session")) |v|
        try allocator.dupe(u8, v.string)
    else
        try allocator.dupe(u8, "");

    return Command{
        .command_type = command_type,
        .session_id = session_id,
        .content = content,
        .cwd_session = cwd_session,
    };
}

test {
    _ = @import("http_server_test.zig");
}
