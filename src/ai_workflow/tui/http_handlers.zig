const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;
const logger = nalarcore.logger;

const kerjabot_create_session = nalarcore.kerjabot_create_session;
const kerjabot_get_session = nalarcore.kerjabot_get_session;
const kerjabot_get_list_session = nalarcore.kerjabot_get_list_session;
const tui_check_session_exists = nalarcore.tui_check_session_exists;
const session_helpers = nalarcore.session_helpers;
const session_db = nalarcore.session_db;
const session_table = nalarcore.session_table;
const session_queue_messages = nalarcore.session_queue_messages;
const config = nalarcore.config;
const cancellation_registry = nalarcore.session.cancellation_registry;

const httpz = http_server.httpz;
const SseEvent = http_server.SseEvent;
const SseConnectionManager = http_server.SseConnectionManager;

// Re-export handler types from http_server for convenience
pub const MessageHandler = http_server.MessageHandler;
pub const SessionHandler = http_server.SessionHandler;

// =============================================================================
// CORS Preflight Handler
// =============================================================================

/// Handle OPTIONS preflight requests for CORS
pub fn corsPreflightHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    _ = req;
    res.status = 204;
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    res.header("Access-Control-Allow-Headers", "Content-Type, Authorization, Accept, Origin");
    res.header("Access-Control-Max-Age", "86400");
}

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

/// Workflow arguments for async LLM execution
const WorkflowArgs = struct {
    allocator: std.mem.Allocator,
    sqlite_db: *sqlite.SqliteBackend,
    logger: *logger.Logger,
    session_id: []u8,
    message: []u8,
    cwd: []u8,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    llm_config: *const config.LlmConfig,
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
///   - cwd_session: working directory (string, optional)
/// Returns JSON with created session info
pub fn session_create_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    // Generate or parse session ID
    var session_id: []u8 = undefined;
    var session_name: []const u8 = "New Session";
    var queue_message: ?[]const u8 = null;
    var cwd_session: ?[]const u8 = null;

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

        // Extract cwd_session if provided
        if (root.get("cwd_session")) |val| {
            if (val == .string) {
                cwd_session = val.string;
            }
        }
    } else {
        // No body provided, generate session ID
        session_id = try generateSessionId(alloc);
    }

    if (http_server.global_server) |server| {
        if (server.db) |db| {
            const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));
            if (server.ctx) |ctx| {
                const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));

                // Spawn workflow in detached thread (fire-and-forget)
                const workflow_args = try server.allocator.create(WorkflowArgs);
                workflow_args.* = .{
                    .allocator = server.allocator,
                    .sqlite_db = sqlite_db,
                    .logger = ctxTui.logger,
                    .session_id = try server.allocator.dupe(u8, session_id),
                    .message = try server.allocator.dupe(u8, queue_message orelse ""),
                    .cwd = try server.allocator.dupe(u8, cwd_session orelse ""),
                    .api_key = ctxTui.llm_config.api_key,
                    .model = ctxTui.llm_config.model,
                    .base_url = ctxTui.llm_config.base_url,
                    .llm_config = ctxTui.llm_config,
                };

                const thread = try std.Thread.spawn(.{}, struct {
                    fn run(args: *WorkflowArgs) void {
                        defer {
                            args.allocator.free(args.session_id);
                            args.allocator.free(args.message);
                            args.allocator.free(args.cwd);
                            args.allocator.destroy(args);
                        }
                        var arena = std.heap.ArenaAllocator.init(args.allocator);
                        defer arena.deinit();
                        var workflow = ai_workflow.TUIWorkflow.init(args.sqlite_db, args.logger);
                        workflow.run(
                            arena.allocator(),
                            args.session_id,
                            args.message,
                            args.cwd,
                            args.api_key,
                            args.model,
                            args.base_url,
                            args.llm_config,
                        );
                    }
                }.run, .{workflow_args});
                thread.detach();
            }

            res.status = 201;
            res.body = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"status\":\"{s}\"}}", .{ session_id, session_name, "send" });
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
// SSE Disconnect Handler
// =============================================================================

/// Notify server that client is disconnecting from SSE stream
/// This removes the SSE connection from the manager so server can clean up
pub fn sseDisconnectHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    if (http_server.global_server) |server| {
        server.sse_manager.remove(session_id);
        std.log.info("SSE client notified disconnect: session_id={s}", .{session_id});
        res.status = 200;
        res.body = "{\"status\":\"disconnected\"}";
        return;
    }

    res.status = 500;
    res.body = "{\"error\":\"Server not available\"}";
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
// LLM Run Handler (TUI)
// =============================================================================

