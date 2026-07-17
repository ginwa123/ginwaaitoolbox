//! `GET /api/logs` — read rows from the `logs` table for `curl` /
//! scripts / debug inspection. Mirrors the design doc's Section 2
//! "Handler: GET /api/logs" contract (most-recent first, optional
//! filters, capped result size).
//!
//! Query parameters (all optional):
//!   - `level`       string  exact match (must be one of error/warn/info/debug)
//!   - `kind`        string  exact match (must be one of window_error/unhandled_rejection/console_error/console_warn)
//!   - `session_id`  string  exact match (no validation)
//!   - `since`       integer microseconds filter (`WHERE created_at >= ?`)
//!   - `limit`       integer 1..1000, default 100
//!
//! Response: `{"logs":[<FrontendLogRow>...],"count":N}` — built by
//! `http_response.makeFrontendLogListResponse` (consistent with the
//! other typed response helpers).
//!
//! On success:  200 OK
//! On 400:      `{ "error": "..." }` for invalid level/kind/limit
//! On 500:      `{ "error": "..." }` for DB failure
//!
//! Layered as:
//!   - `parseInput` — pulls the 5 optional query params, validates
//!     whitelists, clamps limit. Pure function; returns a typed
//!     `FrontendLogGetInput` or a `FrontendLogGetError`.
//!   - `useCase` — fetches the singleton + db handle, builds the SQL
//!     dynamically (ArrayList<u8>) so each filter only appears when
//!     supplied, runs `db.query`, maps rows to `FrontendLogRow[]`,
//!     serializes via `makeFrontendLogListResponse`. The SQL build
//!     uses positional `?` placeholders in a fixed order (level,
//!     kind, session_id, since, limit) so the bind list is a single
//!     fixed-size slice of `[]const u8` — no dynamic ArrayList of
//!     args needed (only the SQL string is dynamic).
//!   - `frontendLogGetHandler` — thin orchestrator: parses the query
//!     string via `parseInput`, calls `useCase`, maps errors to
//!     status codes, builds the JSON response.
//!
//! Plan: docs/plans/2026-07-17-frontend-error-logs-design.md
//!       docs/superpowers/plans/2026-07-17-frontend-error-logs.md
//!
//! Preserves the static-contract assertions in `frontend_log_get_test.zig`:
//!   - reads `req.query` (NOT `req.path_params`) — per the project
//!     memory `nalar-http-handler-thin-wrapper-pattern` and the
//!     precedent in `tasks_list.zig` (line 210)
//!   - `makeFrontendLogListResponse` for the success response shape
//!   - `ORDER BY created_at DESC` for the recent-first ordering
//!   - `100` literal for the limit default
//!   - `1000` literal for the limit cap

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;
const http_response = @import("http_response.zig");

// =====================================================================
// Whitelists
// =====================================================================

/// Valid `level` values — matches the POST handler's whitelist. An
/// unknown value → 400 (LLM-friendly hint in the error message).
const VALID_LEVELS = [_][]const u8{ "error", "warn", "info", "debug" };

/// Valid `kind` values — matches the POST handler's whitelist.
const VALID_KINDS = [_][]const u8{
    "window_error",
    "unhandled_rejection",
    "console_error",
    "console_warn",
};

// =====================================================================
// Constants
// =====================================================================

/// Default page size when the client doesn't pass `limit`. Matches the
/// design doc's "default 100".
const DEFAULT_LIMIT: u32 = 100;

/// Maximum page size (guards against a client asking for a million
/// rows). Matches the design doc's "capped at 1000".
const MAX_LIMIT: u32 = 1000;

// =====================================================================
// Error set
// =====================================================================

