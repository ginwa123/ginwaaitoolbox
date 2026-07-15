//! Static regression checks for Migration 060
//! (llm_history.created_iso re-backfill).
//!
//! Why this file exists
//! ────────────────────
//! Production databases that ran V1 of Migration 059 (which used
//! SQLite INSERT/UPDATE triggers to populate `created_iso`) ended up
//! with many rows having `created_iso = NULL` because the trigger's
//! `datetime(CAST(<microseconds> AS REAL) / 1000000, 'unixepoch',
//! 'localtime')` overflowed SQLite's `datetime()` range (cap: year
//! 9999) for modern timestamps. This silently broke the
//! `since`/`until` filter on `search_history` and `getCompactedMessages`.
//!
//! Migration 060 unconditionally re-runs the v2 backfill UPDATE so
//! production users get a fix on the next nalar restart without
//! having to nuke their `agent.db`.
//!
//! This file verifies:
//!   1. Legacy rows with NULL `created_iso` get populated.
//!   2. The migration is idempotent (re-runs are no-ops on populated rows).
//!   3. A row with an empty string `created_at` falls back to `now`.
//!   4. Existing populated rows are NOT overwritten (defensive).

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration001CreateLLMHistory = @import("migration.zig").Migration001CreateLLMHistory;
const Migration059AddCreatedIso = @import("migration.zig").Migration059AddCreatedIso;
const Migration060RebackfillCreatedIso = @import("migration.zig").Migration060RebackfillCreatedIso;

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
    try Migration001CreateLLMHistory.up(&db, alloc);
    // Migration 060 expects `created_iso` to exist. Migration 059
    // creates it (with a backfill that touches the existing rows).
    // Migration 060 then re-runs the backfill.
    try Migration059AddCreatedIso.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "migration 060: re-backfills rows with NULL created_iso" {
    // Simulates the production state: v1 of Migration 059 (broken trigger)
    // left a row with NULL created_iso. v2 of Migration 059 used a
    // different SQL expression that doesn't match what v1's broken trigger
    // would have left, so production NULLs persist.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1785000000000000"; // ~2026-07-25
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_legacy','s1','m','legacy row',?)", &.{micros});

    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_legacy'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "2026") != null);
}

test "migration 060: re-backfills row with empty created_at using datetime('now')" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_empty','s1','m','empty created_at','')", &.{});

    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_empty'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    // datetime('now') produces the current date — match any YYYY-MM-DD prefix.
    try testing.expect(std.mem.indexOf(u8, row.values[0], "-") != null);
}

test "migration 060: idempotent on re-run (no changes after second run)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1785000000000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_idem','s1','m','idempotent row',?)", &.{micros});

    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);
    var q1 = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_idem'", &.{});
    defer q1.deinit();
    const row1 = (try q1.next()) orelse return error.RowMissing;
    const first_value = try alloc.dupe(u8, row1.values[0]);
    row1.deinit(alloc);
    defer alloc.free(first_value);

    // Run again — should not change anything.
    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);
    var q2 = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_idem'", &.{});
    defer q2.deinit();
    const row2 = (try q2.next()) orelse return error.RowMissing;
    defer row2.deinit(alloc);
    try testing.expectEqualStrings(first_value, row2.values[0]);
}

test "migration 060: only updates rows where created_iso is NULL or empty" {
    // Regression check: production datasets that already have valid
    // created_iso (because the application ran the corrected saveMessage
    // for new inserts) must NOT be overwritten with a coarser computation.
    //
    // We can verify this by inserting a row WITH a created_iso value
    // that's clearly human-set (e.g. longer than 19 chars or contains
    // a non-ASCII marker). After the migration, that value should be
    // intact because the second (unconditional) UPDATE doesn't run —
    // the WHERE guard stopped it.
    //
    // For a simpler robustness check: insert a row, hand-set
    // `created_iso` to a known literal, run the migration, and verify
    // the literal is preserved.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1785000000000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at, created_iso) " ++
        "VALUES ('h_pre','s1','m','pre-populated row',?, 'CUSTOM-MARKER-ISO')",
        &.{micros});

    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_pre'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("CUSTOM-MARKER-ISO", row.values[0]);
}
