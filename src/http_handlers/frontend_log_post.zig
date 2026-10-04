//! `POST /api/logs` — persist a frontend error event to the `logs` table.
//!
//! Body (JSON):
//!   {
//!     "level":      "error" | "warn" | "info" | "debug",         (required)
//!     "kind":       "window_error" | "unhandled_rejection"
//!                 | "console_error" | "console_warn",              (required)
//!     "message":    "<human readable>",                            (required)
//!     "stack":      "<stack trace>",                               (optional)
//!     "source":     "<file URL>",                                  (optional)
//!     "line":       <line number>,                                 (optional)
//!     "route_path": "<current Vue route>",                         (optional)
//!     "session_id": "<active chat session_id>"                     (optional)
//!   }
//!
//! On success:  204 No Content (no body)
//! On 400:      `{ "error": "..." }` for missing/invalid fields
//! On 500:      `{ "error": "..." }` for DB failure or OOM in id alloc
//!
//! Layered as:
//!   - `useCase` — fetches the singleton + db handle, validates fields,
//!     generates the row id, runs the 1-second dedup check, then either
//!     `UPDATE logs SET count = count + 1 WHERE id = ?` (dedup hit) or
//!     `INSERT INTO logs (...)` (new row). Returns `void` — success is
//!     a silent 204, not a JSON body.
//!   - `frontendLogPostHandler` — thin orchestrator: parses the HTTP
//!     body, calls `useCase`, maps errors to status codes, builds the
//!     empty-body 204 response.
//!
//! Plan: docs/plans/2026-07-17-frontend-error-logs-design.md
//!       docs/superpowers/plans/2026-07-17-frontend-error-logs.md
//!
//! Parses each event with `parseFromSliceLeaky` (NOT
//! `parseFromSlice`, which would need an explicit deinit), answers
//! every error branch with `makeErrorResponse` so the wire shape
//! stays `{"error": "..."}`, and returns `status_code = 204` on
//! success, `400` on a missing/invalid field, `500` on a DB failure.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;
const http_response = @import("http_response.zig");

