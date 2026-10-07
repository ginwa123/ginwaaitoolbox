const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration049AddDefensiveIndexes = struct {
    pub const version: u32 = 49;
    pub const name = "add_defensive_indexes";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Defensive: covers listAllWorkspaceItems (llm_history.zig:2317)
        // which today has no callers. The query is
        // ORDER BY wi.position DESC, wi.id ASC with no WHERE. The
        // compound (position DESC, id ASC) makes it a single covering
        // index scan if a future "all items across all workspaces" view
        // invokes it. The id tiebreaker is the same one
        // Migration045AddPositionToWorkspaceItems uses on its backfill
        // UPDATE so index-backed ORDER BYs match that ordering.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspace_items_position_id " ++
            "ON workspace_items(position DESC, id ASC)",
            &[_][]const u8{});

        // Defensive: covers resetStuckRunning (routines/Scheduler.zig:51)
        // which runs once at startup. The WHERE on last_status='running'
        // has no index today. Acceptable while routines < 10 000 rows;
        // this index makes the future cost independent of table size.
        // Cardinality is tiny (a handful of distinct values: 'pending',
        // 'running', 'success', 'failed') but the index is still O(log N)
        // for the WHERE filter — meaningful once 'failed' rows accumulate
        // over months of operation.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_routines_last_status " ++
            "ON routines(last_status)",
            &[_][]const u8{});

        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