/// Domain-level error set for `useCase` and `parseInput`. Each
/// variant maps to a distinct HTTP status code. The 3 validation
/// variants split "value is wrong" from "value is not a number"
/// (the latter is currently absorbed into `InvalidLimit` — we
/// treat any unparseable limit as the default fallback, matching
/// `tasks_list.zig`'s defensive pattern; see Task 3.2's
/// `parseInput` for the rationale).
pub const FrontendLogGetError = error{
    /// `nalarcore.getSingleton()` failed (server has not been
    /// initialised yet). Maps to 500.
    ServerNotInitialized,
    /// `level` query param value is not in the whitelist. Maps to 400.
    InvalidLevel,
    /// `kind` query param value is not in the whitelist. Maps to 400.
    InvalidKind,
    /// `limit` query param is < 1 or > 1000. Maps to 400.
    InvalidLimit,
    /// DB read failed. Maps to 500.
    QueryFailed,
    /// Building the response JSON failed (OOM, in practice unreachable
    /// because the per-request arena reaps everything). Maps to 500.
    OutOfMemory,
};

// =====================================================================
// Input / output types
// =====================================================================

/// Parsed query-string input for `GET /api/logs`. All fields are
/// optional (null when absent); `limit` has a default.
pub const FrontendLogGetInput = struct {
    level: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    /// Microseconds — null when no `since` was supplied. Stored as
    /// i64 because SQLite's `created_at` column is INTEGER microseconds.
    since_us: ?i64 = null,
    /// Already clamped to [1, 1000]. Defaults to 100.
    limit: u32 = DEFAULT_LIMIT,
};

/// Output of the use-case: pre-serialized JSON body (lives in the
/// per-request arena; the caller does NOT free).
pub const FrontendLogGetOutput = struct {
    json_body: []const u8,
};

// =====================================================================
// Parse input
// =====================================================================

/// Pure function: pull the 5 query params out of `req.query` and
/// return a typed `FrontendLogGetInput`. Whitelist-validates
/// `level` and `kind`; clamps `limit`. `since` is parsed as i64
/// with a defensive fallback (non-numeric → null, treated as
/// "no filter" — matches the project's `parseInt catch default`
/// convention; see `tasks_list.zig:67`).
fn parseInput(query: std.StringHashMap([]const u8)) FrontendLogGetError!FrontendLogGetInput {
    // level: present+non-empty → validate whitelist; absent/empty → null.
    if (query.get("level")) |lv| {
        if (lv.len > 0) {
            if (!isValidLevel(lv)) return error.InvalidLevel;
        }
    }

    // kind: same shape as level.
    if (query.get("kind")) |k| {
        if (k.len > 0) {
            if (!isValidKind(k)) return error.InvalidKind;
        }
    }

    // session_id: no validation, just pass through.
    const session_id = query.get("session_id");
    const session_id_opt: ?[]const u8 = if (session_id) |s| (if (s.len == 0) null else s) else null;

    // since: parse as i64, defensive fallback to null on any failure.
    // Project convention (see `tasks_list.zig:67`) treats parse
    // failures as the default value rather than a hard error.
    const since_str = query.get("since");
    const since_opt: ?i64 = blk: {
        const s = since_str orelse break :blk null;
        if (s.len == 0) break :blk null;
        break :blk std.fmt.parseInt(i64, s, 10) catch null;
    };

    // limit: default 100, clamp to [1, 1000]. Note we deliberately
    // distinguish "absent" (use default) from "invalid" (return
    // InvalidLimit so the LLM sees a hint) — the design doc says
    // 400 for invalid limits, and our static test asserts the
    // literal "1000" cap is in the source.
    const limit_str = query.get("limit");
    const limit: u32 = blk: {
        const s = limit_str orelse break :blk DEFAULT_LIMIT;
        if (s.len == 0) break :blk DEFAULT_LIMIT;
        const parsed = std.fmt.parseInt(u32, s, 10) catch return error.InvalidLimit;
        if (parsed == 0) return error.InvalidLimit;
        if (parsed > MAX_LIMIT) return error.InvalidLimit;
        break :blk parsed;
    };

    return FrontendLogGetInput{
        .level = query.get("level"),
        .kind = query.get("kind"),
        .session_id = session_id_opt,
        .since_us = since_opt,
        .limit = limit,
    };
}

// =====================================================================
// Use case
// =====================================================================

