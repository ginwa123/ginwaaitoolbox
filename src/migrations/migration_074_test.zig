//! Behavioural regression checks for Migration 074
//! (`llm_history.cache_creation_input_tokens` +
//! `llm_history.cache_read_input_tokens`).
//!
//! Why this file exists
//! ────────────────────
//! Migration 074 adds two cache-breakdown columns to `llm_history` so
//! the Anthropic profile's `cache_creation_input_tokens` and
//! `cache_read_input_tokens` survive the trip from the SSE parser
//! through `CallResponse.usage` → `saveMessage` / `insertLLMHistories`
//! → the row. OpenAI rows always carry 0 (the parser never sets the
//! fields for that profile).
//!
//! The migration must:
//!   1. Add `cache_creation_input_tokens` and `cache_read_input_tokens`
//!      columns to `llm_history`, both INTEGER DEFAULT 0 (so legacy
//!      rows backfill cleanly).
//!   2. Be idempotent on a re-run — `ALTER TABLE … ADD COLUMN` is NOT
//!      idempotent, so we use the existing `addColumnIfMissing` helper
//!      (probe `pragma_table_info` first; same pattern as Migration 020).
//!   3. Allow INSERT + SELECT round-trip on a row with explicit cache
//!      values populated.
//!
//! Plan: docs/superpowers/plans/2026-08-13-fix-anthropic-total-tokens.md
//! Task: task_1786640688092 ("fixing antropic agent total tokens")

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration074AddLlmHistoryCacheTokenColumns = @import("migration.zig").Migration074AddLlmHistoryCacheTokenColumns;

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
    return .{ .db = db, .threaded = threaded };
}

/// Set up the `llm_history` baseline (mirrors what Migration 001 creates
/// on a real DB) so Migration 074 can run against it. Fresh-DB users
/// would have the columns emitted by their Migration 001; legacy users
/// are missing them → Migration 074 adds them. We isolate the baseline
/// to 074-relevant columns only so the test doesn't depend on the FULL
/// Migration 001 schema (which has 30+ columns).
fn setupWithLlmHistoryBaseline(ctx: *TestCtx, alloc: std.mem.Allocator) !void {
    try ctx.db.exec(alloc,
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
        \\    parent_session_id TEXT,
        \\    parent_id TEXT
        \\)
    , &.{});
}

// ============================================================================
// Test 1 — Migration adds the 2 columns with the right name + type +
// default 0.
// ============================================================================

test "Migration074 adds cache_creation_input_tokens + cache_read_input_tokens to llm_history" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try setupWithLlmHistoryBaseline(&ctx, alloc);

    // Pre-migration: the 2 cache columns do NOT exist.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM pragma_table_info('llm_history') WHERE name IN ('cache_creation_input_tokens', 'cache_read_input_tokens')",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have either cache column
        }
    }

    try Migration074AddLlmHistoryCacheTokenColumns.up(&ctx.db, alloc);

    // Post-migration: both columns exist with type=INTEGER and dflt_value=0.
    var q = try ctx.db.query(alloc,
        "SELECT name, type, dflt_value FROM pragma_table_info('llm_history') " ++
            "WHERE name IN ('cache_creation_input_tokens', 'cache_read_input_tokens') " ++
            "ORDER BY name",
        &.{});
    defer q.deinit();

    const expected = [_]struct { name: []const u8, type: []const u8, default: []const u8 }{
        .{ .name = "cache_creation_input_tokens", .type = "INTEGER", .default = "0" },
        .{ .name = "cache_read_input_tokens", .type = "INTEGER", .default = "0" },
    };

    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx].name, row.values[0]);
        try testing.expectEqualStrings(expected[idx].type, row.values[1]);
        try testing.expectEqualStrings(expected[idx].default, row.values[2]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ============================================================================
// Test 2 — Idempotent on re-run.
// ============================================================================

test "Migration074 is idempotent on a re-run" {
    // The migration uses `addColumnIfMissing` which probes
    // `pragma_table_info` before issuing the ALTER. A second run must
    // NOT crash with "duplicate column name" errors.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try setupWithLlmHistoryBaseline(&ctx, alloc);

    try Migration074AddLlmHistoryCacheTokenColumns.up(&ctx.db, alloc);
    try Migration074AddLlmHistoryCacheTokenColumns.up(&ctx.db, alloc);

    // Both columns still exist exactly once each.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('llm_history') " ++
            "WHERE name IN ('cache_creation_input_tokens', 'cache_read_input_tokens')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

// ============================================================================
// Test 3 — Existing rows still INSERT successfully with default 0
// backfill (regression check for the legacy-row backfill contract).
// ============================================================================

test "Migration074 lets legacy-shape INSERTs succeed with default 0 cache counts" {
    // After migration, an INSERT that omits the new cache columns must
    // succeed (the columns default to 0). This is the legacy-row
    // backfill contract — an old DB with N rows already inserted would
    // NOT re-INSERT; the new column just shows up as 0 on SELECT.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try setupWithLlmHistoryBaseline(&ctx, alloc);
    try Migration074AddLlmHistoryCacheTokenColumns.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model) VALUES (?, ?, ?)",
        &.{ "h_legacy", "sess_legacy", "claude-opus-4" });

    var q = try ctx.db.query(alloc,
        "SELECT cache_creation_input_tokens, cache_read_input_tokens FROM llm_history WHERE id = ?",
        &.{"h_legacy"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
    try testing.expectEqualStrings("0", row.values[1]);
}

// ============================================================================
// Test 4 — INSERT + SELECT round-trip with explicit cache values.
// ============================================================================

test "Migration074: insert and select an llm_history row with explicit cache counts" {
    // Mirrors what `saveMessage` / `insertLLMHistories` will write when
    // an Anthropic call returns cache_creation=500, cache_read=5000.
    // Both columns must round-trip the values correctly.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try setupWithLlmHistoryBaseline(&ctx, alloc);
    try Migration074AddLlmHistoryCacheTokenColumns.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, cache_creation_input_tokens, cache_read_input_tokens) " ++
            "VALUES (?, ?, ?, ?, ?)",
        &.{ "h_cached", "sess_cached", "claude-opus-4", "500", "5000" });

    var q = try ctx.db.query(alloc,
        "SELECT cache_creation_input_tokens, cache_read_input_tokens " ++
            "FROM llm_history WHERE id = ?",
        &.{"h_cached"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("500", row.values[0]);
    try testing.expectEqualStrings("5000", row.values[1]);
}
