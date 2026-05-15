const std = @import("std");
const http_parser = @import("http_parser.zig");

// For package-relative imports in tests
const parseRequest = http_parser.parseRequest;
const ok = http_parser.ok;
const created = http_parser.created;
const badRequest = http_parser.badRequest;
const notFound = http_parser.notFound;
const internalError = http_parser.internalError;
const jsonResponse = http_parser.jsonResponse;

// ============================================================================
// HTTP Request Parsing Tests
// ============================================================================

test "parse simple GET request" {
    const data = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var req = try parseRequest(data, std.testing.allocator, undefined, -1);
    defer {
        req.headers.deinit();
        req.params.deinit();
        req.query.deinit();
    }

    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expectEqualStrings("/hello", req.path);
    try std.testing.expectEqualStrings("HTTP/1.1", req.version);
    try std.testing.expectEqualStrings("localhost", req.headers.get("Host").?);
}

test "parse POST request with body" {
    const data = "POST /api/data HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n\r\n{\"key\":\"value\"}";
    var req = try parseRequest(data, std.testing.allocator, undefined, -1);
    defer {
        req.headers.deinit();
        req.params.deinit();
        req.query.deinit();
    }

    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/api/data", req.path);
    try std.testing.expectEqualStrings("application/json", req.headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", req.body);
}

test "parse request with query string" {
    const data = "GET /search?q=zig&lang=rocks HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var req = try parseRequest(data, std.testing.allocator, undefined, -1);
    defer {
        req.headers.deinit();
        req.params.deinit();
        req.query.deinit();
    }

    try std.testing.expectEqualStrings("/search", req.path);
    try std.testing.expectEqualStrings("zig", req.query.get("q").?);
    try std.testing.expectEqualStrings("rocks", req.query.get("lang").?);
}

test "parse request with multiple headers" {
    const data = "GET /api HTTP/1.1\r\nHost: localhost\r\nUser-Agent: TestClient/1.0\r\nAccept: application/json\r\nAuthorization: Bearer token123\r\n\r\n";
    var req = try parseRequest(data, std.testing.allocator, undefined, -1);
    defer {
        req.headers.deinit();
        req.params.deinit();
        req.query.deinit();
    }

    try std.testing.expectEqualStrings("TestClient/1.0", req.headers.get("User-Agent").?);
    try std.testing.expectEqualStrings("application/json", req.headers.get("Accept").?);
    try std.testing.expectEqualStrings("Bearer token123", req.headers.get("Authorization").?);
}

test "parse request without body" {
    const data = "DELETE /resource/123 HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var req = try parseRequest(data, std.testing.allocator, undefined, -1);
    defer {
        req.headers.deinit();
        req.params.deinit();
        req.query.deinit();
    }

    try std.testing.expectEqualStrings("DELETE", req.method);
    try std.testing.expectEqualStrings("/resource/123", req.path);
    try std.testing.expectEqual(0, req.body.len);
}

test "parse request with empty query value" {
    const data = "GET /api?key=&other=value HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var req = try parseRequest(data, std.testing.allocator, undefined, -1);
    defer {
        req.headers.deinit();
        req.params.deinit();
        req.query.deinit();
    }

    try std.testing.expectEqualStrings("", req.query.get("key").?);
    try std.testing.expectEqualStrings("value", req.query.get("other").?);
}

test "parse request with no query params" {
    const data = "GET /simple HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var req = try parseRequest(data, std.testing.allocator, undefined, -1);
    defer {
        req.headers.deinit();
        req.params.deinit();
        req.query.deinit();
    }

    try std.testing.expectEqualStrings("/simple", req.path);
    try std.testing.expect(req.query.get("nonexistent") == null);
}

test "parse incomplete request (missing CRLF)" {
    const data = "GET /incomplete";
    const result = parseRequest(data, std.testing.allocator, undefined, -1);
    try std.testing.expectError(error.IncompleteRequest, result);
}

test "parse request with missing request line" {
    const data = "Host: localhost\r\n\r\n";
    const result = parseRequest(data, std.testing.allocator, undefined, -1);
    try std.testing.expectError(error.MissingRequestLine, result);
}

test "parse request with invalid request line (no method)" {
    const data = "/path HTTP/1.1\r\n\r\n";
    const result = parseRequest(data, std.testing.allocator, undefined, -1);
    try std.testing.expectError(error.InvalidRequestLine, result);
}

test "parse request with extra whitespace in headers" {
    const data = "GET /test HTTP/1.1\r\nHost:   localhost   \r\nContent-Type:    application/json\r\n\r\n";
    var req = try parseRequest(data, std.testing.allocator, undefined, -1);
    defer {
        req.headers.deinit();
        req.params.deinit();
        req.query.deinit();
    }

    // Headers should have trimmed whitespace
    try std.testing.expectEqualStrings("localhost", req.headers.get("Host").?);
    try std.testing.expectEqualStrings("application/json", req.headers.get("Content-Type").?);
}

// ============================================================================
// HTTP Response Builder Tests
// ============================================================================

test "response toBytes - basic ok response" {
    const res = ok("Hello, World!", std.testing.allocator);
    const bytes = try res.toBytes();
    defer res.allocator.free(bytes);

    try std.testing.expect(std.mem.startsWith(u8, bytes, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Content-Length: 13") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Server: GinwaServer/1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Connection: close") != null);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "Hello, World!"));
}

