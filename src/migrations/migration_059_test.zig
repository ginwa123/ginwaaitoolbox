//! Static regression checks for Migration 059
//! (llm_history.created_iso trigger-populated column).
//!
//! Why this file exists
//! ────────────────────
//! Migration 059 adds a regular TEXT column `created_iso` to
//! `llm_history`, populated by INSERT / UPDATE triggers that compute
//! `datetime(CAST(created_at AS REAL) / 1000000, 'unixepoch', 'localtime')`.
//! The search_history / getCompactedMessages SQL filters on `since`/`until`
//! bind to this column, so the documented `since`/`until` format works.
//!
//! Before this migration, the filters did a lex comparison on the
//! `created_at` TEXT column (which stores Unix microseconds like
//! `"1784119389936251112"`) against user input like `"2026-07-15 00:00:00"`.
//! Because `'1' < '2'` lexicographically, every data row was always
//! considered "less than" a date string starting with `'2'`, so the
//! filter silently returned 0 rows. See
//! `docs/superpowers/plans/2026-07-15-search-history-since-until-bug.md`.
//!
//! ## Why a trigger and not a STORED GENERATED column?
//!
//! `datetime(..., 'localtime')` is non-deterministic (depends on the
//! system timezone). SQLite silently DROPS any GENERATED ALWAYS AS
//! STORED column whose expression uses a non-deterministic function —
//! even in ALTER TABLE ADD COLUMN, even in CREATE TABLE. (Verified
//! empirically against SQLite 3.53.3; the column is omitted from
//! `pragma_table_info` with no error message.) Triggers can call
//! non-deterministic functions because they're explicit statements, not
//! declarative expressions, so we use them instead.
//!
//! This file verifies:
//!   1. The column `created_iso` exists on `llm_history` after the
//!      migration (NOT a generated column).
//!   2. The INSERT trigger populates `created_iso` from `created_at` on
//!      every INSERT.
//!   3. Lex comparison against a date string picks up the correct rows
//!      (the actual bug regression).
//!   4. The index `idx_llm_history_created_iso` is created.
//!   5. The migration is idempotent (re-runs are no-ops).
//!
//! Plan: docs/superpowers/plans/2026-07-15-search-history-since-until-bug.md

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration001CreateLLMHistory = @import("migration.zig").Migration001CreateLLMHistory;
const Migration059AddCreatedIso = @import("migration.zig").Migration059AddCreatedIso;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with just the `llm_history` baseline table.
/// Mirrors the migration_058_test.zig / migration_054_test.zig pattern.
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

/// Read a column attribute by name from `pragma_table_xinfo('llm_history')`.
/// Returns null if the column doesn't exist.
///
/// We use `pragma_table_xinfo` (NOT `pragma_table_info`) because the
/// `xinfo` variant includes a 7th column "hidden" with values:
///   - 0 = normal column
///   - 2 = VIRTUAL generated column
///   - 3 = STORED generated column
/// `pragma_table_info` only returns the 6 normal columns and doesn't
/// surface the generated-column flag at all.
fn columnExists(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    column_name: []const u8,
) !?struct { found: bool, is_generated: bool } {
    var q = try db.query(alloc,
        "SELECT name, hidden FROM pragma_table_xinfo('llm_history') WHERE name = ?",
        &.{column_name});
    defer q.deinit();
    const row = (try q.next()) orelse return .{ .found = false, .is_generated = false };
    defer row.deinit(alloc);
    // `hidden` is 0 for normal columns, 2 for VIRTUAL generated, 3 for
    // STORED generated. We treat any nonzero as "is generated".
    const gen = std.fmt.parseInt(u32, row.values[1], 10) catch 0;
    return .{ .found = true, .is_generated = gen != 0 };
}

test "migration 059: creates created_iso regular TEXT column (not generated)" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Pre-migration: no created_iso column.
    const pre = try columnExists(&ctx.db, alloc, "created_iso");
    try testing.expectEqual(false, pre.?.found);

    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Post-migration: column exists, is NOT generated (regular TEXT).
    // The trigger-based approach can't use GENERATED ALWAYS AS STORED
    // because `datetime(..., 'localtime')` is non-deterministic.
    const post = try columnExists(&ctx.db, alloc, "created_iso");
    try testing.expect(post != null);
    try testing.expectEqual(true, post.?.found);
    try testing.expectEqual(false, post.?.is_generated);
}

