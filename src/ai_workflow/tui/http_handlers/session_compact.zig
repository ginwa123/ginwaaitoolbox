const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const ai_workflow = root_mod.ai_workflow;
const llm_history = root_mod.llm_history;
const config = root_mod.config;
const agent = root_mod.agent;
const tool_models = root_mod.tool_models;
const http_response = root_mod.http_response;

/// Trigger session compaction directly (synchronous - blocks until done)
/// Path param: session_id
/// Returns JSON with result
pub fn sessionCompactHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    // Send initial acknowledgment via SSE
    if (gserverz.getGlobalSseManager()) |sse_manager| {
        const ack_response = try std.fmt.allocPrint(allocator, "{{\"app_type\":\"tui\",\"command_type\":\"compact_ack\",\"session_id\":\"{s}\",\"status\":\"processing\"}}", .{session_id});
        const event = gserverz.SseEvent{ .data = ack_response };
        sse_manager.enqueueEvent(session_id, event) catch {
            std.debug.print("Failed to send compact_ack response: SSE error\n", .{});
        };
    }

    // Get server context
    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;

            std.debug.print("[COMPACTION] Manual compaction triggered for session {s}\n", .{session_id});

            // Get cwd from session
            var cwd_buf: [4096]u8 = undefined;
            const cwd = blk: {
                const cwd_rows = llm_history.get_session(allocator, sqlite_db, session_id) catch null;
                if (cwd_rows) |session| {
                    defer session.deinit(allocator);
                    if (session.cwd.len > 0) {
                        break :blk std.fmt.bufPrint(&cwd_buf, "{s}", .{session.cwd}) catch ".";
                    }
                }
                break :blk std.fmt.bufPrint(&cwd_buf, ".", .{}) catch ".";
            };

            // Create LlmConfig for the workflow
            var llm_cfg = config.LlmConfig{
                .allocator = allocator,
                .api_key = ctxTui.llm_config.api_key,
                .model = ctxTui.llm_config.model,
                .base_url = ctxTui.llm_config.base_url,
                .model_compaction_size_kb = ctxTui.llm_config.model_compaction_size_kb,
                .mcpServers = null,
            };

            var workflow = ai_workflow.TUIWorkflow.init(ctxTui.io, sqlite_db, &llm_cfg, ctxTui.logger, null, ctxTui.active_loops);

            // Get session messages directly for compaction
            const db_messages = llm_history.getMessages(allocator, sqlite_db, session_id) catch |err| {
                std.debug.print("[COMPACTION] getMessages failed: {}\n", .{err});
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try std.fmt.allocPrint(allocator, "{{\"success\":false,\"error\":\"getMessages failed\"}}", .{}) });
            };

            // Build initial messages from DB
            const buildMessages = @import("../build_messages_for_agent_prompt.zig").buildMessages;
            var messagesLists = std.ArrayList(agent.AgentMessage).empty;
            defer messagesLists.deinit(allocator);

            // Get all tool definitions (empty for manual compaction)
            const merged_tools: []tool_models.AgentTool = &.{};

            const initialMessages = buildMessages(allocator, ctxTui.io, sqlite_db, cwd, session_id, db_messages, merged_tools) catch |err| {
                std.debug.print("[COMPACTION] buildMessages failed: {}\n", .{err});
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try std.fmt.allocPrint(allocator, "{{\"success\":false,\"error\":\"buildMessages failed\"}}", .{}) });
            };

            messagesLists.appendSlice(allocator, initialMessages) catch |err| {
                std.debug.print("[COMPACTION] appendSlice failed: {}\n", .{err});
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try std.fmt.allocPrint(allocator, "{{\"success\":false,\"error\":\"appendSlice failed\"}}", .{}) });
            };

            // Call CompactionAgent
            const compacted_xml = workflow.callCompactAgent(messagesLists.items, allocator, ctxTui.llm_config.api_key, ctxTui.llm_config.model, ctxTui.llm_config.base_url, cwd);
            if (compacted_xml) |xml| {
                workflow.compactMessageInMemory(allocator, &messagesLists, xml, session_id, ctxTui.llm_config.model, cwd) catch {
                    std.debug.print("[COMPACTION] compactMessageInMemory failed\n", .{});
                    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try std.fmt.allocPrint(allocator, "{{\"success\":false,\"error\":\"compactMessageInMemory failed\"}}", .{}) });
                };
            } else {
                std.debug.print("[COMPACTION] callCompactAgent returned null\n", .{});
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try std.fmt.allocPrint(allocator, "{{\"success\":false,\"error\":\"CompactionAgent failed\"}}", .{}) });
            }

            std.debug.print("[COMPACTION] Manual compaction completed for session {s}\n", .{session_id});
            return res.jsonResponse(allocator, .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"message\":\"Compaction completed\"}}", .{}) });
        }
    }
    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}