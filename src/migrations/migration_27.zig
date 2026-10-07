const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration027AddNameToWorkspaces = struct {
    pub const version: u32 = 27;
    pub const name = "add_name_to_workspaces";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE workspaces ADD COLUMN name TEXT NOT NULL DEFAULT ''", &[_][]const u8{});
    }
};
