const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;
const logger = nalarcore.logger;
const llm_history = nalarcore.llm_history;
const config = nalarcore.config;
const agent = nalarcore.agent;
const llm_models = nalarcore.llm_models;
const tool_models = nalarcore.tool_models;

const httpz = http_server.httpz;

/// Trigger session compaction directly
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
        sse_manager.enqueueEvent(session_id, event) catch {
            std.debug.print("Failed to send compact_ack response: SSE error\n", .{});
        };
    }

    // Get server context
    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            std.debug.print("[COMPACTION] Manual compaction triggered for session {s}\n", .{session_id});

            // Run compaction in a separate thread to not block the HTTP response
            const thread = try std.Thread.spawn(.{}, struct {
                fn run(sqliteDb: *sqlite.SqliteBackend, sessId: []const u8, api_key: []const u8, model: []const u8, base_url: []const u8, compaction_kb: usize, threadAlloc: std.mem.Allocator, loggerPtr: *logger.Logger, io: std.Io) void {
                    var arena = std.heap.ArenaAllocator.init(threadAlloc);
                    defer arena.deinit();
                    const threadAlloc2 = arena.allocator();

                    // Get cwd from session
                    var cwd_buf: [4096]u8 = undefined;
                    const cwd = blk: {
                        const cwd_rows = llm_history.get_session(threadAlloc2, sqliteDb, sessId) catch null;
                        if (cwd_rows) |session| {
                            defer session.deinit(threadAlloc2);
                            if (session.cwd.len > 0) {
                                break :blk std.fmt.bufPrint(&cwd_buf, "{s}", .{session.cwd}) catch ".";
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

                    var workflow = ai_workflow.TUIWorkflow.init(io, sqliteDb, &llm_cfg, loggerPtr, null);

                    // Get session messages directly for compaction
                    const db_messages = llm_history.getMessages(threadAlloc2, sqliteDb, sessId) catch |err| {
                        loggerPtr.errFmt("getMessages failed: {}", .{err}) catch {};
                        return;
                    };
                    defer {
                        for (db_messages) |*msg| msg.deinit(threadAlloc2);
                        threadAlloc2.free(db_messages);
                    }

                    if (db_messages.len < 2) {
                        loggerPtr.debugFmt("[COMPACTION] Skipped: only {} message(s)", .{db_messages.len}) catch {};
                        return;
                    }

                    // Build initial messages from DB
                    const buildMessages = @import("../build_messages_for_agent_prompt.zig").buildMessages;
                    var messagesLists = std.ArrayList(agent.AgentMessage).empty;
                    defer messagesLists.deinit(threadAlloc2);

                    // Get all tool definitions (empty for manual compaction)
                    const merged_tools: []tool_models.AgentTool = &.{};

                    const initialMessages = buildMessages(threadAlloc2, io, sqliteDb, cwd, sessId, db_messages, merged_tools) catch |err| {
                        loggerPtr.errFmt("buildMessages failed: {}", .{err}) catch {};
                        return;
                    };
                    defer for (initialMessages) |*msg| msg.deinit(threadAlloc2);

                    messagesLists.appendSlice(threadAlloc2, initialMessages) catch |err| {
                        loggerPtr.errFmt("appendSlice failed: {}", .{err}) catch {};
                        return;
                    };

                    // Check if compaction is needed
                    var total_tokens: u32 = 0;
                    for (db_messages) |msg| {
                        if (msg.total_tokens > total_tokens) {
                            total_tokens = msg.total_tokens;
                        }
                    }

                    loggerPtr.debugFmt("[COMPACTION] Total tokens from DB: {} ({} messages)", .{ total_tokens, messagesLists.items.len }) catch {};

                    if (!llm_models.is_do_compact(total_tokens, llm_models.get_model_token_count(model))) {
                        loggerPtr.debugFmt("[COMPACTION] Threshold not exceeded, skipping", .{}) catch {};
                        return;
                    }

                    loggerPtr.debugFmt("[COMPACTION] Threshold exceeded, triggering compaction", .{}) catch {};

                    // Call CompactionAgent
                    if (workflow.callCompactAgent(messagesLists.items, threadAlloc2, api_key, model, base_url, cwd)) |compacted_xml| {
                        workflow.compactMessageInMemory(threadAlloc2, &messagesLists, compacted_xml, sessId, model, cwd) catch {
                            loggerPtr.errFmt("compactMessageInMemory failed", .{}) catch {};
                        };
                    }

                    loggerPtr.infoFmt("[COMPACTION] Manual compaction completed for session {s}", .{sessId}) catch {};
                }
            }.run, .{ sqlite_db, session_id, ctxTui.llm_config.api_key, ctxTui.llm_config.model, ctxTui.llm_config.base_url, ctxTui.llm_config.model_compaction_size_kb, server.allocator, ctxTui.logger, ctxTui.io });
            thread.detach();

            res.status = 202;
            res.body = try std.fmt.allocPrint(alloc, "{{\"status\":\"processing\",\"session_id\":\"{s}\"}}", .{session_id});
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}
