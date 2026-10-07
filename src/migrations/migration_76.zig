const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration076CreateSessionPlan = struct {
    pub const version: u32 = 76;
    pub const name = "create_session_plan";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_plan (
            \\    session_id TEXT PRIMARY KEY,
            \\    plan_md TEXT NOT NULL DEFAULT '',
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});
        // No FK on session_id (matches session_activity Migration 073 precedent).
        // No index — session_id IS the PK, lookups are O(log n) by definition.
    }
};
