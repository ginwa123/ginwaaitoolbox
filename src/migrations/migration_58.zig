const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration058AddLlmHistoryFts = struct {
    pub const version: u32 = 58;
    pub const name = "add_llm_history_fts";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // FTS5 virtual table.
        //
        // IMPORTANT: we do NOT use external-content (`content='llm_history'`)
        // because the `snippet()` and `highlight()` FTS5 helper functions
        // return NULL for external-content and contentless tables — they
        // can only retrieve highlighted text from the FTS5 table itself.
        // The `searchMessagesFts` query returns a 10-token snippet with
        // `[match]` markers around matches, so we need the content
        // duplicated in messages_fts.
        //
        // Storage trade-off: ~2x storage for `response_content` (one copy
        // in llm_history, one copy in messages_fts). For a 1MB average
        // message and ~10K messages, that's ~10MB extra. Acceptable.
        try db.exec(allocator,
            \\CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            \\    content,
            \\    tokenize='porter unicode61 remove_diacritics 2'
            \\)
        , &[_][]const u8{});

        // Sync triggers: keep `messages_fts` in sync with `llm_history` rows.
        // The rowid linkage allows searchMessagesFts to JOIN back to
        // llm_history for id/session_id/role/timestamps.
        //
        // Note: we use plain DELETE FROM messages_fts WHERE rowid=... and
        // plain INSERT INTO messages_fts(rowid, content) for sync — NOT
        // the special `INSERT INTO messages_fts(messages_fts, rowid, content)
        // VALUES('delete', ...)` form, which is only valid for external-content
        // tables.
        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_ai AFTER INSERT ON llm_history BEGIN
            \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
            \\END
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_ad AFTER DELETE ON llm_history BEGIN
            \\  DELETE FROM messages_fts WHERE rowid = old.rowid;
            \\END
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_au AFTER UPDATE ON llm_history BEGIN
            \\  DELETE FROM messages_fts WHERE rowid = old.rowid;
            \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
            \\END
        , &[_][]const u8{});

        // Backfill: walk existing llm_history rows and INSERT into the
        // FTS table. For zero rows this is a no-op; for ~10K rows it's
        // ~10ms.
        try db.exec(allocator,
            \\INSERT INTO messages_fts(rowid, content)
            \\SELECT rowid, COALESCE(response_content, '')
            \\FROM llm_history
        , &[_][]const u8{});
    }
};
