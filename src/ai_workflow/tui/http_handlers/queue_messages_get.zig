const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const logger = nalar_core.logger;

/// Queue message entry structure
pub const QueueMessageEntry = struct {
    id: []const u8,
    message: []const u8,
};

/// Response structure for queue messages
pub const QueueMessagesResponse = struct {
    messages: []QueueMessageEntry,
    count: usize,
};

/// GET handler for queue messages - retrieves all queued messages for a session
pub fn queueMessagesGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse {
        const err_resp = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" });
        return res.jsonResponse(.{ .status_code = 400, .data = err_resp });
    };

    const di = nalar_core.getSingleton() catch {
        const err_resp = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" });
        return res.jsonResponse(.{ .status_code = 500, .data = err_resp });
    };

    const db = di.db;

    // Query all queued messages for this session
    const select_sql = "SELECT id, message FROM session_queue_messages WHERE session_id = ? ORDER BY created_at ASC";
    var rows = db.query(allocator, select_sql, &.{session_id}) catch {
        const err_resp = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Database query failed" });
        return res.jsonResponse(.{ .status_code = 500, .data = err_resp });
    };

    var messages = std.ArrayList(QueueMessageEntry).empty;

    while (true) {
        const row_opt = rows.next() catch break;
        const row = row_opt orelse break;

        const id = try allocator.dupe(u8, row.values[0]);
        const msg = try allocator.dupe(u8, row.values[1]);
        try messages.append(allocator, .{ .id = id, .message = msg });
    }

    const response = QueueMessagesResponse{
        .messages = try messages.toOwnedSlice(allocator),
        .count = messages.items.len,
    };

    const json_str = try std.json.Stringify.valueAlloc(allocator, response, .{});

    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}
