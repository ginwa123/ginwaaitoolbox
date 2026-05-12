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
const http_response = nalarcore.http_response;

const httpz = http_server.httpz;

/// Trigger session compaction directly (synchronous - blocks until done)
/// Path param: session_id
/// Returns JSON with result
pub fn sessionCompactHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Missing session_id" });
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

            // Use req.arena directly as allocator
            const threadAlloc = alloc;

            // Get cwd from session
            var cwd_buf: [4096]u8 = undefined;
            const cwd = blk: {
                const cwd_rows = llm_history.get_session(threadAlloc, sqlite_db, session_id) catch null;
                if (cwd_rows) |session| {
                    defer session.deinit(threadAlloc);
                    if (session.cwd.len > 0) {
                        break :blk std.fmt.bufPrint(&cwd_buf, "{s}", .{session.cwd}) catch ".";
                    }
                }
                break :blk std.fmt.bufPrint(&cwd_buf, ".", .{}) catch ".";
            };

            // Create LlmConfig for the workflow
            var llm_cfg = config.LlmConfig{
                .allocator = threadAlloc,
                .api_key = ctxTui.llm_config.api_key,
                .model = ctxTui.llm_config.model,
                .base_url = ctxTui.llm_config.base_url,
                .model_compaction_size_kb = ctxTui.llm_config.model_compaction_size_kb,
                .mcpServers = null,
            };

            var workflow = ai_workflow.TUIWorkflow.init(ctxTui.io, sqlite_db, &llm_cfg, ctxTui.logger, null);

            // Get session messages directly for compaction
            const db_messages = llm_history.getMessages(threadAlloc, sqlite_db, session_id) catch |err| {
                std.debug.print("[COMPACTION] getMessages failed: {}\n", .{err});
                res.status = 500;
                res.body = try std.fmt.allocPrint(alloc, "{{\"success\":false,\"error\":\"getMessages failed\"}}", .{});
                return;
            };

            // Build initial messages from DB
            const buildMessages = @import("../build_messages_for_agent_prompt.zig").buildMessages;
            var messagesLists = std.ArrayList(agent.AgentMessage).empty;
            defer messagesLists.deinit(threadAlloc);

            // Get all tool definitions (empty for manual compaction)
            const merged_tools: []tool_models.AgentTool = &.{};

            const initialMessages = buildMessages(threadAlloc, ctxTui.io, sqlite_db, cwd, session_id, db_messages, merged_tools) catch |err| {
                std.debug.print("[COMPACTION] buildMessages failed: {}\n", .{err});
                res.status = 500;
                res.body = try std.fmt.allocPrint(alloc, "{{\"success\":false,\"error\":\"buildMessages failed\"}}", .{});
                return;
            };

            messagesLists.appendSlice(threadAlloc, initialMessages) catch |err| {
                std.debug.print("[COMPACTION] appendSlice failed: {}\n", .{err});
                res.status = 500;
                res.body = try std.fmt.allocPrint(alloc, "{{\"success\":false,\"error\":\"appendSlice failed\"}}", .{});
                return;
            };

            // Call CompactionAgent
            const compacted_xml = workflow.callCompactAgent(messagesLists.items, threadAlloc, ctxTui.llm_config.api_key, ctxTui.llm_config.model, ctxTui.llm_config.base_url, cwd);
            if (compacted_xml) |xml| {
                workflow.compactMessageInMemory(threadAlloc, &messagesLists, xml, session_id, ctxTui.llm_config.model, cwd) catch {
                    std.debug.print("[COMPACTION] compactMessageInMemory failed\n", .{});
                    res.status = 500;
                    res.body = try std.fmt.allocPrint(alloc, "{{\"success\":false,\"error\":\"compactMessageInMemory failed\"}}", .{});
                    return;
                };
            } else {
                std.debug.print("[COMPACTION] callCompactAgent returned null\n", .{});
                res.status = 500;
                res.body = try std.fmt.allocPrint(alloc, "{{\"success\":false,\"error\":\"CompactionAgent failed\"}}", .{});
                return;
            }

            std.debug.print("[COMPACTION] Manual compaction completed for session {s}\n", .{session_id});
            res.status = 200;
            res.body = try std.fmt.allocPrint(alloc, "{{\"success\":true,\"message\":\"Compaction completed\"}}", .{});
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}
