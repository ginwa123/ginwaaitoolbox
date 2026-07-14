//! Static regression checks for Migration 058
//! (FTS5 virtual table on `llm_history` for the search-history rewrite).
//!
//! Why this file exists
//! ────────────────────
//! Migration 058 creates `messages_fts` (external-content FTS5 over
//! `llm_history.response_content`) plus 3 sync triggers. This file
//! verifies:
//!   1. The virtual table is created with the correct configuration
//!      (external content, porter+unicode61 tokenizer, content_rowid='rowid')
//!   2. Exactly 3 triggers exist on `llm_history` (INSERT/UPDATE/DELETE)
//!   3. Pre-existing rows in `llm_history` are backfilled into the FTS index
//!   4. New INSERTs into `llm_history` are auto-indexed (trigger fires)
//!   5. DELETEs from `llm_history` remove the row from the FTS index
//!
//! Why the test bootstraps with Migration001CreateLLMHistory
//! ──────────────────────────────────────────────────────────
//! Mirrors the migration_054_test.zig pattern — set up the minimum
//! pre-migration baseline (just `llm_history` itself), then apply the
//! migration. This isolates the migration's effect from any schema
//! interaction with Migrations 002..057 that may or may not have run on
//! production DBs.
//!
//! Why FTS5 MATCH ? with single-token words
//! ────────────────────────────────────────
//! FTS5 tokenizes input by default; bare ASCII words are safe queries.
//! Multi-word queries would require FTS5 expression syntax (AND, OR, "...",
//! prefix*) which would couple the test to the tokenizer's exact behavior.
//! Single-token MATCH keeps the contract tight: "the row containing word
//! W is in the FTS index".
//!
//! Plan: docs/superpowers/plans/2026-07-16-search-history-rewrite.md
//!   (Chunk 1, Task 1.3 — Migration 058 regression test)
//!
//! Versioning note: plan called this Migration 055 but the search-history-
//! rewrite branch already has AddDesignPages (55), UpgradeDesignPagesToFileModel
//! (56), AddDesignElementProperties (57). 058 is the next free slot.

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration001CreateLLMHistory = @import("migration.zig").Migration001CreateLLMHistory;
const Migration058AddLlmHistoryFts = @import("migration.zig").Migration058AddLlmHistoryFts;

/// Test fixture for the migration_058 test suite. Hoisted to a top-level named
/// struct (NOT inline anonymous) because Zig 0.16 treats two anonymous
/// `struct { db, threaded }` types as distinct types even with identical
/// fields — see project memory `zig-anonymous-struct-type-identity.md`.
const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with just the `llm_history` baseline table. This
/// matches the state of an existing-DB user right before Migration 058 runs
/// (i.e., after Migrations 001..057 have all applied).
fn setupDbWithLlmHistory() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration001CreateLLMHistory.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Count rows in `sqlite_master` of a given type, optionally matching
/// `tbl_name`. Returns 0 if no match. Helper for the trigger + table tests.
fn countSqliteMaster(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, sql: []const u8) !usize {
    var q = try db.query(alloc, sql, &[_][]const u8{});
    defer q.deinit();
    var count: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        count += 1;
    }
    return count;
}

test "migration 058: creates messages_fts virtual table" {
    // After Migration 058, `sqlite_master` must contain a row for
    // `messages_fts` with type='table' (FTS5 virtual tables show up as
    // 'table' rows in sqlite_master, not 'view' or 'index').
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, no `messages_fts` exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='messages_fts'",
            &[_][]const u8{},
        );
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have messages_fts
        }
    }

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // Post-migration: `messages_fts` exists as a table.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='messages_fts'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.VirtualTableNotCreated;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("messages_fts", row.values[0]);
}

test "migration 058: installs sync triggers (exactly 3 on llm_history)" {
    // The migration creates 3 triggers named llm_history_ai, _ad, _au.
    // After Migration 058, querying sqlite_master with
    // `tbl_name='llm_history'` AND `type='trigger'` must return exactly 3.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, zero triggers on llm_history.
    const pre_count = try countSqliteMaster(&ctx.db, alloc,
        "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='llm_history'");
    try testing.expectEqual(@as(usize, 0), pre_count);

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // Post-migration: exactly 3 triggers.
    const post_count = try countSqliteMaster(&ctx.db, alloc,
        "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='llm_history'");
    try testing.expectEqual(@as(usize, 3), post_count);

    // Verify the exact names (the migration uses _ai, _ad, _au).
    var names_buf: [3][]u8 = .{ &[_]u8{}, &[_]u8{}, &[_]u8{} };
    defer for (names_buf) |n| if (n.len > 0) alloc.free(n);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type='trigger' AND tbl_name='llm_history'
        \\ORDER BY name
    , &[_][]const u8{});
    defer q.deinit();
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < 3);
        names_buf[idx] = try alloc.dupe(u8, row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 3), idx);
    try testing.expectEqualStrings("llm_history_ad", names_buf[0]);
    try testing.expectEqualStrings("llm_history_ai", names_buf[1]);
    try testing.expectEqualStrings("llm_history_au", names_buf[2]);
}

