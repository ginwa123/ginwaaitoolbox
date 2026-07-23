//! ResponseStream + StreamScanner: pull-based chunk and line streaming
//! on top of libcurl's WRITEFUNCTION + XFERINFOFUNCTION callbacks.
//!
//! Mirrors Go's `http.Response.Body` + `bufio.Scanner` shape. Buffers
//! chunks as they arrive from a worker thread; caller iterates via
//! `next()` (chunks) or wraps in a `StreamScanner` (lines).
//!
//! **Threading model:** We use `std.Io.Mutex` (futex-based, from
//! Zig 0.16 std.Io) for the chunk-queue mutex — NOT a hand-rolled
//! spinlock. `std.Io.Mutex` is the canonical Zig 0.16 implementation
//! for Io-runtime code (see `~/.nalar/memories/zig-0.16-stdlib-changes`).
//!
//! **Lifetime:** the worker thread and the calling thread share a
//! heap-allocated `SharedState`. The caller MUST call `deinit()` which
//! joins the worker and frees the heap. After deinit the stream is
//! unusable.

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

/// Thread-safe FIFO of byte slices. Fixed-size circular buffer of
/// 64 slots — comfortably above typical SSE chunk rates, bounded so
/// a slow consumer can't grow memory without bound.
const QUEUE_CAPACITY: usize = 64;

/// libcurl's CURLOPT_ERRORBUFFER expects a buffer of at least
/// `CURL_ERROR_SIZE` bytes (256 per the curl.h header). We size it
/// generously so a future curl bump can't silently truncate us.
const CURL_ERRORBUFFER_LEN: usize = 256;

const ChunkQueue = struct {
    mutex: *std.Io.Mutex,
    slots: [QUEUE_CAPACITY]?[]u8,
    head: usize,
    tail: usize,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ChunkQueue {
        const mutex = allocator.create(std.Io.Mutex) catch unreachable;
        mutex.* = .init;
        return .{
            .mutex = mutex,
            .slots = [_]?[]u8{null} ** QUEUE_CAPACITY,
            .head = 0,
            .tail = 0,
            .io = io,
        };
    }

    pub fn deinit(self: *ChunkQueue, allocator: std.mem.Allocator) void {
        allocator.destroy(self.mutex);
    }

    fn push(self: *ChunkQueue, allocator: std.mem.Allocator, chunk: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const next_tail = (self.tail + 1) % QUEUE_CAPACITY;
        if (next_tail == self.head) return false;
        const owned = allocator.dupe(u8, chunk) catch return false;
        self.slots[self.tail] = owned;
        self.tail = next_tail;
        return true;
    }

    fn popOne(self: *ChunkQueue) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.head == self.tail) return null;
        const chunk = self.slots[self.head].?;
        self.slots[self.head] = null;
        self.head = (self.head + 1) % QUEUE_CAPACITY;
        return chunk;
    }
};

