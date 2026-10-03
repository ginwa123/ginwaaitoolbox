//! `GET /api/workspaces/:id` — fetch a workspace by id.
//!
//! Layered as `useCase` (resolve singleton + read DB) and a thin
//! handler that maps the outcome + errors to status codes / JSON.
//!
//! Database errors include the SQLite error message in the response
//! body (e.g. "no such column: foo", "UNIQUE constraint failed:
//! workspaces.id") so the frontend can surface something useful to
//! the user instead of a bare "Database query failed" string. The
//! message is captured by `Sqlite.Rows.getLastErrorMessage()` (see
//! `src/modules/databases/src/sqlite/Sqlite.zig:303`).

const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const gserverz = nalarcore.gserverz;
const http_response = mod.http_response;
const auth_common = @import("auth_common.zig");

/// SQLite error info surfaced from the use-case to the handler.
/// `sqlite_message` is the raw `sqlite3_errmsg(db)` string for the
/// failing operation (e.g. "no such column: foo", "UNIQUE constraint
/// failed: workspaces.id", "database is locked"). When the backend
/// could not capture a message (e.g. the Rows object was never
/// created), this is empty — the handler falls back to a generic
/// "Database query failed" prefix.
pub const DbErrorInfo = struct {
    sqlite_message: []const u8,
};

/// Tagged outcome of the workspace-get use-case.
pub const WorkspaceGetResult = union(enum) {
    found: WorkspaceGetData,
    not_found,
    /// The SQL query failed at the prepare/bind stage (Rows was never
    /// created, so no `sqlite3_errmsg` capture is available).
    query_failed: DbErrorInfo,
    /// `Rows.next()` returned an error after the Rows object was
    /// created; `sqlite_message` is the last `sqlite3_errmsg(db)`
    /// value (may be empty if the backend couldn't capture it).
    row_fetch_failed: DbErrorInfo,
    out_of_memory,
    id_required,
};

pub const WorkspaceGetData = struct {
    id: []const u8,
    name: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    id: []const u8,
    owner: []const u8,
) WorkspaceGetResult {
    if (id.len == 0) return .id_required;

    // `db.query` returns `Error!Rows`; on failure the Rows object is
    // never created, so we can't capture the SQLite error message.
    // We still map the well-known error codes to a tagged failure so
    // the handler can return a 500 with a useful prefix.
    var rows = db.query(
        allocator,
        "SELECT id, name, created_at, updated_at FROM workspaces WHERE id = ? AND " ++ comptime auth_common.workspaceVisibilityClause("workspaces"),
        &.{ id, owner, owner },
    ) catch |err| {
        // Build a best-effort message. The sqlite3_errmsg is not
        // available here because Rows was never created; surface
        // the error name as the fallback. The dupe can OOM, so we
        // catch it and downgrade to .out_of_memory (the caller
        // can't do anything useful with an error message inside
        // an OOM anyway).
        const fallback: []const u8 = @errorName(err);
        const duped = allocator.dupe(u8, fallback) catch return .out_of_memory;
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            else => .{ .query_failed = .{ .sqlite_message = duped } },
        };
    };
    defer rows.deinit();

    // `rows.next()` calls `sqlite3_errmsg` on failure and caches the
    // message in `Rows.last_error_msg`. We dup it before `rows.deinit`
    // so the handler can render it. If the capture fails (db closed,
    // OOM in the dupe), we fall back to an empty message — the
    // handler will see the error tag and render a generic 500.
    const row = (rows.next() catch {
        const captured = rows.getLastErrorMessage() orelse "";
        const duped = allocator.dupe(u8, captured) catch return .out_of_memory;
        return .{ .row_fetch_failed = .{ .sqlite_message = duped } };
    }) orelse return .not_found;

    // Dupe the strings BEFORE `rows.deinit()` fires below. Otherwise
    // the returned `WorkspaceGetData` carries slice headers into the
    // row's storage, and the handler's `std.fmt.allocPrint` reads
    // freed memory (0xAA bytes) when it formats `{data.id}`/`{data.name}`.
    // Pattern: `getWorkspaceItem` in `llm_history.zig` does the same
    // dupes explicitly. See `zig-slice-headers-across-defer-lifetimes`
    // skill for the rationale.
    //
    // `row.deinit(allocator)` is NOT called — `row.values[]` are
    // arena-allocated (via `db.query(allocator, ...)` above), so the
    // per-request arena frees them when its scope ends (see the
    // AGENTS.md "Per-request arena cleanup" lesson).
    return .{
        .found = .{
            .id = allocator.dupe(u8, row.values[0]) catch return .out_of_memory,
            .name = allocator.dupe(u8, row.values[1]) catch return .out_of_memory,
            .created_at = allocator.dupe(u8, row.values[2]) catch return .out_of_memory,
            .updated_at = allocator.dupe(u8, row.values[3]) catch return .out_of_memory,
        },
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn workspaceGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const id = req.params.get("id") orelse "";

    // Not-found (not 403) when the workspace belongs to another user, so a
    // caller cannot probe for the existence of someone else's ids.
    const owner = auth_common.resolveRequestUserId(allocator, sqlite_db, di.auth_enabled, req.headers) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
        });
    };
    defer allocator.free(owner);

    const outcome = useCase(allocator, sqlite_db, id, owner);

    switch (outcome) {
        .found => |data| {
            // The four strings are duped by useCase; the response body
            // copies them into a fresh allocation. No manual
            // `defer allocator.free(...)` is needed — `ctx.allocator`
            // is a per-request `ArenaAllocator` (see
            // `kabelweb/src/server/http_server.zig:349-362`); when
            // the request scope ends the arena `deinit()`s and frees
            // every arena-backed allocation in one shot.
            const body = try std.fmt.allocPrint(
                allocator,
                "{{\"id\":\"{s}\",\"name\":\"{s}\",\"created_at\":\"{s}\",\"updated_at\":\"{s}\"}}",
                .{ data.id, data.name, data.created_at, data.updated_at },
            );
            return res.jsonResponse(.{ .status_code = 200, .data = body });
        },
        .not_found => {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = "{\"error\":\"Workspace not found\"}",
            });
        },
        .id_required => {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "id required" }),
            });
        },
        .out_of_memory => {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
            });
        },
        .query_failed => |info| {
            // `info.sqlite_message` is duped by useCase but lives in
            // the per-request arena — freed when the request scope
            // ends (no manual `defer allocator.free` needed; see the
            // arena note on `.found` above).
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try std.fmt.allocPrint(
                    allocator,
                    "{{\"error\":\"Database query failed: {s}\"}}",
                    .{info.sqlite_message},
                ),
            });
        },
        .row_fetch_failed => |info| {
            // Two shapes: with a captured sqlite message (most common,
            // surfaces e.g. "no such column: foo") or without
            // (backend couldn't capture — generic fallback).
            const data = if (info.sqlite_message.len > 0)
                try std.fmt.allocPrint(
                    allocator,
                    "{{\"error\":\"Failed to fetch row: {s}\"}}",
                    .{info.sqlite_message},
                )
            else
                try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch row" });
            return res.jsonResponse(.{ .status_code = 500, .data = data });
        },
    }
}

// =====================================================================
// Tests
// =====================================================================

const testing = @import("std").testing;

test "workspaceGetError DbErrorInfo shape is plain" {
    // Sanity: the struct is a plain data type so the captured
    // sqlite message can be examined in tests without unwrapping.
    const info: DbErrorInfo = .{ .sqlite_message = "no such column: foo" };
    try testing.expectEqualStrings("no such column: foo", info.sqlite_message);
}

