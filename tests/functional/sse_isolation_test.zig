// Functional tests for per-user SSE channel isolation (plan 2026-09-25, W3).
//
// Zig port of `tests/functional/sse_isolation_test.py` (same test names,
// same order).
//
// Python docstring, preserved verbatim:
//
//   """Functional tests for per-user SSE channel isolation (plan
//   2026-09-25, W3).
//
//   Boots a REAL pabrik binary + REAL SQLite via the harness (never a live dev
//   server, never port 8081). Two authenticated admins share ONE database and
//   BOTH open `/api/events?channels=sessions,workers`, so this is the wire-level
//   proof that user A's live events never reach user B's EventSource.
//
//   Why a wire test and not only a unit test: the leak lives in the fan-out loop
//   of `unified_events_sse.zig` — the bus broadcasts by *family routing key*
//   (`sessions`, `workers`, `llm`, …), so every connected client receives every
//   user's events. A unit test that calls the filter directly cannot catch a
//   handler that forgets to record the client's owner at connect time, nor a
//   fan-out that skips the filter. Only a real two-cookie round-trip exercises
//   cookie -> auth_sessions -> users.id -> client registry -> fan-out.
//
//   Covers:
//     * SESSIONS-CHANNEL — A renames its session; B's stream must see ZERO frames
//                          mentioning A's session id, while A's own stream does.
//     * OWN-EVENTS       — B still receives its OWN session events (guards against
//                          an "everyone gets nothing" false pass).
//     * AUTH-OFF-REGRESS — without `--auth` the same rename still reaches a
//                          connected client (byte-identical legacy behaviour).
//
//   Both users are created with `create-admin`, so the isolation assertions here
//   are also the admin-vs-admin assertions: `admin` grants NO cross-user
//   visibility (user decision 2026-09-25).
//   """
//
// ── WHY THE SSE READER ACCUMULATES RAW BYTES ─────────────────────────────
// The Python `SseReader` is a raw socket that pumps bytes into a
// `bytearray` and every assertion is a SUBSTRING test on that buffer
// (`sess_a not in stream_b.text()`). That is deliberately weaker than
// frame parsing: the leak is "A's session id appears anywhere in B's
// byte stream", and a payload-level filter cannot scrub the id while
// still delivering the frame. So the port keeps the shape — read raw
// bytes into a growing buffer on a reader thread, poll it from the test
// thread — rather than borrowing `sse_auth_test.zig`'s event parser,
// which would answer a different (easier) question.
//
// `Harness.http` cannot do this at all: it calls
// `reader.streamRemaining(...)`, which blocks until the server closes
// the connection, and a healthy SSE stream never closes. Hence
// `std.http.Client` directly, the idiom `sse_auth_test.zig` established.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

// ============================================================================
// Raw HTTP (cookie jars are just strings here)
// ============================================================================

/// Issue a request WITHOUT a status assertion — the caller asserts.
///
/// The harness's `Harness.http` asserts on `expect` by default, and the
/// STATUS ITSELF is the assertion in this suite's helpers (`assert status
/// == 200`, `== 201`). The harness's `{ .assert_status = false }` flag
/// exists for exactly that, so no suite needs a private HTTP client.
fn rawHttp(
    h: *Harness,
    method: harness.HttpMethod,
    path: []const u8,
    body: ?[]const u8,
    cookie: ?[]const u8,
) !harness.Response {
    var extra: [1]harness.Header = undefined;
    const n: usize = if (cookie) |c| blk: {
        extra[0] = .{ .name = "Cookie", .value = c };
        break :blk 1;
    } else 0;
    return h.http(io, method, path, .{
        .json_body = body,
        .extra_headers = extra[0..n],
        .assert_status = false,
    });
}

/// Boot a harness with `--auth` (the gate is opt-in).
fn bootAuth() !Harness {
    return Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
}