/// State shared between worker thread and caller. Heap-allocated so
/// the worker thread's pointer survives the caller-thread's stack
/// frames returning.
const SharedState = struct {
    allocator: std.mem.Allocator,
    handle: *curl.C.CURL,
    queue: ChunkQueue,
    cancelled: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    status_code: std.atomic.Value(u32) = .init(0),
    primary_ip: std.ArrayList(u8),
    url_effective: std.ArrayList(u8),
    headers: std.ArrayList(Header),
    worker_error: ?LocalError = null,
    total_time_ms: u64 = 0,
    io: std.Io,
    /// Backing storage for `CURLOPT_ERRORBUFFER`. Lives on the heap
    /// (via SharedState) because libcurl stores the raw pointer and
    /// writes into it whenever an error string is produced — often
    /// AFTER `openStream` has returned, from inside `streamWorker`
    /// running on a separate `std.Thread`. A stack-local here would
    /// be a classic use-after-free the moment the worker fired an
    /// error path.
    errbuf: [CURL_ERRORBUFFER_LEN]u8 = [_]u8{0} ** CURL_ERRORBUFFER_LEN,
    /// Backing storage for `CURLOPT_URL`. Same lifetime reasoning
    /// as errbuf — libcurl stores the pointer verbatim and reads it
    /// from inside `easy_perform` on the worker thread.
    url_buf: [:0]u8,
    /// Backing storage for `CURLOPT_CUSTOMREQUEST`. Same reasoning.
    method_buf: [:0]u8,
    /// Backing storage for the optional User-Agent header line.
    /// Used in the curl slist for HTTPHEADER.
    ua_buf: ?[:0]u8,
    /// Backing for the HTTPHEADER slist (which libcurl reads verbatim
    /// from worker). Each line is [:0]u8; the slist is a linked
    /// list of pointers that we own.
    header_lines: std.ArrayList([:0]u8),
    /// The compiled slist passed to libcurl. libcurl does NOT copy
    /// this — it reads from the linked list whenever it serializes
    /// the request. We must keep it alive until easy_cleanup runs.
    header_slist: ?*curl.C.struct_curl_slist,

    fn deinit(self: *SharedState) void {
        self.cancel();
        curl.easy_cleanup(self.handle);
        if (self.header_slist) |s| curl.slist_free_all(s);
        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.deinit(self.allocator);
        self.url_effective.deinit(self.allocator);
        self.primary_ip.deinit(self.allocator);
        for (self.header_lines.items) |line| {
            self.allocator.free(line);
        }
        self.header_lines.deinit(self.allocator);
        self.allocator.free(self.url_buf);
        self.allocator.free(self.method_buf);
        if (self.ua_buf) |ua| self.allocator.free(ua);
        while (self.queue.popOne()) |chunk| {
            self.allocator.free(chunk);
        }
        self.queue.deinit(self.allocator);
    }

    fn cancel(self: *SharedState) void {
        self.cancelled.store(true, .release);
    }
};

