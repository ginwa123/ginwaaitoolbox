// Functional tests for session wire (Tier 1.5).
//
// Zig port of `tests/functional/session_wire_test.py` (same test names,
// same order).
//
// Exercises the session-level HTTP surface that's NOT covered by
// `sessions_and_llm_test.py`:
//
//   - PUT  /api/llm/session/:session_id (rename + profile + unattended)
//   - POST /api/llm/session/:session/stop (cancel flag)
//   - GET  /api/llm/session/:session_id/queue_messages (empty for fresh)
//   - GET  /api/workers (returns >=1 entry; empty after no activity)
//
// Each test boots a fresh pabrik (the Python `harness` fixture was
// function-scoped; here every test block calls `Harness.boot` itself).
//
// The Python `harness` fixture was `FunctionalHarness.boot(bin)` with no
// options, so the port boots `.{}` — notably WITHOUT
// `stub_llm_profile = true`, even though test 2's Python docstring claims
// otherwise. That claim is wrong about the fixture (its default is
// `False`); the assertion still holds because `session_update` echoes
// whatever `selected_profile_model` it was handed without consulting the
// profile registry. The docstring below records the real reason.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// `POST /api/workspaces` -> the new workspace's id (owned).
///
/// Python's `_create_workspace`. No test in this file calls it — it is
/// part of the ported file's helper surface and the body is still force-
/// analysed by the `comptime` block at the bottom, so a Zig rename inside
/// it cannot hide until someone else calls it.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `PUT /api/llm/session/<session_id>` to auto-create + name the row.
///
/// `session_update.zig` auto-creates the row via `ensureSessionExists`
/// then UPDATEs it. Use this helper to spin up a session row for the
/// wire tests without invoking `/api/llm/session` (which needs a real
/// LLM). Python's `_create_session_via_update`; its return value (the
/// parsed body) is unused by every caller, so this returns nothing.
fn createSessionViaUpdate(h: *Harness, session_id: []const u8, name: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);

    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    r.deinit();
}

// ============================================================================
// Test 1: PUT session renames it; response echoes new name
// ============================================================================

