const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;

pub const WorkspaceWithItemsResponse = struct { id: []const u8, name: []const u8, created_at: ?[]const u8 = null, updated_at: ?[]const u8 = null, icon: []const u8 = "📁", items: []const WorkspaceItemWithTasksResponse, expanded: bool = false };

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
pub fn workspacesListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Parse is_include_items parameter (default: true = include items + tasks)
    const is_include_items_str = req.query.get("is_include_items") orelse "true";
    const is_include_items = std.mem.eql(u8, is_include_items_str, "true");

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const response = useCase(allocator, sqlite_db, is_include_items) catch |err| {
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

fn useCase(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, include_items: bool) WorkspacesListError!WorkspacesListResponse {
    return fetchWorkspacesList(alloc, db, include_items) catch |err| {
        std.log.err("Failed to fetch workspaces: {s}", .{@errorName(err)});
        return error.DatabaseError;
    };
}

fn fetchWorkspacesList(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, include_items: bool) !WorkspacesListResponse {
    // Fetch all workspaces first. ORDER BY position DESC drives the
    // user-controlled drag-and-drop reorder (see
    // docs/plans/2026-06-12-workspace-drag-and-drop.md); created_at
    // DESC is a tiebreaker for any workspaces that share a position
    // (shouldn't happen post-reorder, but defense in depth).
    var rows = try db.query(alloc, "SELECT id, name, created_at, updated_at FROM workspaces ORDER BY position DESC, created_at DESC", &[_][]const u8{});

    var workspace_ids = std.ArrayList([]const u8).empty;

    var workspaces_data = std.ArrayList(struct {
        id: []const u8,
        name: []const u8,
        created_at: ?[]const u8,
        updated_at: ?[]const u8,
    }).empty;

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
    }

    // No workspaces? Return empty
    if (workspaces_data.items.len == 0) {
        return WorkspacesListResponse{ .workspaces = &[_]WorkspaceWithItemsResponse{} };
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

            const tasks_sql = try std.fmt.allocPrint(alloc, "SELECT id, name, workspace_item_id, created_at, updated_at, COALESCE(is_pinned, 0), COALESCE(pinned_position, 0) FROM workspace_item_tasks WHERE workspace_item_id IN {s} ORDER BY is_pinned DESC, pinned_position DESC, created_at DESC", .{task_in_clause.items});
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
                    .created_at = if (row.values[3].len > 0) try alloc.dupe(u8, row.values[3]) else null,
                    .updated_at = if (row.values[4].len > 0) try alloc.dupe(u8, row.values[4]) else null,
                    .is_pinned = std.mem.eql(u8, row.values[5], "1"),
                    .pinned_position = std.fmt.parseInt(i64, row.values[6], 10) catch 0,
                });
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
            });
        }
    }

    return WorkspacesListResponse{
        .workspaces = try workspaces_list.toOwnedSlice(alloc),
    };
}