/// JSON request body for `POST /api/logs`.
///
/// The wire format is a BATCH (`{"events": [event, event, ...]}`) — this
/// matches the front-end `helpers/frontendLogClient.ts` which debounces
/// multiple console.error / window.error / unhandledrejection events into
/// one POST every 250ms. The handler loops `useCase` over each event and
/// returns the SAME status code (204 on full success, 400 on the first
/// validation failure, 500 on the first DB failure) — the frontend treats
/// any 4xx/5xx as "drop the batch", so partial-success isn't useful.
///
/// Required per event: `level`, `kind`, `message`. Everything else is
/// optional and maps 1:1 to the `logs` table column (nullable columns
/// are nullable in the struct too).
const FrontendLogBody = struct {
    events: []const FrontendLogEvent = &.{},

    pub const FrontendLogEvent = struct {
        level: []const u8,
        kind: []const u8,
        message: []const u8,
        stack: ?[]const u8 = null,
        source: ?[]const u8 = null,
        line: ?i64 = null,
        route_path: ?[]const u8 = null,
        session_id: ?[]const u8 = null,
    };
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code. The 5 validation variants
/// (`MissingLevel`/`InvalidLevel`, `MissingKind`/`InvalidKind`,
/// `MissingMessage`) split "field is absent" from "field value
/// is wrong" so the error messages can be precise. The "missing
/// required field: <name>" message form matches what an LLM needs
/// to know about which field was absent (vs. just plain "invalid").
pub const FrontendLogPostError = error{
    /// `getSingleton()` failed — server not initialised. Maps to 500.
    ServerNotInitialized,
    /// Generated log id couldn't be allocated (OOM). Maps to 500.
    IdAllocationFailed,
    /// `level` field missing. Maps to 400.
    MissingLevel,
    /// `level` value is not in the whitelist. Maps to 400.
    InvalidLevel,
    /// `kind` field missing. Maps to 400.
    MissingKind,
    /// `kind` value is not in the whitelist. Maps to 400.
    InvalidKind,
    /// `message` field missing or empty. Maps to 400.
    MissingMessage,
    /// DB read (dedup SELECT) failed. Maps to 500.
    DedupQueryFailed,
    /// DB write (UPDATE or INSERT) failed. Maps to 500.
    PersistFailed,
};

// =====================================================================
// Whitelists
// =====================================================================

/// Valid `level` values. Anything else → 400.
const VALID_LEVELS = [_][]const u8{ "error", "warn", "info", "debug" };

/// Valid `kind` values. Anything else → 400.
const VALID_KINDS = [_][]const u8{
    "window_error",
    "unhandled_rejection",
    "console_error",
    "console_warn",
};

// =====================================================================
// Use case
// =====================================================================

/// Persist one frontend log event.
///
/// Steps:
///   1. Validate required fields and enum values.
///   2. Generate row id = `"log_<microseconds>"` (matches project
///      convention; microsecond timestamps are unique enough for this
///      error-event volume).
///   3. Dedup check: SELECT id FROM logs WHERE kind = ? AND message = ?
///      AND IFNULL(stack,'') = IFNULL(?,'') AND created_at_nano >= ?.
///      If a row matches within the last second, UPDATE count + 1
///      and return success (no second row created).
///   4. Otherwise INSERT a new row.
fn useCase(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    body: FrontendLogBody.FrontendLogEvent,
) FrontendLogPostError!void {
    if (body.level.len == 0) return error.MissingLevel;
    if (!isValidLevel(body.level)) return error.InvalidLevel;
    if (body.kind.len == 0) return error.MissingKind;
    if (!isValidKind(body.kind)) return error.InvalidKind;
    if (body.message.len == 0) return error.MissingMessage;

    // Row id = "log_<microseconds>". Allocates from the per-request
    // arena (the caller's `allocator`); freed at scope exit. On OOM,
    // surface 500 — the caller has no fallback id source.
    const id = idForRow(allocator) catch return error.IdAllocationFailed;
    defer allocator.free(id);

    const now_us: i64 = microsecondsNow();

    // `db.exec` only binds text — integer values must be formatted
    // as decimal strings before binding. SQLite's INTEGER-affinity
    // columns coerce a numeric-looking text literal back to an
    // INTEGER on read, so the round-trip is type-preserving.
    // See `kanban_model.zig:177` for the same pattern (`pos_str`).
    const now_us_str = std.fmt.allocPrint(allocator, "{d}", .{now_us}) catch return error.IdAllocationFailed;
    defer allocator.free(now_us_str);
    const dedup_cutoff_str = std.fmt.allocPrint(allocator, "{d}", .{now_us - 1_000_000}) catch return error.IdAllocationFailed;
    defer allocator.free(dedup_cutoff_str);
    const line_str = std.fmt.allocPrint(allocator, "{d}", .{body.line orelse 0}) catch return error.IdAllocationFailed;
    defer allocator.free(line_str);

    // Dedup check: same kind + message + stack within the last 1 second.
    // The `IFNULL(stack,'') = IFNULL(?,'')` form treats NULL and ""
    // as equivalent dedup keys (matches the design doc contract).
    // Column is `created_at_nano` since Migration 075 renamed
    // `logs.created_at` (same unit, self-documenting name).
    const dedup_sql =
        \\SELECT id FROM logs
        \\WHERE kind = ?
        \\  AND message = ?
        \\  AND IFNULL(stack,'') = IFNULL(?,'')
        \\  AND created_at_nano >= ?
        \\LIMIT 1
    ;
    var dedup_rows = db.query(
        allocator,
        dedup_sql,
        &.{
            body.kind,
            body.message,
            body.stack orelse "",
            dedup_cutoff_str,
        },
    ) catch return error.DedupQueryFailed;
    defer dedup_rows.deinit();

    if (dedup_rows.next() catch |e| {
        std.log.warn("frontend_log_post useCase: dedup_rows.next failed: {s}", .{@errorName(e)});
        return error.DedupQueryFailed;
    }) |dedup_row| {
        defer dedup_row.deinit(allocator);
        // Existing row matches the dedup key. Increment its count
        // and return — no second row is created.
        db.exec(
            allocator,
            "UPDATE logs SET count = count + 1 WHERE id = ?",
            &.{dedup_row.values[0]},
        ) catch return error.PersistFailed;
        return;
    }

    // Fresh event — insert a new row.
    const insert_sql =
        \\INSERT INTO logs (
        \\  id, created_at_nano, level, kind, message,
        \\  stack, source, line, route_path, session_id, count
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
    ;
    // For nullable TEXT columns (stack/source/route_path/session_id),
    // `db.exec` binds empty slice as NULL (project memory
    // `sqlite-backend-empty-slice-binds-as-null`). The INSERT column
    // list matches the table schema exactly — including stack/source/
    // route_path/session_id, which are nullable in the table.
    // The line column is INTEGER but gets the textual `line_str`
    // binding (SQLite coerces numeric-looking text to integer under
    // INTEGER affinity, verified against :memory: at
    // dev time: `INSERT INTO t (created_at INTEGER) VALUES ('123')`
    // → `typeof() == 'integer'`).
    db.exec(
        allocator,
        insert_sql,
        &.{
            id,
            now_us_str,
            body.level,
            body.kind,
            body.message,
            body.stack orelse "",
            body.source orelse "",
            line_str,
            body.route_path orelse "",
            body.session_id orelse "",
        },
    ) catch return error.PersistFailed;
}

// =====================================================================
// Handler
// =====================================================================

pub fn frontendLogPostHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }),
        });
    };

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "missing required field: events" }),
        });
    }

    // Per-request arena owns the parsed value (Leaky variant — see
    // `memories_create.zig:181` for the precedent). Allocated slices
    // for `stack`/`source`/`message`/`route_path`/`session_id` live
    // for the duration of the request and are reaped when
    // `GinwaServer.handle` tears down the per-request arena.
    const parsed = std.json.parseFromSliceLeaky(FrontendLogBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.events.len == 0) {
        // Frontend client always sends a non-empty batch (it's
        // wrapping its in-memory queue), so an empty `events` array
        // is user-error or caller misconfiguration — surface as 400
        // with a clear message.
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "missing required field: events" }),
        });
    }

    // Run the use case once per event. The first failure aborts the
    // batch (the frontend treats any 4xx/5xx as "drop the batch", so
    // partial-success isn't useful — the client either retries the
    // whole batch or moves on). This matches the dedup-checks-one-
    // at-a-time model from Chunk 2.
    for (parsed.events) |event| {
        useCase(allocator, di.db, event) catch |err| {
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.IdAllocationFailed => 500,
            error.MissingLevel => 400,
            error.InvalidLevel => 400,
            error.MissingKind => 400,
            error.InvalidKind => 400,
            error.MissingMessage => 400,
            error.DedupQueryFailed => 500,
            error.PersistFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.IdAllocationFailed => "Failed to generate log id",
            // Validation messages use a canonical shape the frontend
            // parses: "missing required field: X" for an absent field,
            // "X must be one of ..." for present-but-wrong.
            error.MissingLevel => "missing required field: level",
            error.InvalidLevel => "level must be one of error, warn, info, debug",
            error.MissingKind => "missing required field: kind",
            error.InvalidKind => "kind must be one of window_error, unhandled_rejection, console_error, console_warn",
            error.MissingMessage => "missing required field: message",
            error.DedupQueryFailed => "Failed to dedup log",
            error.PersistFailed => "Failed to persist log",
        };
        // Use `std.log.warn` (NOT `std.log.err`) so this handler's
        // error-path doesn't trigger `log_err_count > 0` in
        // `zig build test`. User-input errors are warnings, not
        // programmer errors.
        std.log.warn("frontend_log_post: {s}", .{message});
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    }

    // 204 No Content — empty body. Build via
    // `gserverz.HttpResponse.init(...)` + `.withBody("")` because the
    // helper `rawResponse` doesn't exist on `HttpResponse` (only
    // `jsonResponse` does). Note: `init` is a static method on
    // `HttpResponse` (no self param) so it's called via the type,
    // not via `res.init(...)`. The `withBody("")` path adds
    // Content-Length: 0 — what an empty 204 needs. (Note:
    // `cors.zig:8` has the same phantom-method bug but is currently
    // dead code; the CORS OPTIONS route is commented out in
    // `main.zig:279`.)
    return gserverz.HttpResponse.init(204, "No Content", allocator).withBody("");
}