/// Resolve the singleton, build + execute the SELECT, map rows to
/// `FrontendLogRow`, and return the pre-serialized JSON.
fn useCase(
    allocator: std.mem.Allocator,
    input: FrontendLogGetInput,
) FrontendLogGetError!FrontendLogGetOutput {
    const di = nalarcore.getSingleton() catch return error.ServerNotInitialized;
    const db = di.db;

    // Build the SQL string dynamically. We always include
    // `WHERE 1=1` so subsequent optional filters can append
    // `AND ...` uniformly. The bind positions are fixed:
    //   1. level  (if present)
    //   2. kind   (if present)
    //   3. session_id (if present)
    //   4. since (if present)
    //   5. limit  (always — required by SQL)
    // The limit is always bound as the LAST arg; if no other
    // filters were added, it's the only arg.
    var sql_buf = std.ArrayList(u8).empty;
    defer sql_buf.deinit(allocator);
    try sql_buf.appendSlice(
        allocator,
        \\SELECT id, created_at, level, kind, message,
        \\       stack, source, line, route_path, session_id, count
        \\FROM logs
        \\WHERE 1=1
    );

    // Track which filters are present so we know what to bind.
    // `limit` is always present at the end; the others are optional.
    var present_level: bool = false;
    var present_kind: bool = false;
    var present_session: bool = false;
    var present_since: bool = false;

    if (input.level) |lv| {
        if (lv.len > 0) {
            try sql_buf.appendSlice(allocator, "\n  AND level = ?");
            present_level = true;
        }
    }
    if (input.kind) |k| {
        if (k.len > 0) {
            try sql_buf.appendSlice(allocator, "\n  AND kind = ?");
            present_kind = true;
        }
    }
    if (input.session_id) |_| {
        try sql_buf.appendSlice(allocator, "\n  AND session_id = ?");
        present_session = true;
    }
    if (input.since_us) |_| {
        try sql_buf.appendSlice(allocator, "\n  AND created_at >= ?");
        present_since = true;
    }

    try sql_buf.appendSlice(allocator, "\nORDER BY created_at DESC\nLIMIT ?");

    // Format i64 / u32 values as decimal strings BEFORE binding —
    // `db.exec` / `db.query` only bind TEXT, and SQLite coerces
    // numeric-looking text to INTEGER under INTEGER affinity
    // (verified via :memory: round-trip — project memory
    // `nalar-sqlite-exec-binds-text-only`).
    //
    // `since_str` is conditionally allocated — only when `since_us`
    // was supplied. For empty binds (no filter), we use `""` which
    // the SQLite wrapper treats as NULL (memory
    // `sqlite-backend-empty-slice-binds-as-null`) — but we DON'T
    // need to pass anything for absent filters because the
    // `present_*` flags align the bind count with the SQL `?` count.
    const since_str = if (input.since_us) |us| blk: {
        const s = try std.fmt.allocPrint(allocator, "{d}", .{us});
        break :blk s;
    } else null;
    defer if (since_str) |s| allocator.free(s);

    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{input.limit});
    defer allocator.free(limit_str);

    // Build the bind slice. SQLite binds arguments positionally to
    // `?` placeholders; the ORDER here must match the SQL build
    // above exactly. The conditional `if (present_X) X_str` keeps
    // the bind list aligned with the SQL placeholders.
    // We allocate `args` on the heap (not a stack array) because
    // the count varies; a `std.ArrayList([]const u8)` keeps the
    // pattern straightforward.
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    if (present_level) {
        if (input.level) |lv| try args.append(allocator, lv);
    }
    if (present_kind) {
        if (input.kind) |k| try args.append(allocator, k);
    }
    if (present_session) {
        if (input.session_id) |sid| try args.append(allocator, sid);
    }
    if (present_since) {
        if (since_str) |s| try args.append(allocator, s);
    }
    try args.append(allocator, limit_str);

    // Run the query. The `sqlite.query` helper returns a
    // `Rows` iterator whose `.next()` returns `!?Row`.
    // Per-request arena reaps everything; no manual `deinit` of
    // `row.values[i]` needed (project memory
    // `custom-http-server-per-request-arena`).
    var rows = db.query(allocator, sql_buf.items, args.items) catch return error.QueryFailed;
    defer rows.deinit();

    // Map rows to FrontendLogRow. We allocate a `std.ArrayList`
    // because the count varies; the slice it returns is borrowed
    // by `makeFrontendLogListResponse` (which `valueAlloc`s the
    // JSON, copying all the string bytes).
    var logs_list = std.ArrayList(http_response.FrontendLogRow).empty;
    defer logs_list.deinit(allocator);

    while (true) {
        const row_opt = try rows.next();
        const row = row_opt orelse break;
        // Empty slice from `row.values[i]` corresponds to NULL on
        // a nullable column (project memory
        // `sqlite-backend-empty-slice-binds-as-null`); non-empty
        // means a value (which may be the textual representation
        // of an INTEGER for `created_at`, `line`, `count`).
        // Defensive `parseInt ... catch` returns 0 on any malformed
        // value — in practice all writes go through the use-case
        // which formats via `{d}`, so this is belt-and-suspenders.
        try logs_list.append(allocator, http_response.FrontendLogRow{
            .id = row.values[0],
            .created_at = std.fmt.parseInt(i64, row.values[1], 10) catch 0,
            .level = row.values[2],
            .kind = row.values[3],
            .message = row.values[4],
            .stack = nullableText(row.values[5]),
            .source = nullableText(row.values[6]),
            .line = nullableInt(row.values[7]),
            .route_path = nullableText(row.values[8]),
            .session_id = nullableText(row.values[9]),
            .count = std.fmt.parseInt(i64, row.values[10], 10) catch 0,
        });
    }

    const json_body = http_response.makeFrontendLogListResponse(
        allocator,
        logs_list.items,
    ) catch return error.OutOfMemory;

    return .{ .json_body = json_body };
}

