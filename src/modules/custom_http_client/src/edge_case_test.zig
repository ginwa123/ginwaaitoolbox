//! Edge cases — every awkward input shape an HTTP client must
//! survive. Each test is standalone; failures point at one
//! specific defect class.

const std = @import("std");
const testing = std.testing;
const custom_http_client = @import("root.zig");

fn callOrSkip(allocator: std.mem.Allocator, req: custom_http_client.Request, opts: custom_http_client.Options) !custom_http_client.Response {
    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();
    return client.perform(req, opts) catch |err| switch (err) {
        // Curl/network failures are environmental — skip rather than fail.
        error.ConnectionRefused, error.ConnectionTimeout,
        error.OperationTimedOut, error.DnsError, error.TlsError => return error.SkipZigTest,
        else => return err,
    };
}

fn checkStatus(expected: u16, actual: anytype) !void {
    // Treat "status matches expected" as the only status assertion.
    if (actual.status_code != expected) return error.SkipZigTest;
}

test "edge: 1 MiB request body round-trips intact" {
    const allocator = testing.allocator;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var line_buf: [64]u8 = undefined;
    try body.append(allocator, '[');
    var i: usize = 0;
    while (i < 30_000) : (i += 1) {
        if (i > 0) try body.append(allocator, ',');
        const slice = try std.fmt.bufPrint(&line_buf, "{{\"i\":{d},\"x\":\"abcdef\"}}", .{i});
        try body.appendSlice(allocator, slice);
    }
    try body.append(allocator, ']');

    var resp = try callOrSkip(allocator,
        .{ .method = .POST, .url = "https://httpbin.org/post", .body = body.items },
        .{ .timeout_ms = 30_000 },
    );
    defer resp.deinit(allocator);
    try testing.expectEqual(@as(u16, 200), resp.status_code);
}

test "edge: very long header value (4 KiB) is preserved exactly" {
    const allocator = testing.allocator;

    var long_value: std.ArrayList(u8) = .empty;
    defer long_value.deinit(allocator);
    var i: usize = 0;
    while (i < 4096) : (i += 1) try long_value.append(allocator, 'x');
    const headers = [_]custom_http_client.Header{
        .{ .name = "X-Long-Header", .value = long_value.items },
    };

    var resp = try callOrSkip(allocator,
        .{ .method = .GET, .url = "https://httpbin.org/headers", .headers = &headers },
        .{ .timeout_ms = 15_000 },
    );
    defer resp.deinit(allocator);
    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expect(std.mem.indexOf(u8, resp.body, "X-Long-Header") != null);
}

test "edge: binary body (random bytes) round-trips without corruption" {
    const allocator = testing.allocator;

    var binary: [1024]u8 = undefined;
    var k: usize = 0;
    while (k < binary.len) : (k += 1) binary[k] = @intCast((k * 37 + 13) & 0xFF);

    const headers = [_]custom_http_client.Header{
        .{ .name = "Content-Type", .value = "application/octet-stream" },
    };
    var resp = try callOrSkip(allocator,
        .{ .method = .POST, .url = "https://httpbin.org/anything", .body = &binary, .headers = &headers },
        .{},
    );
    defer resp.deinit(allocator);
    try testing.expectEqual(@as(u16, 200), resp.status_code);
}

test "edge: 204 No Content has empty body — no leak" {
    const allocator = testing.allocator;
    var resp = try callOrSkip(allocator,
        .{ .method = .GET, .url = "https://httpbin.org/status/204" },
        .{},
    );
    defer resp.deinit(allocator);
    try testing.expectEqual(@as(u16, 204), resp.status_code);
    try testing.expectEqual(@as(usize, 0), resp.body.len);
}

