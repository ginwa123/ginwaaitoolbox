//! Behavioural regression checks for Migration 068
//! (`llm_history.is_loading` + UNIQUE INDEX on `tool_call_id`).
//!
//! Why this file exists
//! ────────────────────
//! Migration 068 adds an `is_loading INTEGER NOT NULL DEFAULT 0` column
//! to `llm_history` so we can mark tool-result placeholder rows that
//! were pre-created BEFORE the long-running tool execution started.
//!
//! It also adds a partial UNIQUE INDEX on `tool_call_id`:
//!     CREATE UNIQUE INDEX idx_llm_history_tool_call_id_loading
//!         ON llm_history(tool_call_id)
//!         WHERE tool_call_id IS NOT NULL AND tool_call_id != ''
//!
//! The UNIQUE INDEX is required so duplicate placeholders for the same
//! id are rejected at the DB level — without it, the dispatcher could
//! accidentally create two placeholders for one tool_call.id (a race
//! between the dispatcher + a stray retry). The partial WHERE clause
//! excludes empty-string tool_call_ids (the assistant message rows)
//! so the assistant row's `tool_call_id = ''` doesn't conflict with
//! the placeholders' `tool_call_id = 'tcA'` etc.
//!
//! The migration must:
//!   1. Add `is_loading INTEGER NOT NULL DEFAULT 0` to `llm_history`.
//!   2. Add the partial UNIQUE INDEX on `tool_call_id`.
//!   3. Be idempotent on re-run (re-running must not crash with
//!      "duplicate column name" or "index already exists").
//!   4. Leave existing rows at `is_loading = 0` (the canonical "not
//!      loading" sentinel — every historical row was either written
//!      directly by the dispatcher (not loading) or it was the
//!      assistant message (which doesn't apply here)).
//!   5. Be registered in `allMigrations` — defining the struct alone
//!      is a silent-skip bug per project memory
//!      `migration-registration-trap`.
//!
//! Plan: docs/superpowers/plans/2026-08-06-tool-call-loading-placeholder.md
//! Bug: task_1785784899843 ("invalid function ID tool call error")

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration068AddToolCallLoading = @import("migration.zig").Migration068AddToolCallLoading;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal `llm_history` schema matching the v1 shape — no
    // `is_loading` column yet (that's exactly what the migration
    // adds). Production walks migrations 001 → 067 first, so
    // `tool_call_id` and `is_feed_to_llm` are already there; we
    // include them so the migration's addColumnIfMissing succeeds
    // and the partial UNIQUE INDEX has the column to attach to.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_call_id TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration068 adds is_loading column to llm_history" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('llm_history')
            \\WHERE name = 'is_loading'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('llm_history')
        \\WHERE name = 'is_loading'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("is_loading", row.values[0]);

    // Type sanity: the column must be INTEGER (NOT NULL DEFAULT 0).
    var qt = try ctx.db.query(alloc,
        \\SELECT type, "notnull", dflt_value
        \\FROM pragma_table_info('llm_history')
        \\WHERE name = 'is_loading'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("INTEGER", type_row.values[0]);
    // "notnull" is 1 when NOT NULL.
    try testing.expectEqualStrings("1", type_row.values[1]);
    // Default value is "0" — the canonical "not loading" sentinel.
    try testing.expectEqualStrings("0", type_row.values[2]);
}

test "Migration068 adds partial UNIQUE INDEX on tool_call_id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Confirm the index exists.
    var q = try ctx.db.query(alloc,
        \\SELECT name, sql FROM sqlite_master
        \\WHERE type = 'index' AND tbl_name = 'llm_history'
        \\AND name = 'idx_llm_history_tool_call_id_loading'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.IndexMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_llm_history_tool_call_id_loading", row.values[0]);
    // Confirm the partial WHERE clause is present (the index should
    // exclude empty-string tool_call_ids so the assistant row's
    // tool_call_id = '' doesn't conflict with the placeholders').
    try testing.expect(std.mem.indexOf(u8, row.values[1], "WHERE") != null);
    try testing.expect(std.mem.indexOf(u8, row.values[1], "tool_call_id IS NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, row.values[1], "tool_call_id != ''") != null);
}

test "Migration068 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration068AddToolCallLoading.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name"
    // or "index idx_llm_history_tool_call_id_loading already exists".
    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Still exactly one is_loading column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('llm_history')
        \\WHERE name = 'is_loading'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration068 leaves pre-existing rows at is_loading=0 (the not-loading sentinel)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing row BEFORE applying the migration. Every
    // historical row was either written directly (not loading) or
    // pre-existed; the migration MUST backfill is_loading = 0 for
    // every row.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
            "VALUES ('msg_pre_068', 'sess_1', 'm', 'pre-existing')",
        &.{});

    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT is_loading FROM llm_history WHERE id = 'msg_pre_068'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "Migration068 enables the UNIQUE INDEX to reject duplicate tool_call_ids" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Two rows with the SAME tool_call_id must be rejected. The
    // assistant message has tool_call_id = '' (not the placeholder's
    // id), but the index is partial so the assistant row passes
    // through unaffected.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, tool_call_id, is_loading) " ++
            "VALUES ('msg_tool_a', 'sess_1', 'm', 'result_a', 'tcA', 0)",
        &.{});
    // Second placeholder with the same tool_call_id — must fail.
    const result = ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, tool_call_id, is_loading) " ++
            "VALUES ('msg_tool_a_dup', 'sess_1', 'm', 'result_a_dup', 'tcA', 0)",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);

    // But a row with tool_call_id = '' (the assistant message shape)
    // is allowed — the partial WHERE clause excludes it. Insert a
    // SECOND row with tool_call_id = '' to prove the partial index
    // is correctly scoped.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, tool_call_id) " ++
            "VALUES ('msg_assistant', 'sess_1', 'm', 'assistant content', '')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, tool_call_id) " ++
            "VALUES ('msg_user', 'sess_1', 'm', 'user message', '')",
        &.{});
}

test "Migration068 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined
    // but the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version
    // number so the test stays stable across reordering.
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration068AddToolCallLoading.version) return;
    }
    return error.Migration068NotRegistered;
}