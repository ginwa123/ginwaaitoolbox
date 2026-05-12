const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const http_response = nalarcore.http_response;

const httpz = http_server.httpz;

pub const WorkspaceWithItemsResponse = struct {
    id: []const u8,
    name: []const u8,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    icon: []const u8 = "📁",
    items: []const http_response.WorkspaceItemFullResponse,
    expanded: bool = false
};

pub const WorkspacesListResponse = struct {
    workspaces: []WorkspaceWithItemsResponse
};

/// GET /api/workspaces
pub fn workspacesListHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            // Fetch all workspaces first
            var rows = sqlite_db.query(alloc, "SELECT id, name, created_at, updated_at FROM workspaces ORDER BY created_at DESC", &[_][]const u8{}) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Database query failed" });
                return;
            };
            defer rows.deinit();

            // Collect workspace data first (id, name, timestamps)
            const WorkspaceData = struct {
                id: []const u8,
                name: []const u8,
                created_at: ?[]const u8,
                updated_at: ?[]const u8,
            };
            var workspace_data = std.ArrayList(WorkspaceData).empty;
            errdefer {
                for (workspace_data.items) |ws| {
                    alloc.free(ws.id);
                    alloc.free(ws.name);
                    if (ws.created_at) |ca| alloc.free(ca);
                    if (ws.updated_at) |ua| alloc.free(ua);
                }
                workspace_data.deinit(alloc);
            }

            while (true) {
                const row_opt = rows.next() catch {
                    res.status = 500;
                    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to iterate rows" });
                    return;
                };
                const row = row_opt orelse break;
                defer row.deinit(alloc);

                try workspace_data.append(alloc, .{
                    .id = try alloc.dupe(u8, row.values[0]),
                    .name = try alloc.dupe(u8, row.values[1]),
                    .created_at = if (row.values[2].len > 0) try alloc.dupe(u8, row.values[2]) else null,
                    .updated_at = if (row.values[3].len > 0) try alloc.dupe(u8, row.values[3]) else null,
                });
            }

            // No workspaces? Return empty
            if (workspace_data.items.len == 0) {
                const response = WorkspacesListResponse{ .workspaces = &[_]WorkspaceWithItemsResponse{} };
                res.status = 200;
                res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
                return;
            }

            // Collect workspace IDs for query first
            var workspace_ids = std.ArrayList([]const u8).empty;
            for (workspace_data.items) |ws| {
                try workspace_ids.append(alloc, ws.id);
            }
            errdefer {
                for (workspace_ids.items) |id| alloc.free(id);
                workspace_ids.deinit(alloc);
            }

            // Build IN clause for items query
            var in_clause = std.ArrayList(u8).empty;
            try in_clause.appendSlice(alloc, "(");
            var idx: usize = 0;
            while (idx < workspace_ids.items.len) : (idx += 1) {
                if (idx > 0) try in_clause.appendSlice(alloc, ",");
                try in_clause.appendSlice(alloc, "?");
            }
            try in_clause.appendSlice(alloc, ")");

            std.debug.print("DEBUG: workspace_ids count={}, in_clause={s}\n", .{workspace_ids.items.len, in_clause.items});

            // Fetch ALL items for these workspaces in ONE query
            const query_sql = try std.fmt.allocPrint(alloc,
                "SELECT id, workspace_id, item_type, name, path, created_at, updated_at FROM workspace_items WHERE workspace_id IN {s} ORDER BY created_at DESC",
                .{in_clause.items});

            var all_items = sqlite_db.query(alloc, query_sql, workspace_ids.items) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to fetch workspace items" });
                return;
            };
            defer all_items.deinit();

            std.debug.print("DEBUG: query executed, iterating rows\n", .{});

            // Group items by workspace_id
            var items_by_workspace = std.StringHashMap(std.ArrayList(http_response.WorkspaceItemFullResponse)).init(alloc);
            defer {
                var it = items_by_workspace.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.*.deinit(alloc);
                }
                items_by_workspace.deinit();
            }

            var item_count: usize = 0;
            while (true) {
                const row_opt = all_items.next() catch {
                    res.status = 500;
                    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to iterate items" });
                    return;
                };
                const row = row_opt orelse break;
                defer row.deinit(alloc);

                item_count += 1;

                // Duplicate the workspace_id key since row memory will be freed
                const ws_key = try alloc.dupe(u8, row.values[1]);
                const gop = items_by_workspace.getOrPutValue(ws_key, std.ArrayList(http_response.WorkspaceItemFullResponse).empty) catch continue;
                gop.value_ptr.append(alloc, .{
                    .id = try alloc.dupe(u8, row.values[0]),
                    .workspace_id = try alloc.dupe(u8, row.values[1]),
                    .item_type = try alloc.dupe(u8, row.values[2]),
                    .name = if (row.values[3].len > 0) try alloc.dupe(u8, row.values[3]) else null,
                    .path = if (row.values[4].len > 0) try alloc.dupe(u8, row.values[4]) else null,
                    .created_at = if (row.values[5].len > 0) try alloc.dupe(u8, row.values[5]) else null,
                    .updated_at = if (row.values[6].len > 0) try alloc.dupe(u8, row.values[6]) else null,
                }) catch {};
            }

            // Build final workspaces list with items attached
            var workspaces_list = std.ArrayList(WorkspaceWithItemsResponse).empty;
            errdefer workspaces_list.deinit(alloc);

            for (workspace_data.items) |ws| {
                var items_slice: []const http_response.WorkspaceItemFullResponse = &[_]http_response.WorkspaceItemFullResponse{};
                if (items_by_workspace.getEntry(ws.id)) |entry| {
                    items_slice = try entry.value_ptr.*.toOwnedSlice(alloc);
                }

                try workspaces_list.append(alloc, .{
                    .id = ws.id,
                    .name = ws.name,
                    .created_at = ws.created_at,
                    .updated_at = ws.updated_at,
                    .icon = "📁",
                    .items = items_slice,
                    .expanded = false,
                });
            }

            const response = WorkspacesListResponse{
                .workspaces = try workspaces_list.toOwnedSlice(alloc),
            };
            res.status = 200;
            res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}
