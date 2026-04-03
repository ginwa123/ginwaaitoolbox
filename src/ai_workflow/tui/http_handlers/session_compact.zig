const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;
const logger = nalarcore.logger;
const kerjabot_get_session = nalarcore.kerjabot_get_session;
const config = nalarcore.config;

const httpz = http_server.httpz;

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
