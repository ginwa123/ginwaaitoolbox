//! ResponseStream + StreamScanner: pull-based chunk and line streaming
//! on top of libcurl's WRITEFUNCTION + XFERINFOFUNCTION callbacks.
//!
//! Mirrors Go's `http.Response.Body` + `bufio.Scanner` shape. Buffers
//! chunks as they arrive from a worker thread; caller iterates via
//! `next()` (chunks) or wraps in a `StreamScanner` (lines).
//!
//! Cancellation: set an atomic flag → libcurl's progress callback
//! (`XFERINFOFUNCTION`) returns non-zero to abort the transfer.

const std = @import("std");
const builtin = @import("builtin");
const curl = @import("curl.zig");
const root = @import("root.zig");
const Method = @import("request.zig").Method;
const Header = @import("request.zig").Header;
const Request = @import("request.zig").Request;
const Options = @import("options.zig").Options;
const Client = root.Client;
const LocalError = root.Error;
pub const _Error = LocalError; // alias for visibility inside the module

/// Thread-safe FIFO of byte slices. Fixed-size circular buffer of
/// 64 slots — comfortably above typical SSE chunk rates, bounded so
/// a slow consumer can't grow memory without bound.
const QUEUE_CAPACITY: usize = 64;

/// Tiny atomic spinlock (Zig 0.16 has no built-in Mutex — see
/// `~/.nalar/memories/zig-0.16-stdlib-changes` for context).
/// Used to protect ChunkQueue slot access. Hold time is sub-µs so
/// spinlock contention is acceptable.
const Spinlock = struct {
    state: std.atomic.Value(u32) = .init(0),
    const UNLOCKED: u32 = 0;
    const LOCKED: u32 = 1;

    fn lock(self: *Spinlock) void {
        while (true) {
            const prev = self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic);
            if (prev == null) break;
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Spinlock) void {
        self.state.store(UNLOCKED, .release);
    }
};

const ChunkQueue = struct {
    mutex: Spinlock,
    slots: [QUEUE_CAPACITY]?[]u8,
    head: usize,
    tail: usize,
    pushed_count: std.atomic.Value(u32),

    pub fn init() ChunkQueue {
        return .{
            .mutex = .{},
            .slots = [_]?[]u8{null} ** QUEUE_CAPACITY,
            .head = 0,
            .tail = 0,
            .pushed_count = .init(0),
        };
    }

    fn push(self: *ChunkQueue, allocator: std.mem.Allocator, chunk: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const next_tail = (self.tail + 1) % QUEUE_CAPACITY;
        if (next_tail == self.head) {
            return false; // queue full
        }
        const owned = allocator.dupe(u8, chunk) catch return false;
        self.slots[self.tail] = owned;
        self.tail = next_tail;
        _ = self.pushed_count.fetchAdd(1, .release);
        return true;
    }

    fn popOne(self: *ChunkQueue) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.head == self.tail) return null;
        const chunk = self.slots[self.head].?;
        self.slots[self.head] = null;
        self.head = (self.head + 1) % QUEUE_CAPACITY;
        return chunk;
    }
};

/// State shared between the worker thread (driver of curl_easy_perform)
/// and the calling thread (which calls next/cancel/deinit).
pub const ResponseStream = struct {
    allocator: std.mem.Allocator,
    handle: *curl.C.CURL,
    thread: std.Thread,
    queue: ChunkQueue,
    cancelled: std.atomic.Value(bool),
    finished: std.atomic.Value(bool),
    /// Set by worker AFTER `curl_easy_getinfo(...RESPONSE_CODE)`.
    status_code: std.atomic.Value(u32),
    primary_ip: std.ArrayList(u8),
    url_effective: std.ArrayList(u8),
    headers: std.ArrayList(Header),
    worker_error: ?LocalError,
    total_time_ms: u64,
    io: std.Io,

    /// Pulls the next body chunk. Returns null only when the transfer
    /// has finished cleanly AND no chunks remain in the queue. Returns
    /// an Error if the worker hit one (the stream is then unusable —
    /// caller should still `deinit()`).
    pub fn next(self: *ResponseStream) !?[]const u8 {
        if (self.worker_error) |e| return e;
        if (self.queue.popOne()) |chunk| return chunk;
        if (self.finished.load(.acquire)) return null;
        return null;
    }

    pub fn statusCode(self: *const ResponseStream) u16 {
        return @intCast(self.status_code.load(.acquire));
    }

    pub fn headersView(self: *const ResponseStream) []const Header {
        return self.headers.items;
    }

    pub fn effectiveUrl(self: *const ResponseStream) []const u8 {
        return self.url_effective.items;
    }

    pub fn primaryIp(self: *const ResponseStream) []const u8 {
        return self.primary_ip.items;
    }

    pub fn totalTimeMs(self: *const ResponseStream) u64 {
        return self.total_time_ms;
    }

    pub fn cancel(self: *ResponseStream) void {
        self.cancelled.store(true, .release);
    }

    pub fn deinit(self: *ResponseStream) void {
        self.cancel();
        self.thread.join();
        curl.easy_cleanup(self.handle);
        // Free per-header name/value copies.
        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.deinit(self.allocator);
        self.url_effective.deinit(self.allocator);
        self.primary_ip.deinit(self.allocator);
        // Drain remaining chunks (we own them all).
        while (self.queue.popOne()) |chunk| {
            self.allocator.free(chunk);
        }
        self.* = undefined;
    }
};

