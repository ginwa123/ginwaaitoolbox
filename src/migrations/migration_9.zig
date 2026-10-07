const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration009RemoveCreatedColumn = struct {
    pub const version: u32 = 9;
    pub const name = "remove_created_column";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Rename old table
        try db.exec(allocator, "ALTER TABLE llm_history RENAME TO llm_history_old", &[_][]const u8{});

        // Create new table with `created_at` (the column this migration
        // was supposed to consolidate). Columns added by later migrations
        // (e.g. `temperature` / `is_thinking` from migration 011) MUST
        // NOT be inlined here — that forward-projects the schema and
        // causes a "duplicate column name" error when those migrations
        // later try to `ALTER TABLE ... ADD COLUMN` on a fresh DB.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS llm_history (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    model TEXT NOT NULL,
            \\    response_content TEXT,
            \\    tool_calls_json TEXT,
            \\    tool_results_json TEXT,
            \\    finish_reason TEXT,
            \\    usage_json TEXT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    role TEXT DEFAULT 'assistant',
            \\    reasoning_content TEXT,
            \\    session_dir TEXT,
            \\    is_feed_to_llm INTEGER DEFAULT 1,
            \\    agent TEXT DEFAULT 'Agent',
            \\    session_name TEXT,
            \\    loop_index INTEGER DEFAULT 0
            \\)
        , &[_][]const u8{});

        // Copy data from old table.
        //
        // NOTE on `created_at`: this migration's rename-and-copy dance
        // assumes the old table had a `created` column to convert into
        // `created_at`, but Migration 001 has always created
        // `llm_history` with `created_at` directly (no historical
        // `created` column ever existed in this codebase). Reading
        // `created` from `llm_history_old` therefore crashes the
        // migration on a fresh DB:
        //
        //   sqlite3_prepare_v2 error: no such column: created
        //
        // We use `COALESCE(created_at, CURRENT_TIMESTAMP)` instead. On
        // the (only) schema that actually exists, `created_at` is the
        // column on `llm_history_old`; the COALESCE fallback guards
        // against the (hypothetical) empty-table case where every
        // column is NULL — there are no rows to copy, but the function
        // still needs a well-typed projection.
        //
        // Columns added by later migrations (`temperature`,
        // `is_thinking` from migration 011; etc.) MUST NOT appear in
        // the INSERT column list or the SELECT projection — they're
        // not on `llm_history_old` (only added by their own migrations)
        // and the new `llm_history` no longer declares them either.
        try db.exec(allocator,
            \\INSERT INTO llm_history (id, session_id, model, response_content, tool_calls_json,
            \\    tool_results_json, finish_reason, usage_json, created_at, role,
            \\    reasoning_content, session_dir, is_feed_to_llm, agent, session_name, loop_index)
            \\SELECT id, session_id, model, response_content, tool_calls_json,
            \\    tool_results_json, finish_reason, usage_json,
            \\    COALESCE(created_at, CURRENT_TIMESTAMP),
            \\    COALESCE(role, 'assistant'), reasoning_content, session_dir,
            \\    COALESCE(is_feed_to_llm, 1), COALESCE(agent, 'Agent'),
            \\    session_name, COALESCE(loop_index, 0)
            \\FROM llm_history_old
        , &[_][]const u8{});

        // Recreate index
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_session ON llm_history(session_id)", &[_][]const u8{});

        // Drop old table
        try db.exec(allocator, "DROP TABLE llm_history_old", &[_][]const u8{});
    }
};
