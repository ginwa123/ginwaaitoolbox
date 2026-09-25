const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;
const auth_common = @import("auth_common.zig");

pub const WorkspaceWithItemsResponse = struct {
    id: []const u8,
    name: []const u8,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    icon: []const u8 = "📁",
    items: []const WorkspaceItemWithTasksResponse,
    expanded: bool = false,
    /// Number of `workspace_items` rows for this workspace. Populated
    /// regardless of `is_include_items` (one GROUP BY query, no N+1)
    /// so a badge can render before/without the lazy items fetch.
    items_count: usize = 0,
};

pub const WorkspaceItemWithTasksResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    tasks: []const http_response.WorkspaceItemTaskResponse = &[_]http_response.WorkspaceItemTaskResponse{},
};

pub const WorkspacesListResponse = struct { workspaces: []WorkspaceWithItemsResponse };

pub const WorkspacesListError = error{
    OutOfMemory,
    DatabaseError,
};

/// GET /api/workspaces
/// Query params:
///   - is_include_items (default: "true") — when "false", skip the workspace_items
///     and workspace_item_tasks queries and return `items: []` for each workspace.
///
/// Every workspace row carries `items_count` (its `workspace_items`
/// row count) either way — computed from one grouped query, so the
/// badge stays cheap even when the items themselves are lazy-loaded.
pub fn workspacesListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Parse is_include_items parameter (default: true = include items + tasks)
    const is_include_items_str = req.query.get("is_include_items") orelse "true";
    const is_include_items = std.mem.eql(u8, is_include_items_str, "true");

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    // Scope the list to this request's owner (server-derived from the
    // `nalar_session` cookie). Auth off / no cookie -> the shared sentinel,
    // which also matches every legacy row, so auth-off is unchanged.
    const owner = auth_common.resolveRequestUserId(allocator, sqlite_db, di.auth_enabled, req.headers) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
        });
    };
    defer allocator.free(owner);

    const response = useCase(allocator, sqlite_db, is_include_items, owner) catch |err| {
        const message: []const u8 = switch (err) {
            error.DatabaseError => "Failed to fetch workspaces",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try std.json.Stringify.valueAlloc(allocator, response, .{}) });
}

fn useCase(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, include_items: bool, owner: []const u8) WorkspacesListError!WorkspacesListResponse {
    return fetchWorkspacesList(alloc, db, include_items, owner) catch |err| {
        std.log.err("Failed to fetch workspaces: {s}", .{@errorName(err)});
        return error.DatabaseError;
    };
}

