const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const session_registry = root_mod.session.session_registry;

const httpz = http_server.httpz;

/// Get queued messages for a session
/// Path param: session_id
/// Returns JSON with array of queued messages
/// Note: This GETs AND CLEARS the queue (matches ActivityRegistry behavior)
pub fn sessionQueueGetHandler(
    _: *http_server.HttpServer.ServerHandler,
    req: *httpz.Request,
    res: *httpz.Response,
) anyerror!void {
    res.content_type = .JSON;

    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    if (session_registry.get_global_registry()) |registry| {
        if (registry.get_queue_messages(session_id)) |messages| {
            var msgs = messages;
            defer {
                for (msgs.items) |msg| req.arena.free(msg);
                msgs.deinit(req.arena);
            }

            // Build JSON array response
            if (msgs.items.len == 0) {
                res.status = 200;
                res.body = try std.fmt.allocPrint(req.arena, 
                    "{{\"session_id\":\"{s}\",\"messages\":[],\"count\":0}}", 
                    .{session_id});
                return;
            }

            // Build array string manually
            var json_buf = std.ArrayList(u8).empty;
            try json_buf.appendSlice(req.arena, "[");
            for (msgs.items, 0..) |msg, i| {
                if (i > 0) try json_buf.appendSlice(req.arena, ",");
                const escaped = try escapeJsonString(req.arena, msg);
                try json_buf.appendSlice(req.arena, "\"");
                try json_buf.appendSlice(req.arena, escaped);
                try json_buf.appendSlice(req.arena, "\"");
            }
            try json_buf.appendSlice(req.arena, "]");

            res.status = 200;
            res.body = try std.fmt.allocPrint(req.arena,
                "{{\"session_id\":\"{s}\",\"messages\":{s},\"count\":{d}}}",
                .{ session_id, json_buf.items, msgs.items.len });
            return;
        } else {
            // No messages in queue
            res.status = 200;
            res.body = try std.fmt.allocPrint(req.arena,
                "{{\"session_id\":\"{s}\",\"messages\":[],\"count\":0}}",
                .{session_id});
            return;
        }
    }

    res.status = 500;
    res.body = "{\"error\":\"Activity registry not available\"}";
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
