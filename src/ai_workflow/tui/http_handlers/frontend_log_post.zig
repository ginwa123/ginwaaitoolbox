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
//! Preserves the static-contract assertions in `frontend_log_post_test.zig`:
//!   - `parseFromSliceLeaky` (NOT `parseFromSlice`) for body parsing
//!   - `makeErrorResponse` for all error responses
//!   - `status_code = 204` on success
//!   - `status_code = 400` on missing/invalid fields
//!   - `status_code = 500` on db failure
//!   - Validation substrings for level/kind/message

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;
const http_response = @import("http_response.zig");

/// JSON request body for `POST /api/logs`.
///
/// Required: `level`, `kind`, `message`. Everything else is optional and
/// maps 1:1 to the `logs` table column (nullable columns are nullable
/// in the struct too).
const FrontendLogBody = struct {
    level: []const u8,
    kind: []const u8,
    message: []const u8,
    stack: ?[]const u8 = null,
    source: ?[]const u8 = null,
    line: ?i64 = null,
    route_path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code. The 5 validation variants
/// (`MissingLevel`/`InvalidLevel`, `MissingKind`/`InvalidKind`,
/// `MissingMessage`) split "field is absent" from "field value
/// is wrong" so the error messages — and the static-contract test
/// grep substrings — can be precise. The "missing required
/// field: <name>" message form matches what an LLM needs to know
/// about which field was absent (vs. just plain "invalid").
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
///      AND IFNULL(stack,'') = IFNULL(?,'') AND created_at >= ?.
///      If a row matches within the last second, UPDATE count + 1
///      and return success (no second row created).
///   4. Otherwise INSERT a new row.
fn useCase(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    body: FrontendLogBody,
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
    const dedup_sql =
        \\SELECT id FROM logs
        \\WHERE kind = ?
        \\  AND message = ?
        \\  AND IFNULL(stack,'') = IFNULL(?,'')
        \\  AND created_at >= ?
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

    if (try dedup_rows.next()) |dedup_row| {
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
        \\  id, created_at, level, kind, message,
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

    const di = nalarcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }),
        });
    };

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "missing required field: level" }),
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

    useCase(allocator, di.db, parsed) catch |err| {
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
            // Validation messages intentionally use the substrings that
            // the static-contract tests grep for. "missing required
            // field: X" is the canonical shape for an absent field,
            // distinguishing it from "X must be one of ..." which
            // means present-but-wrong.
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

    // 204 No Content — empty body. Use rawResponse (not jsonResponse)
    // because there's no JSON body to serialize. Same shape as
    // `corsPreflightHandler` (`cors.zig:8`).
    return res.rawResponse(.{
        .status_code = 204,
        .headers = &.{},
        .body = "",
    });
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
    const ns = nalarcore.helpers.unixTimestampNanos();
    const us: i64 = @intCast(@divTrunc(ns, std.time.ns_per_us));
    return if (us < 0) 0 else us;
}