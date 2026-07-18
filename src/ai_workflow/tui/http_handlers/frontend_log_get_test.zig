//! Static-contract + behavioural SQL tests for `frontend_log_get`
//! (GET /api/logs, Chunk 3 of
//! `docs/superpowers/plans/2026-07-17-frontend-error-logs.md`).
//!
//! Layout of this file
//! ────────────────────
//!   1. Static-contract tests (5): grep the handler source for the
//!      contract substrings a future refactor must preserve — query
//!      param access, response helper, ORDER BY, limit default, limit
//!      cap. Same shape as `frontend_log_post_test.zig::readSource`
//!      and `tasks_list_test.zig`.
//!
//!   2. Behavioural SQL tests (4): exercise the SAME SQL the use-case
//!      builds (recent-first ordering, `WHERE level = ?`,
//!      `WHERE created_at >= ?`, `LIMIT ?`) against an in-memory
//!      SQLite DB with the `logs` table loaded. The handler itself
//!      is too tightly coupled to `nalarcore.getSingleton()` to
//!      behavioural-test end-to-end (would need a live
//!      `ContextIPCTui`), so the tests assert the SQL contract
//!      directly. Mirrors the dedup-SQL tests in
//!      `frontend_log_post_test.zig`.
//!
//! Plan: docs/plans/2026-07-17-frontend-error-logs-design.md
//!       docs/superpowers/plans/2026-07-17-frontend-error-logs.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/frontend_log_get.zig";

/// Read a source file from disk, normalize CRLF→LF, free raw.
/// Same shape as `frontend_log_post_test.zig::readSource` and
/// `tasks_list_test.zig::readSource`.
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

// =============================================================================
// Static-contract tests
// =============================================================================

test "frontend_log_get handler reads the query params via req.query" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // `req.query` (NOT `req.params.get` — that's the path-param
    // pattern) is the project convention for query-string params;
    // see `tasks_list.zig:210` for the precedent.
    if (std.mem.indexOf(u8, source, "req.query") == null) {
        std.debug.print(
            "\n!! {s} does not read query params !!\n" ++
                "   The handler must access `req.query` (the StringHashMap field\n" ++
                "   on the request struct) to read the level/kind/session_id/\n" ++
                "   since/limit query string. See `tasks_list.zig:210`.\n",
            .{HANDLER_PATH},
        );
        return error.QueryParamAccessMissing;
    }
}

test "frontend_log_get handler uses makeFrontendLogListResponse for the response" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The response helper enforces the typed response envelope.
    // A hand-rolled `std.fmt.allocPrint` would risk escaping
    // bugs in the `message` field (which can contain quotes /
    // newlines from the frontend).
    if (std.mem.indexOf(u8, source, "makeFrontendLogListResponse") == null) {
        std.debug.print(
            "\n!! {s} does not use makeFrontendLogListResponse !!\n" ++
                "   The response shape must come from the typed helper to\n" ++
                "   guarantee the documented envelope (logs array + count\n" ++
                "   field) and match the frontend's typed interfaces.\n",
            .{HANDLER_PATH},
        );
        return error.MakeFrontendLogListResponseMissing;
    }
}

test "frontend_log_get handler orders by created_at DESC" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Most-recent-first is the documented order (design doc §2,
    // GET handler). Static test guards against a refactor that
    // accidentally drops the DESC clause.
    if (std.mem.indexOf(u8, source, "ORDER BY created_at DESC") == null) {
        std.debug.print(
            "\n!! {s} is missing 'ORDER BY created_at DESC' !!\n" ++
                "   The GET handler must order by created_at DESC so the\n" ++
                "   most recent error appears first. The design doc says\n" ++
                "   this explicitly; the index idx_logs_created_at also\n" ++
                "   expects DESC ordering.\n",
            .{HANDLER_PATH},
        );
        return error.OrderByDescMissing;
    }
}

