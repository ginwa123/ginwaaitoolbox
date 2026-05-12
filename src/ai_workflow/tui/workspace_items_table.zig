const std = @import("std");
const sqlite = @import("nalarcore").sqlite;

/// WorkspaceItem info for CRUD operations
pub const WorkspaceItemInfo = struct {
    id: []u8,
    workspace_id: []u8,
    item_type: []u8,
    name: ?[]u8 = null,
    path: ?[]u8 = null,
    created_at: ?[]u8 = null,
    updated_at: ?[]u8 = null,

    pub fn deinit(self: WorkspaceItemInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.workspace_id);
        allocator.free(self.item_type);
        if (self.name) |n| allocator.free(n);
        if (self.path) |p| allocator.free(p);
        if (self.created_at) |ca| allocator.free(ca);
        if (self.updated_at) |ua| allocator.free(ua);
    }
};

/// Create a new workspace item
pub fn createWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
) !WorkspaceItemInfo {
    const sql = "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES (?, ?, ?)";
    try db.exec(allocator, sql, &.{ id, workspace_id, item_type });

    return WorkspaceItemInfo{
        .id = try allocator.dupe(u8, id),
        .workspace_id = try allocator.dupe(u8, workspace_id),
        .item_type = try allocator.dupe(u8, item_type),
    };
}

/// Get a workspace item by id
pub fn getWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !?WorkspaceItemInfo {
    const sql = "SELECT id, workspace_id, item_type, name, path, created_at, updated_at FROM workspace_items WHERE id = ?";

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const item = WorkspaceItemInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_id = try allocator.dupe(u8, row.values[1]),
            .item_type = try allocator.dupe(u8, row.values[2]),
            .name = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .path = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .created_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .updated_at = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else null,
        };
        row.deinit(allocator);
        return item;
    }

    return null;
}

/// Update workspace item
pub fn updateWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
) !void {
    const sql = "UPDATE workspace_items SET workspace_id = ?, item_type = ?, updated_at = datetime('now') WHERE id = ?";
    try db.exec(allocator, sql, &.{ workspace_id, item_type, id });
}

/// Delete a workspace item by id
pub fn deleteWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !void {
    const sql = "DELETE FROM workspace_items WHERE id = ?";
    try db.exec(allocator, sql, &.{id});
}

/// List all workspace items by workspace_id
pub fn listWorkspaceItems(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
) ![]WorkspaceItemInfo {
    const sql = "SELECT id, workspace_id, item_type, name, path, created_at, updated_at FROM workspace_items WHERE workspace_id = ? ORDER BY created_at DESC";

    var rows = try db.query(allocator, sql, &.{workspace_id});
    defer rows.deinit();

    var items = std.ArrayList(WorkspaceItemInfo).empty;
    errdefer {
        for (items.items) |item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const item = WorkspaceItemInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_id = try allocator.dupe(u8, row.values[1]),
            .item_type = try allocator.dupe(u8, row.values[2]),
            .name = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .path = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .created_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .updated_at = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else null,
        };
        try items.append(allocator, item);
        row.deinit(allocator);
    }

    return try items.toOwnedSlice(allocator);
}

/// List ALL workspace items (for N+1 fix)
pub fn listAllWorkspaceItems(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
) ![]WorkspaceItemInfo {
    const sql = "SELECT id, workspace_id, item_type, name, path, created_at, updated_at FROM workspace_items ORDER BY created_at DESC";

    var rows = try db.query(allocator, sql, &.{});
    defer rows.deinit();

    var items = std.ArrayList(WorkspaceItemInfo).empty;
    errdefer {
        for (items.items) |item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const item = WorkspaceItemInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_id = try allocator.dupe(u8, row.values[1]),
            .item_type = try allocator.dupe(u8, row.values[2]),
            .name = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .path = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .created_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .updated_at = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else null,
        };
        try items.append(allocator, item);
        row.deinit(allocator);
    }

    return try items.toOwnedSlice(allocator);
}
