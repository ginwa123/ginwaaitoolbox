const std = @import("std");
const linux = std.posix.system;

pub const HttpContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Optional client ID for SSE connections (set after registerClient)
    client_id: ?[16]u8 = null,
};

/// Decode URL-encoded string (handles %XX, +, and all special chars)
pub fn urlDecode(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Calculate exact size needed
    var decoded_len: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '%' and i + 2 < data.len) {
            _ = std.fmt.parseInt(u8, data[i + 1 .. i + 3], 16) catch {
                decoded_len += 1;
                i += 1;
                continue;
            };
            decoded_len += 1;
            i += 2;
        } else if (data[i] == '+') {
            decoded_len += 1;
        } else {
            decoded_len += 1;
        }
    }

    // Allocate exact size
    const result = try allocator.alloc(u8, decoded_len);
    var j: usize = 0;
    i = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '%' and i + 2 < data.len) {
            const decoded = std.fmt.parseInt(u8, data[i + 1 .. i + 3], 16) catch {
                result[j] = data[i];
                j += 1;
                i += 1;
                continue;
            };
            result[j] = decoded;
            j += 1;
            i += 2;
        } else if (data[i] == '+') {
            result[j] = ' ';
            j += 1;
        } else {
            result[j] = data[i];
            j += 1;
        }
    }

    return result[0..j];
}

/// HTTP Request structure parsed from raw HTTP data
pub const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    version: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    raw: []const u8,

    /// Route params extracted from path patterns like /hello/:name
    params: std.StringHashMap([]const u8),
    /// Query string params extracted from URL like ?foo=bar&baz=qux
    query: std.StringHashMap([]const u8),

    _client_fd: i32,

    pub fn writeSSEEvent(self: *const HttpRequest, event: []const u8) void {
        _ = linux.write(self._client_fd, event.ptr, event.len);
    }

    /// Free all heap-owned data:
    /// - `path` was allocated by `urlDecode` in `parseRequest`
    /// - `query` keys + values were URL-decoded (heap-owned)
    /// - `headers`, `params` maps own their buckets; their entries are
    ///   slices into `raw` (request_data) or into `path`, so no per-entry free
    ///
    /// Production usage (http_server.zig handle function) does NOT call this
    /// because the per-request arena reaps everything. This method exists for
    /// test code (where `std.testing.allocator` enforces leak detection) and
    /// for non-arena callers that want explicit ownership.
    pub fn deinit(self: *HttpRequest, allocator: std.mem.Allocator) void {
        // `path` was always allocated by `urlDecode` in `parseRequest` (even
        // for empty inputs the function allocates `decoded_len` bytes, which
        // can be 0). Free unconditionally.
        allocator.free(self.path);

        // Query keys + values are heap-allocated URL-decoded strings
        // (see `parseRequest` body). Free each before deiniting the map
        // (which only frees the bucket array).
        var qit = self.query.iterator();
        while (qit.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.query.deinit();

        self.headers.deinit();
        self.params.deinit();
    }
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
        try buf.appendSlice(self.allocator, "Server: Server/1.0\r\n"); // todo change i think
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

    pub fn jsonResponse(self: HttpResponse, jsonStruct: JsonStruct) HttpResponse {
        return jsonResponseHelper(self.allocator, jsonStruct);
    }
};

/// Parse an HTTP request from raw bytes
pub fn parseRequest(data: []const u8, allocator: std.mem.Allocator, _: std.Io, client_fd: i32) !HttpRequest {
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
    const path_with_query = first_parts.next() orelse return error.InvalidRequestLine;
    const version = first_parts.next() orelse return error.InvalidRequestLine;

    // Split path and query string
    var path: []const u8 = path_with_query;
    var query_str: []const u8 = "";
    if (std.mem.indexOf(u8, path_with_query, "?")) |q_idx| {
        path = path_with_query[0..q_idx];
        query_str = path_with_query[q_idx + 1 ..];
    }

    // Decode URL-encoded path
    const decoded_path = try urlDecode(path, allocator);

    var headers = std.StringHashMap([]const u8).init(allocator);
    while (lines.next()) |line| {
        const clean_line = if (line.len > 0 and line[0] == '\r') line[1..] else line;
        if (clean_line.len == 0) break;
        if (std.mem.indexOf(u8, clean_line, ":")) |colon| {
            const key = std.mem.trim(u8, clean_line[0..colon], " ");
            const value = std.mem.trim(u8, clean_line[colon + 1 ..], " ");
            try headers.put(key, value);
        }
    }

    // Parse query params
    var query = std.StringHashMap([]const u8).init(allocator);
    if (query_str.len > 0) {
        var query_params = std.mem.splitScalar(u8, query_str, '&');
        while (query_params.next()) |param| {
            var key: []const u8 = param;
            var value: []const u8 = "";

            if (std.mem.indexOf(u8, param, "=")) |eq_idx| {
                key = param[0..eq_idx];
                value = param[eq_idx + 1 ..];
            }

            // URL decode both key and value
            const decoded_key = try urlDecode(key, allocator);
            const decoded_value = try urlDecode(value, allocator);
            try query.put(decoded_key, decoded_value);
        }
    }

    // Params are populated by the router when matching route patterns
    const params = std.StringHashMap([]const u8).init(allocator);

    return HttpRequest{
        .method = method,
        .path = decoded_path,
        .version = version,
        .headers = headers,
        .body = body,
        .raw = data,
        .params = params,
        .query = query,
        ._client_fd = client_fd,
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

pub const JsonStruct = struct {
    data: []const u8,
    status_code: u16,
};

pub fn jsonResponseHelper(allocator: std.mem.Allocator, jsonStruct: JsonStruct) HttpResponse {
    const status_text: []const u8 = switch (jsonStruct.status_code) {
        // 1xx Informational
        100 => "Continue",
        101 => "Switching Protocols",
        102 => "Processing",
        103 => "Early Hints",

        // 2xx Success
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        203 => "Non-Authoritative Information",
        204 => "No Content",
        205 => "Reset Content",
        206 => "Partial Content",
        207 => "Multi-Status",
        208 => "Already Reported",
        226 => "IM Used",

        // 3xx Redirection
        300 => "Multiple Choices",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        305 => "Use Proxy",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",

        // 4xx Client Errors
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        407 => "Proxy Authentication Required",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Content Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        418 => "I'm a Teapot",
        421 => "Misdirected Request",
        422 => "Unprocessable Content",
        423 => "Locked",
        424 => "Failed Dependency",
        425 => "Too Early",
        426 => "Upgrade Required",
        428 => "Precondition Required",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        451 => "Unavailable For Legal Reasons",

        // 5xx Server Errors
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
        506 => "Variant Also Negotiates",
        507 => "Insufficient Storage",
        508 => "Loop Detected",
        510 => "Not Extended",
        511 => "Network Authentication Required",

        else => "Unknown",
    };

    return HttpResponse.init(jsonStruct.status_code, status_text, allocator).withJson(jsonStruct.data);
}
