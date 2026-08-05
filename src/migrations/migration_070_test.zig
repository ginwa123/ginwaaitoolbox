//! Behavioural regression checks for Migration 070
//! (`agent_memories` table + `agent_memories_fts` FTS5 virtual table).
//!
//! Why this file exists
//! ────────────────────
//! Migration 070 backs the new `save_memory` + `load_memory` agent tools.
//! It creates:
//!   - `agent_memories` — the source table (id PK, content, tags, timestamps)
//!   - `agent_memories_fts` — a non-external-content FTS5 virtual table
//!     over `content` + `tags` (content is duplicated so `snippet()` works,
//!     matching the existing `messages_fts` pattern from Migration 058)
//!   - 3 sync triggers (INSERT / DELETE / UPDATE) that keep the FTS index
//!     in lockstep with the source table
//!
//! Plan: docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md (Task 1)
//! Task: task_1785958319567 (save_memory + load_memory tools)
//!
//! Why non-external-content
//! ─────────────────────────
//! `snippet()` returns NULL for external-content FTS5 tables. The
//! `load_memory` tool needs snippets to render compact `<snippet>` blocks
//! (10 tokens with `[match]` markers). Duplicating content costs ~2x
//! storage but enables the only UX feature that matters here.
//!
//! Why FTS5 MATCH ? with single-token words
//! ─────────────────────────────────────────
//! Same rationale as migration_058_test.zig — multi-word queries would
//! couple the test to the tokenizer's exact behavior; single-token MATCH
//! keeps the contract tight: "the row containing word W is in the FTS
//! index".

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration070AddAgentMemories = @import("migration.zig").Migration070AddAgentMemories;

/// Test fixture. Hoisted to a top-level named struct (NOT inline anonymous)
/// because Zig 0.16 treats two anonymous `struct { db, threaded }` types as
/// distinct types even with identical fields — see project memory
/// `zig-anonymous-struct-type-identity.md`.
const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with the empty (pre-migration) state. After
/// Migration 070 runs, `agent_memories` exists and the FTS5 sync triggers
/// are installed.
fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

test "Migration070 creates agent_memories table with correct columns" {
    // After migration, `pragma_table_info('agent_memories')` must show
    // columns: id (TEXT PK), content (TEXT NOT NULL), tags (TEXT NOT NULL
    // DEFAULT ''), created_at (DATETIME DEFAULT CURRENT_TIMESTAMP),
    // updated_at (DATETIME DEFAULT CURRENT_TIMESTAMP).
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: table does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='agent_memories'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have agent_memories
        }
    }

    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    // Post-migration: table exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.AgentMemoriesTableNotCreated;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("agent_memories", row.values[0]);
    }

    // Verify the 5 expected columns exist with the expected names.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('agent_memories') ORDER BY cid",
        &.{});
    defer q.deinit();
    const expected_columns = [_][]const u8{ "id", "content", "tags", "created_at", "updated_at" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected_columns.len);
        try testing.expectEqualStrings(expected_columns[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected_columns.len), idx);
}

test "Migration070 is idempotent on a re-run" {
    // The migration's CREATE statements all use IF NOT EXISTS. A second
    // run must NOT crash with "table agent_memories already exists" or
    // similar errors.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration070AddAgentMemories.up(&ctx.db, alloc);
    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    // Still exactly 1 agent_memories table.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='agent_memories'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration070 creates agent_memories_fts FTS5 virtual table" {
    // After migration, `sqlite_master` must contain a row for
    // `agent_memories_fts` with type='table' (FTS5 virtual tables show
    // up as 'table' rows in sqlite_master, not 'view' or 'index').
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories_fts'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.FtsVirtualTableNotCreated;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("agent_memories_fts", row.values[0]);
}

test "Migration070 installs sync triggers (exactly 3 on agent_memories)" {
    // The migration creates 3 triggers: agent_memories_ai, _ad, _au.
    // After migration, querying sqlite_master with `tbl_name='agent_memories'`
    // AND `type='trigger'` must return exactly 3.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, zero triggers on agent_memories.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='agent_memories'",
            &.{});
        defer q.deinit();
        var pre_count: usize = 0;
        while (try q.next()) |row| {
            defer row.deinit(alloc);
            pre_count += 1;
        }
        try testing.expectEqual(@as(usize, 0), pre_count);
    }

    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    // Post-migration: exactly 3 triggers.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type='trigger' AND tbl_name='agent_memories'
        \\ORDER BY name
        , &.{});
    defer q.deinit();
    const names = [_][]const u8{ "agent_memories_ad", "agent_memories_ai", "agent_memories_au" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < names.len);
        try testing.expectEqualStrings(names[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, names.len), idx);
}

test "Migration070 sync triggers keep FTS5 in lockstep with source table" {
    // The whole point of the triggers is that INSERT/UPDATE/DELETE on
    // `agent_memories` auto-mirror into `agent_memories_fts`. Insert a
    // row, FTS5 MATCH on a unique word from it must return the row.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    // INSERT a row post-migration. The ai trigger should auto-add it to FTS5.
    try ctx.db.exec(alloc,
        \\INSERT INTO agent_memories (id, content, tags)
        \\VALUES ('mem-trig-1', 'this row contains zeppelinword for trigger test', 'preferences')
        , &.{});

    // FTS5 MATCH on the unique word must return the row.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT m.id FROM agent_memories m
            \\JOIN agent_memories_fts f ON f.rowid = m.rowid
            \\WHERE agent_memories_fts MATCH ?
            , &.{"zeppelinword"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.InsertTriggerDidNotFire;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("mem-trig-1", row.values[0]);
    }

    // UPDATE the content. The au trigger should remove the old FTS5 row
    // and insert the new one. The OLD word must NOT match; the NEW word must.
    try ctx.db.exec(alloc,
        \\UPDATE agent_memories SET content = 'updated content has quasarword now'
        \\WHERE id = 'mem-trig-1'
        , &.{});

    // Old word no longer matches (au trigger's DELETE part fired).
    {
        var q = try ctx.db.query(alloc,
            \\SELECT m.id FROM agent_memories m
            \\JOIN agent_memories_fts f ON f.rowid = m.rowid
            \\WHERE agent_memories_fts MATCH ?
            , &.{"zeppelinword"});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // UPDATE trigger DELETE part did not fire
        }
    }

    // New word matches (au trigger's INSERT part fired).
    {
        var q = try ctx.db.query(alloc,
            \\SELECT m.id FROM agent_memories m
            \\JOIN agent_memories_fts f ON f.rowid = m.rowid
            \\WHERE agent_memories_fts MATCH ?
            , &.{"quasarword"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.UpdateTriggerInsertPartDidNotFire;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("mem-trig-1", row.values[0]);
    }

    // DELETE the row. The ad trigger should remove it from FTS5.
    try ctx.db.exec(alloc,
        "DELETE FROM agent_memories WHERE id = 'mem-trig-1'",
        &.{});

    // New word no longer matches (ad trigger fired).
    {
        var q = try ctx.db.query(alloc,
            \\SELECT m.id FROM agent_memories m
            \\JOIN agent_memories_fts f ON f.rowid = m.rowid
            \\WHERE agent_memories_fts MATCH ?
            , &.{"quasarword"});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // DELETE trigger did not fire
        }
    }
}

test "Migration070 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined but
    // the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version number
    // so the test stays stable across reordering.
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration070AddAgentMemories.version) return;
    }
    return error.Migration070NotRegistered;
}