test "migration 059: INSERT trigger populates created_iso from created_at" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Insert a row with a known microsecond timestamp. The INSERT trigger
    // should populate created_iso with datetime(<micros>/1000000,
    // 'unixepoch', 'localtime').
    const micros: []const u8 = "1780000000000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_iso','s1','m','content with isocheckword',?)", &.{micros});

    // Read the trigger-populated value.
    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_iso'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.TriggerDidNotPopulate;
    defer row.deinit(alloc);
    const generated = row.values[0];

    // Compute the expected value using the SAME SQLite expression the
    // trigger uses. This keeps the test timezone-agnostic.
    var expected_q = try ctx.db.query(alloc,
        "SELECT datetime(CAST(? AS REAL) / 1000000, 'unixepoch', 'localtime')", &.{micros});
    defer expected_q.deinit();
    const expected_row = (try expected_q.next()) orelse return error.ExpectedExprFailed;
    defer expected_row.deinit(alloc);
    const expected = expected_row.values[0];

    try testing.expectEqualStrings(expected, generated);
    // Sanity: generated must NOT be empty (regression for the silent
    // GENERATED-column drop bug).
    try testing.expect(generated.len > 0);
}

test "migration 059: lex comparison against a date string selects the correct rows (regression)" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Insert two rows at known microsecond timestamps.
    const old_micros: []const u8 = "1780000000000000";
    const new_micros: []const u8 = "1785000000000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_old','s1','m','old isocheckword',?)", &.{old_micros});
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_new','s1','m','new isocheckword',?)", &.{new_micros});

    // Compute the ISO for `new_micros` — this is what `created_iso` holds.
    var iso_q = try ctx.db.query(alloc,
        "SELECT datetime(CAST(? AS REAL) / 1000000, 'unixepoch', 'localtime')", &.{new_micros});
    defer iso_q.deinit();
    const iso_row = (try iso_q.next()) orelse return error.IsoExprFailed;
    defer iso_row.deinit(alloc);
    const new_iso = iso_row.values[0];

    // Lex comparison against `created_iso`: rows with created_iso >=
    // new_iso should match. This is the EXACT shape of the bug fix —
    // a date string like "2026-07-15 00:00:00" lexicographically
    // matches against the populated ISO column, not the raw microsecond
    // string.
    var hits_q = try ctx.db.query(alloc,
        \\SELECT id FROM llm_history
        \\WHERE created_iso >= ?
        \\ORDER BY id
    , &.{new_iso});
    defer hits_q.deinit();

    var count: usize = 0;
    var matched_ids: [4][]u8 = undefined;
    var match_idx: usize = 0;
    while (try hits_q.next()) |row| {
        defer row.deinit(alloc);
        if (match_idx < matched_ids.len) {
            matched_ids[match_idx] = try alloc.dupe(u8, row.values[0]);
            match_idx += 1;
        }
        count += 1;
    }
    defer for (matched_ids[0..match_idx]) |id| alloc.free(id);

    // Only h_new should match (created_iso >= new_iso excludes h_old).
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("h_new", matched_ids[0]);
}

test "migration 059: creates idx_llm_history_created_iso index" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Post-migration: an index named `idx_llm_history_created_iso` exists
    // on the `created_iso` column.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type='index' AND tbl_name='llm_history' AND name='idx_llm_history_created_iso'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.IndexNotCreated;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_llm_history_created_iso", row.values[0]);
}

test "migration 059: is idempotent on a re-run (column + triggers + index)" {
    // `addColumnIfMissing` checks pragma_table_info first, the triggers
    // use `IF NOT EXISTS`, and the index uses `IF NOT EXISTS`. A re-run
    // on a DB that already has everything is a no-op.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration059AddCreatedIso.up(&ctx.db, alloc);
    // Run it again — must not error.
    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Still exactly one created_iso column.
    const post = try columnExists(&ctx.db, alloc, "created_iso");
    try testing.expectEqual(true, post.?.found);
    try testing.expectEqual(false, post.?.is_generated);
}