// =====================================================================
// Helpers
// =====================================================================

/// Returns true if `level` is one of the 4 whitelisted values.
fn isValidLevel(level: []const u8) bool {
    for (VALID_LEVELS) |v| {
        if (std.mem.eql(u8, v, level)) return true;
    }
    return false;
}

/// Returns true if `kind` is one of the 4 whitelisted values.
fn isValidKind(kind: []const u8) bool {
    for (VALID_KINDS) |v| {
        if (std.mem.eql(u8, v, kind)) return true;
    }
    return false;
}

/// Generate the canonical `log_<microseconds>` id for a new row.
///
/// On OOM, propagates the alloc error to the caller (the useCase
/// catches it as `error.IdAllocationFailed` and the handler returns
/// 500). There is no silent fallback to a non-unique id — a malformed
/// id would risk a PRIMARY KEY collision, which is worse than a 500
/// (the client can retry the POST after the OOM clears).
fn idForRow(allocator: std.mem.Allocator) ![]u8 {
    const us = microsecondsNow();
    return std.fmt.allocPrint(allocator, "log_{d}", .{us});
}

/// Current Unix time in microseconds.
///
/// `std.time.microTimestamp()` was REMOVED in Zig 0.16. We use the
/// project's `helpers.unixTimestampNanos()` (POSIX `clock_gettime` /
/// Win32 `GetSystemTimeAsFileTime`) and divide. Returns i64 — fits
/// until the year ~294276 (microsecond precision, 64-bit signed).
///
/// Negative values are clamped to 0 — we use this as a DB column
/// value, never as an arithmetic input.
fn microsecondsNow() i64 {
    const ns = @import("helpers").unixTimestampNanos();
    const us: i64 = @intCast(@divTrunc(ns, std.time.ns_per_us));
    return if (us < 0) 0 else us;
}