test "frontend_log_get handler defaults limit to 100" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The DEFAULT_LIMIT constant must be present in the source so the
    // static test can grep for it. Using a named constant + the
    // literal `100` in the same line keeps the assertion stable.
    // The substring search is anchored to "DEFAULT_LIMIT: u32 = 100"
    // — the const declaration shape — which uniquely identifies the
    // constant value in this file.
    if (std.mem.indexOf(u8, source, "DEFAULT_LIMIT: u32 = 100") == null) {
        std.debug.print(
            "\n!! {s} does not define DEFAULT_LIMIT: u32 = 100 !!\n" ++
                "   The handler must default the limit to 100 when the\n" ++
                "   client omits the query param. See the design doc §2.\n",
            .{HANDLER_PATH},
        );
        return error.DefaultLimitMissing;
    }
}

test "frontend_log_get handler caps limit at 1000" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The MAX_LIMIT constant must be present with literal 1000 in
    // the source — design doc §2 caps the limit at 1000 rows.
    if (std.mem.indexOf(u8, source, "MAX_LIMIT: u32 = 1000") == null) {
        std.debug.print(
            "\n!! {s} does not define MAX_LIMIT: u32 = 1000 !!\n" ++
                "   The handler must reject limit values > 1000 to prevent\n" ++
                "   a client asking for unbounded rows. See design doc §2.\n",
            .{HANDLER_PATH},
        );
        return error.MaxLimitMissing;
    }
}

// =============================================================================
// Behavioural SQL tests
//
// These exercise the SAME SQL the use-case runs against an in-memory
// SQLite DB with the logs table loaded. They lock in the contract:
// ORDER BY created_at DESC, optional WHERE level/kind/session_id/created_at
// filters, and LIMIT clamping. Each test sets up its own DB so they
// are independent.
// =============================================================================

const sqlite = nalarcore.sqlite;

/// Open a fresh in-memory sqlite DB with the `logs` table loaded.
/// Mirrors `frontend_log_post_test.zig::setupDbWithLogs`.
fn setupDbWithLogs() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try nalarcore.migrations_mod.migration.Migration064AddFrontendLogs.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Insert one log row with a specific id, microsecond timestamp, and
/// level. Mirrors the use-case's INSERT shape (sans dedup — we
/// always insert fresh rows here).
fn insertLog(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    id: []const u8,
    created_at_us: i64,
    level: []const u8,
    kind: []const u8,
    message: []const u8,
) !void {
    const ts_str = try std.fmt.allocPrint(alloc, "{d}", .{created_at_us});
    defer alloc.free(ts_str);
    try db.exec(
        alloc,
        "INSERT INTO logs (id, created_at, level, kind, message, count) VALUES (?, ?, ?, ?, ?, 1)",
        &.{ id, ts_str, level, kind, message },
    );
}

const SelectedLogRow = struct {
    id: []const u8,
    created_at: []const u8,
    level: []const u8,
    message: []const u8,
};

/// Run a SELECT against `logs` with the use-case's exact column order
/// and ORDER BY/LIMIT shape. Returns owned slices — caller frees via
/// `alloc.free(slice)` then `defer rows.deinit()`.
fn selectLogs(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    where_clause: []const u8,
    limit: u32,
) ![]SelectedLogRow {
    const sql = try std.fmt.allocPrint(
        alloc,
        "SELECT id, created_at, level, message FROM logs WHERE 1=1{s} ORDER BY created_at DESC LIMIT {d}",
        .{ where_clause, limit },
    );
    defer alloc.free(sql);

    // No bind args — the LIMIT was interpolated directly into the
    // SQL above (the test exercises the use-case's SQL SHAPE, not
    // its bind-positional pattern, so we don't need to mirror
    // the limit bind).
    var rows = try db.query(alloc, sql, &.{});
    defer rows.deinit();

    var out = std.ArrayList(SelectedLogRow).empty;
    while (try rows.next()) |row| {
        defer row.deinit(alloc);
        // Dupe each `row.values[i]` into heap-owned memory. The
        // `defer row.deinit(alloc)` above fires at end-of-iteration
        // and frees the row's `values` array; storing a borrowed
        // slice header from it into `out` (which lives in the
        // outer scope) would be a use-after-free. Project memory
        // `zig-sqlite-defer-row-deinit-use-after-free` documents
        // this trap.
        try out.append(alloc, .{
            .id = try alloc.dupe(u8, row.values[0]),
            .created_at = try alloc.dupe(u8, row.values[1]),
            .level = try alloc.dupe(u8, row.values[2]),
            .message = try alloc.dupe(u8, row.values[3]),
        });
    }
    return out.toOwnedSlice(alloc);
}