test "migration 058: backfills existing rows into FTS index" {
    // Pre-existing rows must be backfilled into messages_fts during
    // migration. Insert 2 rows BEFORE the migration, run it, then verify
    // that FTS5 MATCH on a unique word from each row returns the row.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert 2 rows BEFORE the migration — uses Migration001's schema
    // (id, session_id, model, response_content). Note: the `id` column
    // is TEXT PRIMARY KEY so we pass explicit IDs.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('msg-pre-1', 'sess-1', 'm', 'first message contains zephyrword')",
        &[_][]const u8{},
    );
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('msg-pre-2', 'sess-2', 'm', 'second message contains quasarterm')",
        &[_][]const u8{},
    );

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // FTS MATCH on 'zephyrword' must return the row with id 'msg-pre-1'.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT h.id FROM llm_history h
            \\JOIN messages_fts f ON f.rowid = h.rowid
            \\WHERE messages_fts MATCH ?
        , &.{"zephyrword"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.BackfillMissingRow1;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("msg-pre-1", row.values[0]);

        // Should be only 1 row matching zephyrword.
        const extra = (try q.next()) orelse null;
        if (extra) |e| {
            defer e.deinit(alloc);
            try testing.expect(false); // zephyrword matched more than 1 row
        }
    }

    // FTS MATCH on 'quasarterm' must return the row with id 'msg-pre-2'.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT h.id FROM llm_history h
            \\JOIN messages_fts f ON f.rowid = h.rowid
            \\WHERE messages_fts MATCH ?
        , &.{"quasarterm"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.BackfillMissingRow2;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("msg-pre-2", row.values[0]);
    }
}

test "migration 058: INSERT trigger fires for new rows" {
    // After migration, INSERT INTO llm_history must auto-add to the FTS
    // index. Insert one new row AFTER migration; FTS MATCH must find it.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // Insert AFTER migration.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('msg-post-1', 'sess-1', 'm', 'post-migration message has deltaword')",
        &[_][]const u8{},
    );

    // FTS MATCH on 'deltaword' must return the new row.
    var q = try ctx.db.query(alloc,
        \\SELECT h.id FROM llm_history h
        \\JOIN messages_fts f ON f.rowid = h.rowid
        \\WHERE messages_fts MATCH ?
    , &.{"deltaword"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.InsertTriggerDidNotFire;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("msg-post-1", row.values[0]);
}

test "migration 058: DELETE trigger removes row from index" {
    // After migration, DELETE FROM llm_history must auto-remove from the
    // FTS index. Insert one row, delete it, then FTS MATCH must return
    // null (no rows match).
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('msg-del-1', 'sess-1', 'm', 'about to be deleted contains omegaword')",
        &[_][]const u8{},
    );

    // Sanity: the row IS indexed before deletion.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT h.id FROM llm_history h
            \\JOIN messages_fts f ON f.rowid = h.rowid
            \\WHERE messages_fts MATCH ?
        , &.{"omegaword"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowNotIndexedBeforeDelete;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("msg-del-1", row.values[0]);
    }

    // Delete the row.
    try ctx.db.exec(alloc,
        "DELETE FROM llm_history WHERE id = 'msg-del-1'",
        &[_][]const u8{},
    );

    // After deletion, FTS MATCH on the unique word must return null.
    var q = try ctx.db.query(alloc,
        \\SELECT h.id FROM llm_history h
        \\JOIN messages_fts f ON f.rowid = h.rowid
        \\WHERE messages_fts MATCH ?
    , &.{"omegaword"});
    defer q.deinit();
    const row = (try q.next()) orelse null;
    if (row) |r| {
        defer r.deinit(alloc);
        try testing.expect(false); // DELETE trigger did not fire — row still in index
    }
}