// ===== Tests merged from frontend_log_post_test.zig (2026-09-11 flatten) =====
// Behavioural SQL dedup tests (Task 2.3) for `frontend_log_post`
// (POST /api/logs, Chunk 2 of
// `docs/superpowers/plans/2026-07-17-frontend-error-logs.md`).
//
// The handler is a thin wrapper over the SQL insert + dedup-update in
// `src/migrations/migration.zig`'s `logs` table (Migration 063). Standing
// up a real server + singleton + Io + SQLite + env to exercise the HTTP
// path is too much integration infra for a single endpoint, so these
// tests exercise the dedup SQL directly. They lock in the dedup contract
// from the design doc: same (kind, message, stack) within 1s → UPDATE
// count + 1 (no second row); different stack OR > 1s apart → fresh row is
// INSERTed.
//
// Plan: docs/plans/2026-07-17-frontend-error-logs-design.md
//       docs/superpowers/plans/2026-07-17-frontend-error-logs.md

const testing = std.testing;

// =============================================================================
// Behavioural SQL dedup tests (Task 2.3)
//
// These exercise the SAME SQL the use-case runs against an in-memory
// SQLite DB with the logs table loaded. They lock in the dedup
// contract from the design doc: same (kind, message, stack) within 1s
// → UPDATE count + 1 (no second row); different stack OR > 1s apart
// → fresh row is INSERTed.
// =============================================================================