/// Run `pabrik create-admin` against the harness HOME.
///
/// `runPabrikCommand` prepends the resolved binary itself, so `argv`
/// starts at the SUBCOMMAND — passing the binary again would make the
/// subcommand dispatch miss (it matches argv[1]) and boot a SERVER,
/// which then tries to bind the default port.
fn createAdmin(home: []const u8, email: []const u8, password: []const u8, force: bool) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "create-admin", "--email", email, "--password", password });
    if (force) try argv.append(gpa, "--force");

    var r = try harness.runPabrikCommand(io, gpa, home, argv.items, 30_000);
    defer r.deinit(gpa);
    if (r.exit_code == null or r.exit_code.? != 0) {
        std.debug.print("create-admin failed (rc={?}): {s}\n", .{ r.exit_code, r.stderr });
        return error.TestUnexpectedResult;
    }
}

/// Log in and return the raw session token (Python `_login`).
fn login(h: *Harness, email: []const u8, password: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"email\":\"{s}\",\"password\":\"{s}\"}}",
        .{ email, password },
    );
    defer gpa.free(body);

    var r = try rawHttp(h, .POST, "/api/auth/login", body, null);
    defer r.deinit();
    if (r.status != 200) {
        std.debug.print("login failed (status={d}): {s}\n", .{ r.status, r.body });
        return error.TestUnexpectedResult;
    }
    const set_cookie = r.header("Set-Cookie") orelse "";
    if (std.mem.indexOf(u8, set_cookie, "pabrik_session=") == null) {
        std.debug.print("login sent no pabrik_session cookie: {s}\n", .{set_cookie});
        return error.TestUnexpectedResult;
    }
    // `split("pabrik_session=", 1)[1].split(";", 1)[0].strip()`: the
    // token is the text BETWEEN the name and the next `;`. The
    // harness's `afterFirst` returns the text AFTER a delimiter, which
    // here would be the attribute list (`Path=/; HttpOnly`) — the
    // wrong direction, hence the manual split.
    var attrs = std.mem.splitSequence(u8, set_cookie, ";");
    const first_attr = attrs.next() orelse return error.TestUnexpectedResult;
    const raw_token = harness.afterFirst(first_attr, "pabrik_session=") orelse
        return error.TestUnexpectedResult;
    return gpa.dupe(u8, std.mem.trim(u8, raw_token, " \t\r\n"));
}

/// Create a session with an EXPLICIT id (Python `_create_session`).
///
/// The auto-generated id is timestamp-based (`sess_<unix>_<rand>`), so
/// two creates in the same second can collide — and a colliding second
/// create is an `INSERT OR IGNORE` no-op on the first user's row, which
/// then 404s for the second user. Explicit ids keep the two users'
/// sessions distinct.
fn createSession(h: *Harness, cookie: ?[]const u8, session_id: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"session_id\":\"{s}\"}}", .{session_id});
    defer gpa.free(body);

    var r = try rawHttp(h, .POST, "/api/session", body, cookie);
    defer r.deinit();
    if (r.status != 201) {
        std.debug.print("session create failed (status={d}): {s}\n", .{ r.status, r.body });
        return error.TestUnexpectedResult;
    }
    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse return error.TestUnexpectedResult;
    return gpa.dupe(u8, id);
}

/// Rename a session, waiting for its row to exist (Python
/// `_rename_session`).
///
/// `POST /api/session` returns before the row is INSERTed: the insert
/// runs in the concurrent `emit_run_agent` task (`root.zig` ::
/// `insert_worker`). The `:session_id` middleware choke point 404s a
/// not-yet-existing row, so a rename issued immediately after create
/// can race the insert. Retry until the row lands (bounded), then
/// require the rename to have succeeded.
fn renameSession(h: *Harness, session_id: []const u8, name: []const u8, cookie: ?[]const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/session/{s}", .{session_id});
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);

    const deadline = nowMs() + 10_000;
    var last_status: u16 = 0;
    // Owned from the FIRST failure onward, so there is exactly one owner
    // at every point. Seeding it with a string LITERAL and freeing it
    // unconditionally would hand a comptime slice to `gpa.free`.
    var last_body: ?[]u8 = null;
    defer if (last_body) |b| gpa.free(b);
    while (nowMs() < deadline) {
        var r = try rawHttp(h, .PUT, path, body, cookie);
        defer r.deinit();
        if (r.status == 200) return;
        if (last_body) |b| gpa.free(b);
        last_body = try gpa.dupe(u8, r.body);
        last_status = r.status;
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    }
    std.debug.print("rename never succeeded: {d} {s}\n", .{ last_status, last_body orelse "" });
    return error.TestUnexpectedResult;
}

