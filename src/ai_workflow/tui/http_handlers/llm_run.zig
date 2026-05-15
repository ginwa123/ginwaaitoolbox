const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;
const http_response = nalarcore.http_response;

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
        res.status_code = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Missing request body" });
        return;
    }

    // Parse JSON body
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        res.status_code = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Invalid JSON" });
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    const session_id = root.get("session_id") orelse {
        res.status_code = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Missing session_id" });
        return;
    };
    if (session_id != .string) {
        res.status_code = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "session_id must be a string" });
        return;
    }

    const message = root.get("message") orelse {
        res.status_code = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Missing message" });
        return;
    };
    if (message != .string) {
        res.status_code = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "message must be a string" });
        return;
    }

    const cwd_session = if (root.get("cwd_session")) |v| if (v == .string) v.string else "" else "";

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            // Spawn workflow in detached thread
            const workflow_args = try server.allocator.create(WorkflowArgs);
            workflow_args.* = .{
                .allocator = server.allocator,
                .io = ctxTui.io,
                .sqlite_db = sqlite_db,
                .logger = ctxTui.logger,
                .llm_config = ctxTui.llm_config,
                .session_id = try server.allocator.dupe(u8, session_id.string),
                .message = try server.allocator.dupe(u8, message.string),
                .cwd = try server.allocator.dupe(u8, cwd_session),
                .environment = server.environment,
                .active_loops = ctxTui.active_loops,
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
                    var workflow = ai_workflow.TUIWorkflow.init(args.io, args.sqlite_db, args.llm_config, args.logger, args.environment, args.active_loops);
                    workflow.runAgenticMultiStep(.{
                        .parent_allocator = arena.allocator(),
                        .parent_session_id = args.session_id,
                        .session_id = args.session_id,
                        .message = args.message,
                        .cwd = args.cwd,
                        .body = "",
                        .allowed_tools = "",
                    }) catch |err| {
                        args.logger.errFmt("workflow.runAgenticMultiStep failed: {s}", .{@errorName(err)});
                    };
                }
            }.run, .{workflow_args});
            thread.detach();

            res.status_code = 202;
            res.body = try http_response.makeLlmRunResponse(alloc, .{ .status = "processing", .session_id = session_id.string });
            return;
        }
    }
    res.status_code = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}
