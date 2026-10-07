const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration035AddDiffViewColumns = struct {
    pub const version: u32 = 35;
    pub const name = "add_diffview_columns";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN diffview_before TEXT", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN diffview_after TEXT", &[_][]const u8{});
    }
};
