//! HTTP client wrapper around kabelweb's client
//! module.
//!
//! The thin shim exists to:
//!   1. keep the call sites in `commands/*.zig` terse (one `getJson` /
//!      `postJson` call instead of three lines of `client.{get,post}`
//!   2. centralize the JSON header so commands don't all repeat
//!      `Content-Type: application/json`
//!   3. centralize status-code mapping (2xx → success, otherwise
//!      → `Error.HttpRequestFailed` with the body preserved for
//!      error printing)
//!
//! The underlying libcurl-backed transport is cross-platform
//! (Linux/macOS/Windows) per `kabelweb repo docs-client-NALAR.md`.

const std = @import("std");
const custom_http_client = @import("kabelweb").client;

pub const Response = custom_http_client.Response;

pub const Error = custom_http_client.Error || error{
    /// Server returned a non-2xx status (the response body is kept
    /// alongside the error so the CLI can print the server's error
    /// message verbatim).
    HttpRequestFailed,
};

/// Build a URL from `server` + `path` (which must start with `/`).
/// Caller owns the returned slice.
pub fn buildUrl(
    allocator: std.mem.Allocator,
    server: []const u8,
    path: []const u8,
) (Error || std.mem.Allocator.Error)![]u8 {
    if (path.len == 0 or path[0] != '/') return Error.HttpRequestFailed;
    const base = if (server.len > 0 and server[server.len - 1] == '/')
        server[0 .. server.len - 1]
    else
        server;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, path });
}

const JSON_HEADER = [_]custom_http_client.Header{
    .{ .name = "Content-Type", .value = "application/json" },
};

/// GET that joins `server + path` and returns the parsed body.
/// Non-2xx responses become `Error.HttpRequestFailed`.
pub fn getJson(
    allocator: std.mem.Allocator,
    client: *custom_http_client.Client,
    server: []const u8,
    path: []const u8,
) Error![]u8 {
    const url = try buildUrl(allocator, server, path);
    defer allocator.free(url);
    const response = try custom_http_client.get(
        client,
        url,
        .{ .timeout_ms = 30_000 },
    );
    // The Response owns its body AND its headers/url_effective/primary_ip;
    // `Response.deinit` walks all of them. Always run it on the error path
    // so a 404 doesn't leak the parsed headers / effective URL.
    defer response.deinit(allocator);
    if (response.status_code < 200 or response.status_code >= 300) {
        std.log.warn(
            "GET {s} returned status {d}: {s}",
            .{ url, response.status_code, response.body },
        );
        return Error.HttpRequestFailed;
    }
    return allocator.dupe(u8, response.body);
}

/// POST with a JSON body. Returns the parsed body or
/// `Error.HttpRequestFailed` on a non-2xx status.
pub fn postJson(
    allocator: std.mem.Allocator,
    client: *custom_http_client.Client,
    server: []const u8,
    path: []const u8,
    body: []const u8,
) Error![]u8 {
    const url = try buildUrl(allocator, server, path);
    defer allocator.free(url);
    const response = try custom_http_client.post(
        client,
        url,
        body,
        &JSON_HEADER,
        .{ .timeout_ms = 30_000 },
    );
    defer response.deinit(allocator);
    if (response.status_code < 200 or response.status_code >= 300) {
        std.log.warn(
            "POST {s} returned status {d}: {s}",
            .{ url, response.status_code, response.body },
        );
        return Error.HttpRequestFailed;
    }
    return allocator.dupe(u8, response.body);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "buildUrl: simple join" {
    const u = try buildUrl(testing.allocator, "http://x:8081", "/api/llm/session");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("http://x:8081/api/llm/session", u);
}

test "buildUrl: strips trailing slash from server" {
    const u = try buildUrl(testing.allocator, "http://x:8081/", "/api/x");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("http://x:8081/api/x", u);
}

test "buildUrl: rejects path without leading slash" {
    try testing.expectError(
        @as(anyerror, Error.HttpRequestFailed),
        buildUrl(testing.allocator, "http://x:8081", "api/x"),
    );
}

const testing = std.testing;