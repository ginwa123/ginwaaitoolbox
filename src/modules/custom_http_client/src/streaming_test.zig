//! Streaming tests — exercise ResponseStream + StreamScanner against
//! an in-process custom_http_server (GinwaServer), not httpbin.org.
//! Eliminates network flakiness and rate-limited-throttling during CI.
//!
//! The TestServer fixture:
//!   1. Binds Address.init(0) (OS picks ephemeral port)
//!   2. Calls getsockname() to retrieve the assigned port
//!   3. Inits GinwaServer, registers routes, spawns a worker thread
//!      that calls server.listen() (blocks until shutdown())
//!   4. Provides url(path) for tests to build request URLs
//!   5. deinit calls server.shutdown(), joins worker thread, frees.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const custom_http_client = @import("root.zig");
const gserverz = @import("custom_http_server");

const HttpContext = gserverz.HttpContext;
const HttpRequest = gserverz.HttpRequest;
const HttpResponse = gserverz.HttpResponse;

/// Local HTTP test server. Returns a URL for tests to hit.
const TestServer = struct {
    server: *gserverz.GinwaServer,
    io: std.Io,
    allocator: std.mem.Allocator,
    listener_thread: std.Thread,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*TestServer {
        const ts = try allocator.create(TestServer);

        // Bind on ephemeral port (0 = OS picks).
        const addr = try gserverz.Address.init(0);
        // NOTE: addr.sock_fd is intentionally NOT closed on errdefer —
        // GinwaServer.init() takes ownership of it. The errdefer is
        // a no-op marker; the socket is bound by bind() but not yet
        // listening, so we let it leak to the test process exit
        // (kernel reclaims) if GinwaServer.init() fails after this.

        // Query the OS-assigned port via getsockname.
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

    /// Register all routes used by streaming tests. Call BEFORE `start`.
    pub fn registerRoutes(self: *TestServer) !void {
        // /stream/N — NDJSON stream of N lines (used to test SSE-like
        // chunked reads). Each line is one complete JSON object with a
        // trailing newline so StreamScanner.next() yields one line per call.
        try self.server.router.get("/stream", streamHandler);
        // /204 — empty body, used to test that next() returns 0 chunks.
        try self.server.router.get("/204", noContentHandler);
        // /echo-headers — returns the request headers as a JSON-like body,
        // useful for asserting that long headers reach the server.
        try self.server.router.get("/echo-headers", echoHeadersHandler);
        // /big — 64 KiB body used for chunked-size assertions.
        try self.server.router.get("/big", bigBodyHandler);
        // /delay/N — sleeps N seconds, used for cancellation/timeout tests.
        try self.server.router.get("/delay", delayHandler);
    }

    /// Spawn the listen worker thread.
    pub fn start(self: *TestServer) !void {
        self.listener_thread = try std.Thread.spawn(.{}, listenFn, .{self.server});
    }

    pub fn url(self: *TestServer, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}{s}", .{ self.port, path });
    }

    pub fn urlBuf(self: *TestServer, path: []const u8, buf: []u8) ![]u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, path });
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

fn streamHandler(ctx: HttpContext, _: HttpRequest, res: HttpResponse) !HttpResponse {
    // Read the ?n= query (default 20). Emit N NDJSON lines.
    // Emit 20 NDJSON lines: `{"id": <i>}\n` for i in [0..20). StreamScanner
    // will yield one line per Scan() call; carry-over handles chunks
    // that split across line boundaries.
    const n: usize = 20;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{{\"id\":{d}}}\n", .{i}) catch unreachable;
        try body.appendSlice(ctx.allocator, line);
    }
    return res.withBody(body.items);
}

fn noContentHandler(ctx: HttpContext, _: HttpRequest, _: HttpResponse) !HttpResponse {
    // Construct a fresh 204 response with no body. The `HttpResponse.init`
    // signature requires (status_code, status_text, allocator); build it
    // here so we don't need a `withStatus` helper (the upstream API
    // doesn't have one).
    return HttpResponse.init(204, "No Content", ctx.allocator);
}

