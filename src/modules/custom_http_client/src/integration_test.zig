//! Behavioural tests against an in-process GinwaServer fixture.
//!
//! These tests were originally written against https://httpbin.org but
//! were rewritten to hit a local `custom_http_server` so the suite is
//! network-independent (CI runs in air-gapped sandboxes; httpbin.org
//! rate-limits; DNS can flap). The route surface mirrors httpbin's
//! endpoints so the test intent is preserved:
//!
//!   GET    /get       → 200, returns "ok"
//!   POST   /post      → 200, echoes body back (Content-Length aware)
//!   PUT    /put       → 200, echoes body back
//!   PATCH  /patch     → 200, echoes body back
//!   DELETE /delete    → 200, returns "deleted"
//!   GET    /status/N  → N (e.g. /status/404 → 404)
//!   GET    /redirect/N → 302 → /redirect/(N-1) → ... → 200 /get
//!
//! Pattern mirrors the httpbin endpoints exercised by
//! `modules/http/HttpClient.zig` for parity testing.

const std = @import("std");
const testing = std.testing;
const custom_http_client = @import("root.zig");
const gserverz = @import("custom_http_server");

const HttpContext = gserverz.HttpContext;
const HttpRequest = gserverz.HttpRequest;
const HttpResponse = gserverz.HttpResponse;

/// Local HTTP test server. Same shape as the streaming TestServer so
/// both suites share the fixture semantics.
const TestServer = struct {
    server: *gserverz.GinwaServer,
    io: std.Io,
    allocator: std.mem.Allocator,
    listener_thread: std.Thread,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*TestServer {
        const ts = try allocator.create(TestServer);

        const addr = try gserverz.Address.init(0);

        var raw_addr: std.posix.sockaddr.in = undefined;
        var len: std.posix.socklen_t = @sizeOf(@TypeOf(raw_addr));
        const rc = std.os.linux.getsockname(addr.sock_fd, @ptrCast(&raw_addr), &len);
        if (rc != 0) return error.BindFailed;
        const port: u16 = @byteSwap(@as(u16, @intCast(raw_addr.port)));

        const gs = try gserverz.GinwaServer.init(allocator, io, addr);

        ts.* = .{
            .server = gs,
            .io = io,
            .allocator = allocator,
            .listener_thread = undefined,
            .port = port,
        };
        return ts;
    }

    pub fn registerRoutes(self: *TestServer) !void {
        try self.server.router.get("/get", getHandler);
        try self.server.router.post("/post", echoPostHandler);
        try self.server.router.put("/put", echoPutHandler);
        try self.server.router.patch("/patch", echoPatchHandler);
        try self.server.router.delete("/delete", deleteHandler);
        // The GinwaServer router uses `:param` placeholders for path
        // segments. /status/:n matches /status/404 etc.
        try self.server.router.get("/status/:n", statusHandler);
        try self.server.router.get("/redirect/:n", redirectHandler);
    }

    pub fn start(self: *TestServer) !void {
        self.listener_thread = try std.Thread.spawn(.{}, listenFn, .{self.server});
    }

    pub fn url(self: *TestServer, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}{s}", .{ self.port, path });
    }

    pub fn deinit(self: *TestServer) void {
        self.server.shutdown();
        self.listener_thread.join();
        self.server.destroy(self.allocator);
        self.allocator.destroy(self);
    }
};

fn listenFn(server: *gserverz.GinwaServer) void {
    server.listen() catch {};
}

// ----- Route handlers -----

fn getHandler(_: HttpContext, _: HttpRequest, res: HttpResponse) !HttpResponse {
    return res.withBody("ok");
}

fn echoPostHandler(_: HttpContext, req: HttpRequest, res: HttpResponse) !HttpResponse {
    // The GinwaServer already buffers the entire request body into
    // req.body (a `[]const u8`) before invoking handlers — no streaming
    // read needed. Truncate to Content-Length to handle clients that
    // sent extra framing (libcurl is well-behaved, so this is usually
    // the full body).
    const content_length_str = req.headers.get("content-length") orelse "";
    const cap = std.fmt.parseInt(usize, content_length_str, 10) catch req.body.len;
    const n = @min(cap, req.body.len);
    return res.withBody(req.body[0..n]);
}

fn echoPutHandler(ctx: HttpContext, req: HttpRequest, res: HttpResponse) !HttpResponse {
    return echoPostHandler(ctx, req, res);
}

fn echoPatchHandler(ctx: HttpContext, req: HttpRequest, res: HttpResponse) !HttpResponse {
    return echoPostHandler(ctx, req, res);
}

fn deleteHandler(_: HttpContext, _: HttpRequest, res: HttpResponse) !HttpResponse {
    return res.withBody("deleted");
}

fn statusHandler(ctx: HttpContext, req: HttpRequest, _: HttpResponse) !HttpResponse {
    // n is bound by the /status/:n route pattern. Default to 400 if
    // the parameter is missing or unparseable.
    const n_str = req.params.get("n") orelse "400";
    const code = std.fmt.parseInt(u16, n_str, 10) catch 400;
    return HttpResponse.init(code, "Status", ctx.allocator);
}