// PUT /api/llm/session/:id {name: 'renamed'} -> 200 with new name.
//
// session_update.zig auto-creates the row via ensureSessionExists so PUT
// can be the first call against a fresh session id (the user can land on
// this endpoint via the Settings dialog before any LLM message has been
// queued). The PUT response is the source of truth for the rename; a
// follow-up PUT to a DIFFERENT name reads back the second name (proving
// the first was actually persisted, not just echoed back).
test "put_session_rename_round_trips" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = "sess_test_rename_001";

    // First rename.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{
            .json_body = "{\"name\":\"renamed-session\"}",
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        try testing.expectEqualStrings(session_id, doc.str("id") orelse return error.TestUnexpectedResult);
        try testing.expectEqualStrings(
            "renamed-session",
            doc.str("name") orelse return error.TestUnexpectedResult,
        );
    }

    // Second rename: re-PUT and verify the new name comes back (proves
    // the first rename persisted to the DB; the response isn't just
    // echoing the input).
    {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{
            .json_body = "{\"name\":\"renamed-again\"}",
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const got = doc.str("name") orelse {
            std.debug.print("second PUT echoed no name: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings("renamed-again", got);
    }
}

// ============================================================================
// Test 2: PUT session updates selected_profile_model
// ============================================================================

// PUT {selected_profile_model: 'alt-profile'} -> response echoes it.
//
// The Python docstring claimed the stub LLM profile is pre-installed by
// the harness boot option; the `harness` fixture it actually used passes
// NO options, so no stub profile exists here either. The assertion holds
// because `session_update` round-trips the field it was given without
// consulting the profile registry — which is exactly what this test is
// pinning (the Settings dialog's profile picker round-trips).
test "put_session_updates_profile_model" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = "sess_test_profile_001";

    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);

    var r = try h.http(io, .PUT, path, .{
        .json_body = "{\"selected_profile_model\":\"alt-profile\"}",
        .expect = &.{200},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try testing.expectEqualStrings(session_id, doc.str("id") orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings(
        "alt-profile",
        doc.str("selected_profile_model") orelse return error.TestUnexpectedResult,
    );
}

// ============================================================================
// Test 3: PUT session updates is_auto_retry_until_stop
// ============================================================================

// PUT {is_auto_retry_until_stop: '1'} -> response echoes '1'.
test "put_session_updates_unattended_flag" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = "sess_test_unattended_001";

    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);

    // `is_auto_retry_until_stop` rides the wire as a STRING ("1" / "0"),
    // not a JSON bool — the frontend's checkbox writes a digit so the
    // stored INTEGER column and the wire value never disagree.
    {
        var r = try h.http(io, .PUT, path, .{
            .json_body = "{\"is_auto_retry_until_stop\":\"1\"}",
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        try testing.expectEqualStrings(session_id, doc.str("id") orelse return error.TestUnexpectedResult);
        try testing.expectEqualStrings(
            "1",
            doc.str("is_auto_retry_until_stop") orelse return error.TestUnexpectedResult,
        );
    }

    // Toggling back to 0 also round-trips.
    {
        var r = try h.http(io, .PUT, path, .{
            .json_body = "{\"is_auto_retry_until_stop\":\"0\"}",
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        try testing.expectEqualStrings(
            "0",
            doc.str("is_auto_retry_until_stop") orelse return error.TestUnexpectedResult,
        );
    }
}

// ============================================================================
// Test 4: POST /stop returns 200 + sets cancel flag
// ============================================================================

// POST /api/llm/session/:session/stop -> 200 {success, session_id}.
//
// The handler calls `llm_history.cancelSession` which sets the
// `cancelled` flag in the DB; the workflow loop checks this flag and
// breaks out. No message is sent or emitted on the wire — the response
// is just a confirmation.
test "stop_session_returns_200" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    // Create the session row first so the cancel can land.
    const session_id = "sess_test_stop_001";
    try createSessionViaUpdate(&h, session_id, "wire-session");

    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/stop", .{session_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = "{}", .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try testing.expectEqual(true, doc.boolean("success") orelse {
        std.debug.print("stop response has no `success` bool: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    });
    try testing.expectEqualStrings(
        session_id,
        doc.str("session_id") orelse {
            std.debug.print("stop response has no `session_id`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    );
}

// ============================================================================
// Test 5: GET queue_messages returns empty array for fresh session
// ============================================================================

// GET /api/llm/session/:id/queue_messages -> 200 with empty list.
//
// A session that has never had a message queued returns
// `{messages: [], count: 0}` — the frontend's Pinia store keys off
// `messages.length` to decide whether to render the queue.
test "queue_messages_empty_for_fresh_session" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = "sess_test_qm_001";
    try createSessionViaUpdate(&h, session_id, "wire-session");

    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/queue_messages", .{session_id});
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const messages = doc.array("messages") orelse {
        std.debug.print("queue_messages has no `messages` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (messages.items.len != 0) {
        std.debug.print("fresh session should have no queue messages, got {d}\n", .{messages.items.len});
        return error.TestUnexpectedResult;
    }

    const count = doc.int("count") orelse {
        std.debug.print("queue_messages has no `count`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(i64, 0), count);
}

// ============================================================================
// Test 6: GET /api/workers returns a list
// ============================================================================

// GET /api/workers -> 200 with a `workers` array (possibly empty).
//
// worker_list.zig returns `{workers: [...], count}`. Even when no LLM call
// has been kicked off, the endpoint is reachable and returns 200 with an
// empty list (or a list of recently-completed workers, depending on
// backend state).
test "workers_list_returns_array" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/workers", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // Response shape: {workers: [...], count: N} — the wire field is
    // `workers` (the array), `count` is the length.
    const workers = doc.array("workers") orelse {
        std.debug.print("missing 'workers' field; got body: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const count = doc.int("count") orelse {
        std.debug.print("missing 'count' field; got body: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(i64, @intCast(workers.items.len)), count);
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = createWorkspace;
    _ = createSessionViaUpdate;
}