fn fetchWorkspacesList(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, include_items: bool, owner: []const u8) !WorkspacesListResponse {
    // Fetch the workspaces this request may see first. ORDER BY position DESC
    // drives the user-controlled drag-and-drop reorder (see
    // docs/plans/2026-06-12-workspace-drag-and-drop.md); created_at
    // DESC is a tiebreaker for any workspaces that share a position
    // (shouldn't happen post-reorder, but defense in depth).
    //
    // Every nested read below is keyed by ids from THIS result, so a
    // workspace's items/tasks are filtered transitively by the same owner
    // predicate and need no predicate of their own (see plan §Design D1).
    var rows = try db.query(
        alloc,
        "SELECT id, name, created_at, updated_at FROM workspaces WHERE " ++ comptime auth_common.ownerVisibilityClause("workspaces") ++ " ORDER BY position DESC, created_at DESC",
        &[_][]const u8{ owner, owner },
    );
    defer rows.deinit();

    var workspace_ids = std.ArrayList([]const u8).empty;
    defer workspace_ids.deinit(alloc);

    var workspaces_data = std.ArrayList(struct {
        id: []const u8,
        name: []const u8,
        created_at: ?[]const u8,
        updated_at: ?[]const u8,
    }).empty;
    defer workspaces_data.deinit(alloc);

    while (true) {
        const row_opt = try rows.next();
        const row = row_opt orelse break;

        const id = try alloc.dupe(u8, row.values[0]);
        try workspace_ids.append(alloc, id);
        try workspaces_data.append(alloc, .{
            .id = id,
            .name = try alloc.dupe(u8, row.values[1]),
            .created_at = if (row.values[2].len > 0) try alloc.dupe(u8, row.values[2]) else null,
            .updated_at = if (row.values[3].len > 0) try alloc.dupe(u8, row.values[3]) else null,
        });
        // Values are duped above; row memory is owned by the row.
        row.deinit(alloc);
    }

    // No workspaces? Return empty
    if (workspaces_data.items.len == 0) {
        return WorkspacesListResponse{ .workspaces = &[_]WorkspaceWithItemsResponse{} };
    }

    // Items count per workspace — ONE grouped query for all rows
    // (no N+1). Keys are duped because row memory dies with
    // row.deinit; freed with the map on function exit. Populated
    // for BOTH branches: the badge must not depend on
    // is_include_items.
    var items_count_by_ws: std.StringHashMap(usize) = .init(alloc);
    defer {
        var key_it = items_count_by_ws.keyIterator();
        while (key_it.next()) |k| alloc.free(k.*);
        items_count_by_ws.deinit();
    }
    {
        var count_rows = try db.query(alloc, "SELECT workspace_id, COUNT(*) FROM workspace_items GROUP BY workspace_id", &.{});
        defer count_rows.deinit();
        while (try count_rows.next()) |row| {
            defer row.deinit(alloc);
            if (row.values[0].len == 0) continue;
            const key = try alloc.dupe(u8, row.values[0]);
            errdefer alloc.free(key);
            try items_count_by_ws.put(key, std.fmt.parseInt(usize, row.values[1], 10) catch 0);
        }
    }

    // Build final response
    var workspaces_list = std.ArrayList(WorkspaceWithItemsResponse).empty;

    if (include_items) {
        // Build IN clause for items query
        var in_clause = std.ArrayList(u8).empty;
        try in_clause.appendSlice(alloc, "(");
        for (workspace_ids.items, 0..) |_, i| {
            if (i > 0) try in_clause.appendSlice(alloc, ",");
            try in_clause.appendSlice(alloc, "?");
        }
        try in_clause.appendSlice(alloc, ")");

        // Fetch all items for these workspaces. Uses the
        // project's "always alias tables in SQL" convention —
        // see the cross-ref comment in
        // `llm_history.zig:listWorkspaceItems`. The `wi` alias
        // matches the short-single-letter pattern used elsewhere
        // (`h` for `llm_history`, `s` for `sessions`, etc.).
        const items_sql = try std.fmt.allocPrint(alloc, "SELECT wi.id, wi.workspace_id, wi.item_type, wi.name, wi.path, wi.created_at, wi.updated_at FROM workspace_items wi WHERE wi.workspace_id IN {s} ORDER BY wi.position DESC, wi.id ASC", .{in_clause.items});
        var items_rows = try db.query(alloc, items_sql, workspace_ids.items);

        // Collect items and their IDs
        var items_list = std.ArrayList(struct {
            id: []const u8,
            workspace_id: []const u8,
            item_type: []const u8,
            name: ?[]const u8,
            path: ?[]const u8,
            created_at: ?[]const u8,
            updated_at: ?[]const u8,
        }).empty;

        var item_ids = std.ArrayList([]const u8).empty;

        while (true) {
            const row_opt = try items_rows.next();
            const row = row_opt orelse break;

            const id = try alloc.dupe(u8, row.values[0]);
            try item_ids.append(alloc, id);
            try items_list.append(alloc, .{
                .id = id,
                .workspace_id = try alloc.dupe(u8, row.values[1]),
                .item_type = try alloc.dupe(u8, row.values[2]),
                .name = if (row.values[3].len > 0) try alloc.dupe(u8, row.values[3]) else null,
                .path = if (row.values[4].len > 0) try alloc.dupe(u8, row.values[4]) else null,
                .created_at = if (row.values[5].len > 0) try alloc.dupe(u8, row.values[5]) else null,
                .updated_at = if (row.values[6].len > 0) try alloc.dupe(u8, row.values[6]) else null,
            });
            row.deinit(alloc);
        }

        // Fetch all tasks for these items
        var tasks_by_item = std.StringHashMap(std.ArrayList(http_response.WorkspaceItemTaskResponse)).init(alloc);

        if (item_ids.items.len > 0) {
            // Build IN clause for tasks query
            var task_in_clause = std.ArrayList(u8).empty;
            try task_in_clause.appendSlice(alloc, "(");
            for (item_ids.items, 0..) |_, i| {
                if (i > 0) try task_in_clause.appendSlice(alloc, ",");
                try task_in_clause.appendSlice(alloc, "?");
            }
            try task_in_clause.appendSlice(alloc, ")");

            // Migration 062: added `description` to the SELECT column list
            // (right after `workspace_item_id`). All subsequent indices shift
            // by one.
            // Auto-retry-until-stop: LEFT JOIN sessions on id (task.id
            // == session.id for routine tasks per the project
            // convention; standard tasks get NULL → COALESCE to '0').
            // Adds 1 column to the SELECT list and shifts pinned_position
            // to index 8 (previously 7).
            // Migration 067: added `t.tags` (JSON-encoded array of tag
            // strings) at index 9. NOT NULL DEFAULT '' so always
            // present. shifts no other columns (appsended at the end).
            const tasks_sql = try std.fmt.allocPrint(alloc, "SELECT t.id, t.name, t.workspace_item_id, t.description, t.created_at, t.updated_at, COALESCE(t.is_pinned, 0), COALESCE(t.pinned_position, 0), COALESCE(s.is_auto_retry_until_stop, '0'), t.tags FROM workspace_item_tasks t LEFT JOIN sessions s ON s.id = t.id WHERE t.workspace_item_id IN {s} ORDER BY t.is_pinned DESC, t.pinned_position DESC, t.created_at DESC", .{task_in_clause.items});
            var tasks_rows = try db.query(alloc, tasks_sql, item_ids.items);

            while (true) {
                const row_opt = try tasks_rows.next();
                const row = row_opt orelse break;

                const item_id = try alloc.dupe(u8, row.values[2]);
                const gop = try tasks_by_item.getOrPutValue(item_id, std.ArrayList(http_response.WorkspaceItemTaskResponse).empty);
                try gop.value_ptr.*.append(alloc, http_response.WorkspaceItemTaskResponse{
                    .id = try alloc.dupe(u8, row.values[0]),
                    .name = try alloc.dupe(u8, row.values[1]),
                    .workspace_item_id = item_id,
                    // Migration 062: description at index 3.
                    .description = try alloc.dupe(u8, row.values[3]),
                    .created_at = if (row.values[4].len > 0) try alloc.dupe(u8, row.values[4]) else null,
                    .updated_at = if (row.values[5].len > 0) try alloc.dupe(u8, row.values[5]) else null,
                    .is_pinned = std.mem.eql(u8, row.values[6], "1"),
                    .pinned_position = std.fmt.parseInt(i64, row.values[7], 10) catch 0,
                    // Auto-retry-until-stop: index 8 (joined from sessions).
                    .is_auto_retry_until_stop = try alloc.dupe(u8, row.values[8]),
                    // Migration 067: tags at index 9 (JSON-encoded array
                    // string). Empty string = no tags. Borrowed from the
                    // per-request arena; arena reaps it on teardown.
                    .tags = try alloc.dupe(u8, row.values[9]),
                });
                row.deinit(alloc);
            }
        }

        for (workspaces_data.items) |ws| {
            // Find items for this workspace
            var workspace_items = std.ArrayList(WorkspaceItemWithTasksResponse).empty;

            for (items_list.items) |item| {
                if (std.mem.eql(u8, item.workspace_id, ws.id)) {
                    // Get tasks for this item
                    var tasks_slice: []const http_response.WorkspaceItemTaskResponse = &[_]http_response.WorkspaceItemTaskResponse{};
                    if (tasks_by_item.getEntry(item.id)) |entry| {
                        tasks_slice = try entry.value_ptr.*.toOwnedSlice(alloc);
                    }

                    try workspace_items.append(alloc, .{
                        .id = item.id,
                        .workspace_id = item.workspace_id,
                        .item_type = item.item_type,
                        .name = item.name,
                        .path = item.path,
                        .created_at = item.created_at,
                        .updated_at = item.updated_at,
                        .tasks = tasks_slice,
                    });
                }
            }

            try workspaces_list.append(alloc, .{
                .id = ws.id,
                .name = ws.name,
                .created_at = ws.created_at,
                .updated_at = ws.updated_at,
                .icon = "📁",
                .items = try workspace_items.toOwnedSlice(alloc),
                .expanded = false,
                .items_count = items_count_by_ws.get(ws.id) orelse 0,
            });
        }
    } else {
        // Caller asked to skip items: emit workspaces with empty items array
        for (workspaces_data.items) |ws| {
            try workspaces_list.append(alloc, .{
                .id = ws.id,
                .name = ws.name,
                .created_at = ws.created_at,
                .updated_at = ws.updated_at,
                .icon = "📁",
                .items = &[_]WorkspaceItemWithTasksResponse{},
                .expanded = false,
                .items_count = items_count_by_ws.get(ws.id) orelse 0,
            });
        }
    }

    return WorkspacesListResponse{
        .workspaces = try workspaces_list.toOwnedSlice(alloc),
    };
}