/// Monotonic milliseconds (`.awake` = monotonic, not wall clock).
fn nowMs() i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

// ============================================================================
// SSE reader
// ============================================================================

/// Transfer buffer for the response body reader.
///
/// NOT `&.{}`: `Response.reader(transfer_buffer)` uses that slice as
/// the reader's own buffer, and a short buffer turns every heartbeat
/// into `error.StreamTooLong`. 8 KiB is generous for an SSE frame.
const transfer_buffer_len = 8 * 1024;

/// An open SSE connection that pumps raw bytes into a growing buffer.
///
/// Heap-allocated, not returned by value: `std.http.Client` embeds a
/// `ConnectionPool` with an `Io.Mutex` and `Response.request` points
/// back at the request, so the trio is UNCOPYABLE.
const RawSse = struct {
    client: std.http.Client,
    req: std.http.Client.Request,
    /// The transfer buffer `body` reads out of. Owned here so its
    /// address outlives every read.
    transfer_buffer: [transfer_buffer_len]u8 = undefined,
    /// `req.reader` after `resp.reader(&transfer_buffer)`.
    body: *std.Io.Reader = undefined,
    status: u16 = 0,
    /// Set by the test thread to release the reader.
    stop: std.atomic.Value(bool) = .init(false),
    /// Set by the reader thread once it has stopped touching `buf`.
    done: std.atomic.Value(bool) = .init(false),
    /// `buf` is guarded by `mutex`: the reader thread appends while the
    /// test thread polls, and an unsynchronised read during the
    /// append is a use-after-free.
    mutex: Io.Mutex = .init,
    buf: std.ArrayList(u8) = .empty,

    fn deinit(self: *RawSse) void {
        self.req.deinit();
        self.client.deinit();
        self.buf.deinit(gpa);
        gpa.destroy(self);
    }

    /// A PRINTABLE rendering of the bytes received so far. Owned by the
    /// caller.
    ///
    /// Only ever used for failure messages, and only in this form: the
    /// raw buffer can hold non-UTF-8 bytes (a tool payload pasted into an
    /// event), and `{s}` on invalid UTF-8 trips a debug assertion in the
    /// test runner. Python sidestepped it with
    /// `bytes.decode("utf-8", errors="replace")`; here every byte >= 0x80
    /// becomes a `\xNN` escape instead, which keeps the output ASCII and
    /// lossless. Assertions NEVER go through this function — they run
    /// `waitFor` against the raw buffer, so a needle is matched against
    /// the bytes the server actually sent.
    fn text(self: *RawSse) ![]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        for (self.buf.items) |c| {
            if (c < 0x80) {
                out.writer.writeByte(c) catch return error.OutOfMemory;
            } else {
                out.writer.print("\\x{x:0>2}", .{c}) catch return error.OutOfMemory;
            }
        }
        return out.toOwnedSlice();
    }

    /// Wait until `needle` appears in the stream. False on timeout.
    ///
    /// Infallible on purpose: it only READS `buf` under the mutex and
    /// allocates nothing, so a `try` at the call site could add no
    /// information — but it would turn an OOM into a leaked reader
    /// thread (its stack is DebugAllocator memory, so the NEXT test
    /// would report the leak instead of this one).
    fn waitFor(self: *RawSse, needle: []const u8, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            // Snapshot under the lock, then RELEASE it before
            // sleeping: holding the mutex across the sleep starves the
            // reader, which needs the same lock to append.
            self.mutex.lockUncancelable(io);
            const found = std.mem.indexOf(u8, self.buf.items, needle) != null;
            self.mutex.unlock(io);
            if (found) return true;
            if (nowMs() >= deadline) return false;
            std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
        }
    }
};