/// Line-oriented pull. Buffers partial-line bytes across chunk
/// boundaries. Empty lines are returned as `&[_]u8{}` unless
/// `skip_empty = true` at init.
pub const StreamScanner = struct {
    stream: *ResponseStream,
    carry: std.ArrayList(u8),
    line_buf: std.ArrayList(u8),
    skip_empty: bool,

    pub fn init(stream: *ResponseStream, skip_empty: bool) StreamScanner {
        return .{
            .stream = stream,
            .carry = .empty,
            .line_buf = .empty,
            .skip_empty = skip_empty,
        };
    }

    /// Pull the next line. Returns null at clean EOF. Empty lines
    /// become `&[_]u8{}` unless `skip_empty` was set.
    pub fn next(self: *StreamScanner) !?[]const u8 {
        const allocator = self.stream.allocator;
        while (true) {
            // First, search carry for a newline.
            if (std.mem.indexOfScalar(u8, self.carry.items, '\n')) |nl_idx| {
                self.line_buf.clearRetainingCapacity();
                try self.line_buf.appendSlice(allocator, self.carry.items[0..nl_idx]);
                const line_end: usize = if (self.line_buf.items.len > 0 and
                    self.line_buf.items[self.line_buf.items.len - 1] == '\r')
                    self.line_buf.items.len - 1
                else
                    self.line_buf.items.len;
                const drop_through_nl: usize = nl_idx + 1;
                const remaining = self.carry.items.len - drop_through_nl;
                std.mem.copyForwards(
                    u8,
                    self.carry.items[0..remaining],
                    self.carry.items[drop_through_nl..],
                );
                self.carry.shrinkRetainingCapacity(remaining);
                if (self.skip_empty and line_end == 0) continue;
                return self.line_buf.items[0..line_end];
            }

            // No newline in carry. Pull another chunk.
            const chunk_opt = try self.stream.next();
            const chunk = chunk_opt orelse {
                // EOF: if carry has bytes (no trailing newline), flush
                // them as the final line.
                if (self.carry.items.len > 0) {
                    self.line_buf.clearRetainingCapacity();
                    try self.line_buf.appendSlice(allocator, self.carry.items);
                    self.carry.clearRetainingCapacity();
                    if (self.skip_empty and self.line_buf.items.len == 0) return null;
                    return self.line_buf.items;
                }
                return null;
            };
            try self.carry.appendSlice(allocator, chunk);
        }
    }

    pub fn deinit(self: *StreamScanner) void {
        self.carry.deinit(self.stream.allocator);
        self.line_buf.deinit(self.stream.allocator);
    }
};

// ----- Callbacks -----

fn writeCallback(buf: [*]const u8, size: u64, nmemb: u64, userdata: *anyopaque) callconv(.c) u64 {
    const WriteCtx = struct {
        queue: *ChunkQueue,
        allocator: std.mem.Allocator,
    };
    const ctx: *WriteCtx = @ptrCast(@alignCast(userdata));
    const slice = buf[0 .. size * nmemb];
    if (!ctx.queue.push(ctx.allocator, slice)) return 0;
    return size * nmemb;
}

