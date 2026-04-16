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

                // Ensure session exists in sessions table (for JOIN queries)
                const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status) VALUES (?, ?, 'active')";
                const copy_session_name = try alloc.dupe(u8, session_name);
                defer alloc.free(copy_session_name);
                sqlite_db.exec(alloc, session_sql, &.{ session_id, copy_session_name }) catch {
                    // Non-fatal error, continue anyway
                };

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
