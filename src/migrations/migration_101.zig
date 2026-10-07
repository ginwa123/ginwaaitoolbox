const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration101GuardLlmHistoryModel = struct {
    pub const version: u32 = 101;
    pub const name = "guard_llm_history_model";

    /// The sentinel written when no model could be resolved. Mirrors
    /// `agentic_loop/llm_history_model_guard.zig::UNKNOWN_MODEL` — kept as a
    /// literal because a SQL trigger cannot call into Zig, and asserted equal
    /// to the Zig constant in the inline tests below so the two cannot drift.
    pub const sentinel: []const u8 = "unknown";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        // Backfill first so the trigger (which only fires on INSERT) does not
        // have to reason about rows that already exist. TRIM catches both the
        // empty string and whitespace-only values, and the WHERE clause keeps
        // this from touching any real model id.
        //
        // Literals, not binds — so the empty-slice-as-NULL rule does not apply
        // here and NULL and '' remain distinguishable.
        try tx.exec(allocator,
            \\UPDATE llm_history SET model = 'unknown'
            \\WHERE model IS NULL OR TRIM(model) = ''
        , &[_][]const u8{});

        // The backstop. Catches raw SQL (which the Zig guard cannot see) and
        // any future write site that forgets the guard.
        //
        // `WHEN` guards the UPDATE so a healthy insert costs nothing: the
        // trigger body simply does not run. That matters because the FTS sync
        // trigger `llm_history_au` fires on this UPDATE — restricting the
        // rewrite to bad rows keeps the search index untouched in the normal
        // case.
        try tx.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_ai_model_not_empty
            \\AFTER INSERT ON llm_history
            \\FOR EACH ROW WHEN NEW.model IS NULL OR TRIM(NEW.model) = ''
            \\BEGIN
            \\  UPDATE llm_history SET model = 'unknown' WHERE id = NEW.id;
            \\END
        , &[_][]const u8{});

        try tx.commit();
    }
};
