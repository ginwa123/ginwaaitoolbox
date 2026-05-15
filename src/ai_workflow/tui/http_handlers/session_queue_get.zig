const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const session_registry = root_mod.session.session_registry;
const http_response = root_mod.http_response;

/// Get queued messages for a session
/// Path param: session_id
/// Returns JSON with array of queued messages
/// Note: This GETs AND CLEARS the queue (matches ActivityRegistry behavior)
pub fn sessionQueueGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    if (session_registry.get_global_registry()) |registry| {
        if (registry.getQueueMessages(session_id)) |messages| {
            var msgs = messages;
            defer {
                for (msgs.items) |msg| allocator.free(msg);
                msgs.deinit(allocator);
            }

            // Build JSON array response
            if (msgs.items.len == 0) {
                return res.jsonResponse(allocator, .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"session_id\":\"{s}\",\"messages\":[],\"count\":0}}", .{session_id}) });
            }

            // Build array string manually
            var json_buf = std.ArrayList(u8).empty;
            try json_buf.appendSlice(allocator, "[");
            for (msgs.items, 0..) |msg, i| {
                if (i > 0) try json_buf.appendSlice(allocator, ",");
                const escaped = try escapeJsonString(allocator, msg);
                try json_buf.appendSlice(allocator, "\"");
                try json_buf.appendSlice(allocator, escaped);
                try json_buf.appendSlice(allocator, "\"");
            }
            try json_buf.appendSlice(allocator, "]");

            return res.jsonResponse(allocator, .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"session_id\":\"{s}\",\"messages\":{s},\"count\":{d}}}", .{ session_id, json_buf.items, msgs.items.len }) });
        } else {
            // No messages in queue
            return res.jsonResponse(allocator, .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"session_id\":\"{s}\",\"messages\":[],\"count\":0}}", .{session_id}) });
        }
    }

    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Activity registry not available" }) });
}

/// Escape special characters for JSON string
fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, c),
        }
    }
    return result.toOwnedSlice(allocator);
}