const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 059 — Add a `created_iso` column to `llm_history` (populated
/// by application code — NOT SQLite triggers).
///
/// ## Why this exists
///
/// `llm_history.created_at` is a TEXT column storing **Unix microseconds**
/// since the epoch as a string (e.g. `"1784119389936251112"`). The
/// previous history `since`/`until`
/// filters did a lex-comparison on this column against user input like
/// `"2026-07-15 00:00:00"` — which silently returned 0 rows because
/// `'1' < '2'` (so `'1784…' < '2026-…'` is always true, excluding every
/// row).
///
/// ## What this does
///
/// Adds a regular TEXT column `created_iso` that holds the
/// `YYYY-MM-DD HH:MM:SS` (localtime) form of the microsecond timestamp.
/// The column is populated by **application code** in `saveMessage`
/// (see `llm_history.zig`) using libc's `localtime_r` + `strftime`.
/// This is intentionally NOT done via SQLite triggers — see the
/// "Why not triggers?" section below.
///
/// ## Why not triggers / generated columns?
///
/// SQLite silently DROPS `GENERATED ALWAYS AS ... STORED` columns whose
/// expression uses a non-deterministic function (such as
/// `datetime(..., 'localtime')`, which depends on the system timezone) —
/// verified empirically against SQLite 3.53.3. The column is omitted
/// from `pragma_table_info` with no error.
///
/// Triggers can populate a regular column with `datetime()`, but they
/// have two practical failures:
///
///   1. Triggers are invisible to the application layer. The
///      production DBs ended up with many `created_iso = NULL` rows
///      because the trigger's `datetime(CAST(<microseconds> AS REAL) /
///      1000000, ...)` overflows SQLite's `datetime()` range (which
///      caps at year 9999) and silently returns NULL.
///
///   2. The trigger-based approach is invisible — hard to debug when
///      the conversion silently returns NULL.
///
/// Application-level computation in `saveMessage` (using libc
/// `localtime_r` + `strftime`) sidesteps both issues: the conversion
/// is explicit in the application's INSERT path, and libc handles
/// arbitrary Unix timestamps in the i64 range without overflow.
///
/// ## Idempotency notes
///
/// Re-running this migration is safe:
///   - `addColumnIfMissing` skips the ALTER if the column exists.
///   - The backfill UPDATE has `WHERE created_iso IS NULL OR created_iso = ''`,
///     so it only touches rows that still need populating.
///   - The CREATE INDEX uses IF NOT EXISTS.
///
/// The backfill runs every time the migration runs, so production
/// users with stale NULL rows (from earlier broken trigger-based
/// attempts) get them fixed on the next pabrik restart.
pub const Migration059AddCreatedIso = struct {
    pub const version: u32 = 59;
    pub const name = "add_llm_history_created_iso";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Add the column (regular TEXT, nullable).
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "created_iso",
            "created_iso TEXT",
        );

        // 2. Backfill existing rows. The application code in
        //    `saveMessage` populates `created_iso` at INSERT time, but
        //    legacy rows (and rows created before the application
        //    update is deployed) still have NULL. We update them
        //    using the INTEGER part of the microsecond string (the
        //    first 10 digits = seconds since epoch, which fits in
        //    SQLite's `datetime()` range).
        //
        //    Note: this loses the sub-second precision of the
        //    microsecond timestamp, but `since`/`until` filters
        //    operate at second/minute granularity anyway, so the
        //    loss is acceptable.
        //
        //    We use UTC (no `'localtime'` modifier) for consistency
        //    with the application-level `currentTimeIsoLocal`
        //    helper, which also produces UTC strings. The two paths
        //    (application INSERTs and this backfill) produce identical
        //    strings for the same input.
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

        // 3. Index for queries filtering by created_iso.
        try db.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS idx_llm_history_created_iso ON llm_history(created_iso)",
            &[_][]const u8{},
        );
    }
};