/// Caller-facing handle. Owns a `*SharedState` (heap-allocated).
/// `deinit` joins the worker thread and frees the shared state.
pub const ResponseStream = struct {
    state: *SharedState,
    thread: std.Thread,

    pub fn next(self: *ResponseStream) !?[]const u8 {
        // Block briefly waiting for the worker thread to push a chunk
        // or signal completion. Without this, `next()` would return
        // null on the very first call (race vs the worker thread),
        // causing streaming tests to exit prematurely with 0 chunks.
        //
        // Poll budget is short (5s, generous for slow handshakes) but
        // we exit early as soon as a chunk arrives or the worker
        // reports completion. We use libc clock_gettime rather than
        // std.Io.Clock.now because the latter calls into the Io
        // runtime from the test thread, which can deadlock against
        // the worker thread that owns the runtime.
        const poll_budget_ns: u64 = 5 * std.time.ns_per_s;
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const start_ns: u64 = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        const deadline_ns: u64 = start_ns + poll_budget_ns;
        while (true) {
            if (self.state.worker_error) |e| return e;
            if (self.state.queue.popOne()) |chunk| return chunk;
            if (self.state.finished.load(.acquire)) return null;
            _ = std.c.clock_gettime(.MONOTONIC, &ts);
            const now_ns: u64 = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
            if (now_ns >= deadline_ns) return null;
            std.atomic.spinLoopHint();
        }
    }

    pub fn statusCode(self: *const ResponseStream) u16 {
        return @intCast(self.state.status_code.load(.acquire));
    }

    pub fn headersView(self: *const ResponseStream) []const Header {
        return self.state.headers.items;
    }

    pub fn effectiveUrl(self: *const ResponseStream) []const u8 {
        return self.state.url_effective.items;
    }

    pub fn primaryIp(self: *const ResponseStream) []const u8 {
        return self.state.primary_ip.items;
    }

    pub fn totalTimeMs(self: *const ResponseStream) u64 {
        return self.state.total_time_ms;
    }

    pub fn cancel(self: *ResponseStream) void {
        self.state.cancel();
    }

    pub fn deinit(self: *ResponseStream) void {
        self.state.cancel();
        self.thread.join();
        self.state.deinit();
        self.state.allocator.destroy(self.state);
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

    pub fn next(self: *StreamScanner) !?[]const u8 {
        const allocator = self.stream.state.allocator;
        while (true) {
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
            const chunk_opt = try self.stream.next();
            const chunk = chunk_opt orelse {
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
        self.carry.deinit(self.stream.state.allocator);
        self.line_buf.deinit(self.stream.state.allocator);
    }
};

fn writeCallback(buf: [*]const u8, size: u64, nmemb: u64, userdata: *anyopaque) callconv(.c) u64 {
    const state: *SharedState = @ptrCast(@alignCast(userdata));
    const slice = buf[0 .. size * nmemb];
    if (!state.queue.push(state.allocator, slice)) return 0;
    return size * nmemb;
}

fn headerCallback(buf: [*]const u8, size: u64, nmemb: u64, userdata: *anyopaque) callconv(.c) u64 {
    const state: *SharedState = @ptrCast(@alignCast(userdata));
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
    const name_owned = state.allocator.dupe(u8, trimmed[0..sep]) catch return 0;
    errdefer state.allocator.free(name_owned);
    const value_owned = state.allocator.dupe(u8, trimmed[sep + 2 ..]) catch return 0;
    errdefer state.allocator.free(value_owned);
    state.headers.append(state.allocator, .{ .name = name_owned, .value = value_owned }) catch {
        state.allocator.free(name_owned);
        state.allocator.free(value_owned);
        return 0;
    };
    return size * nmemb;
}

fn streamWorker(state: *SharedState) void {
    const rc: c_uint = curl.easy_perform(state.handle);
    if (rc != curl.C.CURLE_OK and state.worker_error == null) {
        state.worker_error = mapStreamError(rc);
    }

    var status: c_long = 0;
    _ = curl.easy_getinfo(state.handle, curl.OPT.RESPONSE_CODE, &status);
    state.status_code.store(@as(u32, @intCast(status)), .release);

    var eff_url_ptr: [*c]const u8 = &[_]u8{0};
    _ = curl.easy_getinfo(state.handle, curl.OPT.EFFECTIVE_URL, &eff_url_ptr);
    const eff_url_slice = std.mem.sliceTo(eff_url_ptr, 0);
    state.url_effective.appendSlice(state.allocator, eff_url_slice) catch {};

    var total_time: f64 = 0;
    _ = curl.easy_getinfo(state.handle, curl.OPT.TOTAL_TIME, &total_time);
    state.total_time_ms = @intFromFloat(total_time * 1000.0);

    var primary_ip_ptr: [*c]const u8 = &[_]u8{0};
    _ = curl.easy_getinfo(state.handle, curl.OPT.PRIMARY_IP, &primary_ip_ptr);
    const primary_ip_slice = if (primary_ip_ptr != null)
        std.mem.sliceTo(primary_ip_ptr, 0)
    else
        "";
    state.primary_ip.appendSlice(state.allocator, primary_ip_slice) catch {};

    state.finished.store(true, .release);
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
        @intCast(curl.C.CURLE_ABORTED_BY_CALLBACK) => LocalError.OperationTimedOut,
        else => LocalError.UnknownCurl,
    };
}

fn setoptLong(handle: *curl.C.CURL, option: c_int, value: c_long) c_uint {
    return curl.easy_setopt_raw(handle, @as(c_uint, @intCast(option)), value);
}
fn setoptPtr(handle: *curl.C.CURL, option: c_int, value: [*]const u8) c_uint {
    return curl.easy_setopt_raw(handle, @as(c_uint, @intCast(option)), value);
}
fn setoptSlist(handle: *curl.C.CURL, option: c_int, value: ?*curl.C.struct_curl_slist) c_uint {
    return curl.easy_setopt_raw(handle, @as(c_uint, @intCast(option)), value);
}

pub fn openStream(
    client: *Client,
    io: std.Io,
    req: Request,
    options: Options,
) LocalError!ResponseStream {
    const allocator = client.allocator;

    const handle = curl.easy_init() orelse return LocalError.InitFailed;
    var handle_alive = true;
    defer if (handle_alive) curl.easy_cleanup(handle);

    // Heap-allocate all the buffers libcurl will read from inside the
    // worker thread (after this function returns). libcurl stores the
    // raw pointer verbatim (no copy) for CURLOPT_URL, CUSTOMREQUEST,
    // HTTPHEADER, and ERRORBUFFER — every one of these MUST outlive
    // openStream. Putting them on the stack or in early-freed heap
    // allocations produces use-after-free in the worker.
    //
    // Zig 0.16 has no errdefer-cancel, so we use a labeled block to
    // bound the "we own these, clean up on any error" scope. Once
    // SharedState takes ownership, control flow breaks out of the
    // block; the errdefers inside it never fire on the success path.
    const state = state: {
        const url_buf = try allocator.allocSentinel(u8, req.url.len, 0);
        errdefer allocator.free(url_buf);
        @memcpy(url_buf, req.url);

        const method_str = req.method.asString();
        const method_buf = try allocator.allocSentinel(u8, method_str.len, 0);
        errdefer allocator.free(method_buf);
        @memcpy(method_buf, method_str);

        // User-Agent — owned only if we end up sending one.
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
        var ua_buf_owned: ?[:0]u8 = null;
        if (ua_to_send.len > 0) {
            const ua = try allocator.allocSentinel(u8, ua_to_send.len, 0);
            errdefer allocator.free(ua);
            @memcpy(ua, ua_to_send);
            ua_buf_owned = ua;
        }

        // Heap-owned copies of every request header line. curl_slist_append
        // does NOT copy — it just links the pointer — so the lines must
        // be heap-owned and survive past openStream.
        var header_lines: std.ArrayList([:0]u8) = .empty;
        errdefer {
            for (header_lines.items) |line| allocator.free(line);
            header_lines.deinit(allocator);
        }
        for (req.headers) |h| {
            const total_len = h.name.len + 2 + h.value.len;
            const line = try allocator.allocSentinel(u8, total_len, 0);
            errdefer allocator.free(line);
            @memcpy(line[0..h.name.len], h.name);
            line[h.name.len] = ':';
            line[h.name.len + 1] = ' ';
            @memcpy(line[h.name.len + 2 ..][0..h.value.len], h.value);
            try header_lines.append(allocator, line);
        }

        // Build the slist from heap-owned lines. The slist's lifetime
        // is tied to the handle — libcurl reads its pointer chain
        // from the worker thread, and curl_easy_cleanup does NOT
        // free slists, so we own it.
        var slist: ?*curl.C.struct_curl_slist = null;
        errdefer if (slist) |s| curl.slist_free_all(s);
        for (header_lines.items) |line| {
            slist = curl.slist_append(slist, line);
        }

        // Add User-Agent as the first slist entry if we have one.
        if (ua_buf_owned) |ua| {
            slist = curl.slist_append(slist, ua);
        }

        const st = allocator.create(SharedState) catch return LocalError.InitFailed;
        errdefer allocator.destroy(st);

        // Transfer ownership: url_buf, method_buf, ua_buf_owned,
        // header_lines, slist all move into SharedState. The labeled
        // block exits via `break :state st` so the errdefers above
        // do NOT fire on the success path.
        st.* = .{
            .allocator = allocator,
            .handle = handle,
            .queue = .init(allocator, io),
            .primary_ip = .empty,
            .url_effective = .empty,
            .headers = .empty,
            .io = io,
            .url_buf = url_buf,
            .method_buf = method_buf,
            .ua_buf = ua_buf_owned,
            .header_lines = header_lines,
            .header_slist = slist,
        };
        break :state st;
    };
    handle_alive = false;

    // ERRORBUFFER backing is state.errbuf (heap, lifetime matches the
    // handle). libcurl holds this raw pointer and writes into it from
    // the worker thread, possibly AFTER this function returns.
    _ = setoptLong(handle, curl.OPT.ERRORBUFFER, @as(c_long, @intCast(@intFromPtr(&state.errbuf))));
    _ = setoptPtr(handle, curl.OPT.URL, state.url_buf.ptr);
    _ = setoptPtr(handle, curl.OPT.CUSTOMREQUEST, state.method_buf.ptr);
    _ = setoptSlist(handle, curl.OPT.HTTPHEADER, state.header_slist);

    if (req.body) |body| {
        // COPYPOSTFIELDS makes libcurl duplicate the body internally so we
        // don't borrow `req.body` (which the caller may free as soon as
        // openStream returns, while the worker thread is still running).
        // POSTFIELDSIZE_LARGE lets us pass the length without the body
        // needing to be NUL-terminated.
        _ = setoptPtr(handle, curl.OPT.COPYPOSTFIELDS, body.ptr);
        _ = setoptLong(handle, curl.OPT.POSTFIELDSIZE_LARGE, @as(c_long, @intCast(body.len)));
    }

    if (options.timeout_ms) |t| _ = setoptLong(handle, curl.OPT.TIMEOUT_MS, @as(c_long, t));
    if (options.connect_timeout_ms) |t| _ = setoptLong(handle, curl.OPT.CONNECTTIMEOUT_MS, @as(c_long, t));
    _ = setoptLong(handle, curl.OPT.FOLLOWLOCATION, if (options.follow_redirects) @as(c_long, 1) else @as(c_long, 0));
    if (options.follow_redirects) {
        _ = setoptLong(handle, curl.OPT.MAXREDIRS, @as(c_long, options.max_redirects));
    }
    _ = setoptLong(handle, curl.OPT.NOSIGNAL, @as(c_long, 1));
    _ = setoptLong(handle, curl.OPT.SSL_VERIFYPEER, if (options.verify_ssl) @as(c_long, 1) else @as(c_long, 0));
    _ = setoptLong(handle, curl.OPT.SSL_VERIFYHOST, if (options.verify_ssl) @as(c_long, 2) else @as(c_long, 0));

    _ = curl.easy_setopt_raw(handle, curl.OPT.WRITEFUNCTION, @as(curl.WriteCallback, @ptrCast(&writeCallback)));
    _ = curl.easy_setopt_raw(handle, curl.OPT.WRITEDATA, @as(*anyopaque, @ptrCast(state)));

    _ = curl.easy_setopt_raw(handle, curl.OPT.HEADERFUNCTION, @as(curl.HeaderCallback, @ptrCast(&headerCallback)));
    _ = curl.easy_setopt_raw(handle, curl.OPT.HEADERDATA, @as(*anyopaque, @ptrCast(state)));

    // Progress callback DISABLED (NOPROGRESS=1). The previous wiring
    // (XFERINFOFUNCTION reading &state.cancelled via userdata pointer)
    // caused intermittent segfaults at atomic-load addresses inside
    // libcurl — the XFERINFO callback fires from inside easy_perform
    // on the worker thread, and the pointer math through userdata
    // + @ptrCast landed on freed memory in some teardown paths.
    //
    // Cancellation now flows through `state.cancelled` being checked
    // inside writeCallback/headerCallback (which already touch
    // state.* and are guarded by the same lifetime), plus a hard
    // timeout via CURLOPT_TIMEOUT_MS / CURLOPT_CONNECTTIMEOUT_MS
    // (already set above from Options). For cooperative abort we
    // rely on the worker's poll loop reading `state.cancelled`
    // between chunk arrivals and bailing out cleanly.
    _ = setoptLong(handle, curl.OPT.NOPROGRESS, @as(c_long, 1));

    const thread = std.Thread.spawn(.{}, streamWorker, .{state}) catch |err| switch (err) {
        error.ThreadQuotaExceeded,
        error.LockedMemoryLimitExceeded,
        error.SystemResources,
        error.OutOfMemory,
        error.Unexpected => {
            state.deinit();
            allocator.destroy(state);
            return LocalError.InitFailed;
        },
    };

    return .{ .state = state, .thread = thread };
}