/// Open `GET /api/events?channels=<channels>` and start pumping. The
/// caller owns the returned pointer and must `deinit` it.
fn openSse(port: u16, channels: []const u8, cookie: ?[]const u8) !*RawSse {
    const s = try gpa.create(RawSse);
    errdefer gpa.destroy(s);
    // `gpa.create` returns UNINITIALIZED memory — it does NOT run the
    // struct's field default initializers. `s.* = .{}` applies all of
    // them in one shot; an uninitialised `Io.Mutex` is not a lock at
    // all.
    s.* = .{ .client = .{ .allocator = gpa, .io = io }, .req = undefined };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/api/events?channels={s}", .{ port, channels });
    defer gpa.free(url);

    // `extra_headers` borrows the array for the duration of the
    // request, so it must stay alive until `receiveHead` returns.
    var extra: [2]std.http.Header = undefined;
    extra[0] = .{ .name = "Accept", .value = "text/event-stream" };
    const header_count: usize = if (cookie) |c| blk: {
        extra[1] = .{ .name = "Cookie", .value = c };
        break :blk extra.len;
    } else 1;

    s.req = s.client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .extra_headers = extra[0..header_count],
    }) catch |err| {
        s.client.deinit();
        return err;
    };
    errdefer {
        s.req.deinit();
        s.client.deinit();
    }

    try s.req.sendBodiless();
    var resp = try s.req.receiveHead(&.{});
    s.status = @intFromEnum(resp.head.status);
    s.body = resp.reader(&s.transfer_buffer);
    return s;
}

/// Pump `s`'s body into `s.buf` until the stream ends. Runs on its own
/// thread.
fn pump(s: *RawSse) void {
    defer s.done.store(true, .release);

    while (!s.stop.load(.acquire)) {
        // `fill(1)` + `buffered()` + `toss()`, NOT `readSliceShort`.
        //
        // `readSliceShort` goes through the reader's `readVec` vtable
        // slot, and an HTTP body reader installed by
        // `std.http.Reader.bodyReader` supplies only `stream` and
        // `discard` — there is no `readVec`, and the read fails with a
        // bare `error.ReadFailed` (with `body_err == null`, so the
        // cause is not even recoverable). `fill` drives the `stream`
        // slot, which every reader implements, and it is the same path
        // `takeDelimiter` uses — so this is the idiom
        // `sse_auth_test.zig` and the stub servers already rely on.
        s.body.fill(1) catch return; // EOF or a read error: the stream is over

        s.mutex.lockUncancelable(io);
        const n = s.body.buffered().len;
        const appended = s.buf.appendSlice(gpa, s.body.buffered());
        s.mutex.unlock(io);
        // `toss` AFTER the copy: the slice `buffered()` returned is a
        // view into the reader's transfer buffer, and advancing first
        // would invalidate it.
        s.body.toss(n);
        appended catch return;
    }
}

/// Spawn the reader thread. Caller owns the returned `std.Thread` and
/// MUST join it.
///
/// `releaseReader` must precede `join`: a stream the server holds open
/// parks the reader in `readv` forever, and `join` on a parked thread
/// deadlocks the suite.
fn startPump(s: *RawSse) !std.Thread {
    return std.Thread.spawn(.{}, pump, .{s});
}

/// Release a blocked pump by shutting the socket's read side.
fn releaseReader(s: *RawSse) void {
    s.stop.store(true, .release);
    s.req.connection.?.stream_reader.stream.shutdown(io, .recv) catch {};
}

/// An open stream plus the thread reading it, torn down together.
///
/// Python's `try/finally { stream_a.close(); stream_b.close() }` is
/// the ONE teardown path for the pair, and Zig has no `finally` — so
/// this pair of defers is what keeps an early `return` from leaking a
/// thread and a socket.
const Stream = struct {
    s: *RawSse,
    thread: std.Thread,

    fn deinit(self: *Stream) void {
        releaseReader(self.s);
        self.thread.join();
        self.s.deinit();
    }
};

