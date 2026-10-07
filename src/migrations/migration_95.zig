const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration095AddWorkspaceIdToAgentMemories = struct {
    pub const version: u32 = 95;
    pub const name = "add_workspace_id_to_agent_memories";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(.{ .db = db }, allocator, "agent_memories", "workspace_id", "workspace_id TEXT NOT NULL DEFAULT ''");

        // Every read path filters `workspace_id = ?` and the FTS path
        // orders by the join's own rank, so a leading `workspace_id`
        // column lets SQLite seek straight to the calling workspace's
        // rows instead of probing every FTS hit. `updated_at DESC` rides
        // along for the (still unused, but already indexed) "most recent
        // memories in this workspace" surface.
        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_agent_memories_workspace
            \\ON agent_memories(workspace_id, updated_at DESC)
        , &[_][]const u8{});
    }
};
