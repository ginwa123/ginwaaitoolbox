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
const session_table = nalarcore.session_table;
const session_queue_messages = nalarcore.session_queue_messages;

const httpz = http_server.httpz;
const SseEvent = http_server.SseEvent;
const SseConnectionManager = http_server.SseConnectionManager;

// Re-export handler types from http_server for convenience
pub const MessageHandler = http_server.MessageHandler;
pub const SessionHandler = http_server.SessionHandler;

// =============================================================================
// Response Format Helpers
// =============================================================================

/// Response format types
const ResponseFormat = enum { json, xml };

/// Determine response format from Accept header or query param
fn getResponseFormat(req: *httpz.Request) ResponseFormat {
    // First check Accept header (higher priority)
    if (req.header("accept")) |accept| {
        if (std.mem.indexOf(u8, accept, "text/xml") != null or
            std.mem.indexOf(u8, accept, "application/xml") != null)
        {
            return .xml;
        }
        if (std.mem.indexOf(u8, accept, "application/json") != null) {
            return .json;
        }
    }

    // Fallback to query parameter
    const query = req.query() catch return .json;
    const format_param = query.get("format") orelse return .json;

    if (std.mem.eql(u8, format_param, "xml")) {
        return .xml;
    }
    return .json;
}

/// Build error response based on format
fn buildErrorResponse(allocator: std.mem.Allocator, format: ResponseFormat, error_msg: []const u8) ![]u8 {
    if (format == .xml) {
        return std.fmt.allocPrint(allocator, "<error>{s}</error>", .{error_msg});
    } else {
        return std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{error_msg});
    }
}

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
        std.Thread.sleep(5_000_000_000); // 5 seconds

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

/// Hex digits for session ID generation
const hexDigits = "0123456789abcdef";

/// Generate a unique session ID using timestamp and random suffix
fn generateSessionId(allocator: std.mem.Allocator) ![]u8 {
    const timestamp = std.time.timestamp();
    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // Convert random bytes to hex string
    var hex_chars: [16]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex_chars[i * 2] = hexDigits[b >> 4];
        hex_chars[i * 2 + 1] = hexDigits[b & 0xF];
    }

    return std.fmt.allocPrint(allocator, "sess_{d}_{s}", .{ timestamp, hex_chars });
}

/// Create a new session
/// Request body (JSON, optional):
///   - name: session name (string, defaults to "New Session")
///   - session_id: custom session ID (string, optional, auto-generated if not provided)
///   - queue_message: initial message to add to session queue (string, optional)
/// Returns JSON with created session info
pub fn session_create_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    // Generate or parse session ID
    var session_id: []u8 = undefined;
    var session_name: []const u8 = "New Session";
    var queue_message: ?[]const u8 = null;

    const body = req.body() orelse "";

    if (body.len > 0) {
        // Parse JSON body for optional parameters
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
            res.status = 400;
            res.body = "{\"error\":\"Invalid JSON body\"}";
            return;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        // Extract session_id if provided
        if (root.get("session_id")) |val| {
            if (val == .string) {
                session_id = try alloc.dupe(u8, val.string);
            } else {
                res.status = 400;
                res.body = "{\"error\":\"session_id must be a string\"}";
                return;
            }
        } else {
            // Generate unique session ID
            session_id = try generateSessionId(alloc);
        }

        // Extract name if provided
        if (root.get("name")) |val| {
            if (val == .string) {
                session_name = val.string;
            }
        }

        // Extract queue_message if provided
        if (root.get("queue_message")) |val| {
            if (val == .string) {
                queue_message = val.string;
            }
        }
    } else {
        // No body provided, generate session ID
        session_id = try generateSessionId(alloc);
    }

    if (http_server.global_server) |server| {
        if (server.db) |db| {
            const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));
            var session: session_table.SessionInfo = undefined;

            // Check if session already exists
            const existing = session_table.get_session(alloc, sqlite_db, session_id) catch null;
            if (existing) |s| {
                session = s;
            } else {
                session = session_table.create_session(alloc, sqlite_db, session_id, session_name) catch {
                    res.status = 500;
                    res.body = "{\"error\":\"Failed to create session\"}";
                    return;
                };
                defer session.deinit(alloc);
            }

            // Create queue message if provided
            if (queue_message) |msg| {
                const msg_id = try generateSessionId(alloc);
                _ = session_queue_messages.create_queue_message(alloc, sqlite_db, msg_id, session_id, msg) catch {
                    // Log but don't fail - session was created successfully
                    std.log.err("Failed to create queue message for session {s}", .{session_id});
                };
            }

            // Return created session info
            res.status = 201;
            res.body = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"status\":\"{s}\"}}", .{ session.id, session.name, session.status });
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

