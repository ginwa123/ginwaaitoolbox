const std = @import("std");
const sqlite = @import("nalarcore").sqlite;

/// WorkspaceItemTask info for CRUD operations
pub const WorkspaceItemTaskInfo = struct {
    id: []u8,
    name: []u8,
    workspace_item_id: []u8,
    session_id: ?[]u8 = null,
    created_at: ?[]u8 = null,
    updated_at: ?[]u8 = null,

    pub fn deinit(self: WorkspaceItemTaskInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.workspace_item_id);
        if (self.session_id) |s| allocator.free(s);
        if (self.created_at) |ca| allocator.free(ca);
        if (self.updated_at) |ua| allocator.free(ua);
    }
};

/// Create a new workspace item task
pub fn createWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    session_id: ?[]const u8,
) !WorkspaceItemTaskInfo {
    if (session_id) |sid| {
        const sql = "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id) VALUES (?, ?, ?, ?)";
        try db.exec(allocator, sql, &.{ id, name, workspace_item_id, sid });
    } else {
        const sql = "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES (?, ?, ?)";
        try db.exec(allocator, sql, &.{ id, name, workspace_item_id });
    }

    return WorkspaceItemTaskInfo{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .workspace_item_id = try allocator.dupe(u8, workspace_item_id),
        .session_id = if (session_id) |s| try allocator.dupe(u8, s) else null,
    };
}

/// Get a workspace item task by id
pub fn getWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !?WorkspaceItemTaskInfo {
    const sql = "SELECT id, name, workspace_item_id, session_id, created_at, updated_at FROM workspace_item_tasks WHERE id = ?";

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            .session_id = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
        };
        row.deinit(allocator);
        return task;
    }

    return null;
}

/// Update workspace item task
pub fn updateWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    name: ?[]const u8,
    session_id: ?[]const u8,
) !void {
    if (name == null and session_id == null) {
        // Nothing to update
        return;
    }

    var set_clauses = std.ArrayList([]const u8).empty;
    var values = std.ArrayList([]const u8).empty;

    if (name) |n| {
        try set_clauses.append(allocator, "name = ?");
        try values.append(allocator, n);
    }

    if (session_id) |s| {
        try set_clauses.append(allocator, "session_id = ?");
        try values.append(allocator, s);
    }

    try values.append(allocator, id);

    var sql = std.ArrayList(u8).empty;
    try sql.appendSlice(allocator, "UPDATE workspace_item_tasks SET ");
    for (set_clauses.items, 0..) |clause, i| {
        if (i > 0) try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, clause);
    }
    try sql.appendSlice(allocator, ", updated_at = datetime('now') WHERE id = ?");

    try db.exec(allocator, sql.items, values.items);
}

/// Delete a workspace item task by id
pub fn deleteWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !void {
    const sql = "DELETE FROM workspace_item_tasks WHERE id = ?";
    try db.exec(allocator, sql, &.{id});
}

/// List all workspace item tasks by workspace_item_id
pub fn listWorkspaceItemTasks(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]WorkspaceItemTaskInfo {
    const sql = "SELECT id, name, workspace_item_id, session_id, created_at, updated_at FROM workspace_item_tasks WHERE workspace_item_id = ? ORDER BY created_at DESC";

    var rows = try db.query(allocator, sql, &.{workspace_item_id});
    defer rows.deinit();

    var tasks = std.ArrayList(WorkspaceItemTaskInfo).empty;
    errdefer {
        for (tasks.items) |task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            .session_id = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
        };
        try tasks.append(allocator, task);
        row.deinit(allocator);
    }

    return try tasks.toOwnedSlice(allocator);
}
