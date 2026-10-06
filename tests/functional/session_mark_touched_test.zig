// `POST /api/llm/session/:id/touched` — mark-as-seen clears the amber stale dot.
//
// Zig port of `tests/functional/session_mark_touched_test.py`
// (same test names).
//
// Replays the exact wire the sidebar sends on click:
//   POST /api/llm/session/:session_id/touched  body {}
//
// Cases (in the Python file's order):
//   1. `touched` returns 200 {success:true} and stamps the column.
//   2. GET list shows `last_human_touched_at` as a SQLite datetime so the
//      dot clears: `updated_at <= last_human_touched_at`.
//   3. Dual-route parity: `POST /api/session/:id/touched` also 200.
//
// The Python docstring's case 3 ("empty session_id -> 400") has no test
// of its own: an empty path segment cannot match the route, so the file
// folded it into case 4, the dual-alias parity check. That mapping is
// preserved here — there are three tests, not four.
//
// ── WHY `_db_val` IS NOT A RAW SQLITE READ ──────────────────────────────
// The Python `_db_val` helper opened `<temp_dir>/.config/pabrik/agent.db`
// with the stdlib `sqlite3` module (read-only URI) and asserted
// `last_human_touched_at_nano IS NOT NULL` for the session row.
//
// `sessionLastHumanTouchedAt` below replaces that with the wire's own
// view of the SAME column, and it is an equivalent witness rather than a
// weaker one: `src/http_handlers/session_list.zig` builds the list row as
//
//     CASE WHEN last_human_touched_at_nano IS NULL THEN ''
//          ELSE strftime('%Y-%m-%d %H:%M:%S', last_human_touched_at_nano/1000, 'unixepoch') END
//
// so a NON-EMPTY `last_human_touched_at` on `GET /api/llm/session` is
// reachable only when the column is non-NULL in SQLite — the assertion
// still fails if the UPDATE never landed.
//
// TODO(port): a raw-DB witness needs an SQLite driver, which this package
// deliberately does not have. `tests/functional/build.zig` declares NO
// dependency on `pabrikcore` and links no SQLite precisely so a suite can
// never "pass" without crossing the wire; adding `sqlite3` here (or
// shelling out to a `sqlite3` CLI that is absent on the windows-2022
// runner image) would break that property. If a real DB-level assertion
// is ever wanted, the honest home is `tests/sqlite_test.py`'s Zig
// successor or a `harness.zig` helper added with that intent — not a
// per-suite dependency.
//
// NOTE ON STRING ORDERING: case 2 compares two timestamps as STRINGS
// (`updated > human` in Python). Both are `YYYY-MM-DD HH:MM:SS`, so
// byte-wise comparison is chronological; `std.mem.order` reproduces
// Python's comparison exactly.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// `sessionLastHumanTouchedAt`'s replacement for the Python `_db_val`:
/// read `GET /api/llm/session`, find the one entry whose `session_id`
/// matches, and return its `last_human_touched_at` wire field — `""`
/// when the column is NULL. Fails when the entry is missing or
/// ambiguous, exactly like Python's `assert len(matches) == 1`.
///
/// The returned slice borrows from `doc`, which the caller must keep
/// alive.
fn sessionLastHumanTouchedAt(doc: *const harness.Json, session_id: []const u8) ![]const u8 {
    const entry = findSessionInList(doc, session_id) catch |err| {
        std.debug.print("expected 1 match for {s}: {s}\n", .{ session_id, @errorName(err) });
        return err;
    };
    return jsonStringField(entry, "last_human_touched_at");
}

/// The single `sessions[]` entry with `session_id == id`.
///
/// Borrows from `doc`.
fn findSessionInList(doc: *const harness.Json, id: []const u8) !std.json.Value {
    const sessions = doc.array("sessions") orelse return error.TestUnexpectedResult;

    var found: ?std.json.Value = null;
    for (sessions.items) |item| {
        const sid = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const n = switch (sid.get("session_id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, n, id)) continue;
        if (found != null) return error.TestUnexpectedResult; // ambiguous
        found = item;
    }
    return found orelse error.TestUnexpectedResult;
}

/// Python's `entry.get(key) or ""` — missing key, JSON `null`, or a
/// non-string all collapse to `""`.
fn jsonStringField(value: std.json.Value, key: []const u8) []const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return "",
    };
    return switch (obj.get(key) orelse return "") {
        .string => |s| s,
        else => return "",
    };
}

