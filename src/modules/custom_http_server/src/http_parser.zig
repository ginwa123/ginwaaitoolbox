const std = @import("std");

/// HTTP Request structure parsed from raw HTTP data
pub const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    version: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    raw: []const u8,
};

/// HTTP Response builder
pub const HttpResponse = struct {
    status_code: u16,
    status_text: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(status_code: u16, status_text: []const u8, allocator: std.mem.Allocator) HttpResponse {
        return .{
            .status_code = status_code,
            .status_text = status_text,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = "",
            .allocator = allocator,
        };
    }

    pub fn withBody(self: HttpResponse, body: []const u8) HttpResponse {
        var copy = self;
        copy.body = body;
        const len_str = std.fmt.allocPrint(self.allocator, "{}", .{body.len}) catch @panic("OOM");
        copy.headers.put("Content-Length", len_str) catch @panic("OOM");
        return copy;
    }

    pub fn withJson(self: HttpResponse, json: []const u8) HttpResponse {
        var copy = self;
        copy.body = json;
        const len_str = std.fmt.allocPrint(self.allocator, "{}", .{json.len}) catch @panic("OOM");
        copy.headers.put("Content-Type", "application/json") catch @panic("OOM");
        copy.headers.put("Content-Length", len_str) catch @panic("OOM");
        return copy;
    }

    pub fn toBytes(self: HttpResponse) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "HTTP/1.1 ");

        var status_buf: [20]u8 = undefined;
        const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{self.status_code}) catch return error.OutOfMemory;
        try buf.appendSlice(self.allocator, status_str);

        try buf.appendSlice(self.allocator, " ");
        try buf.appendSlice(self.allocator, self.status_text);
        try buf.appendSlice(self.allocator, "\r\n");
        try buf.appendSlice(self.allocator, "Server: GinwaServer/1.0\r\n"); // todo change i think
        try buf.appendSlice(self.allocator, "Connection: close\r\n");

        var it = self.headers.iterator();
        while (it.next()) |entry| {
            try buf.appendSlice(self.allocator, entry.key_ptr.*);
            try buf.appendSlice(self.allocator, ": ");
            try buf.appendSlice(self.allocator, entry.value_ptr.*);
            try buf.appendSlice(self.allocator, "\r\n");
        }

        try buf.appendSlice(self.allocator, "\r\n");
        try buf.appendSlice(self.allocator, self.body);

        return buf.toOwnedSlice(self.allocator);
    }
};

/// Parse an HTTP request from raw bytes
pub fn parseRequest(data: []const u8, allocator: std.mem.Allocator) !HttpRequest {
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse {
        return error.IncompleteRequest;
    };

    const header_section = data[0..header_end];
    const body_start = header_end + 4;
    const body = if (body_start < data.len) data[body_start..] else "";

    var lines = std.mem.splitScalar(u8, header_section, '\n');

    const first_line = lines.next() orelse return error.MissingRequestLine;
    const trimmed_line = if (first_line.len > 0 and first_line[0] == '\r') first_line[1..] else first_line;
    var first_parts = std.mem.splitScalar(u8, trimmed_line, ' ');
    const method = first_parts.next() orelse return error.InvalidRequestLine;
    const path = first_parts.next() orelse return error.InvalidRequestLine;
    const version = first_parts.next() orelse return error.InvalidRequestLine;

    var headers = std.StringHashMap([]const u8).init(allocator);
    while (lines.next()) |line| {
        const clean_line = if (line.len > 0 and line[0] == '\r') line[1..] else line;
        if (clean_line.len == 0) break;
        if (std.mem.indexOf(u8, clean_line, ":")) |colon| {
            const key = std.mem.trim(u8, clean_line[0..colon], " ");
            const value = std.mem.trim(u8, clean_line[colon + 1..], " ");
            try headers.put(key, value);
        }
    }

    return HttpRequest{
        .method = method,
        .path = path,
        .version = version,
        .headers = headers,
        .body = body,
        .raw = data,
    };
}

/// Helper to create common responses
pub fn ok(body: []const u8, allocator: std.mem.Allocator) HttpResponse {
    return HttpResponse.init(200, "OK", allocator).withBody(body);
}

pub fn created(body: []const u8, allocator: std.mem.Allocator) HttpResponse {
    return HttpResponse.init(201, "Created", allocator).withBody(body);
}

pub fn badRequest(msg: []const u8, allocator: std.mem.Allocator) HttpResponse {
    return HttpResponse.init(400, "Bad Request", allocator).withBody(msg);
}

pub fn notFound(allocator: std.mem.Allocator) HttpResponse {
    return HttpResponse.init(404, "Not Found", allocator).withBody("Not Found");
}

pub fn internalError(msg: []const u8, allocator: std.mem.Allocator) HttpResponse {
    return HttpResponse.init(500, "Internal Server Error", allocator).withBody(msg);
}

pub fn jsonResponse(data: []const u8, allocator: std.mem.Allocator) HttpResponse {
    return HttpResponse.init(200, "OK", allocator).withJson(data);
}

test "parse simple GET request" {
    const data = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const req = try parseRequest(data, std.testing.allocator);
    defer req.headers.deinit();

    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expectEqualStrings("/hello", req.path);
    try std.testing.expectEqualStrings("HTTP/1.1", req.version);
    try std.testing.expectEqualStrings("localhost", req.headers.get("Host").?);
}

test "parse POST request with body" {
    const data = "POST /api/data HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"key\":\"value\"}";
    const req = try parseRequest(data, std.testing.allocator);
    defer req.headers.deinit();

    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/api/data", req.path);
    try std.testing.expectEqualStrings("13", req.headers.get("Content-Length").?);
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", req.body);
}

test "response toBytes" {
    const res = ok("Hello, World!", std.testing.allocator);
    const bytes = try res.toBytes();
    defer res.allocator.free(bytes);

    try std.testing.expect(std.mem.startsWith(u8, bytes, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.contains(u8, bytes, "Content-Length: 13"));
    try std.testing.expect(std.mem.contains(u8, bytes, "Hello, World!"));
}