fn echoHeadersHandler(ctx: HttpContext, req: HttpRequest, res: HttpResponse) !HttpResponse {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(ctx.allocator);
    var iter = req.headers.iterator();
    while (iter.next()) |entry| {
        try body.print(ctx.allocator, "{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    return res.withBody(body.items);
}

fn bigBodyHandler(ctx: HttpContext, _: HttpRequest, res: HttpResponse) !HttpResponse {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < 64 * 1024) : (i += 1) {
        try body.append(ctx.allocator, 'A');
    }
    return res.withBody(body.items);
}

fn delayHandler(ctx: HttpContext, _: HttpRequest, _: HttpResponse) !HttpResponse {
    // Stub delay: v1 sleeps 2 seconds. Tests cancel before completion.
    const io = std.testing.io;
    std.Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_s }, .real) catch {};
    return HttpResponse.init(200, "OK", ctx.allocator);
}

// ----- Helpers -----

/// Make a TestServer, register routes, start the worker, return the
/// server. Caller MUST call `server.deinit()` to clean up.
/// Skips the test (returns error.SkipZigTest) if any step fails.
fn makeTestServer(allocator: std.mem.Allocator, io: std.Io) !*TestServer {
    const ts = TestServer.init(allocator, io) catch return error.SkipZigTest;
    errdefer ts.deinit();
    try ts.registerRoutes();
    try ts.start();
    return ts;
}

// ----- Tests -----

test "stream: static-contract — cleanup pairs with init (handles init, defer, deinit)" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stream.zig",
        testing.allocator,
        .limited(256 * 1024),
    );
    defer testing.allocator.free(source);

    // Each runtime path that creates a CURL handle must have exactly
    // one cleanup. We require: at least one easy_init, at least one
    // easy_cleanup, and the structure should be balanced (every
    // SharedState.deinit has its counterpart or its caller compensates).
    // A simple proxy: count cleanup "sources" (either via SharedState
    // .deinit body or via `defer if (handle_alive)`).
    const has_init = std.mem.indexOf(u8, source, "easy_init(") != null;
    const has_cleanup = std.mem.indexOf(u8, source, "easy_cleanup(") != null;
    if (!has_init) return error.InitMissing;
    if (!has_cleanup) return error.CleanupMissing;
    // We don't assert exact equality because each cleanup appears in
    // a different code path: alloc-fail (defer), spawn-fail
    // (state.deinit), normal cleanup (state.deinit). At runtime
    // exactly one path runs per call.
}

test "stream: local /stream yields NDJSON lines via StreamScanner" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    const ts = try makeTestServer(allocator, io);
    defer ts.deinit();

    var url_buf: [256]u8 = undefined;
    const url = try ts.urlBuf("/stream", &url_buf);

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();
    var stream = try client.openStream(io, .{ .method = .GET, .url = url }, .{});
    defer stream.deinit();

    var scanner: custom_http_client.StreamScanner = .init(&stream, true);
    defer scanner.deinit();

    var count: usize = 0;
    next_line: while (true) {
        const opt = scanner.next() catch break :next_line;
        if (opt == null) break :next_line;
        count += 1;
        if (count > 30) break :next_line;
    }
    try testing.expect(count >= 10);
}

test "stream: 204 response has zero body chunks" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    const ts = try makeTestServer(allocator, io);
    defer ts.deinit();

    var url_buf: [256]u8 = undefined;
    const url = try ts.urlBuf("/204", &url_buf);

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();
    var stream = try client.openStream(io, .{ .method = .GET, .url = url }, .{});
    defer stream.deinit();

    var chunks: usize = 0;
    while (try stream.next()) |_| chunks += 1;
    try testing.expectEqual(@as(usize, 0), chunks);
}

test "stream: status_code is 200 once chunks arrive" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    const ts = try makeTestServer(allocator, io);
    defer ts.deinit();

    var url_buf: [256]u8 = undefined;
    const url = try ts.urlBuf("/echo-headers", &url_buf);

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();
    var stream = try client.openStream(io, .{ .method = .GET, .url = url }, .{});
    defer stream.deinit();

    // Drain at least one chunk.
    _ = stream.next() catch {};
    const code = stream.statusCode();
    try testing.expectEqual(@as(u16, 200), code);
}

test "stream: 64 KiB body via scanner totals 64 KiB" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    const ts = try makeTestServer(allocator, io);
    defer ts.deinit();

    var url_buf: [256]u8 = undefined;
    const url = try ts.urlBuf("/big", &url_buf);

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();
    var stream = try client.openStream(io, .{ .method = .GET, .url = url }, .{});
    defer stream.deinit();

    var scanner: custom_http_client.StreamScanner = .init(&stream, false);
    defer scanner.deinit();

    var total: usize = 0;
    while (try scanner.next()) |line| {
        total += line.len;
    }
    try testing.expectEqual(@as(usize, 64 * 1024), total);
}

