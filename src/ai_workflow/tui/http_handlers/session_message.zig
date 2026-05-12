const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;
const llm_history = nalarcore.llm_history;
const http_response = nalarcore.http_response;
const getResponseFormat = @import("mod.zig").getResponseFormat;

/// Get messages for a session
pub fn session_message_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(req.arena, .{ .@"error" = "Missing session_id" });
        return;
    };

    const query = try req.query();
    const limit_str = query.get("limit") orelse "100";
    const cursor = query.get("cursor");
    const sort_by_str = query.get("sort_by") orelse "created_at";
    const direction_str = query.get("direction") orelse "asc";
    const limit_val = std.fmt.parseInt(u32, limit_str, 10) catch 100;

    // Determine sort direction (default: asc)
    const is_desc = std.mem.eql(u8, direction_str, "desc");

    // Parse sort_by parameter and combine with direction
    const sort_spec: llm_history.SortSpec = blk: {
        if (std.mem.eql(u8, sort_by_str, "id")) {
            break :blk if (is_desc)
                llm_history.SortSpec{ .id_desc = {} }
            else
                llm_history.SortSpec{ .id_asc = {} };
        } else if (std.mem.eql(u8, sort_by_str, "role")) {
            break :blk if (is_desc)
                llm_history.SortSpec{ .role_desc = {} }
            else
                llm_history.SortSpec{ .role_asc = {} };
        } else {
            // Default to created_at
            break :blk if (is_desc)
                llm_history.SortSpec{ .created_at_desc = {} }
            else
                llm_history.SortSpec{ .created_at_asc = {} };
        }
    };

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            const msg_response = llm_history.getSessionMessagesSorted(alloc, sqlite_db, session_id, limit_val, cursor, sort_spec) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Database query failed" });
                return;
            };

            // Convert llm_history.SessionMessageResponse to http_response.SessionMessagesResponse
            var messages: []http_response.SessionMessage = try alloc.alloc(http_response.SessionMessage, msg_response.messages.len);
            for (msg_response.messages, 0..) |msg, idx| {
                messages[idx] = http_response.SessionMessage{
                    .id = msg.id,
                    .session_id = msg.session_id,
                    .role = msg.role,
                    .content = msg.content,
                    .timestamp = msg.timestamp,
                    .is_input = msg.is_input,
                    .is_output = msg.is_output,
                    .tool_name = msg.tool_name,
                    .finish_reason = msg.finish_reason,
                    .reasoning_content = msg.reasoning_content,
                };
            }

            const http_resp = http_response.SessionMessagesResponse{
                .messages = messages,
                .has_more = msg_response.has_more,
                .next_cursor = msg_response.next_cursor,
                .cwd = msg_response.cwd,
                .max_total_tokens = msg_response.max_total_tokens,
                .max_capacity_total_tokens = msg_response.max_capacity_total_tokens,
            };

            res.status = 200;
            res.body = try http_response.makeSessionMessagesResponse(alloc, http_resp);
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}
