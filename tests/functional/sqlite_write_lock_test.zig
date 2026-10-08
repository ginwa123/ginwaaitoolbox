// Functional test: the SQLite connection policy, and the fate of the
// endpoint the original contention test wrote through.
//
// Zig port of `tests/functional/sqlite_write_lock_test.py`
// (test names drop the `test_` prefix; test 1 is renamed — see below).
//
// Cases:
//   1. `log_post_is_disabled_while_get_stays_read_only` — POST /api/logs
//      is 404 (disabled) while GET /api/logs stays 200.
//   2. `boot_logs_the_connection_pragma_policy` — the boot log shows the
//      live connection's `journal_mode=wal`, `busy_timeout=15000ms` and
//      `synchronous=2` (FULL) policy.
//
// ── WHY TEST 1 IS NOT THE PYTHON TEST 1 ─────────────────────────────
// The Python test held WAL's single writer slot from a SECOND connection
// (`BEGIN IMMEDIATE` + 6.5 s sleep, past the old 5 s `busy_timeout`) and
// then proved the server's write waited instead of failing with
// `500 {"error": "Failed to persist log"}`.
//
// Neither half survives on current main. This package deliberately has no
// SQLite driver (so a suite can never "pass" without crossing the wire),
// which already ruled out the second connection — and PR #839 then
// disabled the endpoint the test wrote through (`POST /api/logs` is now
// 404; the desktop log client spammed it). A port asserting 204 would pin
// a route that no longer exists, against a binary that correctly refuses
// it. What the port pins instead is the disabled contract itself: POST is
// 404 and GET stays a read-only 200, so a future re-registration (or a
// second disabling) fails loudly here rather than silently. The contention
// wait itself is covered by `src/boot/db_config.zig` unit tests
// (`busy_timeout_ms = 15_000`, `PRAGMA synchronous == 2`).
//
// The boot-log pragma test ports verbatim: it only ever read the wire
// (`GET /health`) and the process log.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const LOG_MESSAGE = "functional-sqlite-write-lock-probe";

// POST /api/logs is DISABLED (#839): the desktop log client spammed it,
// so the route is unregistered and POST is 404. GET stays as a read-only
// debug endpoint. This pins that contract: a re-registration without
// updating this suite (or a second disabling that also takes GET) goes red.
test "log_post_is_disabled_while_get_stays_read_only" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        const body =
            "{\"events\":[{\"level\":\"error\",\"kind\":\"console_error\"," ++
            "\"message\":\"" ++ LOG_MESSAGE ++ "\"," ++
            "\"stack\":\"at <anonymous> (probe.js:1:1)\"," ++
            "\"source\":\"http://127.0.0.1/app.js\",\"line\":1," ++
            "\"route_path\":\"/chats/probe\",\"session_id\":\"probe-session\"}]}";
        var r = try h.http(io, .POST, "/api/logs", .{
            .json_body = body,
            .expect = &.{404},
        });
        defer r.deinit();
        try testing.expectEqual(@as(u16, 404), r.status);
    }

    {
        const params = [1]Harness.Param{.{ .name = "limit", .value = "200" }};
        var r = try h.http(io, .GET, "/api/logs", .{
            .params = &params,
            .expect = &.{200},
            .timeout_s = 20.0,
        });
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }
}

// The live connection's settings are visible in the boot log.
test "boot_logs_the_connection_pragma_policy" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var r = try h.http(io, .GET, "/health", .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqualStrings("ok", doc.str("status") orelse "");
    }

    const log = try h.tailLog(io, gpa, 400);
    defer gpa.free(log);
    if (std.mem.indexOf(u8, log, "journal_mode=wal") == null) {
        std.debug.print("no sqlite pragma line in boot log:\n{s}\n", .{log});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, log, "busy_timeout=15000ms") == null) {
        std.debug.print("busy_timeout not the configured value:\n{s}\n", .{log});
        return error.TestUnexpectedResult;
    }
    // `synchronous=FULL` (2), not WAL's usual NORMAL (1): `src/boot/db_config.zig`
    // pays one fsync per commit so a returned success survives a power cut.
    // The Python original pinned `synchronous=1`; main moved to FULL after it
    // was written (`db_config.best.synchronous = .full`, unit-pinned as
    // `PRAGMA synchronous == 2`), so the port follows the live policy.
    const sync_ok = std.mem.indexOf(u8, log, "synchronous=2 ") != null or
        std.mem.endsWith(u8, std.mem.trimEnd(u8, log, "\r\n"), "synchronous=2");
    if (!sync_ok) {
        std.debug.print("the app did not opt into synchronous=FULL:\n{s}\n", .{log});
        return error.TestUnexpectedResult;
    }
}
