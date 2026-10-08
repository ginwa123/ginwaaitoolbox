// Functional tests for the /api/logs write path — now the DISABLED path.
//
// History: this suite was the POST /api/logs dedup suite (Migration 075
// regression: the dedup SELECT referenced the pre-075 `created_at` column,
// so every POST failed with 500 "Failed to dedup log"). PR #839 then
// DISABLED the route entirely (`http_routes.zig` unregisters
// `POST /api/logs`; the desktop log client spammed it on every
// console.error/warn) while keeping `GET /api/logs` as a read-only debug
// endpoint. The three 204-asserting tests below went red with that change —
// correctly, because the feature they pinned no longer exists on the wire.
//
// What this file pins now:
//   * `post_api_logs_is_disabled` — the EXACT frontend batch (same bytes
//     the old EXACT-FRONTEND-BODY test sent) is 404, not 204 and not 500.
//     A re-registration without updating this suite goes red here.
//   * `get_api_logs_stays_read_only` — GET stays 200 with a `logs` list
//     (empty on a fresh boot). A second disabling that also takes GET
//     goes red here.
//
// If POST is ever re-enabled, restore the dedup assertions from git
// history (this file at the #839 parent) rather than extending these.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// The exact batch shape from the failing DevTools screenshot: a
/// console_error for a kanban prefetch failure, enriched with the
/// current route_path by frontendLogClient. Still sent verbatim — now to
/// prove the route is gone (404) even for the real payload.
const KANBAN_FETCH_ERROR_BATCH =
    \\{"events":[{"level":"error","kind":"console_error","message":"Failed to fetch kanban tasks for item item_178785157619947723","route_path":"app?view=workspace&workspaceId=ws_1785055733544_28e79c9db8950100&itemId=item_1788811112791088699"}]}
;

/// `GET /api/logs?limit=100`, expecting the `{logs: [...]}` envelope.
fn getLogs(h: *Harness) !harness.Response {
    // The query string rides in `path`, not in `HttpOptions.params` —
    // `Harness.http` appends `path` to `http://127.0.0.1:<port>`
    // verbatim, so these are byte-identical request lines.
    return h.http(io, .GET, "/api/logs?limit=100", .{ .expect = &.{200} });
}

// POST /api/logs is DISABLED (#839): the route is unregistered, so even
// the exact frontend batch is 404 — not 204, and not a 500 from the old
// dedup path.
test "post_api_logs_is_disabled" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var post = try h.http(io, .POST, "/api/logs", .{
        .json_body = KANBAN_FETCH_ERROR_BATCH,
        .expect = &.{404},
    });
    defer post.deinit();
    try testing.expectEqual(@as(u16, 404), post.status);
}

// GET /api/logs stays as a read-only debug endpoint: 200 with a `logs`
// list, empty on a fresh boot.
test "get_api_logs_stays_read_only" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try getLogs(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const logs = doc.array("logs") orelse {
        std.debug.print("GET /api/logs should return a logs list, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 0), logs.items.len);
}