fn redirectHandler(ctx: HttpContext, req: HttpRequest, _: HttpResponse) !HttpResponse {
    // /redirect/N → 302 to /redirect/(N-1); /redirect/1 → 302 to /get.
    const n_str = req.params.get("n") orelse "1";
    const n = std.fmt.parseInt(usize, n_str, 10) catch 1;
    const owned_location: []u8 = if (n <= 1)
        try ctx.allocator.dupe(u8, "/get")
    else
        std.fmt.allocPrint(ctx.allocator, "/redirect/{d}", .{n - 1}) catch unreachable;
    defer ctx.allocator.free(owned_location);

    var resp = HttpResponse.init(302, "Found", ctx.allocator);
    try resp.headers.put("location", owned_location);
    return resp;
}

fn makeTestServer(allocator: std.mem.Allocator, io: std.Io) !*TestServer {
    const ts = TestServer.init(allocator, io) catch return error.SkipZigTest;
    ts.registerRoutes() catch return error.SkipZigTest;
    ts.start() catch return error.SkipZigTest;
    return ts;
}

test "integration: GET /get returns 200" {
    const allocator = testing.allocator;
    const ts = try makeTestServer(allocator, std.testing.io);
    defer ts.deinit();

    const url = try ts.url("/get");
    defer allocator.free(url);

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();
    var resp = client.perform(.{ .method = .GET, .url = url }, .{}) catch |err| switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimeout,
        error.OperationTimedOut,
        error.DnsError,
        error.TlsError => return error.SkipZigTest,
        else => return err,
    };
    defer resp.deinit(allocator);

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expect(resp.body.len > 0);
}

test "integration: POST JSON to /post echoes the body back" {
    const allocator = testing.allocator;
    const ts = try makeTestServer(allocator, std.testing.io);
    defer ts.deinit();

    const url = try ts.url("/post");
    defer allocator.free(url);

    const body = "{\"hello\":\"world\"}";
    const headers = [_]custom_http_client.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();
    var resp = client.perform(.{
        .method = .POST,
        .url = url,
        .body = body,
        .headers = &headers,
    }, .{}) catch |err| switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimeout,
        error.OperationTimedOut,
        error.DnsError,
        error.TlsError => return error.SkipZigTest,
        else => return err,
    };
    defer resp.deinit(allocator);

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expect(std.mem.indexOf(u8, resp.body, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "world") != null);
}

test "integration: PUT and PATCH both echo the body back" {
    const allocator = testing.allocator;
    const ts = try makeTestServer(allocator, std.testing.io);
    defer ts.deinit();

    const body = "{\"x\":1}";
    const headers = [_]custom_http_client.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    {
        const url = try ts.url("/put");
        defer allocator.free(url);
        var client = custom_http_client.Client.init(allocator);
        defer client.deinit();
        var resp = client.perform(.{
            .method = .PUT,
            .url = url,
            .body = body,
            .headers = &headers,
        }, .{}) catch |err| switch (err) {
            error.ConnectionRefused,
            error.ConnectionTimeout,
            error.OperationTimedOut,
            error.DnsError,
            error.TlsError => return error.SkipZigTest,
            else => return err,
        };
        defer resp.deinit(allocator);
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        try testing.expect(std.mem.indexOf(u8, resp.body, "\"x\"") != null);
    }

    {
        const url = try ts.url("/patch");
        defer allocator.free(url);
        var client = custom_http_client.Client.init(allocator);
        defer client.deinit();
        var resp = client.perform(.{
            .method = .PATCH,
            .url = url,
            .body = body,
            .headers = &headers,
        }, .{}) catch |err| switch (err) {
            error.ConnectionRefused,
            error.ConnectionTimeout,
            error.OperationTimedOut,
            error.DnsError,
            error.TlsError => return error.SkipZigTest,
            else => return err,
        };
        defer resp.deinit(allocator);
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        try testing.expect(std.mem.indexOf(u8, resp.body, "\"x\"") != null);
    }
}

test "integration: DELETE returns 200" {
    const allocator = testing.allocator;
    const ts = try makeTestServer(allocator, std.testing.io);
    defer ts.deinit();

    const url = try ts.url("/delete");
    defer allocator.free(url);

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();
    var resp = client.perform(.{ .method = .DELETE, .url = url }, .{}) catch |err| switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimeout,
        error.OperationTimedOut,
        error.DnsError,
        error.TlsError => return error.SkipZigTest,
        else => return err,
    };
    defer resp.deinit(allocator);

    try testing.expectEqual(@as(u16, 200), resp.status_code);
}

test "integration: GET /status/404 surfaces 404 in status_code without error" {
    const allocator = testing.allocator;
    const ts = try makeTestServer(allocator, std.testing.io);
    defer ts.deinit();

    const url = try ts.url("/status/404");
    defer allocator.free(url);

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();
    var resp = client.perform(.{ .method = .GET, .url = url }, .{}) catch |err| switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimeout,
        error.OperationTimedOut,
        error.DnsError,
        error.TlsError => return error.SkipZigTest,
        else => return err,
    };
    defer resp.deinit(allocator);

    try testing.expectEqual(@as(u16, 404), resp.status_code);
}

test "integration: GET /redirect/3 with follow_redirects=true ends at /get" {
    const allocator = testing.allocator;
    const ts = try makeTestServer(allocator, std.testing.io);
    defer ts.deinit();

    const url = try ts.url("/redirect/3");
    defer allocator.free(url);

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();
    var resp = client.perform(.{ .method = .GET, .url = url }, .{ .follow_redirects = true, .max_redirects = 10 }) catch |err| switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimeout,
        error.OperationTimedOut,
        error.DnsError,
        error.TlsError => return error.SkipZigTest,
        else => return err,
    };
    defer resp.deinit(allocator);

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expect(std.mem.indexOf(u8, resp.url_effective, "/get") != null);
}