// =====================================================================
// Handler
// =====================================================================

pub fn frontendLogGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Parse query params — pass `req.query` directly (it's the
    // `StringHashMap([]const u8)` field on the request struct; see
    // `tasks_list.zig:210` for the same usage pattern).
    //
    // IMPORTANT: `parseInput`'s inferred error set is the NARROW set
    // {InvalidLevel, InvalidKind, InvalidLimit}. The wider
    // FrontendLogGetError variants (ServerNotInitialized /
    // QueryFailed / OutOfMemory) cannot be returned from parseInput
    // and are NOT valid arms here. Project memory
    // `zig-catch-narrows-error-set-before-switch` documents the trap.
    const input = parseInput(req.query) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidLevel => 400,
            error.InvalidKind => 400,
            error.InvalidLimit => 400,
        };
        const message: []const u8 = switch (err) {
            error.InvalidLevel => "level must be one of error, warn, info, debug",
            error.InvalidKind => "kind must be one of window_error, unhandled_rejection, console_error, console_warn",
            error.InvalidLimit => "limit must be between 1 and 1000",
        };
        // Use `std.log.warn` (NOT `std.log.err`) so this handler's
        // error path doesn't trigger `log_err_count > 0` in
        // `zig build test` (project memory
        // `zig-0.16-test-log-err-count`). User-input validation
        // errors are warnings, not programmer errors.
        std.log.warn("frontend_log_get: {s}", .{message});
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // useCase's inferred error set is {ServerNotInitialized, QueryFailed,
    // OutOfMemory}. The InvalidLevel/Kind/Limit variants cannot come
    // from useCase (validation already passed in parseInput) and are
    // not valid arms here.
    const outcome = useCase(allocator, input) catch |err| {
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.QueryFailed => "Failed to query logs",
            error.OutOfMemory => "Out of memory",
        };
        std.log.warn("frontend_log_get: {s}", .{message});
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = outcome.json_body });
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

/// Convert a TEXT column slice to a `?[]const u8` — empty slice is
/// treated as NULL (project memory
/// `sqlite-backend-empty-slice-binds-as-null`).
fn nullableText(v: []const u8) ?[]const u8 {
    return if (v.len == 0) null else v;
}

/// Convert an INTEGER column's textual representation to a `?i64` —
/// empty slice is NULL (matches the same convention as `nullableText`).
/// Defensive `parseInt catch null` covers any malformed value (in
/// practice all writes go through `frontend_log_post` which formats
/// via `std.fmt.allocPrint "{d}"`, so this is belt-and-suspenders).
fn nullableInt(v: []const u8) ?i64 {
    if (v.len == 0) return null;
    return std.fmt.parseInt(i64, v, 10) catch null;
}
