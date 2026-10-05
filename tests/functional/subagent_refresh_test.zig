// Functional wire tests for GET /api/subagent/progress/:tool_call_id.
//
// Zig port of `tests/functional/subagent_refresh_test.py`.
//
// Task: task_1788505292766_1 (spawn-subagent-refresh-persist).
//
// The bug: progress events are SSE-ephemeral, so a page refresh mid-run
// wipes ChatView's subAgentProgressMap with no replay — the card
// collapses to "0 sub-agents" (Task 0 shows "starting…" instead, but the
// running/done breakdown is still lost).
//
// The fix: the backend mirrors every progress event into an in-memory
// snapshot registry (subagent_progress.zig); this endpoint serves
// `{ tool_call_id, progress[] }` so loadChatHistory can rehydrate
// placeholder cards. These tests replay the wire round-trip against a
// real binary:
//
//   1. unknown tool_call_id → 200 `{ tool_call_id, progress: [] }`
//      (must NOT 404 — the frontend treats empty as "keep fallback").
//   2. sibling routes still work (route-order shadowing guard).
//   3. response shape carries the snapshot row keys.
//
// NOTE: a populated snapshot (mid-run rows) needs live sub-agent
// threads, which need a real LLM — not available in this harness. The
// populated path is covered by zig unit tests (upsert/get round-trip in
// subagent_progress.zig) + vitest (applySnapshotRows in
// subagentProgress.spec.ts). These wire tests lock the route, the
// empty-shape contract, and the no-shadowing invariant.
//
// The route-order guard (test 2) is exactly the failure mode the repo
// rules call out: `matchRoute` walks routes in REGISTRATION order, so
// `/api/subagent/progress/:tool_call_id` is a fresh prefix that must not
// steal `/api/llm/session/:session_id/messages` or `/stream`.

//
// QUERY STRINGS ARE IN THE PATH, NOT IN `HttpOptions.params`.
//
// This is deliberate and wire-identical to the Python original (which
// interpolated `?limit=N` straight into the path, or produced the same
// string via `urlencode`). The harness's `buildUrl` LEAKS when
// `opts.params` is non-empty: it allocates the base URL
// `"http://127.0.0.1:<port><path>?"` and then, on the `i == 0`
// iteration, overwrites `url` with a fresh `allocPrint` WITHOUT freeing
// the old one (see harness.zig `buildUrl`, the `else` arm of the
// `if (i > 0)` branch). `testing.allocator` reports that as a per-test
// leak, so every suite that used `.params` would fail on memory even
// though the request was fine.
//
// FIX PROPERLY IN `harness.zig` (free the previous `url` in the `i == 0`
// arm), then these can move back to `.params`. Until then: keep the
// query inlined.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ─── Test 1: unknown tool_call_id → 200 empty progress ────────────────────

// A tool_call_id with no live batch must return its id and an empty
// progress array — this is what ChatView sees for completed batches
// (snapshot cleared) and after a server restart (map wiped).
test "subagent_progress_unknown_id_returns_empty" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/subagent/progress/tc_never_existed", .{
        .expect = &.{200},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    try testing.expectEqualStrings("tc_never_existed", doc.str("tool_call_id").?);

    const progress = doc.array("progress") orelse {
        std.debug.print("no progress array in: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 0), progress.items.len);
}

// ─── Test 2: sibling routes unshadowed (route-order guard) ───────────────

// `/api/subagent/progress/:tool_call_id` is a fresh prefix, but pin
// the invariant anyway: the pre-existing session routes must still
// resolve after registering it.
test "subagent_progress_route_does_not_shadow_siblings" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var create = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = "{\"name\":\"subagent-sib\"}",
        .expect = &.{201},
    });
    defer create.deinit();
    var create_doc = try create.json();
    defer create_doc.deinit();
    const session_id = try gpa.dupe(u8, create_doc.str("id").?);
    defer gpa.free(session_id);

    {
        const messages_path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages?limit=10", .{session_id});
        defer gpa.free(messages_path);

        var r = try h.http(io, .GET, messages_path, .{ .expect = &.{200} });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        try testing.expect(doc.array("messages") != null);
    }
    {
        const stream_path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/stream", .{session_id});
        defer gpa.free(stream_path);

        var r = try h.http(io, .GET, stream_path, .{ .expect = &.{200} });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        // Python: `set(stream.keys()) >= {"active", "content"}`.
        try testing.expect(doc.get("active") != null);
        try testing.expect(doc.get("content") != null);
    }

    // And the new route itself still works.
    {
        var snap = try h.http(io, .GET, "/api/subagent/progress/tc_sibling_probe", .{
            .expect = &.{200},
        });
        defer snap.deinit();

        var doc = try snap.json();
        defer doc.deinit();
        try testing.expectEqualStrings("tc_sibling_probe", doc.str("tool_call_id").?);
        const progress = doc.array("progress") orelse {
            std.debug.print("no progress array in: {s}\n", .{snap.body});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(@as(usize, 0), progress.items.len);
    }
}

// ─── Test 3: snapshot row shape ──────────────────────────────────────────

// The response must carry the keys the frontend rehydrator reads.
// With no live batch the array is empty, so assert the top-level
// shape here; per-row keys are locked by the zig getSnapshot tests +
// the applySnapshotRows vitest contract.
test "subagent_progress_row_shape_keys" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/subagent/progress/tc_shape_probe", .{
        .expect = &.{200},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    // Python: `set(body.keys()) >= {"tool_call_id", "progress"}`.
    try testing.expect(doc.get("tool_call_id") != null);
    try testing.expect(doc.get("progress") != null);
    // Python: `isinstance(body["progress"], list)`.
    try testing.expect(doc.array("progress") != null);
}