/// `_open_stream(...)`: connect, then wait for the `connected`
/// handshake.
fn openStream(port: u16, cookie: ?[]const u8) !Stream {
    const s = try openSse(port, "sessions,workers", cookie);
    // No `errdefer s.deinit()`: the handshake-failure path below already
    // tears the stream down explicitly, and an `errdefer` would fire a
    // SECOND time on that `return` — a double `deinit` of the client,
    // the reader and the buffer.
    const t = startPump(s) catch |err| {
        s.deinit();
        return err;
    };
    if (!s.waitFor("event: connected", 10_000)) {
        releaseReader(s);
        t.join();
        const got = try s.text();
        defer gpa.free(got);
        const status = s.status;
        s.deinit();
        std.debug.print("SSE stream never emitted the `connected` handshake; status={d} got({d})={s}\n", .{ status, got.len, got });
        return error.TestUnexpectedResult;
    }
    return .{ .s = s, .thread = t };
}

/// Two authenticated admins in the SAME database, plus their tokens.
const TwoUsers = struct {
    h: Harness,
    tok_a: []u8,
    tok_b: []u8,

    fn deinit(self: *TwoUsers) void {
        gpa.free(self.tok_a);
        gpa.free(self.tok_b);
        self.h.deinit(io) catch |err| {
            std.debug.print("teardown: {s}\n", .{@errorName(err)});
        };
    }

    /// `Cookie: pabrik_session=<token>`.
    fn cookieA(self: *TwoUsers) ![]u8 {
        return std.fmt.allocPrint(gpa, "pabrik_session={s}", .{self.tok_a});
    }

    fn cookieB(self: *TwoUsers) ![]u8 {
        return std.fmt.allocPrint(gpa, "pabrik_session={s}", .{self.tok_b});
    }
};

fn twoUsers() !TwoUsers {
    var h = try bootAuth();
    errdefer h.deinit(io) catch {};
    try createAdmin(h.temp_dir, "a@example.com", "supersecret123", false);
    try createAdmin(h.temp_dir, "b@example.com", "supersecret123", true);
    const tok_a = try login(&h, "a@example.com", "supersecret123");
    errdefer gpa.free(tok_a);
    const tok_b = try login(&h, "b@example.com", "supersecret123");
    return .{ .h = h, .tok_a = tok_a, .tok_b = tok_b };
}

// ============================================================================
// tests
// ============================================================================

// A's session rename must never reach B's EventSource.
//
// This is the W3 leak: the bus fans out by family routing key, so
// before the fix B's `?channels=sessions` stream received A's
// `session_updated` frame verbatim. The assertion is on A's session id
// appearing anywhere in B's stream — the payload carries `id`, so a
// leak is unmistakable.
test "sse_does_not_deliver_foreign_session_events" {
    try harness.requirePabrikBin(io, gpa);

    var tu = try twoUsers();
    defer tu.deinit();

    const cookie_a = try tu.cookieA();
    defer gpa.free(cookie_a);
    const cookie_b = try tu.cookieB();
    defer gpa.free(cookie_b);

    const sess_a = try createSession(&tu.h, cookie_a, "sess_iso_a_1");
    defer gpa.free(sess_a);
    // Python bound `sess_b` and never read it either; here the OWNED
    // copy must be freed, or the test leaks on the passing path.
    const sess_b_unused = try createSession(&tu.h, cookie_b, "sess_iso_b_1");
    defer gpa.free(sess_b_unused);

    var stream_a = try openStream(tu.h.port, cookie_a);
    defer stream_a.deinit();
    var stream_b = try openStream(tu.h.port, cookie_b);
    defer stream_b.deinit();

    // A renames its own session — this emits `session_updated` on the
    // `sessions` routing key with A's session id in the payload.
    try renameSession(&tu.h, sess_a, "A renamed this", cookie_a);

    // A's own stream must receive it (proves the event was actually
    // published, so B's silence is isolation and not a dead bus).
    if (!stream_a.s.waitFor(sess_a, 10_000)) {
        const tail = try stream_a.s.text();
        defer gpa.free(tail);
        std.debug.print(
            "A's own stream never received its session event — the event was " ++
                "not published, so this test cannot prove isolation.\nA stream tail:\n{s}\n",
            .{tail},
        );
        return error.TestUnexpectedResult;
    }

    // B must receive ZERO frames mentioning A's session id.
    std.Io.sleep(io, .fromMilliseconds(1000), .awake) catch {};
    const b_text = try stream_b.s.text();
    defer gpa.free(b_text);
    if (std.mem.indexOf(u8, b_text, sess_a) != null) {
        std.debug.print("LEAK: B's SSE stream received A's session event.\nB stream tail:\n{s}\n", .{b_text});
        return error.TestUnexpectedResult;
    }
}