/// Free the heap-owned strings inside a `[]SelectedLogRow` slice, then
/// free the outer slice. Mirrors the project's
/// `defer row.deinit(alloc)`-then-free pattern from
/// `frontend_log_post_test.zig`.
fn freeSelectedLogRows(alloc: std.mem.Allocator, rows: []SelectedLogRow) void {
    for (rows) |row| {
        alloc.free(row.id);
        alloc.free(row.created_at);
        alloc.free(row.level);
        alloc.free(row.message);
    }
    alloc.free(rows);
}

test "behavioural: recent-first ordering — DESC by created_at" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Insert in NON-DESC order to prove the SELECT reorders them.
    try insertLog(&s.db, alloc, "log_t1", 100, "info", "console_error", "first");
    try insertLog(&s.db, alloc, "log_t3", 300, "info", "console_error", "third");
    try insertLog(&s.db, alloc, "log_t2", 200, "info", "console_error", "second");

    const rows = try selectLogs(&s.db, alloc, "", 100);
    defer freeSelectedLogRows(alloc, rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("log_t3", rows[0].id);
    try testing.expectEqualStrings("log_t2", rows[1].id);
    try testing.expectEqualStrings("log_t1", rows[2].id);
}

test "behavioural: WHERE level = ? returns only matching rows" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try insertLog(&s.db, alloc, "log_e1", 100, "error", "console_error", "boom-error");
    try insertLog(&s.db, alloc, "log_w1", 200, "warn", "console_warn", "heads-up");
    try insertLog(&s.db, alloc, "log_e2", 300, "error", "window_error", "boom-error-2");

    const rows = try selectLogs(&s.db, alloc, " AND level = 'error'", 100);
    defer freeSelectedLogRows(alloc, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    // DESC by created_at — t=300 first, t=100 second.
    try testing.expectEqualStrings("log_e2", rows[0].id);
    try testing.expectEqualStrings("log_e1", rows[1].id);
}

test "behavioural: WHERE created_at >= ? (since filter)" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try insertLog(&s.db, alloc, "log_t1", 100, "info", "console_error", "old-1");
    try insertLog(&s.db, alloc, "log_t2", 200, "info", "console_error", "cutoff");
    try insertLog(&s.db, alloc, "log_t3", 300, "info", "console_error", "new-1");

    // Use the exact WHERE clause shape the use-case appends:
    //   "\n  AND created_at >= ?"
    // (the newline + 2-space indent is cosmetic but we mirror it).
    const rows = try selectLogs(&s.db, alloc, "\n  AND created_at >= '200'", 100);
    defer freeSelectedLogRows(alloc, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    // DESC order: t3 first, t2 second.
    try testing.expectEqualStrings("log_t3", rows[0].id);
    try testing.expectEqualStrings("log_t2", rows[1].id);
}

test "behavioural: LIMIT ? caps the result size" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Insert 5 rows.
    try insertLog(&s.db, alloc, "log_t1", 100, "info", "console_error", "1");
    try insertLog(&s.db, alloc, "log_t2", 200, "info", "console_error", "2");
    try insertLog(&s.db, alloc, "log_t3", 300, "info", "console_error", "3");
    try insertLog(&s.db, alloc, "log_t4", 400, "info", "console_error", "4");
    try insertLog(&s.db, alloc, "log_t5", 500, "info", "console_error", "5");

    // Limit 2 — only the 2 most recent (DESC by created_at).
    const rows = try selectLogs(&s.db, alloc, "", 2);
    defer freeSelectedLogRows(alloc, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("log_t5", rows[0].id);
    try testing.expectEqualStrings("log_t4", rows[1].id);
}
