//! `GET /api/sessions` — list sessions with cursor pagination.
//!
//! Optional query params: `limit` (default 50), `cursor` (pagination),
//! `cwd` (filter by working directory), `workspace_id` (scope the list
//! to one workspace's sessions — task-linked ∪ cwd-matched, resolved
//! via `workspace_scope`; fail-closed on empty/unknown ids),
//! `sort_by` (`created_at` or `updated_at`), `direction` (`asc` or
//! `desc`).
//!
//! Layered as `useCase` (resolve singleton + parse query + DB call +
//! build JSON) and a thin handler that maps errors to status codes.

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const llm_history = nalarcore.llm_history;

pub const SessionListError = error{
    QueryFailed,
    /// `buildSessionListJson` returns `![]u8` (its body uses
    /// `std.json.Stringify.valueAlloc` which can fail with
    /// `OutOfMemory`). Effectively unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const SessionListInput = struct {
    limit: u32,
    cursor: ?[]const u8,
    cwd: ?[]const u8,
    /// Raw `workspace_id` query param. null = param absent (global
    /// list); present (including empty "") = scope to that workspace.
    workspace_id: ?[]const u8,
    sort_field: llm_history.SessionSortField,
    sort_direction: llm_history.SessionSortDirection,
};

pub const SessionListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

/// Parse query params into the typed input.
fn parseInput(query: anytype) !SessionListInput {
    const limit_str = query.get("limit") orelse "50";
    const limit = std.fmt.parseInt(u32, limit_str, 10) catch 50;

    const sort_by_str = query.get("sort_by") orelse "created_at";
    const sort_field = llm_history.enumFromString(llm_history.SessionSortField, sort_by_str) catch .created_at;

    const direction_str = query.get("direction") orelse "desc";
    const sort_direction = llm_history.enumFromString(llm_history.SessionSortDirection, direction_str) catch .desc;

    return .{
        .limit = limit,
        .cursor = query.get("cursor"),
        .cwd = query.get("cwd"),
        .workspace_id = query.get("workspace_id"),
        .sort_field = sort_field,
        .sort_direction = sort_direction,
    };
}

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: SessionListInput,
) SessionListError!SessionListResult {
    // Workspace scope: resolve `workspace_id` into the concrete
    // session-id set (task-linked ∪ cwd-matched). An empty or
    // unknown workspace resolves to an EMPTY set, which
    // `getSessionListWithCursor` fails closed on (`1 = 0`) — the
    // endpoint never leaks another workspace's sessions.
    var scoped_ids: ?[][]u8 = null;
    defer if (scoped_ids) |ids| nalarcore.workspace_scope.freeSessionIds(allocator, ids);

    // Const view of the same ids ([][]u8 does not coerce to
    // []const []const u8 element-wise); pointer-shares the id
    // buffers owned by scoped_ids — no extra string copies.
    var scope_view = std.ArrayList([]const u8).empty;
    defer scope_view.deinit(allocator);

    if (input.workspace_id) |wid| {
        scoped_ids = nalarcore.workspace_scope.workspaceSessionIds(allocator, db, wid) catch return error.QueryFailed;
        if (scoped_ids) |ids| {
            for (ids) |id| scope_view.append(allocator, id) catch return error.OutOfMemory;
        }
    }
    const workspace_ids: ?[]const []const u8 = if (input.workspace_id != null) scope_view.items else null;

    const result = llm_history.getSessionListWithCursor(
        allocator,
        db,
        null,
        null,
        input.cwd,
        workspace_ids,
        input.limit,
        input.cursor,
        input.sort_field,
        input.sort_direction,
    ) catch return error.QueryFailed;
    defer {
        for (result.sessions) |s| s.deinit(allocator);
        allocator.free(result.sessions);
    }

    // has_more is true iff we got the full page back.
    const has_more = result.sessions.len == @as(usize, input.limit);

    // The cursor value is the last item's sort-field value
    // (created_at or updated_at depending on sort_field).
    const cursor_value: ?[]const u8 = if (result.sessions.len > 0)
        switch (input.sort_field) {
            .updated_at => result.sessions[result.sessions.len - 1].updated_at,
            else => result.sessions[result.sessions.len - 1].created_at,
        }
    else
        null;

    return try llm_history.buildSessionListJson(
        allocator,
        result.sessions,
        result.total,
        has_more,
        cursor_value,
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn sessionListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const input = parseInput(req.query) catch |err| {
        // Today `parseInput` never returns an error (parseInt with
        // catch defaults; enumFromString with catch defaults). Kept
        // for forward compatibility — if a future field gains a
        // strict parse, surface it as 400.
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
        });
    };

    const response = useCase(allocator, sqlite_db, input) catch |err| {
        const status: u16 = switch (err) {
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.QueryFailed => "Database query failed",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = response });
}

