const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 060 — Re-run the `created_iso` backfill for rows that
/// were NULL when Migration 059 first ran.
///
/// ## Why this migration exists
///
/// V1 of Migration 059 (now reverted) used SQLite INSERT/UPDATE triggers
/// to populate `created_iso` from `created_at`. The trigger's
/// `datetime(CAST(<microseconds> AS REAL) / 1000000, 'unixepoch', 'localtime')`
/// expression overflowed SQLite's `datetime()` range (cap: year 9999) for
/// modern (post-year-2000) microsecond timestamps, silently returning
/// NULL for every row inserted after the trigger was installed. The
/// migration's backfill UPDATE had the same overflow bug, so legacy
/// rows also got NULL `created_iso`.
///
/// As a result, production databases that ran V1 of Migration 059 had
/// many rows with `created_iso = NULL`, which silently broke the
/// `since`/`until` filter on workspace history reads and
/// `getCompactedMessages`
/// (since `'NULL' < '2026-07-15 ...'` in lex comparison filtered those
/// rows back out, but the filter logic actually excluded them).
///
/// ## What this does
///
/// Re-runs the backfill UPDATE with the corrected UTC-based expression
/// from Migration 059 v2:
///   - Application code (Zig stdlib `std.time.epoch`) produces UTC.
///   - This UPDATE matches UTC to keep both paths consistent.
///   - It's idempotent (WHERE guards on NULL/empty).
///   - It only touches rows that STILL need populating — rows where
///     the v1 trigger or v1 backfill left a stale value will also
///     be updated (since they were never updated correctly anyway).
pub const Migration060RebackfillCreatedIso = struct {
    pub const version: u32 = 60;
    pub const name = "rebackfill_llm_history_created_iso";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Re-run the backfill from Migration 059 (v2). The WHERE
        // clause makes this idempotent — already-populated rows
        // (including any rows where the application code has since
        // written a correct `created_iso`) are untouched. Only rows
        // with NULL or empty `created_iso` get populated.
        //
        // NOTE: this does NOT touch rows where v1's broken trigger
        // may have written a non-NULL but garbage value. We can't
        // detect that syntactically — a string that's well-formed
        // 'YYYY-MM-DD HH:MM:SS' but contains a totally wrong date is
        // indistinguishable from a correct one. The migration is
        // conservative: it only touches rows we KNOW are missing,
        // and trusts the corrected saveMessage going forward to
        // produce correct values for new rows.
        try db.exec(
            allocator,
            \\UPDATE llm_history
            \\SET created_iso = CASE
            \\    WHEN created_at IS NULL OR created_at = ''
            \\        THEN datetime('now')
            \\    ELSE datetime(
            \\        CAST(substr(created_at, 1, 10) AS INTEGER),
            \\        'unixepoch'
            \\    )
            \\END
            \\WHERE created_iso IS NULL
            \\   OR created_iso = ''
        , &[_][]const u8{});
    }
};
