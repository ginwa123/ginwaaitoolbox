// Functional e2e for the right-sidebar terminal HTTP endpoints.
//
// Zig port of `tests/functional/terminal_session_test.py` (same test
// names, same order).
//
// Covers the five REST endpoints backed by the in-memory PTY registry
// (src/http_handlers/terminal_*.zig — forkpty, no WebSocket, no
// migration, no kabelweb changes):
//
//   * POST   /api/terminal/sessions             {cwd, shell?, cols?, rows?}
//     -> 201 { id, pid }
//   * POST   /api/terminal/sessions/:id/input   {data}
//     -> 200 { ok, bytes } (410 once the shell has exited)
//   * GET    /api/terminal/sessions/:id/output?cursor=N
//     -> 200 { data, cursor, exited, exit_code }
//   * POST   /api/terminal/sessions/:id/resize  {cols, rows}
//     -> 200 { ok, cols, rows }
//   * DELETE /api/terminal/sessions/:id
//     -> 200 { ok } (second delete is 404)
//
// Wire rule: sessions use the harness tempdir as cwd and /bin/sh as the
// shell so the test is deterministic on any POSIX host. Output polling
// replays the frontend's 300ms poll loop with a hard deadline.
//
// ── PORTING NOTES ───────────────────────────────────────────────────────
// * `harness.harnessPath` replaces the literal `harness.temp_dir` and
//   the literal `/tmp/pabrik-terminal-never-exists-9d2c41`: the server
//   validates `cwd` with `std.fs.path.isAbsolute`, which is
//   platform-relative, so a hardcoded POSIX literal that is correct on
//   ubuntu-2022 fails at the HTTP door on windows-2022 and reads there
//   as a server regression that does not exist.
// * `harness.Json` BORROWS from the `Response` body it was parsed from,
//   so every helper here returns OWNED bytes (`OutputPage`) rather than
//   a `Json` — Python's dict-returning helpers got that for free.
// * `time.sleep` is `Io.sleep(io, .fromMilliseconds(n), .awake)`, and
//   `time.time()` deadlines are `Io.Timestamp.now(io, .awake)`.
// * Every JSON body goes through `std.json.Stringify`, so the `data`
//   field's trailing newline is escaped by the encoder instead of by a
//   hand-written `\\n` in a string literal.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// The shell every terminal in this suite runs. Python hardcoded
/// `/bin/sh`; `PATH_ABSOLUTE` is not portable to Windows, and the file's
/// contract is "deterministic on any POSIX host" — the PTY handlers
/// themselves are covered for the platform gates by `platform_gates_test`.
const SHELL = "/bin/sh";

/// Monotonic milliseconds (`.awake`, not the wall clock — an NTP step
/// must not extend a poll deadline).
fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// `"echo <marker>\n"` as an OWNED buffer.
///
/// Written with `allocPrint` rather than `"echo " ++ marker ++ "\n"`,
/// which only compiles for comptime-known operands — and a marker is
/// exactly the value a test wants to vary.
fn echoLine(marker: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "echo {s}\n", .{marker});
}

// ============================================================================
// Helpers
// ============================================================================

/// One `GET /api/terminal/sessions/<id>/output` answer, with every
/// string COPIED so it can outlive the `Response` it came from.
///
/// `exit_code` is null when the field is absent or JSON `null` — the
/// Python original read the same thing with `.get("exit_code")`.
const OutputPage = struct {
    data: []u8,
    cursor: i64,
    exited: bool,
    exit_code: ?i64,

    fn deinit(self: *OutputPage) void {
        gpa.free(self.data);
        self.* = undefined;
    }
};