/// Run LLM workflow for a session
/// Request body (JSON):
///   - session_id: session ID (required)
///   - message: message to process (required)
///   - cwd_session: working directory (optional)
/// Returns JSON with accepted status
pub fn llmRunHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const body = req.body() orelse "";
    if (body.len == 0) {
        res.status = 400;
        res.body = "{\"error\":\"Missing request body\"}";
        return;
    }

    // Parse JSON body
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        res.status = 400;
        res.body = "{\"error\":\"Invalid JSON\"}";
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    const session_id = root.get("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };
    if (session_id != .string) {
        res.status = 400;
        res.body = "{\"error\":\"session_id must be a string\"}";
        return;
    }

    const message = root.get("message") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing message\"}";
        return;
    };
    if (message != .string) {
        res.status = 400;
        res.body = "{\"error\":\"message must be a string\"}";
        return;
    }

    const cwd_session = if (root.get("cwd_session")) |v| if (v == .string) v.string else "" else "";

    if (http_server.global_server) |server| {
        if (server.db) |db| {
            const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));
            if (server.ctx) |ctx| {
                const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));

                // Spawn workflow in detached thread
                const workflow_args = try server.allocator.create(WorkflowArgs);
                workflow_args.* = .{
                    .allocator = server.allocator,
                    .sqlite_db = sqlite_db,
                    .logger = ctxTui.logger,
                    .session_id = try server.allocator.dupe(u8, session_id.string),
                    .message = try server.allocator.dupe(u8, message.string),
                    .cwd = try server.allocator.dupe(u8, cwd_session),
                    .api_key = ctxTui.llm_config.api_key,
                    .model = ctxTui.llm_config.model,
                    .base_url = ctxTui.llm_config.base_url,
                    .llm_config = ctxTui.llm_config,
                };

                const thread = try std.Thread.spawn(.{}, struct {
                    fn run(args: *WorkflowArgs) void {
                        defer {
                            args.allocator.free(args.session_id);
                            args.allocator.free(args.message);
                            args.allocator.free(args.cwd);
                            args.allocator.destroy(args);
                        }
                        var arena = std.heap.ArenaAllocator.init(args.allocator);
                        defer arena.deinit();
                        var workflow = ai_workflow.TUIWorkflow.init(args.sqlite_db, args.logger);
                        workflow.run(
                            arena.allocator(),
                            args.session_id,
                            args.message,
                            args.cwd,
                            args.api_key,
                            args.model,
                            args.base_url,
                            args.llm_config,
                        );
                    }
                }.run, .{workflow_args});
                thread.detach();

                res.status = 202;
                res.body = try std.fmt.allocPrint(alloc, "{{\"status\":\"processing\",\"session_id\":\"{s}\"}}", .{session_id.string});
                return;
            }
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

// =============================================================================
// Session Cancel Handler (TUI)
// =============================================================================

/// Cancel an active session
/// Path param: session_id
/// Returns JSON with cancelled status
pub fn sessionCancelHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    if (cancellation_registry.get_global_registry()) |registry| {
        registry.cancel(session_id);
        res.status = 200;
        res.body = try std.fmt.allocPrint(req.arena, "{{\"status\":\"cancelled\",\"session_id\":\"{s}\"}}", .{session_id});
        return;
    }

    res.status = 500;
    res.body = "{\"error\":\"Cancellation registry not available\"}";
}

// =============================================================================
// Session Compact Handler (TUI)
// =============================================================================

/// Trigger session compaction
/// Path param: session_id
/// Returns JSON with processing status
pub fn sessionCompactHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    // Send initial acknowledgment via SSE
    if (http_server.getGlobalSseManager()) |sse_manager| {
        const ack_response = try std.fmt.allocPrint(alloc, "{{\"app_type\":\"tui\",\"command_type\":\"compact_ack\",\"session_id\":\"{s}\",\"status\":\"processing\"}}", .{session_id});
        const event = http_server.SseEvent{ .data = ack_response };
        sse_manager.sendEvent(session_id, event) catch {
            std.debug.print("Failed to send compact_ack response: SSE error\n", .{});
        };
    }

    // Run compaction in a separate thread
    if (http_server.global_server) |server| {
        if (server.db) |db| {
            const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));
            if (server.ctx) |ctx| {
                const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));

                std.debug.print("[COMPACTION] Manual compaction triggered for session {s}\n", .{session_id});

                const thread = try std.Thread.spawn(.{}, struct {
                    fn run(sqliteDb: *sqlite.SqliteBackend, sessId: []const u8, api_key: []const u8, model: []const u8, base_url: []const u8, compaction_kb: usize, threadAlloc: std.mem.Allocator, loggerPtr: *logger.Logger) void {
                        var arena = std.heap.ArenaAllocator.init(threadAlloc);
                        defer arena.deinit();
                        const threadAlloc2 = arena.allocator();

                        // Get cwd from session
                        var cwd_buf: [4096]u8 = undefined;
                        const cwd = blk: {
                            const result = kerjabot_get_session.getSession(threadAlloc2, sqliteDb, sessId) catch null;
                            if (result) |session| {
                                defer session.deinit(threadAlloc2);
                                if (session.session_dir.len > 0) {
                                    break :blk std.fmt.bufPrint(&cwd_buf, "{s}", .{session.session_dir}) catch ".";
                                }
                            }
                            break :blk std.fmt.bufPrint(&cwd_buf, ".", .{}) catch ".";
                        };

                        // Create LlmConfig for the workflow
                        var llm_cfg = config.LlmConfig{
                            .allocator = threadAlloc2,
                            .api_key = api_key,
                            .model = model,
                            .base_url = base_url,
                            .model_compaction_size_kb = compaction_kb,
                            .mcpServers = null,
                        };

                        var workflow = ai_workflow.TUIWorkflow.init(sqliteDb, loggerPtr);
                        workflow.run(threadAlloc2, sessId, "", cwd, api_key, model, base_url, &llm_cfg);
                    }
                }.run, .{ sqlite_db, session_id, ctxTui.llm_config.api_key, ctxTui.llm_config.model, ctxTui.llm_config.base_url, ctxTui.llm_config.model_compaction_size_kb, server.allocator, ctxTui.logger });
                thread.detach();

                res.status = 202;
                res.body = try std.fmt.allocPrint(alloc, "{{\"status\":\"processing\",\"session_id\":\"{s}\"}}", .{session_id});
                return;
            }
        }
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
