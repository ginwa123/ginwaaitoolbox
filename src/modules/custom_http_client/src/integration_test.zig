//! Behavioural tests against https://httpbin.org.
//!
//! These tests hit the real network. They are NOT enabled by default
//! (`zig build test`) — only when `-Dintegration=true` is passed at
//! the module level. When the network is unavailable or DNS fails
//! they all SKIP via `error.SkipZigTest`.
//!
//! Pattern mirrors the httpbin endpoints exercised by
//! `modules/http/HttpClient.zig` for parity testing.

const std = @import("std");
const testing = std.testing;
const custom_http_client = @import("root.zig");

fn callOrSkip(allocator: std.mem.Allocator, req: custom_http_client.Request, opts: custom_http_client.Options) !custom_http_client.Response {
    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();
    return client.perform(req, opts) catch |err| switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimeout,
        error.OperationTimedOut,
        error.DnsError,
        error.TlsError => return error.SkipZigTest,
        else => return err,
    };
}

test "integration: GET https://httpbin.org/get returns 200" {
    const allocator = testing.allocator;
    var resp = try callOrSkip(allocator, .{
        .method = .GET,
        .url = "https://httpbin.org/get",
    }, .{});
    defer resp.deinit(allocator);

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expect(resp.body.len > 0);
}

test "integration: POST JSON to /post echoes the body back" {
    const allocator = testing.allocator;
    const body = "{\"hello\":\"world\"}";
    const headers = [_]custom_http_client.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    var resp = try callOrSkip(allocator, .{
        .method = .POST,
        .url = "https://httpbin.org/post",
        .body = body,
        .headers = &headers,
    }, .{});
    defer resp.deinit(allocator);

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expect(std.mem.indexOf(u8, resp.body, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "world") != null);
}

test "integration: PUT and PATCH both echo the body back" {
    const allocator = testing.allocator;
    const body = "{\"x\":1}";
    const headers = [_]custom_http_client.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    {
        var resp = try callOrSkip(allocator, .{
            .method = .PUT,
            .url = "https://httpbin.org/put",
            .body = body,
            .headers = &headers,
        }, .{});
        defer resp.deinit(allocator);
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        try testing.expect(std.mem.indexOf(u8, resp.body, "\"x\"") != null);
    }

    {
        var resp = try callOrSkip(allocator, .{
            .method = .PATCH,
            .url = "https://httpbin.org/patch",
            .body = body,
            .headers = &headers,
        }, .{});
        defer resp.deinit(allocator);
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        try testing.expect(std.mem.indexOf(u8, resp.body, "\"x\"") != null);
    }
}

test "integration: DELETE returns 200" {
    const allocator = testing.allocator;
    var resp = try callOrSkip(allocator, .{
        .method = .DELETE,
        .url = "https://httpbin.org/delete",
    }, .{});
    defer resp.deinit(allocator);
    try testing.expectEqual(@as(u16, 200), resp.status_code);
}

test "integration: GET /status/404 surfaces 404 in status_code without error" {
    const allocator = testing.allocator;
    var resp = try callOrSkip(allocator, .{
        .method = .GET,
        .url = "https://httpbin.org/status/404",
    }, .{});
    defer resp.deinit(allocator);
    try testing.expectEqual(@as(u16, 404), resp.status_code);
}

test "integration: GET /redirect/3 with follow_redirects=true ends at /get" {
    const allocator = testing.allocator;
    var resp = try callOrSkip(allocator, .{
        .method = .GET,
        .url = "https://httpbin.org/redirect/3",
    }, .{ .follow_redirects = true });
    defer resp.deinit(allocator);
    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expect(std.mem.indexOf(u8, resp.url_effective, "/get") != null);
}