/// `POST /api/terminal/sessions` with the Python `_create` body:
/// `{"shell": ...}` plus `"cwd"` only when `cwd` is non-null (so the
/// no-cwd call really sends no `cwd` key at all, like Python's
/// `if cwd is not None`).
///
/// `expect` is a parameter because the STATUS is the thing under test:
/// 201 for a good spawn, 400 for a relative cwd or a bodiless request,
/// 404 for a cwd that does not exist.
fn createRaw(
    h: *Harness,
    cwd: ?[]const u8,
    shell: []const u8,
    expect: []const u16,
) !harness.Response {
    const body = if (cwd) |c|
        try std.json.Stringify.valueAlloc(gpa, .{ .shell = shell, .cwd = c }, .{})
    else
        try std.json.Stringify.valueAlloc(gpa, .{ .shell = shell }, .{});
    defer gpa.free(body);

    return h.http(io, .POST, "/api/terminal/sessions", .{
        .json_body = body,
        .expect = expect,
    });
}

/// `POST /api/terminal/sessions` → the new terminal's id (owned).
fn create(h: *Harness, cwd: ?[]const u8) ![]u8 {
    var r = try createRaw(h, cwd, SHELL, &.{201});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("terminal create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    });
}

/// `POST /api/terminal/sessions/<id>/input {"data": ...}`.
fn inputRaw(
    h: *Harness,
    sid: []const u8,
    data: []const u8,
    expect: []const u16,
) !harness.Response {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .data = data }, .{});
    defer gpa.free(body);
    const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/input", .{sid});
    defer gpa.free(path);
    return h.http(io, .POST, path, .{ .json_body = body, .expect = expect });
}

/// `GET /api/terminal/sessions/<id>/output?cursor=N`.
///
/// The cursor goes through `.params`, which the harness
/// PERCENT-ENCODES — never pre-encode it here.
fn outputRaw(
    h: *Harness,
    sid: []const u8,
    cursor: i64,
    expect: []const u16,
) !harness.Response {
    const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/output", .{sid});
    defer gpa.free(path);
    var buf: [32]u8 = undefined;
    const cs = try std.fmt.bufPrint(&buf, "{d}", .{cursor});
    return h.http(io, .GET, path, .{
        .params = &.{.{ .name = "cursor", .value = cs }},
        .expect = expect,
    });
}

/// The 200 flavour of `outputRaw`, parsed into OWNED bytes.
fn outputPage(h: *Harness, sid: []const u8, cursor: i64) !OutputPage {
    var r = try outputRaw(h, sid, cursor, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const data: []const u8 = doc.str("data") orelse "";
    return .{
        .data = try gpa.dupe(u8, data),
        .cursor = doc.int("cursor") orelse cursor,
        .exited = doc.boolean("exited") orelse false,
        .exit_code = doc.int("exit_code"),
    };
}

/// Poll output until `marker` appears (the frontend poll replay).
///
/// Returns the page that satisfied the marker (owned). On timeout the
/// test FAILS with the accumulated transcript, exactly as Python raised
/// `AssertionError(marker ... never appeared; last=... seen=...)`.
fn pollFor(
    h: *Harness,
    sid: []const u8,
    marker: []const u8,
    deadline_ms: i64,
) !OutputPage {
    const deadline = nowMs() + deadline_ms;
    var cursor: i64 = 0;

    var seen: std.Io.Writer.Allocating = .init(gpa);
    defer seen.deinit();

    var last: ?OutputPage = null;
    defer if (last) |*p| p.deinit();

    while (nowMs() < deadline) {
        const page = try outputPage(h, sid, cursor);
        if (last) |*p| p.deinit();
        last = page;

        seen.writer.writeAll(page.data) catch return error.OutOfMemory;
        if (std.mem.indexOf(u8, seen.written(), marker) != null) break;
        if (page.exited) break;
        cursor = page.cursor;
        std.Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    }

    if (std.mem.indexOf(u8, seen.written(), marker) == null) {
        std.debug.print(
            "marker {s} never appeared for {s}; seen={s}\n",
            .{ marker, sid, seen.written() },
        );
        return error.TestUnexpectedResult;
    }
    const out = last orelse {
        std.debug.print("no output page was ever read for {s}\n", .{sid});
        return error.TestUnexpectedResult;
    };
    last = null;
    return out;
}

/// Poll forward until the session stops producing output; return the
/// cursor.
///
/// A PTY never really stops: after the marker round-trips, the shell
/// redraws its prompt and re-emits the command echo. So a cursor read
/// taken the instant the marker shows up can still be behind the
/// server's ring buffer, and the NEXT read at that cursor correctly
/// returns those not-yet-drained bytes — which looks exactly like a
/// replay. Draining until two consecutive reads come back empty is what
/// makes "no replay" a statement about the server rather than about how
/// fast the test asked.
fn settleCursor(
    h: *Harness,
    sid: []const u8,
    quiet_reads: u32,
    deadline_ms: i64,
) !i64 {
    const deadline = nowMs() + deadline_ms;
    var cursor: i64 = 0;
    var quiet: u32 = 0;
    while (nowMs() < deadline and quiet < quiet_reads) {
        var page = try outputPage(h, sid, cursor);
        defer page.deinit();
        cursor = page.cursor;
        if (page.data.len == 0) {
            quiet += 1;
        } else {
            quiet = 0;
            std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
        }
    }
    return cursor;
}

/// Python's `finally: harness.http("DELETE", ...)`.
fn deleteSession(h: *Harness, sid: []const u8) void {
    const path = std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}", .{sid}) catch return;
    defer gpa.free(path);
    var r = h.http(io, .DELETE, path, .{ .expect = &.{ 200, 404 } }) catch return;
    defer r.deinit();
}