/// List all sessions - returns sessions from database with cursor pagination
pub fn session_list_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const query = try req.query();
    const limit_str = query.get("limit") orelse "50";
    const cursor = query.get("cursor");
    const limit_val = std.fmt.parseInt(u32, limit_str, 10) catch 50;

    if (http_server.global_server) |server| {
        if (server.db) |db| {
            const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));
            const result = session_db.getSessionListWithCursor(alloc, sqlite_db, null, null, limit_val, cursor) catch {
                res.status = 500;
                res.body = "{\"error\":\"Database query failed\"}";
                return;
            };
            defer {
                for (result.sessions) |s| s.deinit(alloc);
                alloc.free(result.sessions);
            }

            // Determine if there are more results
            const has_more = result.sessions.len == @as(usize, limit_val);
            // Next cursor is the created_at of the last session
            const next_cursor: ?[]const u8 = if (result.sessions.len > 0)
                result.sessions[result.sessions.len - 1].created_at
            else
                null;

            // Build JSON response with cursor pagination
            const response = try session_db.buildSessionListJson(alloc, result.sessions, result.total, has_more, next_cursor);

            res.status = 200;
            res.body = response;
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

/// Check if a session exists in the database
pub fn session_exist_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
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
                const response = try std.fmt.allocPrint(alloc, "{{\"sessionId\":\"{s}\",\"sessionDir\":\"{s}\",\"createdAt\":\"{s}\",\"agent\":\"{s}\",\"sessionName\":\"{s}\"}}", .{ s.session_id, s.session_dir, s.created_at, s.agent, s.session_name });
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
pub fn session_message_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;

    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    const query = try req.query();
    const limit_str = query.get("limit") orelse "100";
    const cursor = query.get("cursor");
    const sort_by_str = query.get("sort_by") orelse "created_at";
    const direction_str = query.get("direction") orelse "asc";
    const limit_val = std.fmt.parseInt(u32, limit_str, 10) catch 100;

    // Determine response format from Accept header or query param
    const format = getResponseFormat(req);

    // Set content type based on format
    if (format == .xml) {
        res.content_type = .XML;
    } else {
        res.content_type = .JSON;
    }

    // Determine sort direction (default: asc)
    const is_desc = std.mem.eql(u8, direction_str, "desc");

    // Parse sort_by parameter and combine with direction
    // Use block to allow runtime conditions for union tag selection
    const sort_spec: session_db.SortSpec = blk: {
        if (std.mem.eql(u8, sort_by_str, "id")) {
            break :blk if (is_desc)
                session_db.SortSpec{ .id_desc = {} }
            else
                session_db.SortSpec{ .id_asc = {} };
        } else if (std.mem.eql(u8, sort_by_str, "role")) {
            break :blk if (is_desc)
                session_db.SortSpec{ .role_desc = {} }
            else
                session_db.SortSpec{ .role_asc = {} };
        } else {
            // Default to created_at
            break :blk if (is_desc)
                session_db.SortSpec{ .created_at_desc = {} }
            else
                session_db.SortSpec{ .created_at_asc = {} };
        }
    };

    if (http_server.global_server) |server| {
        if (server.db) |db| {
            const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));

            const msg_response = session_db.get_session_messages_sorted(alloc, sqlite_db, session_id, limit_val, cursor, sort_spec) catch {
                res.status = 500;
                res.body = try buildErrorResponse(alloc, format, "Database query failed");
                return;
            };
            defer {
                for (msg_response.messages) |m| m.deinit(alloc);
                alloc.free(msg_response.messages);
                if (msg_response.next_cursor) |c| alloc.free(c);
            }

            const response_body = if (format == .xml)
                try session_db.buildSessionMessagesXml(alloc, &msg_response)
            else
                try session_db.buildSessionMessagesJson(alloc, &msg_response);
            res.status = 200;
            res.body = response_body;
            return;
        }
    }
    res.status = 500;
    res.body = try buildErrorResponse(alloc, format, "Server not initialized");
}
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
                res.body = try std.fmt.allocPrint(req.arena, "{{\"session_id\":\"{s}\",\"session_dir\":\"{s}\",\"created_at\":\"{s}\",\"found\":true}}", .{ session.session_id, session.session_dir, session.created_at });
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
pub fn ping_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
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
