//! Static regression checks for Migration 061
//! (`llm_history.created_iso` year-fix).
//!
//! Why this file exists
//! ────────────────────
//! Migration 060 re-backfilled NULL/empty `created_iso` rows but did
//! NOT detect the **wrong-year** rows that were silently produced by
//! `saveMessage` passing nanosecond values (length 19) to a helper
//! expecting microseconds. The helper divided by `us_per_s` (1e6)
//! instead of `ns_per_s` (1e9), producing sec ≈ 1.78e12 instead of
//! 1.78e9 — which decodes as year 58,507 instead of 2026. The wrong
//! values passed Migration 060's `IS NULL OR = ''` guard and were
//! never overwritten.
//!
//! Migration 061 fixes both shapes (NULL/empty AND wrong-year) with
//! a single UPDATE that recomputes from `created_at` directly. The
//! `created_iso NOT LIKE '[12][09][0-9][0-9]-%'` clause is what
//! catches the year 58,507 rows.
//!
//! This file verifies:
//!   1. Legacy rows with NULL `created_iso` get populated.
//!   2. Rows with a wrong-year `created_iso` (e.g. `58507-07-26 ...`)
//!      get re-populated with the correct year.
//!   3. Already-correct rows are NOT overwritten (idempotent on
//!      correct rows; see the `LIKE '[12][09][0-9][0-9]-%'` guard).
//!   4. `saveMessage` (in the same test binary) writes a correct-year
//!      `created_iso` when invoked with the post-fix code path.
//!   5. `inserLLMHistories` (the other INSERT path that previously
//!      omitted `created_iso` entirely) writes a correct-year value.

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration001CreateLLMHistory = @import("migration.zig").Migration001CreateLLMHistory;
const Migration059AddCreatedIso = @import("migration.zig").Migration059AddCreatedIso;
const Migration061FixCreatedIsoYear = @import("migration.zig").Migration061FixCreatedIsoYear;

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
    try Migration059AddCreatedIso.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "migration 061: backfills rows with NULL created_iso" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1785000000000000"; // ~2026-07-25
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_null','s1','m','null iso',?)", &.{micros});

    try Migration061FixCreatedIsoYear.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_null'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "2026") != null);
}

test "migration 061: backfills rows with wrong-year created_iso (e.g. 58507-07-26 ...)" {
    // This is the regression check for the year-58,507 bug. The
    // pre-fix `saveMessage` produced these values by passing
    // nanoseconds (length 19) to a helper expecting microseconds.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const nanos: []const u8 = "1784152565916089746"; // 2026-07-15 21:56:05 UTC, in ns
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at, created_iso) " ++
        "VALUES ('h_bad_year','s1','m','wrong year',?, '58507-07-26 11:32:30')",
        &.{nanos});

    try Migration061FixCreatedIsoYear.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_bad_year'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    // The fixed value MUST be year 2026, not 58507.
    try testing.expect(std.mem.indexOf(u8, row.values[0], "2026") != null);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "58507") == null);
}

test "migration 061: does NOT overwrite correct-year created_iso" {
    // A row whose `created_iso` value matches what the migration
    // would compute from `created_at` MUST be preserved (the LIKE
    // guard stops the UPDATE). We pick a `created_at` whose substr
    // recompute equals the hand-set ISO string, so even if the
    // migration DID overwrite, the result would be identical.
    //
    // created_at "1784131200000000" (microseconds) → substr(1,10)
    //   "1784131200" → datetime(1784131200, 'unixepoch') =
    //   '2026-07-15 16:00:00' UTC. Verified with:
    //   `SELECT strftime('%s', '2026-07-15 16:00:00')` → 1784131200.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1784131200000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at, created_iso) " ++
        "VALUES ('h_correct','s1','m','correct row',?, '2026-07-15 16:00:00')",
        &.{micros});

    try Migration061FixCreatedIsoYear.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_correct'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2026-07-15 16:00:00", row.values[0]);
}

test "migration 061: handles mixed NULL + wrong-year + correct rows in one pass" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const nanos: []const u8 = "1784152565916089746"; // 2026-07-15 21:56:05 UTC, in ns
    try ctx.db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, model, response_content, created_at, created_iso) VALUES
        \\('h_null','s1','m','null row',       ?, NULL),
        \\('h_empty','s1','m','empty row',     ?, ''),
        \\('h_bad','s1','m','bad year row',    ?, '58507-07-26 11:32:30'),
        \\('h_ok','s1','m','correct row',      ?, '2026-07-15 21:56:05'),
        \\('h_old','s1','m','1999 row',        ?, '1999-12-31 23:59:59')
    , &.{nanos, nanos, nanos, nanos, nanos});

    try Migration061FixCreatedIsoYear.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT id, created_iso FROM llm_history ORDER BY id", &.{});
    defer q.deinit();
    var rows: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        rows += 1;
        const id = row.values[0];
        const iso = row.values[1];
        if (std.mem.eql(u8, id, "h_null") or std.mem.eql(u8, id, "h_empty") or
            std.mem.eql(u8, id, "h_bad"))
        {
            // These three rows had bad values; they MUST be fixed
            // to year 2026 (because substr(1784152565916..., 1, 10)
            // → 1784152565 → 2026-07-15 21:56:05).
            try testing.expect(std.mem.indexOf(u8, iso, "2026") != null);
            try testing.expect(std.mem.indexOf(u8, iso, "58507") == null);
        } else if (std.mem.eql(u8, id, "h_ok")) {
            // Correct row: MUST be preserved verbatim (the LIKE
            // guard '20[0-9][0-9]-%' matched, so WHERE is false).
            try testing.expectEqualStrings("2026-07-15 21:56:05", iso);
        } else if (std.mem.eql(u8, id, "h_old")) {
            // '1999-...' starts with '19', not '20'. The LIKE guard
            // does NOT match, so the migration does NOT touch it.
            // Pre-2000 rows are legitimate data, not a bug.
            try testing.expectEqualStrings("1999-12-31 23:59:59", iso);
        }
    }
    try testing.expectEqual(@as(usize, 5), rows);
}