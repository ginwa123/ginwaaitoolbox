const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 104 - Add `sessions.is_pinned` + `sessions.pinned_position`.
///
/// Powers the PINNED section above RECENT in the sidebar. Right-clicking a
/// session (global recents list or kanban task row, where task.id ==
/// session_id) pins it; pinned rows render in their own section and stay
/// out of the recents sort.
///
/// Mirrors Migration 050 (workspace_item_tasks.is_pinned/pinned_position):
/// INTEGER 0/1 flag + INTEGER position, COALESCE'd to 0 at the SELECT
/// boundary so legacy rows read as unpinned. New pins bump to MAX+1 so
/// they land at the bottom of the pinned region; unpins reset to 0.
pub const Migration104AddSessionPinned = struct {
    pub const version: u32 = 104;
    pub const name = "add_session_pinned";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "is_pinned",
            "is_pinned INTEGER NOT NULL DEFAULT 0",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "pinned_position",
            "pinned_position INTEGER NOT NULL DEFAULT 0",
        );
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_sessions_pinned " ++
            "ON sessions(is_pinned DESC, pinned_position DESC)",
            &[_][]const u8{});
    }
};