// =====================================================================
// Tests — items_count (workspace-scoped sessions plan)
// =====================================================================
//
// Exercises the is_include_items=false branch directly (that branch
// is leak-clean under testing.allocator). The include_items=true
// branch's items_count is guarded over the wire by
// tests/functional/session_list_workspace_test.py.

const testing = std.testing;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  created_at DATETIME,
        \\  updated_at DATETIME,
        \\  position INTEGER,
        \\  user_id TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER,
        \\  created_at DATETIME,
        \\  updated_at DATETIME
        \\)
    , &.{});

    // ws_1 has 2 items, ws_2 has 1, ws_3 has none (badge = 0).
    try db.exec(alloc,
        \\INSERT INTO workspaces (id, name, created_at, updated_at, position) VALUES
        \\  ('ws_1', 'One', datetime('now'), datetime('now'), 2),
        \\  ('ws_2', 'Two', datetime('now'), datetime('now'), 1),
        \\  ('ws_3', 'Three', datetime('now'), datetime('now'), 0)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) VALUES
        \\  ('i1', 'ws_1', 'kanban', 'K1', '/p/1', 0, datetime('now'), datetime('now')),
        \\  ('i2', 'ws_1', 'folder', 'F1', '', 1, datetime('now'), datetime('now')),
        \\  ('i3', 'ws_2', 'kanban', 'K2', '/p/2', 0, datetime('now'), datetime('now'))
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

