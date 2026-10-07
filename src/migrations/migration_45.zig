const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration045AddPositionToWorkspaceItems = struct {
    pub const version: u32 = 45;
    pub const name = "add_position_to_workspace_items";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Mirror of Migration043AddPositionToWorkspaces but scoped to
        // a single workspace's items. The new `position` column is
        // the sort key for the per-workspace item list (workspaces_list
        // returns items via workspace_items_get.zig which currently
        // does `ORDER BY created_at DESC`; we switch it to
        // `ORDER BY position DESC`). New items get
        // position = MAX(position) + 1 (top of the expanded workspace
        // list, since items are rendered top-to-bottom in DESC order).
        // The drag-and-drop reorder endpoint reassigns these values to
        // reflect the user's chosen order.
        try db.exec(allocator, "ALTER TABLE workspace_items ADD COLUMN position INTEGER NOT NULL DEFAULT 0", &[_][]const u8{});

        // Backfill. Per-workspace: the newest item gets the highest
        // position (so it appears at the TOP of the expanded list with
        // ORDER BY position DESC), the oldest gets position 0 (bottom).
        // This preserves the pre-existing visual order on upgrade.
        // The id tiebreaker (newer id > older id when timestamps tie) is
        // important so the backfill is deterministic when two items
        // share a created_at second.
        try db.exec(allocator,
            \\UPDATE workspace_items
            \\SET position = (
            \\    SELECT COUNT(*)
            \\    FROM workspace_items wi
            \\    WHERE wi.workspace_id = workspace_items.workspace_id
            \\        AND (wi.created_at > workspace_items.created_at
            \\            OR (wi.created_at = workspace_items.created_at AND wi.id > workspace_items.id))
            \\)
        , &[_][]const u8{});

        // Index on (workspace_id, position DESC) so the per-workspace
        // item list query uses an index even with hundreds of items
        // per workspace.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_items_workspace_position ON workspace_items(workspace_id, position DESC)", &[_][]const u8{});

        // Refresh query-planner stats (mirrors Migration043/044
        // pattern) so the new index is picked on pre-existing DBs.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