// ============================================================================
// Tests
// ============================================================================

// Create -> echo a marker -> poll until it comes back -> cursor advances.
test "create_input_output_round_trip" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // `cwd` is derived from the harness tempdir: absolute on every
    // platform, and a directory that certainly exists.
    const cwd = try harness.harnessPath(gpa, h.temp_dir, &.{});
    defer gpa.free(cwd);

    var created = try createRaw(&h, cwd, SHELL, &.{201});
    defer created.deinit();
    const sid = blk: {
        var doc = try created.json();
        defer doc.deinit();
        const id = doc.str("id") orelse {
            std.debug.print("terminal create returned no id: {s}\n", .{created.body});
            return error.TestUnexpectedResult;
        };
        if (id.len == 0) {
            std.debug.print("terminal create returned an empty id\n", .{});
            return error.TestUnexpectedResult;
        }
        const pid = doc.int("pid") orelse {
            std.debug.print("terminal create returned no integer `pid`: {s}\n", .{created.body});
            return error.TestUnexpectedResult;
        };
        if (pid == 0) {
            std.debug.print("terminal create reported pid 0\n", .{});
            return error.TestUnexpectedResult;
        }
        break :blk try gpa.dupe(u8, id);
    };
    defer gpa.free(sid);
    defer deleteSession(&h, sid);

    const marker = "MARKER-9d2c41";
    {
        const line = try echoLine(marker);
        defer gpa.free(line);
        var r = try inputRaw(&h, sid, line, &.{200});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.boolean("ok") != true) {
            std.debug.print("input ack is not ok: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
        const bytes = doc.int("bytes") orelse 0;
        if (bytes <= 0) {
            std.debug.print("input ack reported {d} bytes: {s}\n", .{ bytes, r.body });
            return error.TestUnexpectedResult;
        }
    }

    {
        var page = try pollFor(&h, sid, marker, 20_000);
        defer page.deinit();
    }

    // Let the prompt redraw drain, then hold the cursor fixed: a repeat
    // read at a cursor the server has already served must come back
    // empty. Reading from a cursor taken by a DIFFERENT request (the old
    // `cursor=0` then `fresh["cursor"]` pair) is what raced — see
    // `settleCursor`.
    const settled = try settleCursor(&h, sid, 2, 10_000);
    if (settled <= 0) {
        std.debug.print("session produced no output at all\n", .{});
        return error.TestUnexpectedResult;
    }
    {
        var r = try outputRaw(&h, sid, settled, &.{200});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const data: []const u8 = doc.str("data") orelse "";
        if (data.len != 0) {
            std.debug.print(
                "re-reading from settled cursor {d} replayed \"{s}\"\n",
                .{ settled, data },
            );
            return error.TestUnexpectedResult;
        }
    }
}