fn progressCallback(
    handle: *curl.C.CURL,
    dltotal: c_longlong,
    dlnow: c_longlong,
    ultotal: c_longlong,
    ulnow: c_longlong,
    userdata: *anyopaque,
) callconv(.c) c_int {
    _ = handle;
    _ = dltotal;
    _ = dlnow;
    _ = ultotal;
    _ = ulnow;
    const cancelled: *std.atomic.Value(bool) = @ptrCast(@alignCast(userdata));
    return if (cancelled.load(.acquire)) 1 else 0;
}

fn headerCallback(buf: [*]const u8, size: u64, nmemb: u64, userdata: *anyopaque) callconv(.c) u64 {
    const HeaderCtx = struct {
        list: *std.ArrayList(Header),
        allocator: std.mem.Allocator,
    };
    const ctx: *HeaderCtx = @ptrCast(@alignCast(userdata));
    const slice = buf[0 .. size * nmemb];
    if (slice.len == 0) return size * nmemb;
    if (slice.len >= 5 and std.mem.startsWith(u8, slice, "HTTP/")) return size * nmemb;
    const trimmed: []const u8 = trim: {
        if (slice.len >= 2 and slice[slice.len - 2] == '\r' and slice[slice.len - 1] == '\n') {
            break :trim slice[0 .. slice.len - 2];
        }
        if (slice.len >= 1 and slice[slice.len - 1] == '\n') {
            break :trim slice[0 .. slice.len - 1];
        }
        break :trim slice;
    };
    const sep = std.mem.indexOf(u8, trimmed, ": ") orelse return size * nmemb;
    const name_owned = ctx.allocator.dupe(u8, trimmed[0..sep]) catch return 0;
    errdefer ctx.allocator.free(name_owned);
    const value_owned = ctx.allocator.dupe(u8, trimmed[sep + 2 ..]) catch return 0;
    errdefer ctx.allocator.free(value_owned);
    ctx.list.append(ctx.allocator, .{ .name = name_owned, .value = value_owned }) catch {
        ctx.allocator.free(name_owned);
        ctx.allocator.free(value_owned);
        return 0;
    };
    return size * nmemb;
}

// Worker thread entry point. Drives curl_easy_perform and captures
// status / url / ip / total_time once it returns.
fn streamWorker(stream: *ResponseStream) void {
    const rc: c_uint = curl.easy_perform(stream.handle);
    if (rc != curl.C.CURLE_OK and stream.worker_error == null) {
        stream.worker_error = mapStreamError(rc);
    }

    var status: c_long = 0;
    _ = curl.easy_getinfo(stream.handle, curl.OPT.RESPONSE_CODE, &status);
    stream.status_code.store(@as(u32, @intCast(status)), .release);

    var eff_url_ptr: [*c]const u8 = &[_]u8{0};
    _ = curl.easy_getinfo(stream.handle, curl.OPT.EFFECTIVE_URL, &eff_url_ptr);
    const eff_url_slice = std.mem.sliceTo(eff_url_ptr, 0);
    stream.url_effective.appendSlice(stream.allocator, eff_url_slice) catch {};

    var total_time: f64 = 0;
    _ = curl.easy_getinfo(stream.handle, curl.OPT.TOTAL_TIME, &total_time);
    stream.total_time_ms = @intFromFloat(total_time * 1000.0);

    var primary_ip_ptr: [*c]const u8 = &[_]u8{0};
    _ = curl.easy_getinfo(stream.handle, curl.OPT.PRIMARY_IP, &primary_ip_ptr);
    const primary_ip_slice = if (primary_ip_ptr != null)
        std.mem.sliceTo(primary_ip_ptr, 0)
    else
        "";
    stream.primary_ip.appendSlice(stream.allocator, primary_ip_slice) catch {};

    stream.finished.store(true, .release);
}