/// `PUT {base}/session/:id` — the auto-creating write the Python tests
/// used to make the row exist. `base` is `"/api/llm"` or `"/api"`; the
/// two spellings are the dual routes under test, so the helper takes the
/// prefix whole rather than an "llm or empty" flag (an empty prefix
/// would build `/api//session/...`, which does not match either route).
fn ensureSession(h: *Harness, base: []const u8, sid: []const u8, name: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/session/{s}", .{ base, sid });
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);
    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

/// `POST {base}/session/:id/touched` with the sidebar's empty body.
/// Returns the parsed response body.
fn postTouched(h: *Harness, base: []const u8, sid: []const u8) !harness.Json {
    const path = try std.fmt.allocPrint(gpa, "{s}/session/{s}/touched", .{ base, sid });
    defer gpa.free(path);
    var r = try h.http(io, .POST, path, .{ .json_body = "{}", .expect = &.{200} });
    defer r.deinit();
    return r.json();
}

// ============================================================================
// Tests
// ============================================================================

// `touched` answers 200 {success:true, session_id:<id>} and the column
// is no longer NULL.
test "touched_stamps_column" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = "sess_touch_1";
    try ensureSession(&h, "/api/llm", sid, "touch me");

    var body = try postTouched(&h, "/api/llm", sid);
    defer body.deinit();

    if (body.boolean("success") != true) {
        std.debug.print("touched did not report success\n", .{});
        return error.TestUnexpectedResult;
    }
    const echoed = body.str("session_id") orelse {
        std.debug.print("touched response has no session_id\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(sid, echoed);

    // The column must be non-NULL. See the file header: the list
    // endpoint's `last_human_touched_at` is a CASE over the very column,
    // so a non-empty value IS the non-NULL reading.
    var list = try h.http(io, .GET, "/api/llm/session", .{ .expect = &.{200} });
    defer list.deinit();
    var ldoc = try list.json();
    defer ldoc.deinit();

    const stamped = try sessionLastHumanTouchedAt(&ldoc, sid);
    if (stamped.len == 0) {
        std.debug.print("sessions.last_human_touched_at_nano is still NULL for {s}\n", .{sid});
        return error.TestUnexpectedResult;
    }
}

// After a touch the amber dot clears: the wire field is populated and
// `updated_at` is no longer strictly greater than it.
test "touched_clears_stale_dot" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = "sess_touch_2";
    try ensureSession(&h, "/api/llm", sid, "dot clear");
    {
        var body = try postTouched(&h, "/api/llm", sid);
        body.deinit();
    }

    var r = try h.http(io, .GET, "/api/llm/session", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const entry = try findSessionInList(&doc, sid);
    const human = jsonStringField(entry, "last_human_touched_at");
    const updated = jsonStringField(entry, "updated_at");

    if (human.len == 0) {
        std.debug.print("touched must populate the last_human_touched_at wire field\n", .{});
        return error.TestUnexpectedResult;
    }

    // The dot condition is `updated_at > last_human_touched_at`; after a
    // touch, `human` is the later stamp so the dot clears. Python:
    // `assert not (updated > human)`.
    if (std.mem.order(u8, updated, human) == .gt) {
        std.debug.print(
            "dot should clear: updated_at={s} last_human_touched_at={s}\n",
            .{ updated, human },
        );
        return error.TestUnexpectedResult;
    }
}

// The `/api/session/:id` alias behaves identically to `/api/llm/session/:id`.
test "touched_dual_route_parity" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = "sess_touch_3";
    try ensureSession(&h, "/api", sid, "parity");

    var body = try postTouched(&h, "/api", sid);
    defer body.deinit();
    if (body.boolean("success") != true) {
        std.debug.print("dual-route touched did not report success\n", .{});
        return error.TestUnexpectedResult;
    }

    var list = try h.http(io, .GET, "/api/llm/session", .{ .expect = &.{200} });
    defer list.deinit();
    var ldoc = try list.json();
    defer ldoc.deinit();

    const stamped = try sessionLastHumanTouchedAt(&ldoc, sid);
    if (stamped.len == 0) {
        std.debug.print("dual-route touched left sessions.last_human_touched_at_nano NULL\n", .{});
        return error.TestUnexpectedResult;
    }
}