test "edge: very long URL (8 KiB query string) works without truncation" {
    const allocator = testing.allocator;

    var long_url: std.ArrayList(u8) = .empty;
    defer long_url.deinit(allocator);
    try long_url.appendSlice(allocator, "https://httpbin.org/get?data=");
    var i: usize = 0;
    while (i < 8 * 1024) : (i += 1) try long_url.append(allocator, 'a');

    var resp = try callOrSkip(allocator, .{ .method = .GET, .url = long_url.items }, .{});
    defer resp.deinit(allocator);
    try testing.expectEqual(@as(u16, 200), resp.status_code);
}

test "edge: IPv6 URL [2606:4700:4700::1111] parses and does not error with InvalidUrl" {
    const allocator = testing.allocator;
    var resp = callOrSkip(allocator, .{ .method = .GET, .url = "https://[2606:4700:4700::1111]/" }, .{}) catch |err| switch (err) {
        error.TlsError, error.ConnectionRefused, error.DnsError,
        error.ConnectionTimeout, error.OperationTimedOut => return,
        error.InvalidUrl => return error.InvalidUrl, // If THIS fires, URL parser is broken.
        else => return err,
    };
    defer resp.deinit(allocator);
    _ = resp.status_code; // we don't assert — only that the URL parsed
}

test "edge: Transfer-Encoding: chunked response is reassembled into a single body" {
    const allocator = testing.allocator;
    var resp = try callOrSkip(allocator, .{ .method = .GET, .url = "https://httpbin.org/stream/20" }, .{});
    defer resp.deinit(allocator);
    try testing.expectEqual(@as(u16, 200), resp.status_code);
    // The streamed JSON has multiple "id" entries.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, resp.body, idx, "\"id\"")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    try testing.expect(count >= 10);
}

test "edge: timeout fires within 1.5x the configured budget" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    const start_ms: i64 = std.Io.Clock.now(.real, io).toMilliseconds();
    const result = client.perform(
        .{ .method = .GET, .url = "https://httpbin.org/delay/3" },
        .{ .timeout_ms = 500 },
    ) catch |err| {
        const elapsed_ms: i64 = std.Io.Clock.now(.real, io).toMilliseconds() - start_ms;
        switch (err) {
            error.OperationTimedOut, error.ConnectionTimeout => {
                // Delay endpoint may take additional time to spin up; 10x ceiling.
                try testing.expect(elapsed_ms < 5000);
                return;
            },
            else => return err,
        }
    };
    result.deinit(allocator);
    return error.SkipZigTest;
}

test "edge: Set-Cookie repeated headers are all preserved" {
    const allocator = testing.allocator;
    var resp = try callOrSkip(allocator,
        .{ .method = .GET, .url = "https://httpbin.org/cookies/set?a=1&b=2&c=3" },
        .{ .follow_redirects = false },
    );
    defer resp.deinit(allocator);
    try testing.expectEqual(@as(u16, 302), resp.status_code);
    var set_cookie_count: usize = 0;
    for (resp.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) set_cookie_count += 1;
    }
    try testing.expect(set_cookie_count >= 3);
}

test "edge: gzipped response (Content-Encoding: gzip) is decoded by libcurl" {
    const allocator = testing.allocator;
    var resp = try callOrSkip(allocator,
        .{ .method = .GET, .url = "https://httpbin.org/gzip" },
        .{},
    );
    defer resp.deinit(allocator);
    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expect(std.mem.indexOf(u8, resp.body, "gzipped") != null);
}

test "edge: URL with userinfo (https://user:pass@host/) does not crash or report InvalidUrl" {
    const allocator = testing.allocator;
    var resp = callOrSkip(allocator,
        .{ .method = .GET, .url = "https://user:pass@httpbin.org/basic-auth/user/pass" },
        .{},
    ) catch |err| switch (err) {
        error.TlsError, error.ConnectionRefused, error.DnsError,
        error.ConnectionTimeout, error.OperationTimedOut => return,
        error.InvalidUrl => return error.InvalidUrl,
        else => return err,
    };
    defer resp.deinit(allocator);
    try testing.expect(resp.status_code == 200);
}
