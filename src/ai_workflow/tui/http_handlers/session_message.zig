const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const helpers = nalarcore.helpers;
const ai_mod = nalarcore.ai_mod;
const llm_history = ai_mod.llm_history;

/// Get messages for a session
pub fn session_message_handler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    const limit_str = req.query.get("limit") orelse "100";
    const cursor = req.query.get("cursor");
    const sort_by_str = req.query.get("sort_by") orelse "created_at";
    const direction_str = req.query.get("direction") orelse "asc";
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

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const msg_response = llm_history.getSessionMessagesSorted(allocator, sqlite_db, session_id, limit_val, cursor, sort_spec) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Database query failed" }) });
    };

    // Convert llm_history.SessionMessageResponse to http_response.SessionMessagesResponse
    var messages: []http_response.SessionMessage = try allocator.alloc(http_response.SessionMessage, msg_response.messages.len);
    for (msg_response.messages, 0..) |msg, idx| {
        // Join multiple image URLs into a pipe-separated string
        var image_url_str: []u8 = &[_]u8{};
        if (msg.image_urls) |urls| {
            var combined = std.ArrayList(u8).empty;
            errdefer combined.deinit(allocator);
            for (urls, 0..) |url, i| {
                if (i > 0) try combined.append(allocator, '|');
                try combined.appendSlice(allocator, url);
            }
            image_url_str = try combined.toOwnedSlice(allocator);
        }

        messages[idx] = http_response.SessionMessage{
            .id = msg.id,
            .session_id = msg.session_id,
            .role = msg.role,
            .content = try helpers.sanitize.sanitizeUtf8(allocator, msg.content),
            .timestamp = msg.timestamp,
            .is_input = msg.is_input,
            .is_output = msg.is_output,
            .tool_name = msg.tool_name,
            .finish_reason = msg.finish_reason,
            .reasoning_content = msg.reasoning_content,
            .diffview_before = msg.diffview_before orelse "",
            .diffview_after = msg.diffview_after orelse "",
            .image_url = image_url_str,
            .tool_call_id = msg.tool_call_id orelse "",
        };
    }

    const http_resp = http_response.SessionMessagesResponse{
        .messages = messages,
        .has_more = msg_response.has_more,
        .next_cursor = msg_response.next_cursor,
        .cwd = msg_response.cwd,
        .skills = msg_response.skills,
        .max_total_tokens = msg_response.max_total_tokens,
        .max_capacity_total_tokens = msg_response.max_capacity_total_tokens,
        .total = msg_response.total_count,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeSessionMessagesResponse(allocator, http_resp) });
}

fn sanitizeUtf8(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Replace invalid UTF-8 bytes with the replacement character U+FFFD
    var result : std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            // Invalid start byte - replace with replacement char
            try result.appendSlice(allocator,&[_]u8{ 0xEF, 0xBF, 0xBD });
            i += 1;
            continue;
        };
        if (i + seq_len > input.len) {
            try result.appendSlice(allocator,&[_]u8{ 0xEF, 0xBF, 0xBD });
            i += 1;
            continue;
        }
        const slice = input[i .. i + seq_len];
        if (std.unicode.utf8ValidateSlice(slice)) {
            try result.appendSlice(allocator,slice);
        } else {
            try result.appendSlice(allocator,&[_]u8{ 0xEF, 0xBF, 0xBD });
        }
        i += seq_len;
    }
    return result.toOwnedSlice(allocator);
}