fn mapStreamError(rc: c_uint) LocalError {
    const rc_int: c_int = @intCast(rc);
    return switch (rc_int) {
        0 => unreachable,
        @intCast(curl.C.CURLE_URL_MALFORMAT) => LocalError.InvalidUrl,
        @intCast(curl.C.CURLE_COULDNT_RESOLVE_PROXY),
        @intCast(curl.C.CURLE_COULDNT_RESOLVE_HOST) => LocalError.DnsError,
        @intCast(curl.C.CURLE_OPERATION_TIMEDOUT) => LocalError.OperationTimedOut,
        @intCast(curl.C.CURLE_COULDNT_CONNECT) => LocalError.ConnectionRefused,
        @intCast(curl.C.CURLE_PEER_FAILED_VERIFICATION),
        @intCast(curl.C.CURLE_SSL_CERTPROBLEM),
        @intCast(curl.C.CURLE_SSL_CIPHER),
        @intCast(curl.C.CURLE_SSL_CONNECT_ERROR) => LocalError.TlsError,
        @intCast(curl.C.CURLE_UNSUPPORTED_PROTOCOL) => LocalError.UnsupportedProtocol,
        @intCast(curl.C.CURLE_TOO_MANY_REDIRECTS) => LocalError.TooManyRedirects,
        @intCast(curl.C.CURLE_OUT_OF_MEMORY) => LocalError.OutOfMemory,
        // CURLE_ABORTED_BY_CALLBACK (42) — cancellation flag tripped.
        // Map to OperationTimedOut; callers should `cancel()` to
        // trigger a clean exit.
        @intCast(curl.C.CURLE_ABORTED_BY_CALLBACK) => LocalError.OperationTimedOut,
        else => LocalError.UnknownCurl,
    };
}

// setopt wrappers (duplicated from client.zig; could be shared later).
fn setoptLong(handle: *curl.C.CURL, option: c_int, value: c_long) c_uint {
    return curl.easy_setopt_raw(handle, @as(c_uint, @intCast(option)), value);
}
fn setoptPtr(handle: *curl.C.CURL, option: c_int, value: [*]const u8) c_uint {
    return curl.easy_setopt_raw(handle, @as(c_uint, @intCast(option)), value);
}
fn setoptSlist(handle: *curl.C.CURL, option: c_int, value: ?*curl.C.struct_curl_slist) c_uint {
    return curl.easy_setopt_raw(handle, @as(c_uint, @intCast(option)), value);
}

