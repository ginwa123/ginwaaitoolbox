const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const http_response = nalarcore.http_response;
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

/// GET /api/workspaces
pub fn workspacesListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;

    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;

            const response = fetchWorkspacesList(allocator, sqlite_db) catch |err| {
                std.log.err("Failed to fetch workspaces: {s}", .{@errorName(err)});
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch workspaces" }) });
            };

            return res.jsonResponse(allocator, .{ .status_code = 200, .data = try std.json.Stringify.valueAlloc(allocator, response, .{}) });
        }
    }
    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}

fn fetchWorkspacesList(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend) !WorkspacesListResponse {
    // Fetch all workspaces first
    var rows = try db.query(alloc, "SELECT id, name, created_at, updated_at FROM workspaces ORDER BY created_at DESC", &[_][]const u8{});

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

    // Build IN clause for items query
    var in_clause = std.ArrayList(u8).empty;
    try in_clause.appendSlice(alloc, "(");
    for (workspace_ids.items, 0..) |_, i| {
        if (i > 0) try in_clause.appendSlice(alloc, ",");
        try in_clause.appendSlice(alloc, "?");
    }
    try in_clause.appendSlice(alloc, ")");

    // Fetch all items for these workspaces
    const items_sql = try std.fmt.allocPrint(alloc, "SELECT id, workspace_id, item_type, name, path, created_at, updated_at FROM workspace_items WHERE workspace_id IN {s} ORDER BY created_at DESC", .{in_clause.items});
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

        const tasks_sql = try std.fmt.allocPrint(alloc, "SELECT id, name, workspace_item_id, session_id, created_at, updated_at FROM workspace_item_tasks WHERE workspace_item_id IN {s} ORDER BY created_at DESC", .{task_in_clause.items});
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
                .session_id = if (row.values[3].len > 0) try alloc.dupe(u8, row.values[3]) else null,
                .created_at = if (row.values[4].len > 0) try alloc.dupe(u8, row.values[4]) else null,
                .updated_at = if (row.values[5].len > 0) try alloc.dupe(u8, row.values[5]) else null,
            });
        }
    }

    // Build final response
    var workspaces_list = std.ArrayList(WorkspaceWithItemsResponse).empty;

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

    return WorkspacesListResponse{
        .workspaces = try workspaces_list.toOwnedSlice(alloc),
    };
}