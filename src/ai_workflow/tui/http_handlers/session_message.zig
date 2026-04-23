const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;
const llm_history = nalarcore.llm_history;
const getResponseFormat = @import("mod.zig").getResponseFormat;
const buildErrorResponse = @import("mod.zig").buildErrorResponse;

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

            const msg_response = llm_history.get_session_messages_sorted(alloc, sqlite_db, session_id, limit_val, cursor, sort_spec) catch {
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
                try llm_history.buildSessionMessagesXml(alloc, &msg_response)
            else
                try llm_history.buildSessionMessagesJson(alloc, &msg_response);
            res.status = 200;
            res.body = response_body;
            return;
        }
    }
    res.status = 500;
    res.body = try buildErrorResponse(alloc, format, "Server not initialized");
}
