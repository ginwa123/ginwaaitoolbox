const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;
const logger = nalarcore.logger;

const httpz = http_server.httpz;
const WorkflowArgs = @import("mod.zig").WorkflowArgs;
const generateSessionId = @import("mod.zig").generateSessionId;

/// Thread arguments for session creation workflow
const SessionCreateThreadArgs = struct {
    allocator: std.mem.Allocator,
    ctxTui: *ai_workflow.ContextIPCTui,
    session_id: []u8,
    session_name: []u8,
    queue_message: []u8,
    cwd_session: []u8,
    body_message: []u8,
    allowed_tools: []u8,
};

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
    var allowed_tools: []const u8 = ""; // empty string = no tools allowed, "all" = all tools allowed, comma-separated list = specific tools
    var body_message: []const u8 = ""; // initial message from body field

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

        // Extract body field (initial message from body field)
        if (root.get("body")) |val| {
            if (val == .string) {
                body_message = val.string;
            }
        }

        // Extract allowed_tools field (comma-separated list or "all")
        if (root.get("allowed_tools")) |val| {
            if (val == .string) {
                allowed_tools = val.string;
            }
        }
    } else {
        // No body provided, generate session ID
        session_id = try generateSessionId(alloc);
    }

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));

            // Spawn workflow in detached thread (fire-and-forget)
            // First allocate all strings, then create struct (to handle partial failures)
            const session_id_alloc = try server.allocator.dupe(u8, session_id);
            errdefer server.allocator.free(session_id_alloc);
            const session_name_alloc = try server.allocator.dupe(u8, session_name);
            errdefer server.allocator.free(session_name_alloc);
            const queue_message_alloc = if (queue_message) |m| try server.allocator.dupe(u8, m) else try server.allocator.dupe(u8, "");
            errdefer server.allocator.free(queue_message_alloc);
            const cwd_session_alloc = if (cwd_session) |c| try server.allocator.dupe(u8, c) else try server.allocator.dupe(u8, "");
            errdefer server.allocator.free(cwd_session_alloc);
            const body_message_alloc = try server.allocator.dupe(u8, body_message);
            errdefer server.allocator.free(body_message_alloc);
            const allowed_tools_alloc = try server.allocator.dupe(u8, allowed_tools);
            errdefer server.allocator.free(allowed_tools_alloc);

            const thread_args = try server.allocator.create(SessionCreateThreadArgs);
            errdefer server.allocator.destroy(thread_args);

            thread_args.* = .{
                .allocator = server.allocator,
                .ctxTui = ctxTui,
                .session_id = session_id_alloc,
                .session_name = session_name_alloc,
                .queue_message = queue_message_alloc,
                .cwd_session = cwd_session_alloc,
                .body_message = body_message_alloc,
                .allowed_tools = allowed_tools_alloc,
            };

            const thread = try std.Thread.spawn(.{}, struct {
                fn run(args: *SessionCreateThreadArgs) void {
                    var thread_arena = std.heap.ArenaAllocator.init(args.allocator);
                    defer thread_arena.deinit();
                    const thread_alloc = thread_arena.allocator();

                    const sqlite_db = args.ctxTui.db;

                    // Ensure session exists in sessions table (for JOIN queries)
                    if (args.cwd_session.len > 0) {
                        const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status, cwd) VALUES (?, ?, 'active', ?)";
                        const copy_session_name = thread_alloc.dupe(u8, args.session_name) catch return;
                        sqlite_db.exec(thread_alloc, session_sql, &.{ args.session_id, copy_session_name, args.cwd_session }) catch {
                            // Non-fatal error, continue anyway
                        };
                    } else {
                        const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status) VALUES (?, ?, 'active')";
                        const copy_session_name = thread_alloc.dupe(u8, args.session_name) catch return;
                        sqlite_db.exec(thread_alloc, session_sql, &.{ args.session_id, copy_session_name }) catch {
                            // Non-fatal error, continue anyway
                        };
                    }

                    // Create workflow args
                    const workflow_args = thread_alloc.create(WorkflowArgs) catch return;

                    workflow_args.* = .{
                        .allocator = thread_alloc,
                        .sqlite_db = sqlite_db,
                        .logger = args.ctxTui.logger,
                        .llm_config = args.ctxTui.llm_config,
                        .session_id = args.session_id,
                        .message = args.queue_message,
                        .cwd = args.cwd_session,
                        .body = args.body_message,
                        .allowed_tools = args.allowed_tools,
                    };

                    var workflow = ai_workflow.TUIWorkflow.init(workflow_args.sqlite_db, workflow_args.llm_config, workflow_args.logger);
                    workflow.runAgenticMultiStep(.{
                        .parent_allocator = thread_alloc,
                        .parent_session_id = workflow_args.session_id,
                        .session_id = workflow_args.session_id,
                        .message = workflow_args.message,
                        .cwd = workflow_args.cwd,
                        .body = workflow_args.body,
                        .allowed_tools = workflow_args.allowed_tools,
                    }) catch |err| {
                        workflow_args.logger.errFmt("workflow.runAgenticMultiStep failed: {s}", .{@errorName(err)}) catch {};
                    };

                    // Clean up thread_args allocations (allocated before thread started)
                    const server_alloc = args.allocator;
                    server_alloc.free(args.session_id);
                    server_alloc.free(args.session_name);
                    server_alloc.free(args.queue_message);
                    server_alloc.free(args.cwd_session);
                    server_alloc.free(args.body_message);
                    server_alloc.free(args.allowed_tools);
                    server_alloc.destroy(args);
                }
            }.run, .{thread_args});
            thread.detach();

            res.status = 201;
            res.body = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"status\":\"{s}\"}}", .{ session_id, session_name, "send" });
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}
