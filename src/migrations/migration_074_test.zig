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
//! Set-up uses `MigrationManager.registerAllMigrations` + `runMigrations`
//! so the test schema matches what production runs (per the reviewer
//! note on PR #172: "when setup db, use from migrations module, migrations
//! module will load all table"). This avoids the drift trap of hand-rolling
//! a minimal `llm_history` schema — the moment a new column or trigger
//! lands in production, the hand-rolled baseline silently tests an
//! outdated schema.
//!
//! Plan: docs/superpowers/plans/2026-08-13-fix-anthropic-total-tokens.md
//! Task: task_1786640688092 ("fixing antropic agent total tokens")

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("migration.zig");

const Migration074AddLlmHistoryCacheTokenColumns = migration.Migration074AddLlmHistoryCacheTokenColumns;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB and run every production migration through
/// 074. After this returns, the schema is exactly what a production
/// DB looks like after Migration 074 has run — including the 2
/// cache-breakdown columns.
fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

// ============================================================================
// Test 1 — Migration adds the 2 columns with the right name + type +
// default 0. (Schema is post-migration; verifies the columns are
// present and have the right shape.)
// ============================================================================

test "Migration074 adds cache_creation_input_tokens + cache_read_input_tokens to llm_history" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

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
// Test 2 — Idempotent on re-run. `runMigrations` tracks versions in
// `schema_migrations` so a second run is a no-op. We also call
// `Migration074AddLlmHistoryCacheTokenColumns.up` directly a second
// time to verify the `addColumnIfMissing` helper doesn't error with
// "duplicate column name" (the failure mode it specifically guards
// against).
// ============================================================================

test "Migration074 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Run all migrations again — the schema_migrations version row
    // makes Migration 074 a no-op.
    var manager = migration.MigrationManager.init(alloc, &ctx.db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    // Both columns still exist exactly once each.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('llm_history') " ++
            "WHERE name IN ('cache_creation_input_tokens', 'cache_read_input_tokens')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);

    // Also directly re-run Migration 074's up() — verifies the
    // addColumnIfMissing helper doesn't crash with "duplicate column
    // name" (the failure mode SQLite raises for the second ALTER).
    try Migration074AddLlmHistoryCacheTokenColumns.up(&ctx.db, alloc);
    try Migration074AddLlmHistoryCacheTokenColumns.up(&ctx.db, alloc);
}

// ============================================================================
// Test 3 — Legacy-style INSERTs that OMIT the cache columns still
// succeed with default 0 backfill. This is the regression check for
// the "legacy rows backfill cleanly" contract — an old DB with rows
// already inserted would NOT re-INSERT; the new columns just show as 0.
// ============================================================================

test "Migration074 lets legacy-shape INSERTs succeed with default 0 cache counts" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // INSERT that does NOT mention the 2 cache columns — the
    // INSERT-time DEFAULT 0 (set by Migration 074) must kick in.
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
// Mirrors what `saveMessage` / `insertLLMHistories` will write when an
// Anthropic call returns cache_creation=500, cache_read=5000.
// ============================================================================

test "Migration074: insert and select an llm_history row with explicit cache counts" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

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

// ============================================================================
// Test 5 — Migration 074 is registered in `allMigrations` (mirrors the
// pattern in migration_066_test.zig / migration_067_test.zig /
// migration_068_test.zig / migration_069_test.zig / migration_070_test.zig
// / migration_071_test.zig). Defining the struct alone is not enough —
// it must also be added to `migration.zig::allMigrations` so the
// production migration runner picks it up.
// ============================================================================

test "Migration074 is registered in allMigrations" {
    const all = migration.allMigrations;
    var found: bool = false;
    for (all) |m| {
        if (m.version == Migration074AddLlmHistoryCacheTokenColumns.version and
            std.mem.eql(u8, m.name, Migration074AddLlmHistoryCacheTokenColumns.name))
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}