// Both users receive their OWN session events — no over-filtering.
//
// Guards the false pass where the filter drops everything: B must
// still see B's rename, and A must still see A's.
test "sse_still_delivers_own_events_to_each_user" {
    try harness.requirePabrikBin(io, gpa);

    var tu = try twoUsers();
    defer tu.deinit();

    const cookie_a = try tu.cookieA();
    defer gpa.free(cookie_a);
    const cookie_b = try tu.cookieB();
    defer gpa.free(cookie_b);

    const sess_a = try createSession(&tu.h, cookie_a, "sess_iso_a_2");
    defer gpa.free(sess_a);
    const sess_b = try createSession(&tu.h, cookie_b, "sess_iso_b_2");
    defer gpa.free(sess_b);

    var stream_a = try openStream(tu.h.port, cookie_a);
    defer stream_a.deinit();
    var stream_b = try openStream(tu.h.port, cookie_b);
    defer stream_b.deinit();

    try renameSession(&tu.h, sess_a, "A own rename", cookie_a);
    try renameSession(&tu.h, sess_b, "B own rename", cookie_b);

    if (!stream_a.s.waitFor(sess_a, 10_000)) {
        std.debug.print("A must receive its own session event\n", .{});
        return error.TestUnexpectedResult;
    }
    if (!stream_b.s.waitFor(sess_b, 10_000)) {
        std.debug.print("B must receive its own session event\n", .{});
        return error.TestUnexpectedResult;
    }

    // And neither sees the other's.
    std.Io.sleep(io, .fromMilliseconds(500), .awake) catch {};
    {
        const a_text = try stream_a.s.text();
        defer gpa.free(a_text);
        if (std.mem.indexOf(u8, a_text, sess_b) != null) {
            std.debug.print("A received B's session event\n", .{});
            return error.TestUnexpectedResult;
        }
    }
    {
        const b_text = try stream_b.s.text();
        defer gpa.free(b_text);
        if (std.mem.indexOf(u8, b_text, sess_a) != null) {
            std.debug.print("B received A's session event\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

// Regression: without `--auth` the stream still delivers session events.
//
// With auth off there is no identity, so the system user sees
// everything and the fan-out filter must be a no-op — the
// pre-isolation behaviour.
test "sse_auth_off_still_delivers_events" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sess = try createSession(&h, null, "sess_iso_noauth");
    defer gpa.free(sess);

    var stream = try openStream(h.port, null);
    defer stream.deinit();

    try renameSession(&h, sess, "no-auth rename", null);

    if (!stream.s.waitFor(sess, 10_000)) {
        const tail = try stream.s.text();
        defer gpa.free(tail);
        std.debug.print("auth-off stream must still receive session events\nstream tail:\n{s}\n", .{tail});
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = rawHttp;
    _ = bootAuth;
    _ = createAdmin;
    _ = login;
    _ = createSession;
    _ = renameSession;
    _ = nowMs;
    _ = openSse;
    _ = pump;
    _ = startPump;
    _ = releaseReader;
    _ = openStream;
    _ = twoUsers;
    _ = TwoUsers.deinit;
    _ = TwoUsers.cookieA;
    _ = TwoUsers.cookieB;
    _ = RawSse.deinit;
    _ = RawSse.text;
    _ = RawSse.waitFor;
    _ = Stream.deinit;
    _ = Harness.boot;
}
