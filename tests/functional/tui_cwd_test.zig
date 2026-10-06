// Functional tests for pabrik-tui cwd fix.
//
// Zig port of `tests/functional/tui_cwd_test.py` (same test names, same
// order).
//
// Regression for "theres a mismatch cwd, when using pabrik-tui"
// (task_1788360732549_2). The TUI was hardcoding cwd_session="" so the
// backend fell back to createSandbox → ~/.local/share/pabrik/data/apps/<session_id>
// (empty). The agent then listed the sandbox instead of the shell's cwd.
//
// Contract:
//   POST /api/llm/session with cwd_session="/tmp/my-proj" → sessions.cwd == "/tmp/my-proj"
//   POST /api/llm/session with cwd_session="" → sessions.cwd is the sandbox path
//
// WHY THE PERSISTED COLUMN IS READ OVER THE WIRE
// ----------------------------------------------
// The Python file opened `<temp_dir>/.config/pabrik/agent.db` with the
// stdlib `sqlite3` module and ran `SELECT cwd FROM sessions WHERE id = ?`.
// This package deliberately declares NO dependency on `pabrikcore` and
// links no SQLite (see `build.zig`), precisely so a functional suite can
// never "pass" without crossing the wire. So `readSessionCwd` below uses
// `GET /api/llm/session/:id` instead.
//
// That is an equivalent witness, not a weaker one. `session_get.zig`
// builds its response from `llm_history.getSession`, whose SQL is
//
//     SELECT s.id, s.name, s.status, COALESCE(s.cwd, ''), ...
//     FROM sessions s WHERE s.id = ?
//
// so the `cwd` field on the wire IS `sessions.cwd`, read through the
// same row the Python query read. A non-empty value is reachable only
// when the column is non-empty, which is the assertion.
//
// TODO(port): the Python `_wait_for_worker` helper polled
// `GET /api/workers/<id>` until 200. There is no such route — the server
// registers `GET /api/workers` (the LIST) and nothing under it — and no
// test in the Python file called the helper, so it asserted nothing. It
// is deliberately not ported; a per-session worker endpoint would be
// the missing capability.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// How long `_wait_for_session_cwd` polled before giving up.
const poll_timeout_ms: i64 = 5_000;
/// Python's `time.sleep(0.05)` between polls.
const poll_interval_ms: i64 = 50;

/// Monotonic milliseconds (`.awake`, not the wall clock — an NTP step
/// must not extend the deadline).
fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// One `GET /api/llm/session/<id>` answer.
///
/// `exists` false means the row is not there yet — 404, which is the
/// EXPECTED answer while the worker has not inserted it, not a failure.
/// When `exists` is true, `cwd` is an OWNED copy (empty when the column
/// is empty) the caller must `gpa.free`.
const SessionCwd = struct {
    exists: bool,
    cwd: []u8,
};

/// Read `sessions.cwd` over the wire. See the file header for why this
/// is the wire and not a SQLite read.
///
/// WHY AN OWNED COPY RATHER THAN A BORROWED SLICE
/// `harness.Json` parses into an arena owned by the `Json`, and
/// `doc.str(..)` returns a pointer INTO that arena. Returning such a
/// slice out of this function is a use-after-free by construction: the
/// `defer doc.deinit()` runs on return, before the caller can dupe it.
/// The first version of this file did exactly that and the run died in
/// `gpa.dupe`'s `memcpy` with a segmentation fault, one frame below
/// the real cause.
fn readSessionCwd(h: *Harness, session_id: []const u8) !SessionCwd {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);

    // `assert_status = false`: the 404 is data here, so it must not go
    // through the harness's status assertion.
    var r = try h.http(io, .GET, path, .{
        .expect = &.{ 200, 404 },
        .assert_status = false,
    });
    defer r.deinit();

    if (r.status != 200) return .{ .exists = false, .cwd = gpa.dupe(u8, "") catch return error.OutOfMemory };

    var doc = try r.json();
    defer doc.deinit();
    const cwd = doc.str("cwd") orelse "";
    return .{
        .exists = true,
        .cwd = gpa.dupe(u8, cwd) catch return error.OutOfMemory,
    };
}

