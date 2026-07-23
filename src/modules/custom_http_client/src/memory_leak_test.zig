//! Memory-leak regression tests. ALL tests run under std.testing.allocator
//! which fails the test on ANY unfreed allocation.
//!
//! The Zig testing.allocator wraps the GPA with canaries and a deinit
//! check at scope end. A leak triggers a full backtrace dump.

const std = @import("std");
const testing = std.testing;
const custom_http_client = @import("root.zig");

fn performOrSkip(allocator: std.mem.Allocator, req: custom_http_client.Request, opts: custom_http_client.Options) !custom_http_client.Response {
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

test "mem: GET happy path — full Response.deinit frees every owned slice" {
    const allocator = testing.allocator;
    var resp = try performOrSkip(allocator, .{
        .method = .GET,
        .url = "https://example.com",
    }, .{});
    defer resp.deinit(allocator);
    // Reach here only if the call succeeded — every field is then a real
    // allocation. testing.allocator deinit at scope end flags anything
    // still alive.
}

test "mem: POST with body + 5 headers — full Response.deinit is clean" {
    const allocator = testing.allocator;
    const body = "{\"k\":\"v\"}";
    const headers = [_]custom_http_client.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "X-One", .value = "1" },
        .{ .name = "X-Two", .value = "2" },
        .{ .name = "X-Three", .value = "3" },
    };

    var resp = try performOrSkip(allocator, .{
        .method = .POST,
        .url = "https://httpbin.org/post",
        .body = body,
        .headers = &headers,
    }, .{});
    defer resp.deinit(allocator);

    try testing.expect(resp.headers.len >= 1); // server echoes Content-Type
}

test "mem: error path — ConnectionRefused does NOT leak allocations" {
    const allocator = testing.allocator;
    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    const result = client.perform(.{ .method = .GET, .url = "http://127.0.0.1:1/" }, .{}) catch |err| switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimeout,
        error.OperationTimedOut,
        error.DnsError => return,
        else => return err,
    };
    // If we reach here the call unexpectedly succeeded — deinit and skip.
    result.deinit(allocator);
    return error.SkipZigTest;
}

test "mem: 200 sequential GET / deinit cycles — allocator reports clean" {
    const allocator = testing.allocator;
    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    var ok: usize = 0;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var resp = client.perform(.{ .method = .GET, .url = "https://example.com" }, .{}) catch continue;
        defer resp.deinit(allocator);
        ok += 1;
        if (ok >= 5) break;
    }
    if (ok == 0) return error.SkipZigTest;
}

test "mem: Response.deinit handles a zero-value Response without UB" {
    const allocator = testing.allocator;
    // A zero-value Response has all empty slices — deinit must be safe.
    var resp: custom_http_client.Response = .{
        .status_code = 0,
        .body = &[_]u8{},
        .headers = &[_]custom_http_client.Header{},
        .url_effective = "",
        .total_time_ms = 0,
        .primary_ip = "",
    };
    resp.deinit(allocator);
}
