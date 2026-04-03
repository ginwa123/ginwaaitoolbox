const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;
const WorkflowArgs = @import("mod.zig").WorkflowArgs;

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
