const std = @import("std");
const http_parser = @import("http_parser.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const allocator = std.testing.allocator;

// ==================== Helper Functions ====================

fn createHttpRequest(method: []const u8, path: []const u8, body: []const u8, alloc: std.mem.Allocator) ![]u8 {
    return createHttpRequestWithHeaders(method, path, &.{}, body, alloc);
}

fn createHttpRequestWithHeaders(method: []const u8, path: []const u8, headers: []const []const u8, body: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    
    try buf.appendSlice(alloc, method);
    try buf.appendSlice(alloc, " ");
    try buf.appendSlice(alloc, path);
    try buf.appendSlice(alloc, " HTTP/1.1\r\n");

    for (headers) |header| {
        try buf.appendSlice(alloc, header);
        try buf.appendSlice(alloc, "\r\n");
    }

    if (body.len > 0) {
        const cl = try std.fmt.allocPrint(alloc, "Content-Length: {d}", .{body.len});
        defer alloc.free(cl);
        try buf.appendSlice(alloc, cl);
        try buf.appendSlice(alloc, "\r\n");
    }

    try buf.appendSlice(alloc, "\r\n");
    try buf.appendSlice(alloc, body);

    return try buf.toOwnedSlice(alloc);
}

/// Create JSON body with exact target size
/// Format: {"key":"xxx...xxx"} where the content makes total size = target_size
fn createJsonBody(comptime target_size: usize, alloc: std.mem.Allocator, char: u8) ![]u8 {
    // prefix: {"":""} = 9 chars ("\"" + ":" + "\"" + ":" + "\"")
    // suffix: "} = 2 chars
    // Need target_size - 11 chars of padding
    var body = std.ArrayList(u8).empty;
    errdefer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"data\":\"");
    while (body.items.len < target_size - 2) {
        try body.append(alloc, char);
    }
    try body.appendSlice(alloc, "\"}");
    return try body.toOwnedSlice(alloc);
}

// ==================== Basic Request Parsing Tests ====================

test "parse GET request without body" {
    const request_data = try createHttpRequest("GET", "/test", "", allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqualStrings("GET", req.method);
    try expectEqualStrings("/test", req.path);
    try expectEqualStrings("HTTP/1.1", req.version);
    try expectEqualStrings("", req.body);
}

test "parse POST request with small JSON" {
    const body = "{\"name\":\"test\"}";
    const request_data = try createHttpRequest("POST", "/api", body, allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqualStrings("POST", req.method);
    try expectEqualStrings("/api", req.path);
    try expectEqualStrings(body, req.body);
}

test "parse request with custom headers" {
    const request_data = try createHttpRequestWithHeaders("GET", "/test", &.{
        "Host: localhost:8080",
        "User-Agent: TestClient/1.0",
        "Accept: application/json",
    }, "", allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    // Headers may have trailing \r from HTTP parsing
    const host_val = req.headers.get("Host") orelse "";
    const user_agent_val = req.headers.get("User-Agent") orelse "";
    const accept_val = req.headers.get("Accept") orelse "";

    // Trim any trailing carriage returns
    const host = std.mem.trim(u8, host_val, "\r");
    const user_agent = std.mem.trim(u8, user_agent_val, "\r");
    const accept = std.mem.trim(u8, accept_val, "\r");

    try expectEqualStrings("localhost:8080", host);
    try expectEqualStrings("TestClient/1.0", user_agent);
    try expectEqualStrings("application/json", accept);
}

// ==================== Large JSON Body Tests ====================

test "parse POST with 4KB JSON (exactly buffer size)" {
    const body = try createJsonBody(4096, allocator, 'x');
    defer allocator.free(body);
    
    try expectEqual(@as(usize, 4096), body.len);

    const request_data = try createHttpRequest("POST", "/api/data", body, allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqual(@as(usize, 4096), req.body.len);
}

test "parse POST with 5KB JSON (exceeds buffer size)" {
    const body = try createJsonBody(5120, allocator, 'y');
    defer allocator.free(body);

    const request_data = try createHttpRequest("POST", "/api/data", body, allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqual(@as(usize, 5120), req.body.len);
}

test "parse POST with 8KB JSON (2x buffer size)" {
    const body = try createJsonBody(8192, allocator, 'z');
    defer allocator.free(body);

    const request_data = try createHttpRequest("POST", "/api/data", body, allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqual(@as(usize, 8192), req.body.len);
}

test "parse POST with 16KB JSON (4x buffer size)" {
    const body = try createJsonBody(16384, allocator, 'a');
    defer allocator.free(body);

    const request_data = try createHttpRequest("POST", "/api/data", body, allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqual(@as(usize, 16384), req.body.len);
}

test "parse POST with 100KB JSON (large payload)" {
    const body = try createJsonBody(102400, allocator, 'b');
    defer allocator.free(body);

    const request_data = try createHttpRequest("POST", "/api/data", body, allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqual(@as(usize, 102400), req.body.len);
}

// ==================== Edge Case Tests ====================

test "parse POST with JSON at buffer boundary (4095 bytes)" {
    const body = try createJsonBody(4095, allocator, 'c');
    defer allocator.free(body);

    const request_data = try createHttpRequest("POST", "/api/data", body, allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqual(@as(usize, 4095), req.body.len);
}

test "parse POST with JSON at buffer boundary (4097 bytes)" {
    const body = try createJsonBody(4097, allocator, 'd');
    defer allocator.free(body);

    const request_data = try createHttpRequest("POST", "/api/data", body, allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqual(@as(usize, 4097), req.body.len);
}

test "parse JSON with special characters" {
    const body = "{\"message\":\"Hello\\nWorld\\t!\\u00A9\"}";
    const request_data = try createHttpRequest("POST", "/api", body, allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqualStrings(body, req.body);
}

test "parse JSON with unicode characters" {
    const body = "{\"name\":\"日本語テスト\"}";
    const request_data = try createHttpRequest("POST", "/api", body, allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqualStrings(body, req.body);
}

test "parse POST with body split across 4096 boundaries" {
    const body = try createJsonBody(8192, allocator, ',');
    defer allocator.free(body);

    const request_data = try createHttpRequest("POST", "/api/chunked", body, allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqual(@as(usize, 8192), req.body.len);
}

test "parse GET with URL-encoded path containing large query" {
    var query = std.ArrayList(u8).empty;
    defer query.deinit(allocator);
    try query.appendSlice(allocator, "data=");
    while (query.items.len < 5000) {
        try query.append(allocator, 'x');
    }
    const query_slice = try query.toOwnedSlice(allocator);
    defer allocator.free(query_slice);
    
    const path = try std.fmt.allocPrint(allocator, "/api/search?{s}", .{query_slice});
    defer allocator.free(path);
    
    const request_data = try createHttpRequest("GET", path, "", allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqualStrings("/api/search", req.path);
    try expect(req.query.get("data") != null);
}

// ==================== Performance Test ====================

test "parse POST with 1MB JSON (stress test)" {
    const body = try createJsonBody(1024 * 1024, allocator, 'M');
    defer allocator.free(body);

    const request_data = try createHttpRequest("POST", "/api/big", body, allocator);
    defer allocator.free(request_data);
    
    var req = try http_parser.parseRequest(request_data, allocator, undefined, 0);
    defer req.deinit(allocator);

    try expectEqual(@as(usize, 1024 * 1024), req.body.len);
}