/// Free every allocation fetchWorkspacesList hands back for the
/// is_include_items=false shape (the items slice is a static empty
/// literal — free() no-ops on zero-length slices).
fn freeResponse(response: WorkspacesListResponse) void {
    const alloc = testing.allocator;
    for (response.workspaces) |ws| {
        alloc.free(ws.id);
        alloc.free(ws.name);
        if (ws.created_at) |v| alloc.free(v);
        if (ws.updated_at) |v| alloc.free(v);
        alloc.free(ws.items);
    }
    alloc.free(response.workspaces);
}

test "fetchWorkspacesList: items_count is populated even when items are skipped" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    const response = try fetchWorkspacesList(alloc, &ctx.db, false, auth_common.system_user_id);
    defer freeResponse(response);

    try testing.expectEqual(@as(usize, 3), response.workspaces.len);

    var checked: usize = 0;
    for (response.workspaces) |ws| {
        // Items were skipped — the badge must still be accurate.
        try testing.expectEqual(@as(usize, 0), ws.items.len);
        if (std.mem.eql(u8, ws.id, "ws_1")) {
            try testing.expectEqual(@as(usize, 2), ws.items_count);
            checked += 1;
        } else if (std.mem.eql(u8, ws.id, "ws_2")) {
            try testing.expectEqual(@as(usize, 1), ws.items_count);
            checked += 1;
        } else if (std.mem.eql(u8, ws.id, "ws_3")) {
            try testing.expectEqual(@as(usize, 0), ws.items_count);
            checked += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), checked);
}

test "fetchWorkspacesList: another user's workspace is invisible; the shared legacy bucket is not" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    // The fixture rows carry `user_id = NULL` (legacy). Add one workspace
    // owned by a real user and one owned by the sentinel.
    try ctx.db.exec(alloc,
        \\INSERT INTO workspaces (id, name, created_at, updated_at, position, user_id) VALUES
        \\  ('ws_b', 'B only', datetime('now'), datetime('now'), 3, 'user_b'),
        \\  ('ws_sys', 'Sentinel', datetime('now'), datetime('now'), 4, 'user_system')
    , &.{});

    // user_a sees the 3 legacy rows + the sentinel row — never ws_b.
    {
        const response = try fetchWorkspacesList(alloc, &ctx.db, false, "user_a");
        defer freeResponse(response);
        try testing.expectEqual(@as(usize, 4), response.workspaces.len);
        for (response.workspaces) |ws| {
            try testing.expect(!std.mem.eql(u8, ws.id, "ws_b"));
        }
    }

    // user_b sees their own row PLUS the shared bucket (legacy NULL rows and
    // the sentinel) — that is the whole point of the shared-bucket rule, so
    // the isolation claim is "A cannot see B's row", not "B sees only one".
    {
        const response = try fetchWorkspacesList(alloc, &ctx.db, false, "user_b");
        defer freeResponse(response);
        try testing.expectEqual(@as(usize, 5), response.workspaces.len);
        var saw_own = false;
        for (response.workspaces) |ws| {
            if (std.mem.eql(u8, ws.id, "ws_b")) saw_own = true;
        }
        try testing.expect(saw_own);
    }

    // The SYSTEM USER sees EVERYTHING (user decision 2026-09-25): with auth
    // off there is no identity and the system user IS the installation, so a
    // real user's row is visible here. ws_b must appear.
    {
        const response = try fetchWorkspacesList(alloc, &ctx.db, false, auth_common.system_user_id);
        defer freeResponse(response);
        try testing.expectEqual(@as(usize, 5), response.workspaces.len);
        var saw_ws_b = false;
        for (response.workspaces) |ws| {
            if (std.mem.eql(u8, ws.id, "ws_b")) saw_ws_b = true;
        }
        try testing.expect(saw_ws_b);
    }
}

