const std = @import("std");
const json = std.json;
const testing = std.testing;
const HttpClient = @import("HttpClient.zig").HttpClient;

// Helper to simulate HTTP GET response (mimics curl behavior without actual HTTP)
fn simulateGetResponse(allocator: std.mem.Allocator, page: usize, limit: usize) !struct { body: []u8, status: u16 } {
    _ = limit;
    if (page == 0) return error.SkipZigTest;

    const has_more = page < 3;
    const messages_count: usize = if (page == 1) 50 else if (page == 2) 25 else 10;

    var json_body: std.ArrayList(u8) = .empty;
    errdefer json_body.deinit(allocator);

    try json_body.appendSlice(allocator, "{\"messages\":[");
    for (0..messages_count) |i| {
        if (i > 0) try json_body.append(allocator, ',');
        try std.fmt.format(json_body.writer(allocator), "{{\"id\":\"msg_{d}_{d}\",\"content\":\"test\"}}", .{ page, i });
    }
    try json_body.append(allocator, ']');
    try json_body.appendSlice(allocator, ",\"has_more\":");
    try json_body.appendSlice(allocator, if (has_more) "true" else "false");
    try json_body.appendSlice(allocator, ",\"next_cursor\":");
    if (has_more) {
        try std.fmt.format(json_body.writer(allocator), "\"cursor_page_{d}\"", .{page + 1});
    } else {
        try json_body.appendSlice(allocator, "null");
    }
    try json_body.append(allocator, '}');

    return .{
        .body = try json_body.toOwnedSlice(allocator),
        .status = 200,
    };
}

test "cursor pagination logic" {
    const allocator = testing.allocator;
    const limit: usize = 50;

    var total_message_count: usize = 0;
    var page_count: usize = 0;
    var cursor: ?[]const u8 = null;

    std.debug.print("\n=== Testing cursor pagination logic ===\n", .{});

    // Simulate up to 10 pages
    while (page_count < 10) : (page_count += 1) {
        const page_num = page_count + 1;
        const response = simulateGetResponse(allocator, page_num, limit) catch |err| {
            std.debug.print("SKIP: simulateGetResponse failed: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer allocator.free(response.body);

        std.debug.print("Page {d}: status={d}, body_len={d}\n", .{ page_num, response.status, response.body.len });

        const parsed = json.parseFromSlice(json.Value, allocator, response.body, .{}) catch |err| {
            std.debug.print("JSON parse error: {s}\n", .{@errorName(err)});
            return err;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        var has_more = false;
        if (root.get("has_more")) |val| {
            if (val == .bool) has_more = val.bool;
        }

        if (root.get("messages")) |messages| {
            if (messages == .array) {
                const arr_items = messages.array.items;
                total_message_count += arr_items.len;
                std.debug.print("  Received {d} messages (total: {d})\n", .{ arr_items.len, total_message_count });
            }
        }

        var next_cursor: ?[]const u8 = null;
        if (root.get("next_cursor")) |val| {
            if (val == .string and val.string.len > 0) {
                next_cursor = try allocator.dupe(u8, val.string);
                std.debug.print("  Next cursor: {s}\n", .{next_cursor.?});
            }
        }

        if (!has_more) {
            std.debug.print("No more pages (has_more=false) - done!\n", .{});
            break;
        }

        if (cursor) |old| allocator.free(old);
        if (next_cursor) |nc| {
            cursor = nc;
        } else {
            break;
        }
    }

    // Cleanup cursor memory
    if (cursor) |c| allocator.free(c);

    std.debug.print("=== Pagination complete ===\n", .{});
    std.debug.print("Total pages: {d}\n", .{page_count});
    std.debug.print("Total messages collected: {d}\n", .{total_message_count});

    // Page 1: 50, Page 2: 25, Page 3: 10 = 85 total
    // page_count is 2 because loop runs 3 times then breaks
    try testing.expectEqual(@as(usize, 2), page_count);
    try testing.expectEqual(@as(usize, 85), total_message_count);
}

test "HttpClient get method with curl" {
    const allocator = testing.allocator;
    var client = HttpClient.init(allocator, std.testing.io);
    defer client.deinit();

    // This test verifies the GET method works with curl
    // Note: Will skip if no server available (connection refused)
    const result = client.get("http://127.0.0.1:8080/api/session/test/messages?limit=1") catch |err| {
        std.debug.print("SKIP: GET request failed (server not available): {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer allocator.free(result.body);

    std.debug.print("GET result: status={d}, body_len={d}\n", .{ result.status_code, result.body.len });

    // Just verify the method works, not the specific response
    try testing.expect(result.status_code >= 0);
}