// Resize round-trips dims; delete is 200 then 404; output 404s after.
test "resize_and_delete" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const cwd = try harness.harnessPath(gpa, h.temp_dir, &.{});
    defer gpa.free(cwd);
    const sid = try create(&h, cwd);
    defer gpa.free(sid);

    const resize_path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/resize", .{sid});
    defer gpa.free(resize_path);

    {
        const body =
            \\{"cols":100,"rows":40}
        ;
        var r = try h.http(io, .POST, resize_path, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqual(@as(i64, 100), doc.int("cols") orelse -1);
        try testing.expectEqual(@as(i64, 40), doc.int("rows") orelse -1);
    }

    // Bad dims are 400, not a resize.
    {
        const bad =
            \\{"cols":1,"rows":40}
        ;
        var r = try h.http(io, .POST, resize_path, .{ .json_body = bad, .expect = &.{400} });
        defer r.deinit();
    }

    {
        const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}", .{sid});
        defer gpa.free(path);
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.boolean("ok") != true) {
            std.debug.print("delete did not report ok: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
    {
        const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}", .{sid});
        defer gpa.free(path);
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{404} });
        defer r.deinit();
    }
    {
        var r = try outputRaw(&h, sid, 0, &.{404});
        defer r.deinit();
    }
    {
        var r = try inputRaw(&h, sid, "echo hi\n", &.{404});
        defer r.deinit();
    }
}

// Relative cwd is 400; cwd-that-is-a-file is 404; empty cwd falls back to
// the server cwd (201, not 400) so cwd-less chats work.
test "create_validation" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Relative cwd: the literal is the point of the assertion, and it is
    // relative on every platform.
    {
        var r = try createRaw(&h, "relative/path", SHELL, &.{400});
        defer r.deinit();
    }

    // Empty cwd falls back to the SERVER's cwd rather than 400ing.
    {
        var r = try createRaw(&h, "", SHELL, &.{201});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const id = doc.str("id") orelse {
            std.debug.print("empty-cwd create returned no id: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (id.len == 0) {
            std.debug.print("expected a session id from the empty-cwd create\n", .{});
            return error.TestUnexpectedResult;
        }
        const sid = try gpa.dupe(u8, id);
        defer gpa.free(sid);
        defer deleteSession(&h, sid);
    }

    // A cwd that does not exist is 404, not 201. Derived from the
    // tempdir so it is absolute on every platform.
    {
        const missing = try harness.harnessPath(gpa, h.temp_dir, &.{"pabrik-terminal-never-exists-9d2c41"});
        defer gpa.free(missing);
        var r = try createRaw(&h, missing, SHELL, &.{404});
        defer r.deinit();
    }

    // No body at all is a validation error, and the error body carries
    // an `error` key.
    {
        var r = try h.http(io, .POST, "/api/terminal/sessions", .{ .expect = &.{400} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.get("error") == null) {
            std.debug.print("bodiless create body has no `error`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
}

// All per-session endpoints 404 an unknown id (no traversal: the id is
// an opaque registry key, never a path).
test "unknown_session_is_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ghost = "term-does-not-exist";
    {
        var r = try outputRaw(&h, ghost, 0, &.{404});
        defer r.deinit();
    }
    {
        var r = try inputRaw(&h, ghost, "echo hi\n", &.{404});
        defer r.deinit();
    }
    {
        const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/resize", .{ghost});
        defer gpa.free(path);
        const body =
            \\{"cols":80,"rows":24}
        ;
        var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{404} });
        defer r.deinit();
    }
    {
        const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}", .{ghost});
        defer gpa.free(path);
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{404} });
        defer r.deinit();
    }
}

