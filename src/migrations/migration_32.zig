const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration032AddNamePathToWorkspaceItems = struct {
    pub const version: u32 = 32;
    pub const name = "add_name_path_to_workspace_items";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE workspace_items ADD COLUMN name TEXT", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE workspace_items ADD COLUMN path TEXT", &[_][]const u8{});
    }
};
