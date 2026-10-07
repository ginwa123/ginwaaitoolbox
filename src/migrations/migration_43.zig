const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration043AddPositionToWorkspaces = struct {
    pub const version: u32 = 43;
    pub const name = "add_position_to_workspaces";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Adds the `position` column to the workspaces table. The
        // column is the sort key for the sidebar's workspace list
        // — see docs/plans/2026-06-12-workspace-drag-and-drop.md.
        // New workspaces get position = MAX(position) + 1 (top of
        // the list, since workspaces_list.zig orders by position
        // DESC). The drag-and-drop reorder endpoint reassigns these
        // values to reflect the user's chosen order.
        try db.exec(allocator, "ALTER TABLE workspaces ADD COLUMN position INTEGER NOT NULL DEFAULT 0", &[_][]const u8{});

        // Backfill. Assign position N-1 to the newest workspace, 0 to
        // the oldest. With ORDER BY position DESC, the newest
        // workspace appears at the top of the list — same UX as the
        // previous ORDER BY created_at DESC. Uses a single UPDATE with
        // a correlated subquery; SQLite handles this efficiently on
        // the small workspaces table (handful of rows in practice).
        //
        // The formula: position = (number of workspaces OLDER than
        // this one). For the newest, all N-1 others are older, so
        // position = N-1 (top of the list). For the oldest, none are
        // older, so position = 0 (bottom of the list). The id
        // tiebreaker handles the rare case where two workspaces share
        // the same created_at second — without it, the COUNT
        // subquery would assign the same position to both rows.
        try db.exec(allocator,
            \\UPDATE workspaces
            \\SET position = (
            \\    SELECT COUNT(*)
            \\    FROM workspaces w2
            \\    WHERE w2.created_at < workspaces.created_at
            \\        OR (w2.created_at = workspaces.created_at AND w2.id > workspaces.id)
            \\)
        , &[_][]const u8{});

        // Index on position for the list endpoint's ORDER BY.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspaces_position ON workspaces(position DESC)", &[_][]const u8{});

        // ANALYZE so the query planner picks up the new index on
        // existing databases (without this, the planner may still
        // pick a full scan on pre-existing data).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
