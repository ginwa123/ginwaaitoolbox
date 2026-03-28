const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const sqlite = nalarcore.sqlite;

const kerjabot_create_session = nalarcore.kerjabot_create_session;
const kerjabot_get_session = nalarcore.kerjabot_get_session;
const kerjabot_get_list_session = nalarcore.kerjabot_get_list_session;
const tui_check_session_exists = nalarcore.tui_check_session_exists;
const session_helpers = nalarcore.session_helpers;
const session_db = nalarcore.session_db;

const httpz = http_server.httpz;
const SseEvent = http_server.SseEvent;
const SseConnectionManager = http_server.SseConnectionManager;

// Re-export handler types from http_server for convenience
pub const MessageHandler = http_server.MessageHandler;
pub const SessionHandler = http_server.SessionHandler;

// =============================================================================
// SSE Stream Handlers
// =============================================================================

const SseStreamCtx = struct {
    server: *http_server.HttpServer,
    session_id: []const u8,
};

fn sseStreamHandler(ctx: SseStreamCtx, stream: std.net.Stream) void {
    std.log.info("SSE stream handler started: session_id={s}", .{ctx.session_id});

    ctx.server.sse_manager.register(ctx.session_id, stream) catch {
        std.log.err("SSE: Failed to register stream for session: {s}", .{ctx.session_id});
        return;
    };

    const connected_data = std.fmt.allocPrint(ctx.server.allocator, "event: connected\n{{\"session_id\":\"{s}\"}}\n\n", .{ctx.session_id}) catch {
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

    while (ctx.server.sse_manager.hasSession(ctx.session_id)) {
        std.Thread.sleep(30_000_000_000);

        stream.writeAll(": keepalive\n\n") catch |err| {
            std.log.warn("SSE keepalive failed for session {s}: {s}", .{ ctx.session_id, @errorName(err) });
            break;
        };

        var i: usize = 0;
        while (i < 300 and ctx.server.sse_manager.hasSession(ctx.session_id)) : (i += 1) {
            std.Thread.sleep(100_000_000);
        }
    }

    std.log.info("SSE stream handler ending: session_id={s}", .{ctx.session_id});
    ctx.server.sse_manager.remove(ctx.session_id);
    ctx.server.allocator.free(ctx.session_id);
}

/// SSE stream endpoint - establishes persistent connection for real-time events
pub fn streamHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "Missing session_id";
        return;
    };

    if (http_server.global_server) |server| {
        std.log.info("SSE STREAM CONNECTED: session_id={s}", .{session_id});

        const session_id_copy = try server.allocator.dupe(u8, session_id);
        errdefer server.allocator.free(session_id_copy);

        const ctx = SseStreamCtx{
            .server = server,
            .session_id = session_id_copy,
        };

        try res.startEventStream(ctx, sseStreamHandler);
    } else {
        res.status = 500;
        res.body = "Server not available";
    }
}

// =============================================================================
// Message Handler (Async, Fire-and-Forget)
// =============================================================================

/// Handle incoming command messages asynchronously
/// Messages are processed in a detached thread for non-blocking operation
pub fn commandHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    if (http_server.global_server) |server| {
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
            thread.detach();
        }
    }

    res.status = 200;
    res.body = "ok";
}

/// Handler arguments for async message handling
const HandlerArgs = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    handler: MessageHandler,
    ctx: ?*anyopaque,
};

// =============================================================================
// Session Handlers (TUI)
// =============================================================================