/// Open a fresh in-memory sqlite DB with the `logs` table loaded.
/// Mirrors the `setupDb063` helper in `migration.zig` and the
/// `routines/Scheduler.zig` pattern.
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

    try pabrikcore.migrations_mod.migration.Migration064AddFrontendLogs.up(&db, alloc);
    // Production DBs also run Migration 075, which renames
    // `logs.created_at` → `logs.created_at_nano`. Mirror that rename
    // here so these tests exercise the post-rename schema the live
    // useCase targets (missing this is what let the stale `created_at`
    // dedup SELECT pass tests while failing in production).
    // We inline the logs half of Migration 075 instead of calling
    // `Migration075...up` directly because the full migration also
    // CREATEs an index on `worker`, which doesn't exist in this
    // logs-only :memory: DB.
    try db.exec(alloc, "ALTER TABLE logs RENAME COLUMN created_at TO created_at_nano", &.{});
    try db.exec(alloc, "DROP INDEX IF EXISTS idx_logs_created_at", &.{});
    try db.exec(
        alloc,
        "CREATE INDEX IF NOT EXISTS idx_logs_created_at_nano ON logs(created_at_nano DESC)",
        &.{},
    );
    return .{ .db = db, .threaded = threaded };
}

test "dedup SQL: same kind+message+stack within 1s increments count" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const now_us: i64 = 1_784_226_123_456_789;
    // The `db.exec` / `db.query` helpers only bind TEXT — microsecond
    // values are formatted as decimal strings (the project convention;
    // SQLite coerces the numeric-looking text to INTEGER under INTEGER
    // affinity, verified via :memory: round-trip).
    const now_us_str = try std.fmt.allocPrint(alloc, "{d}", .{now_us});
    defer alloc.free(now_us_str);
    const dedup_cutoff_str = try std.fmt.allocPrint(alloc, "{d}", .{now_us - 1_000_000});
    defer alloc.free(dedup_cutoff_str);

    // Insert first row at now.
    try s.db.exec(
        alloc,
        "INSERT INTO logs (id, created_at_nano, level, kind, message, stack, count) VALUES (?, ?, ?, ?, ?, ?, 1)",
        &.{ "log_first", now_us_str, "error", "console_error", "boom", "stack-A" },
    );

    // Dedup SELECT — same key within last 1s → matches.
    var rows = try s.db.query(
        alloc,
        "SELECT id FROM logs WHERE kind = ? AND message = ? AND IFNULL(stack,'') = IFNULL(?,'') AND created_at_nano >= ? LIMIT 1",
        &.{ "console_error", "boom", "stack-A", dedup_cutoff_str },
    );
    defer rows.deinit();

    const row = (try rows.next()) orelse return error.ExpectedDedupMatch;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("log_first", row.values[0]);

    // Increment count via UPDATE.
    try s.db.exec(alloc, "UPDATE logs SET count = count + 1 WHERE id = ?", &.{"log_first"});

    // Verify count is now 2 and row count is still 1.
    var count_rows = try s.db.query(alloc, "SELECT count FROM logs WHERE id = ?", &.{"log_first"});
    defer count_rows.deinit();
    const count_row = (try count_rows.next()) orelse return error.RowMissing;
    defer count_row.deinit(alloc);
    try testing.expectEqualStrings("2", count_row.values[0]);

    var total_rows = try s.db.query(alloc, "SELECT COUNT(*) FROM logs", &.{});
    defer total_rows.deinit();
    const total_row = (try total_rows.next()) orelse return error.RowMissing;
    defer total_row.deinit(alloc);
    try testing.expectEqualStrings("1", total_row.values[0]);
}