/// Poll `readSessionCwd` until the row appears, or the deadline passes.
/// Returns an OWNED cwd (the caller frees), or null when the row never
/// appeared.
fn waitForSessionCwd(h: *Harness, session_id: []const u8) !?[]u8 {
    const deadline = nowMs() + poll_timeout_ms;
    while (nowMs() < deadline) {
        const got = try readSessionCwd(h, session_id);
        // Every branch owns `got.cwd`; a not-found answer carries an
        // empty placeholder that has to be released too, or a 5-second
        // poll leaks one buffer per 50ms iteration.
        if (got.exists) return got.cwd;
        gpa.free(got.cwd);
        std.Io.sleep(io, .fromMilliseconds(poll_interval_ms), .awake) catch {};
    }
    return null;
}

/// The exact JSON body the TUI's `transport.buildSendBody` produces
/// (see `src/apps/cli/src/tui/transport.zig`) — `POST /api/llm/session`
/// with every field the desktop client also sends.
///
/// Built with `std.json.Stringify` rather than `allocPrint` because
/// `cwd_session` is a filesystem path: on Windows it carries backslashes
/// and a drive letter, and the third test deliberately puts SPACES in
/// it. Hand-formatting would need a second escaping layer, and getting
/// that wrong fails at the HTTP door for a reason that has nothing to
/// do with the cwd contract.
fn sendBody(gpa_: std.mem.Allocator, session_id: []const u8, message: []const u8, cwd_session: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa_, .{
        .session_id = session_id,
        .queue_message = message,
        .cwd_session = cwd_session,
        .allowed_tools = "all",
        .image_urls = "",
        .selected_profile_model = "",
        .is_auto_retry_until_stop = "",
    }, .{});
}

/// The cwd the TUI would report for `<temp_dir>/my-proj`.
///
/// `os.path.realpath` in Python resolves the EXISTING prefix of a path
/// whose leaf does not exist, then appends the leaf verbatim. The Zig
/// spelling does the same thing explicitly: `canonical` the tempdir (it
/// exists), then join. `harness.canonical` cannot be used for the joined
/// path because `Io.Dir.realPathFile` fails `FileNotFound` on a
/// non-existent leaf — which is why the realpath is taken one level up.
///
/// Realpath matters for the same reason the TUI applies it: on macOS
/// `/tmp` is a symlink to `/private/tmp`, so a literal would send a
/// string no real TUI would ever send.
fn tuiCwdUnderTemp(h: *Harness, leaf: []const u8) ![]u8 {
    const real_temp = try harness.canonical(io, gpa, h.temp_dir);
    defer gpa.free(real_temp);
    return std.fs.path.join(gpa, &.{ real_temp, leaf });
}

// POST with cwd_session='/tmp/my-proj' → sessions.cwd == that path.
//
// This is what pabrik-tui now does: it captures the shell's cwd via
// realPath and sends it as cwd_session. The backend's session_create
// useCase must honor it (`effective_cwd = cwd_session` when non-empty).
// We check `sessions.cwd` (persisted) rather than the worker, which is
// ephemeral — the worker is torn down when the stub LLM fails.
test "tui_cwd_reaches_backend_as_working_directory" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "tui-cwd-test-001";
    const cwd = try tuiCwdUnderTemp(&h, "my-proj");
    defer gpa.free(cwd);

    const body = try sendBody(gpa, session_id, "hello from tui", cwd);
    defer gpa.free(body);
    {
        // Python: `expect=(201, 500)` — the worker runs in the
        // background, so a 500 here is still a healthy boot with a
        // turn that failed, which the poll below reports on.
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = body,
            .expect = &.{ 201, 500 },
        });
        defer r.deinit();
    }

    const got = (try waitForSessionCwd(&h, session_id)) orelse {
        std.debug.print(
            "sessions row for '{s}' never appeared within {d}s\n",
            .{ session_id, poll_timeout_ms / 1000 },
        );
        return error.TestUnexpectedResult;
    };
    defer gpa.free(got);

    if (!std.mem.eql(u8, got, cwd)) {
        std.debug.print(
            "sessions.cwd must equal the cwd_session sent by TUI. " ++
                "Expected '{s}', got '{s}'. If got is a sandbox path, " ++
                "transport.buildSendBody is still hardcoding \"\".\n",
            .{ cwd, got },
        );
        return error.TestUnexpectedResult;
    }
}

