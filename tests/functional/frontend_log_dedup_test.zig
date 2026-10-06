// Functional tests for POST /api/logs dedup (Migration 075 regression).
//
// Zig port of `tests/functional/frontend_log_dedup_test.py` (same test
// names, same order).
//
// Replays the EXACT JSON batch the frontend `frontendLogClient.ts`
// sends when a `console.error` fires (see the DevTools screenshot in
// task_1789917534485_4: `{"events":[{level, kind, message, route_path}]}`).
//
// Regression (2026-09-20): Migration 075 renamed `logs.created_at` →
// `logs.created_at_nano`. The POST handler's INSERT and the GET
// handler were updated, but the POST dedup SELECT still referenced
// `created_at` → every POST failed at the dedup step with
// 500 `{"error":"Failed to dedup log"}` ("no such column:
// created_at" on a production DB that has run all migrations).
//
// Unit tests missed it because their `:memory:` helper only ran
// Migration 064 (which creates the OLD column name), so the stale
// SQL passed in tests while failing in production. The in-file Zig
// tests now mirror the 075 rename; these functional tests lock the
// wire behaviour end-to-end against a real binary + real SQLite.
//
// Covers:
//   * EXACT-FRONTEND-BODY — the screenshot's batch → 204, no 500.
//   * DEDUP-HIT — immediate re-POST of the same batch → 204 and the
//     row's `count` becomes 2 (no second row).
//   * FRESH-EVENT — a different message → 204 and a second row.
//
// The Python original used a `harness` fixture (one booted binary per
// test); Zig has no fixtures, so each test boots its own harness —
// the same isolation, spelled out.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// The exact batch shape from the failing DevTools screenshot: a
/// console_error for a kanban prefetch failure, enriched with the
/// current route_path by frontendLogClient.
const KANBAN_FETCH_ERROR_BATCH =
    \\{"events":[{"level":"error","kind":"console_error","message":"Failed to fetch kanban tasks for item item_178785157619947723","route_path":"app?view=workspace&workspaceId=ws_1785055733544_28e79c9db8950100&itemId=item_1788811112791088699"}]}
;

/// The message inside `KANBAN_FETCH_ERROR_BATCH`, factored out because
/// all three tests filter the GET result on it.
const KANBAN_MESSAGE = "Failed to fetch kanban tasks for item item_178785157619947723";

/// A second, unrelated event — note it carries NO `route_path`, which
/// is the shape a `console.warn` (not enriched by the client) takes.
const UNRELATED_WARN_BATCH =
    \\{"events":[{"level":"warn","kind":"console_warn","message":"unrelated warning"}]}
;

const UNRELATED_MESSAGE = "unrelated warning";

/// Python's `_get_logs`: `GET /api/logs?limit=100`, expecting the
/// `{logs: [...]}` envelope.
///
/// Returns the OWNED response — the caller `deinit`s it, then parses
/// the body into a `Json` that must also be `deinit`ed while the
/// response is still alive.
fn getLogs(h: *Harness) !harness.Response {
    // The query string rides in `path`, not in `HttpOptions.params` —
    // see the note on `harness.buildUrl` in the suite's siblings.
    // `Harness.http` appends `path` to `http://127.0.0.1:<port>`
    // verbatim, so these are byte-identical request lines.
    return h.http(io, .GET, "/api/logs?limit=100", .{ .expect = &.{200} });
}

/// How many rows in `doc`'s `logs` array carry `message` — the Python
/// list-comprehension `[l for l in rows if l["message"] == ...]`
/// reduced to a count.
fn countRowsWithMessage(doc: *const harness.Json, message: []const u8) usize {
    const logs = doc.array("logs") orelse return 0;
    var n: usize = 0;
    for (logs.items) |row| {
        const msg = switch (row) {
            .object => |o| switch (o.get("message") orelse continue) {
                .string => |s| s,
                else => continue,
            },
            else => continue,
        };
        if (std.mem.eql(u8, msg, message)) n += 1;
    }
    return n;
}