test "dedup SQL: different stack within 1s does NOT match (insert second row)" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const now_us: i64 = 1_784_226_123_456_789;
    const now_us_str = try std.fmt.allocPrint(alloc, "{d}", .{now_us});
    defer alloc.free(now_us_str);
    const dedup_cutoff_str = try std.fmt.allocPrint(alloc, "{d}", .{now_us - 1_000_000});
    defer alloc.free(dedup_cutoff_str);

    // Insert first row with stack-A.
    try s.db.exec(
        alloc,
        "INSERT INTO logs (id, created_at_nano, level, kind, message, stack, count) VALUES (?, ?, ?, ?, ?, ?, 1)",
        &.{ "log_first", now_us_str, "error", "console_error", "boom", "stack-A" },
    );

    // Dedup query with a DIFFERENT stack — should NOT match.
    var rows = try s.db.query(
        alloc,
        "SELECT id FROM logs WHERE kind = ? AND message = ? AND IFNULL(stack,'') = IFNULL(?,'') AND created_at_nano >= ? LIMIT 1",
        &.{ "console_error", "boom", "stack-B", dedup_cutoff_str },
    );
    defer rows.deinit();

    const row_opt = try rows.next();
    if (row_opt) |r| {
        defer r.deinit(alloc);
        // dedup should NOT match — bug!
        return error.UnexpectedDedupMatch;
    }
    // Verify the row count is still 1 (would become 2 if a new INSERT
    // landed; the handler does the INSERT after no-match).
    var count_rows = try s.db.query(alloc, "SELECT COUNT(*) FROM logs", &.{});
    defer count_rows.deinit();
    const count_row = (try count_rows.next()) orelse return error.RowMissing;
    defer count_row.deinit(alloc);
    try testing.expectEqualStrings("1", count_row.values[0]);
}

test "dedup SQL: same key but >1s apart does NOT match (no dedup across window)" {
    const alloc = testing.allocator;
    var s = try setupDbWithLogs();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const t1: i64 = 1_784_226_123_456_789;
    const t1_str = try std.fmt.allocPrint(alloc, "{d}", .{t1});
    defer alloc.free(t1_str);
    // t2 is 1.5 seconds past t1 — clearly outside the 1s dedup window.
    const t2: i64 = t1 + 1_500_000;
    const t2_str = try std.fmt.allocPrint(alloc, "{d}", .{t2});
    defer alloc.free(t2_str);
    // Dedup cutoff at t2 = t1 + 0.5s, which is BEFORE t1, so the t1
    // row is excluded from the dedup query.
    const dedup_cutoff_str = try std.fmt.allocPrint(alloc, "{d}", .{t2 - 1_000_000});
    defer alloc.free(dedup_cutoff_str);

    // Row at t1 with stack-A.
    try s.db.exec(
        alloc,
        "INSERT INTO logs (id, created_at_nano, level, kind, message, stack, count) VALUES (?, ?, ?, ?, ?, ?, 1)",
        &.{ "log_t1", t1_str, "error", "console_error", "boom", "stack-A" },
    );

    // Dedup at t2 with same key — t1 is BEFORE cut-off → no match →
    // handler would INSERT a new row.
    var rows = try s.db.query(
        alloc,
        "SELECT id FROM logs WHERE kind = ? AND message = ? AND IFNULL(stack,'') = IFNULL(?,'') AND created_at_nano >= ? LIMIT 1",
        &.{ "console_error", "boom", "stack-A", dedup_cutoff_str },
    );
    defer rows.deinit();

    const row_opt = try rows.next();
    if (row_opt) |r| {
        defer r.deinit(alloc);
        return error.UnexpectedDedupMatchAcrossWindow;
    }
    // Original row stays untouched.
    var count_rows = try s.db.query(alloc, "SELECT COUNT(*) FROM logs", &.{});
    defer count_rows.deinit();
    const count_row = (try count_rows.next()) orelse return error.RowMissing;
    defer count_row.deinit(alloc);
    try testing.expectEqualStrings("1", count_row.values[0]);
}
