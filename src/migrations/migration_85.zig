const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Per-session record of tools the agent enabled for itself through
/// `use_tool`. Session-scoped on purpose: enabling a tool here must never
/// touch the user's persistent `agent_tools` / `agent_kanban_tools`
/// configuration, and it reverts by starting a new session.
///
/// Shape mirrors `session_skills` (Migration 008). No `content` column —
/// tool definitions are code, so a definition change must take effect on
/// the next turn instead of being shadowed by a stale stored copy.
///
/// `PRIMARY KEY(session_id, tool_name)` is the DB-level half of the
/// "if it is already equipped, do not insert" rule; callers use
/// `INSERT OR IGNORE` and treat `false` as "already present".
///
/// Plan: docs/superpowers/plans/2026-09-12-progressive-tool-search.md
pub const Migration085AddSessionProgressiveTool = struct {
    pub const version: u32 = 85;
    pub const name = "add_session_progressive_tool";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_progressive_tool (
            \\    session_id TEXT NOT NULL,
            \\    tool_name TEXT NOT NULL,
            \\    server_name TEXT NOT NULL DEFAULT '',
            \\    loaded_at_nano INTEGER NOT NULL DEFAULT 0,
            \\    PRIMARY KEY (session_id, tool_name)
            \\)
        , &[_][]const u8{});

        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_session_progressive_tool_session ON session_progressive_tool(session_id)",
            &[_][]const u8{},
        );
    }
};