/// Create a new session - delegates to registered session handler
pub fn sessionCreateHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    if (http_server.global_server) |server| {
        if (server.session_handler) |sess_handler| {
            const body = req.body() orelse "";

            var arena = std.heap.ArenaAllocator.init(server.allocator);
            defer arena.deinit();
            sess_handler(arena.allocator(), body, server.ctx, res);
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"No session handler\"}";
}

/// List all sessions - returns sessions from database
pub fn sessionListHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const query = try req.query();
    const limit_str = query.get("limit") orelse "50";
    const offset_str = query.get("offset") orelse "0";
    const limit_val = std.fmt.parseInt(u32, limit_str, 10) catch 50;
    const offset_val = std.fmt.parseInt(u32, offset_str, 10) catch 0;

    if (http_server.global_server) |server| {
        if (server.db) |db| {
            const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));
            const result = session_db.getSessionList(alloc, sqlite_db, null, null, limit_val, offset_val) catch {
                res.status = 500;
                res.body = "{\"error\":\"Database query failed\"}";
                return;
            };
            defer {
                for (result.sessions) |s| s.deinit(alloc);
                alloc.free(result.sessions);
            }

            // Build JSON response
            const response = try session_db.buildSessionListJson(
                alloc, result.sessions, result.total);

            res.status = 200;
            res.body = response;
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

/// Check if a session exists in the database
pub fn sessionExistsHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    if (http_server.global_server) |server| {
        if (server.db) |db| {
            const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));
            const exists = tui_check_session_exists.check_session_exists(server.allocator, sqlite_db, session_id);
            res.status = 200;
            res.body = try std.fmt.allocPrint(req.arena, "{{\"session_id\":\"{s}\",\"exists\":{s}}}", .{ session_id, if (exists) "true" else "false" });
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

/// Get a session by ID
pub fn session_get_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    if (http_server.global_server) |server| {
        if (server.db) |db| {
            const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));
            const session = session_db.get_session(alloc, sqlite_db, session_id) catch {
                res.status = 500;
                res.body = "{\"error\":\"Database query failed\"}";
                return;
            };

            if (session) |s| {
                const response = try std.fmt.allocPrint(alloc,
                    "{{\"sessionId\":\"{s}\",\"sessionDir\":\"{s}\",\"createdAt\":\"{s}\",\"agent\":\"{s}\",\"sessionName\":\"{s}\"}}",
                    .{ s.session_id, s.session_dir, s.created_at, s.agent, s.session_name });
                s.deinit(alloc);
                res.status = 200;
                res.body = response;
            } else {
                res.status = 404;
                res.body = "{\"error\":\"Session not found\"}";
            }
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

/// Get messages for a session
pub fn sessionMessagesHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    const query = try req.query();
    const limit_str = query.get("limit") orelse "100";
    const offset_str = query.get("offset") orelse "0";
    const limit_val = std.fmt.parseInt(u32, limit_str, 10) catch 100;
    const offset_val = std.fmt.parseInt(u32, offset_str, 10) catch 0;

    if (http_server.global_server) |server| {
        if (server.db) |db| {
            const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));
            const messages = session_db.getSessionMessages(alloc, sqlite_db, session_id, limit_val, offset_val) catch {
                res.status = 500;
                res.body = "{\"error\":\"Database query failed\"}";
                return;
            };
            defer {
                for (messages) |m| m.deinit(alloc);
                alloc.free(messages);
            }

            const response = try session_db.buildSessionMessagesJson(alloc, messages);
            res.status = 200;
            res.body = response;
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

/// Get the latest session for a given working directory
pub fn getLatestSessionByDirHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;

    const query = try req.query();
    const cwd = query.get("cwd") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing cwd parameter\"}";
        return;
    };

    if (http_server.global_server) |server| {
        if (server.db) |db| {
            const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));
            var arena = std.heap.ArenaAllocator.init(server.allocator);
            defer arena.deinit();

            const latest_session = session_helpers.getLatestSessionByDir(arena.allocator(), sqlite_db, cwd) catch {
                res.status = 500;
                res.body = "{\"error\":\"Database query failed\"}";
                return;
            };

            if (latest_session) |session| {
                defer {
                    arena.allocator().free(session.session_id);
                    arena.allocator().free(session.session_dir);
                    arena.allocator().free(session.created_at);
                }
                res.status = 200;
                res.body = try std.fmt.allocPrint(req.arena,
                    "{{\"session_id\":\"{s}\",\"session_dir\":\"{s}\",\"created_at\":\"{s}\",\"found\":true}}"
                , .{ session.session_id, session.session_dir, session.created_at });
            } else {
                res.status = 200;
                res.body = "{\"found\":false}";
            }
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

// =============================================================================
// Ping Handler (TUI)
// =============================================================================

/// Ping endpoint for connection health checks
/// Returns connection status for a given session
pub fn pingHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };
    if (http_server.global_server) |server| {
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

// =============================================================================
// Test
// =============================================================================

test {
    _ = http_server;
}