// A shell that exits cleanly reports exited + code 0, and further input
// is 410 (not 500).
//
// Uses the default /bin/sh and asks it to exit rather than spawning
// /bin/true as the "shell". /bin/true is not a shell and the PTY exec of
// it exits 127 on the macOS runners (every _exit(127) path in childMain
// is a chdir/exec failure), so the exit code this test asserts on was
// never produced by /bin/true there. /bin/sh is what every other test in
// this file already spawns successfully on all three platforms, and
// `exit` gives the same deterministic exit-0 the assertion needs.
test "input_after_exit_is_410" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const cwd = try harness.harnessPath(gpa, h.temp_dir, &.{});
    defer gpa.free(cwd);
    const sid = try create(&h, cwd);
    defer gpa.free(sid);
    defer deleteSession(&h, sid);

    {
        var r = try inputRaw(&h, sid, "exit\n", &.{200});
        defer r.deinit();
    }

    // Poll until `exited` flips, mirroring Python's `while ... deadline`.
    const deadline = nowMs() + 15_000;
    var cursor: i64 = 0;
    var exited = false;
    var exit_code: ?i64 = null;
    while (nowMs() < deadline) {
        var page = try outputPage(&h, sid, cursor);
        defer page.deinit();
        if (page.exited) {
            exited = true;
            exit_code = page.exit_code;
            break;
        }
        cursor = page.cursor;
        std.Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    }
    if (!exited) {
        std.debug.print("session {s} never exited within 15s\n", .{sid});
        return error.TestUnexpectedResult;
    }
    if (exit_code == null or exit_code.? != 0) {
        std.debug.print("expected exit code 0, got {?}\n", .{exit_code});
        return error.TestUnexpectedResult;
    }

    // Further input is 410 with an `error` key.
    {
        var r = try inputRaw(&h, sid, "echo hi\n", &.{410});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.get("error") == null) {
            std.debug.print("410 body has no `error`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
}

// Two sessions on the same server never see each other's bytes: a marker
// sent to A appears only in A's output and vice versa.
test "two_sessions_are_isolated" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const cwd = try harness.harnessPath(gpa, h.temp_dir, &.{});
    defer gpa.free(cwd);

    const id_a = try create(&h, cwd);
    defer gpa.free(id_a);
    const id_b = try create(&h, cwd);
    defer gpa.free(id_b);
    defer deleteSession(&h, id_a);
    defer deleteSession(&h, id_b);

    if (std.mem.eql(u8, id_a, id_b)) {
        std.debug.print("session ids must differ, both were \"{s}\"\n", .{id_a});
        return error.TestUnexpectedResult;
    }

    const marker_a = "ISOLATION-A-6c1e";
    const marker_b = "ISOLATION-B-9f4d";
    {
        const line = try echoLine(marker_a);
        defer gpa.free(line);
        var r = try inputRaw(&h, id_a, line, &.{200});
        defer r.deinit();
    }
    {
        const line = try echoLine(marker_b);
        defer gpa.free(line);
        var r = try inputRaw(&h, id_b, line, &.{200});
        defer r.deinit();
    }

    var out_a = try pollFor(&h, id_a, marker_a, 20_000);
    defer out_a.deinit();
    var out_b = try pollFor(&h, id_b, marker_b, 20_000);
    defer out_b.deinit();

    if (std.mem.indexOf(u8, out_a.data, marker_b) != null) {
        std.debug.print("B leaked into A: \"{s}\"\n", .{out_a.data});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, out_b.data, marker_a) != null) {
        std.debug.print("A leaked into B: \"{s}\"\n", .{out_b.data});
        return error.TestUnexpectedResult;
    }

    // Full-buffer check: replay from 0 still shows no cross-talk.
    {
        var full_a = try outputPage(&h, id_a, 0);
        defer full_a.deinit();
        if (std.mem.indexOf(u8, full_a.data, marker_b) != null) {
            std.debug.print("B leaked into A's full buffer: \"{s}\"\n", .{full_a.data});
            return error.TestUnexpectedResult;
        }
    }
    {
        var full_b = try outputPage(&h, id_b, 0);
        defer full_b.deinit();
        if (std.mem.indexOf(u8, full_b.data, marker_a) != null) {
            std.debug.print("A leaked into B's full buffer: \"{s}\"\n", .{full_b.data});
            return error.TestUnexpectedResult;
        }
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = nowMs;
    _ = echoLine;
    _ = OutputPage.deinit;
    _ = createRaw;
    _ = create;
    _ = inputRaw;
    _ = outputRaw;
    _ = outputPage;
    _ = pollFor;
    _ = settleCursor;
    _ = deleteSession;
}