test "response toBytes - created response" {
    const res = created("Resource created", std.testing.allocator);
    const bytes = try res.toBytes();
    defer res.allocator.free(bytes);

    try std.testing.expect(std.mem.startsWith(u8, bytes, "HTTP/1.1 201 Created\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Resource created") != null);
}

test "response toBytes - bad request response" {
    const res = badRequest("Invalid input", std.testing.allocator);
    const bytes = try res.toBytes();
    defer res.allocator.free(bytes);

    try std.testing.expect(std.mem.startsWith(u8, bytes, "HTTP/1.1 400 Bad Request\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Invalid input") != null);
}

test "response toBytes - not found response" {
    const res = notFound(std.testing.allocator);
    const bytes = try res.toBytes();
    defer res.allocator.free(bytes);

    try std.testing.expect(std.mem.startsWith(u8, bytes, "HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Not Found") != null);
}

test "response toBytes - internal error response" {
    const res = internalError("Something went wrong", std.testing.allocator);
    const bytes = try res.toBytes();
    defer res.allocator.free(bytes);

    try std.testing.expect(std.mem.startsWith(u8, bytes, "HTTP/1.1 500 Internal Server Error\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Something went wrong") != null);
}

test "response toBytes - json response" {
    const res = jsonResponse("{\"status\":\"ok\"}", std.testing.allocator);
    const bytes = try res.toBytes();
    defer res.allocator.free(bytes);

    try std.testing.expect(std.mem.startsWith(u8, bytes, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Content-Type: application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "{\"status\":\"ok\"}") != null);
}

test "response withBody sets content length" {
    const res = ok("Test", std.testing.allocator);
    const bytes = try res.toBytes();
    defer res.allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "Content-Length: 4") != null);
}

test "response toBytes - response with custom headers" {
    var res = http_parser.HttpResponse.init(200, "OK", std.testing.allocator);
    defer res.headers.deinit();

    try res.headers.put("X-Custom-Header", "custom-value");
    try res.headers.put("Content-Type", "text/plain");

    const bytes = try res.toBytes();
    defer res.allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "X-Custom-Header: custom-value") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Content-Type: text/plain") != null);
}

test "response withJson sets content type and length" {
    const json_data = "{\"key\":\"value\"}";
    const res = http_parser.HttpResponse.init(200, "OK", std.testing.allocator).withJson(json_data);
    const bytes = try res.toBytes();
    defer res.allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "Content-Type: application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Content-Length: 17") != null);
}

test "response withBody preserves status" {
    const res = http_parser.HttpResponse.init(201, "Created", std.testing.allocator).withBody("Created!");
    const bytes = try res.toBytes();
    defer res.allocator.free(bytes);

    try std.testing.expect(std.mem.startsWith(u8, bytes, "HTTP/1.1 201 Created\r\n"));
}

test "response withBody copies body correctly" {
    const res = ok("Hello", std.testing.allocator);
    try std.testing.expectEqualStrings("Hello", res.body);
}

test "response withJson copies json correctly" {
    const res = jsonResponse("{\"test\":true}", std.testing.allocator);
    try std.testing.expectEqualStrings("{\"test\":true}", res.body);
    try std.testing.expectEqualStrings("application/json", res.headers.get("Content-Type").?);
}

// ============================================================================
// Edge Cases and Error Handling Tests
// ============================================================================

test "parse request with empty body" {
    const data = "GET /empty HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var req = try parseRequest(data, std.testing.allocator, undefined, -1);
    defer {
        req.headers.deinit();
        req.params.deinit();
        req.query.deinit();
    }

    try std.testing.expectEqualStrings("", req.body);
}

test "parse request with path containing dashes and underscores" {
    const data = "GET /api/v2/user_profile-data HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var req = try parseRequest(data, std.testing.allocator, undefined, -1);
    defer {
        req.headers.deinit();
        req.params.deinit();
        req.query.deinit();
    }

    try std.testing.expectEqualStrings("/api/v2/user_profile-data", req.path);
}

test "parse request with numeric headers" {
    const data = "POST /api HTTP/1.1\r\nContent-Length: 12345\r\n\r\n";
    var req = try parseRequest(data, std.testing.allocator, undefined, -1);
    defer {
        req.headers.deinit();
        req.params.deinit();
        req.query.deinit();
    }

    try std.testing.expectEqualStrings("12345", req.headers.get("Content-Length").?);
}

test "parse request with trailing CRLF in body" {
    const data = "POST /api HTTP/1.1\r\nContent-Length: 5\r\n\r\nHello";
    var req = try parseRequest(data, std.testing.allocator, undefined, -1);
    defer {
        req.headers.deinit();
        req.params.deinit();
        req.query.deinit();
    }

    try std.testing.expectEqualStrings("Hello", req.body);
}

test "response bytes ends with double CRLF before body" {
    const res = ok("Body", std.testing.allocator);
    const bytes = try res.toBytes();
    defer res.allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "\r\n\r\nBody") != null);
}
