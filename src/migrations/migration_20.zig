const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration020AddWorkerExtraFields = struct {
    pub const version: u32 = 20;
    pub const name = "add_worker_extra_fields";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // These columns are already part of migration 019's CREATE TABLE
        // (the canonical `worker` schema), so fresh-DB users would
        // crash with "duplicate column name" if we ran the ADD COLUMN
        // unconditionally. SQLite also doesn't support
        // `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` (the syntax errors
        // out at prepare time — see sqlite3_prepare_v2: "near
        // 'EXISTS': syntax error"), so we wrap each ADD COLUMN in a
        // pragma_table_info check.
        try addColumnIfMissing(.{ .db = db }, allocator, "worker", "working_directory", "working_directory TEXT");
        try addColumnIfMissing(.{ .db = db }, allocator, "worker", "last_activity", "last_activity INTEGER DEFAULT (strftime('%s', 'now'))");
        try addColumnIfMissing(.{ .db = db }, allocator, "worker", "last_activity_description", "last_activity_description TEXT");
    }
};