// =====================================================================
// Tests — workspace-scoped list end-to-end through the useCase
// =====================================================================
//
// The useCase is private, so same-file tests exercise the FULL path:
// workspace_id param → workspaceSessionIds resolution →
// getSessionListWithCursor (main + count) → buildSessionListJson.
// In-memory SQLite, mirroring workspace_scope.zig's setupDb style plus
// the column set the list SELECT expects.

const testing = std.testing;

const TestCtx = struct {
    db: nalarcore.sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: nalarcore.sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal schema: the columns the session-list SELECT reads plus
    // the workspace tables the scope resolver joins on.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT NOT NULL DEFAULT 'active',
        \\  cwd TEXT NOT NULL DEFAULT '',
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  selected_profile_model TEXT,
        \\  is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\  last_finish_reason TEXT,
        \\  last_human_touched_at_nano INTEGER
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT, agent TEXT)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    // Workspace A: item i_a (/proj/a) with task-linked sessions
    // task_a1 + task_a2, plus a plain chat cwd-matched under the
    // item path. Workspace B: item i_b (/proj/b) with task_b1.
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('i_a', 'A', 'kanban', 'Kanban A', '/proj/a', 1),
        \\       ('i_b', 'B', 'kanban', 'Kanban B', '/proj/b', 1)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id)
        \\VALUES ('task_a1', 'Task A1', 'i_a'),
        \\       ('task_a2', 'Task A2', 'i_a'),
        \\       ('task_b1', 'Task B1', 'i_b')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd) VALUES
        \\  ('task_a1', 'Task A1', '/proj/a'),
        \\  ('task_a2', 'Task A2', '/proj/a'),
        \\  ('plain_a', 'Plain chat under A', '/proj/a/sub'),
        \\  ('task_b1', 'Task B1', '/proj/b')
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn runUseCase(db: *nalarcore.sqlite.SqliteBackend, workspace_id: ?[]const u8) !SessionListResult {
    return useCase(testing.allocator, db, .{
        .limit = 50,
        .cursor = null,
        .cwd = null,
        .workspace_id = workspace_id,
        .sort_field = .created_at,
        .sort_direction = .desc,
    });
}

test "useCase: workspace_id=A returns exactly task-linked + cwd-matched sessions (total 3)" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    const json = try runUseCase(&ctx.db, "A");
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"task_a1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"task_a2\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"plain_a\"") != null);
    // Workspace B's session must not leak into A's scope.
    try testing.expect(std.mem.indexOf(u8, json, "task_b1") == null);
    // The count query must carry the same filter: 3, not the global 4.
    try testing.expect(std.mem.indexOf(u8, json, "\"total\":3") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"total\":4") == null);
}

test "useCase: workspace scoping is fail-closed and param-absent stays global" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    // B → only its own task session, total 1.
    {
        const json = try runUseCase(&ctx.db, "B");
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "task_b1") != null);
        try testing.expect(std.mem.indexOf(u8, json, "task_a1") == null);
        try testing.expect(std.mem.indexOf(u8, json, "plain_a") == null);
        try testing.expect(std.mem.indexOf(u8, json, "\"total\":1") != null);
    }

    // Unknown workspace → empty list + total 0 (fail closed).
    {
        const json = try runUseCase(&ctx.db, "nope");
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"sessions\":[]") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"total\":0") != null);
    }

    // Empty workspace_id (param present but "") → fail closed too.
    // Guards the `IN ()` / empty-bind bug classes: the resolver
    // returns an empty set, the SQL must stay valid with 0 rows.
    {
        const json = try runUseCase(&ctx.db, "");
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"sessions\":[]") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"total\":0") != null);
    }

    // Param absent (null) → global list unchanged (back-compat).
    {
        const json = try runUseCase(&ctx.db, null);
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"task_a1\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"task_a2\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"plain_a\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"task_b1\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"total\":4") != null);
    }
}