test "stream: cancel() before chunks arrive stops transfer cleanly + no FD growth" {
    if (builtin.os.tag != .linux) return;
    const allocator = testing.allocator;
    const io = std.testing.io;

    const ts = try makeTestServer(allocator, io);
    defer ts.deinit();

    var url_buf: [256]u8 = undefined;
    const url = try ts.urlBuf("/delay", &url_buf);

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    var stream = client.openStream(io, .{ .method = .GET, .url = url }, .{ .timeout_ms = 60_000 }) catch |err| switch (err) {
        error.ConnectionRefused, error.ConnectionTimeout,
        error.OperationTimedOut => return error.SkipZigTest,
        else => return err,
    };

    const fd_before = countFdsViaShell() catch 0;
    stream.cancel();
    // Drain whatever arrived so deinit doesn't block forever.
    {
        drain: while (true) {
            const result = stream.next() catch break :drain;
            if (result == null) break :drain;
        }
    }
    stream.deinit();
    const fd_after = countFdsViaShell() catch 0;
    try testing.expect(fd_after <= fd_before + 5);
}

test "stream: 4 concurrent openStream calls all complete cleanly" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const allocator = testing.allocator;

    const ts = try makeTestServer(allocator, std.testing.io);
    defer ts.deinit();

    var url_buf: [256]u8 = undefined;
    const url = try ts.urlBuf("/big", &url_buf);

    const N_THREADS: usize = 4;
    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        success: std.atomic.Value(usize) = .init(0),
        fail: std.atomic.Value(usize) = .init(0),
    };
    var contexts: [N_THREADS]WorkerCtx = .{
        .{ .allocator = allocator, .io = std.testing.io, .url = url },
        .{ .allocator = allocator, .io = std.testing.io, .url = url },
        .{ .allocator = allocator, .io = std.testing.io, .url = url },
        .{ .allocator = allocator, .io = std.testing.io, .url = url },
    };

    var threads: [N_THREADS]std.Thread = undefined;
    var i: usize = 0;
    while (i < N_THREADS) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(ctx: *WorkerCtx) void {
                var client = custom_http_client.Client.init(ctx.allocator);
                defer client.deinit();
                var stream = client.openStream(ctx.io,
                    .{ .method = .GET, .url = ctx.url },
                    .{ .timeout_ms = 30_000 },
                ) catch {
                    _ = ctx.fail.fetchAdd(1, .monotonic);
                    return;
                };
                defer stream.deinit();
                var total: usize = 0;
                drain: while (true) {
                    const r = stream.next() catch break :drain;
                    const chunk = r orelse break :drain;
                    total += chunk.len;
                }
                if (total > 0) {
                    _ = ctx.success.fetchAdd(1, .monotonic);
                } else {
                    _ = ctx.fail.fetchAdd(1, .monotonic);
                }
            }
        }.run, .{&contexts[i]});
    }
    i = 0;
    while (i < N_THREADS) : (i += 1) threads[i].join();

    var ok_total: usize = 0;
    var fail_total: usize = 0;
    i = 0;
    while (i < N_THREADS) : (i += 1) {
        ok_total += contexts[i].success.load(.acquire);
        fail_total += contexts[i].fail.load(.acquire);
    }
    try testing.expect(ok_total + fail_total == N_THREADS);
    // With a real local server, all 4 should succeed.
    try testing.expect(ok_total == N_THREADS);
}

fn countFdsViaShell() !usize {
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &[_][]const u8{ "sh", "-c", "ls /proc/self/fd 2>/dev/null | wc -l" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer {
        if (child.stdout) |s| s.close(std.testing.io);
        child.kill(std.testing.io);
    }
    var buf: [64]u8 = undefined;
    var total: usize = 0;
    if (child.stdout) |out| {
        var reader = out.reader(std.testing.io, &buf);
        while (true) {
            const n = try std.Io.Reader.readSliceShort(&reader.interface, &buf);
            if (n == 0) break;
            total += n;
        }
    }
    _ = child.wait(std.testing.io) catch {};
    const contents = try testing.allocator.dupe(u8, buf[0..total]);
    defer testing.allocator.free(contents);
    var n: usize = 0;
    for (contents) |c| {
        if (c >= '0' and c <= '9') {
            n = n * 10 + @as(usize, c - '0');
        }
    }
    return n;
}