// POST with cwd_session='' → sessions.cwd is the sandbox path.
//
// Empty cwd is the sentinel for "no override" — the backend falls back
// to createSandbox → ~/.local/share/pabrik/data/apps/<session_id>. This
// preserves backward compat for callers that intentionally want the
// sandbox.
test "tui_empty_cwd_falls_back_to_sandbox" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "tui-cwd-test-002";

    const body = try sendBody(gpa, session_id, "hello with empty cwd", "");
    defer gpa.free(body);
    {
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = body,
            .expect = &.{ 201, 500 },
        });
        defer r.deinit();
    }

    const got = (try waitForSessionCwd(&h, session_id)) orelse {
        std.debug.print(
            "sessions row for '{s}' never appeared within {d}s\n",
            .{ session_id, poll_timeout_ms / 1000 },
        );
        return error.TestUnexpectedResult;
    };
    defer gpa.free(got);

    // Windows joins the sandbox with backslashes
    // (C:\...\pabrik-func-XXX\.local\share\pabrik\data\apps\<session>);
    // POSIX uses forward slashes. Normalize before asserting so the
    // same contract holds on both.
    const normalized = try gpa.dupe(u8, got);
    defer gpa.free(normalized);
    for (normalized) |*c| {
        if (c.* == '\\') c.* = '/';
    }

    const sandbox_ok = std.mem.indexOf(u8, normalized, ".local/share/pabrik/data/apps") != null;
    const tmp_ok = std.mem.indexOf(u8, normalized, "/tmp") != null;
    if (!sandbox_ok and !tmp_ok) {
        std.debug.print(
            "empty cwd_session should fall back to sandbox (or /tmp). Got '{s}'\n",
            .{got},
        );
        return error.TestUnexpectedResult;
    }

    // Must NOT be the explicit cwd the sibling test sends. Each test
    // gets a FRESH harness with its own tempdir, so this comparison is
    // only meaningful against the path derived from THIS test's
    // tempdir — comparing against a module constant would pass for the
    // wrong reason.
    const explicit = try tuiCwdUnderTemp(&h, "my-proj");
    defer gpa.free(explicit);
    if (std.mem.eql(u8, got, explicit)) {
        std.debug.print("empty cwd should not equal explicit cwd, got '{s}'\n", .{got});
        return error.TestUnexpectedResult;
    }
}

// cwd with spaces and quotes must survive JSON escaping.
//
// transport.buildSendBody now uses encodeJsonString for cwd, so paths
// like '/tmp/my project' or '/tmp/a\"b' must round-trip.
test "tui_cwd_with_special_chars_round_trips" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "tui-cwd-test-003";
    const cwd = try tuiCwdUnderTemp(&h, "my project with spaces");
    defer gpa.free(cwd);

    const body = try sendBody(gpa, session_id, "hello", cwd);
    defer gpa.free(body);
    {
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = body,
            .expect = &.{ 201, 500 },
        });
        defer r.deinit();
    }

    const got = (try waitForSessionCwd(&h, session_id)) orelse {
        std.debug.print("sessions row for '{s}' never appeared\n", .{session_id});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(got);

    if (!std.mem.eql(u8, got, cwd)) {
        std.debug.print(
            "cwd with spaces must round-trip. Expected '{s}', got '{s}'\n",
            .{ cwd, got },
        );
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced function is never type-checked,
// so a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = readSessionCwd;
    _ = waitForSessionCwd;
    _ = sendBody;
    _ = tuiCwdUnderTemp;
    _ = nowMs;
}