/// The first row in `doc`'s `logs` array carrying `message`, or null.
fn firstRowWithMessage(doc: *const harness.Json, message: []const u8) ?std.json.Value {
    const logs = doc.array("logs") orelse return null;
    for (logs.items) |row| {
        const msg = switch (row) {
            .object => |o| switch (o.get("message") orelse continue) {
                .string => |s| s,
                else => continue,
            },
            else => continue,
        };
        if (std.mem.eql(u8, msg, message)) return row;
    }
    return null;
}

/// Read a string field off a `logs` row.
fn rowStr(row: std.json.Value, key: []const u8) ?[]const u8 {
    const v = switch (row) {
        .object => |o| o.get(key) orelse return null,
        else => return null,
    };
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Read an integer field off a `logs` row.
fn rowInt(row: std.json.Value, key: []const u8) ?i64 {
    const v = switch (row) {
        .object => |o| o.get(key) orelse return null,
        else => return null,
    };
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

// EXACT-FRONTEND-BODY — the screenshot's batch must persist (204),
// not 500 with "Failed to dedup log".
test "exact_frontend_batch_returns_204" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // A 500 here IS the regression — the harness prints the body.
    var post = try h.http(io, .POST, "/api/logs", .{
        .json_body = KANBAN_FETCH_ERROR_BATCH,
        .expect = &.{204},
    });
    defer post.deinit();

    var r = try getLogs(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.get("logs") == null) {
        std.debug.print("GET /api/logs should return a logs list, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }

    const n = countRowsWithMessage(&doc, KANBAN_MESSAGE);
    if (n != 1) {
        std.debug.print("expected 1 persisted row, got {d}: {s}\n", .{ n, r.body });
        return error.TestUnexpectedResult;
    }
    const row = firstRowWithMessage(&doc, KANBAN_MESSAGE).?;
    try testing.expectEqualStrings("console_error", rowStr(row, "kind").?);
    try testing.expectEqual(@as(i64, 1), rowInt(row, "count").?);
}

// DEDUP-HIT — same batch within the 1s window → 204 + count=2, and
// STILL one row (no second insert).
test "immediate_repost_dedups_to_count_2" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    for (0..2) |_| {
        var post = try h.http(io, .POST, "/api/logs", .{
            .json_body = KANBAN_FETCH_ERROR_BATCH,
            .expect = &.{204},
        });
        defer post.deinit();
    }

    var r = try getLogs(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const n = countRowsWithMessage(&doc, KANBAN_MESSAGE);
    if (n != 1) {
        std.debug.print("dedup should keep 1 row, got {d}: {s}\n", .{ n, r.body });
        return error.TestUnexpectedResult;
    }
    const row = firstRowWithMessage(&doc, KANBAN_MESSAGE).?;
    const count = rowInt(row, "count") orelse 0;
    if (count != 2) {
        std.debug.print("dedup re-POST should bump count to 2, got {d}: {s}\n", .{ count, r.body });
        return error.TestUnexpectedResult;
    }
}

// FRESH-EVENT — a distinct message must NOT dedup; it inserts a
// second row.
test "different_message_inserts_second_row" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var post = try h.http(io, .POST, "/api/logs", .{
            .json_body = KANBAN_FETCH_ERROR_BATCH,
            .expect = &.{204},
        });
        defer post.deinit();
    }
    {
        var post = try h.http(io, .POST, "/api/logs", .{
            .json_body = UNRELATED_WARN_BATCH,
            .expect = &.{204},
        });
        defer post.deinit();
    }

    var r = try getLogs(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const total = (doc.array("logs") orelse return error.TestUnexpectedResult).items.len;
    if (total != 2) {
        std.debug.print("expected 2 rows, got {d}: {s}\n", .{ total, r.body });
        return error.TestUnexpectedResult;
    }
    if (countRowsWithMessage(&doc, KANBAN_MESSAGE) != 1) {
        std.debug.print("kanban message missing: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (countRowsWithMessage(&doc, UNRELATED_MESSAGE) != 1) {
        std.debug.print("unrelated warning missing: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}