/// Open a streaming HTTP request. The transfer runs in a worker thread;
/// chunks arrive via `ResponseStream.next`. The caller MUST call
/// `deinit` (or `cancel` + `deinit`) on the returned stream exactly once.
///
/// On error, the stream is unusable — call `deinit` (which will block
/// briefly joining the worker).
pub fn openStream(
    client: *Client,
    io: std.Io,
    req: Request,
    options: Options,
) LocalError!ResponseStream {
    const allocator = client.allocator;

    const handle = curl.easy_init() orelse return LocalError.InitFailed;

    var errbuf: [256]u8 = [_]u8{0} ** 256;
    _ = setoptLong(handle, curl.OPT.ERRORBUFFER, @as(c_long, @intCast(@intFromPtr(&errbuf))));

    // URL with sentinel terminator.
    const url_buf = try allocator.allocSentinel(u8, req.url.len, 0);
    @memcpy(url_buf, req.url);
    _ = setoptPtr(handle, curl.OPT.URL, url_buf.ptr);

    // Method with stack-buffer sentinel terminator.
    var method_z: [16:0]u8 = undefined;
    const mlen = @min(req.method.asString().len, method_z.len - 1);
    @memcpy(method_z[0..mlen], req.method.asString()[0..mlen]);
    method_z[mlen] = 0;
    _ = setoptPtr(handle, curl.OPT.CUSTOMREQUEST, method_z[0..mlen :0].ptr);

    // Headers slist.
    var slist: ?*curl.C.struct_curl_slist = null;
    defer if (slist) |s| curl.slist_free_all(s);

    var ua_buf: [256]u8 = undefined;
    var ua_to_send: []const u8 = "";
    if (options.user_agent.len > 0) {
        ua_to_send = options.user_agent;
    } else {
        var has_in_headers = false;
        for (req.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
                has_in_headers = true;
                break;
            }
        }
        if (!has_in_headers) ua_to_send = "custom_http_client/0.1.0";
    }
    if (ua_to_send.len > 0 and ua_to_send.len < ua_buf.len) {
        @memcpy(ua_buf[0..ua_to_send.len], ua_to_send);
        ua_buf[ua_to_send.len] = 0;
        slist = curl.slist_append(slist, &ua_buf);
    }

    for (req.headers) |h| {
        const total_len = h.name.len + 2 + h.value.len;
        const line = try allocator.allocSentinel(u8, total_len, 0);
        defer allocator.free(line);
        @memcpy(line[0..h.name.len], h.name);
        line[h.name.len] = ':';
        line[h.name.len + 1] = ' ';
        @memcpy(line[h.name.len + 2 ..][0..h.value.len], h.value);
        slist = curl.slist_append(slist, line);
    }
    _ = setoptSlist(handle, curl.OPT.HTTPHEADER, slist);

    // Body.
    if (req.body) |body| {
        _ = setoptPtr(handle, curl.OPT.POSTFIELDS, body.ptr);
        _ = setoptLong(handle, curl.OPT.POSTFIELDSIZE_LARGE, @as(c_long, @intCast(body.len)));
    }

    // Timeouts / redirects / TLS.
    if (options.timeout_ms) |t| _ = setoptLong(handle, curl.OPT.TIMEOUT_MS, @as(c_long, t));
    if (options.connect_timeout_ms) |t| _ = setoptLong(handle, curl.OPT.CONNECTTIMEOUT_MS, @as(c_long, t));
    _ = setoptLong(handle, curl.OPT.FOLLOWLOCATION, if (options.follow_redirects) @as(c_long, 1) else @as(c_long, 0));
    if (options.follow_redirects) {
        _ = setoptLong(handle, curl.OPT.MAXREDIRS, @as(c_long, options.max_redirects));
    }
    _ = setoptLong(handle, curl.OPT.NOSIGNAL, @as(c_long, 1));
    _ = setoptLong(handle, curl.OPT.SSL_VERIFYPEER, if (options.verify_ssl) @as(c_long, 1) else @as(c_long, 0));
    _ = setoptLong(handle, curl.OPT.SSL_VERIFYHOST, if (options.verify_ssl) @as(c_long, 2) else @as(c_long, 0));

    // ----- Callbacks -----
    var stream: ResponseStream = .{
        .allocator = allocator,
        .handle = handle,
        .thread = undefined,
        .queue = .init(),
        .cancelled = .init(false),
        .finished = .init(false),
        .status_code = .init(0),
        .primary_ip = .empty,
        .url_effective = .empty,
        .headers = .empty,
        .worker_error = null,
        .total_time_ms = 0,
        .io = io,
    };

    const WriteCtx = struct {
        queue: *ChunkQueue,
        allocator: std.mem.Allocator,
    };
    var write_ctx = WriteCtx{ .queue = &stream.queue, .allocator = allocator };
    _ = curl.easy_setopt_raw(handle, curl.OPT.WRITEFUNCTION, @as(curl.WriteCallback, @ptrCast(&writeCallback)));
    _ = curl.easy_setopt_raw(handle, curl.OPT.WRITEDATA, @as(*anyopaque, @ptrCast(&write_ctx)));

    const HeaderCtx = struct {
        list: *std.ArrayList(Header),
        allocator: std.mem.Allocator,
    };
    var header_ctx = HeaderCtx{ .list = &stream.headers, .allocator = allocator };
    _ = curl.easy_setopt_raw(handle, curl.OPT.HEADERFUNCTION, @as(curl.HeaderCallback, @ptrCast(&headerCallback)));
    _ = curl.easy_setopt_raw(handle, curl.OPT.HEADERDATA, @as(*anyopaque, @ptrCast(&header_ctx)));

    // Cancellation: progress callback polls the cancelled flag.
    _ = setoptLong(handle, curl.OPT.NOPROGRESS, @as(c_long, 0));
    _ = curl.easy_setopt_raw(handle, curl.OPT.XFERINFOFUNCTION, @as(curl.ProgressCallback, @ptrCast(&progressCallback)));
    _ = curl.easy_setopt_raw(handle, curl.OPT.XFERINFODATA, @as(*anyopaque, @ptrCast(&stream.cancelled)));

    // Spawn worker thread that runs curl_easy_perform.
    const thread = std.Thread.spawn(.{}, streamWorker, .{&stream}) catch |err| switch (err) {
        error.ThreadQuotaExceeded,
        error.LockedMemoryLimitExceeded,
        error.SystemResources,
        error.OutOfMemory,
        error.Unexpected => return LocalError.InitFailed,
    };
    stream.thread = thread;

    return stream;
}
