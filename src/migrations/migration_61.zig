const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 061 — Re-backfill `created_iso` for rows that are NULL,
/// empty, OR have the wrong year (e.g. year 58,507 from the
/// nanosecond/microsecond mismatch).
///
/// ## Why this migration exists
///
/// Migration 060's backfill only handled rows where `created_iso` was
/// NULL or empty. It did NOT detect the **wrong-year** rows (e.g.
/// `58507-07-26 ...`) that were silently produced by `saveMessage`
/// passing nanosecond values (length 19) to a helper expecting
/// microseconds. The helper divided by `us_per_s` (1,000,000)
/// instead of `ns_per_s` (1,000,000,000), producing sec ≈ 1.78e12
/// instead of 1.78e9 — which decodes as year 58,507 in stdlib
/// epoch math. The wrong value passed SQLite's `IS NULL OR = ''`
/// guard and was never overwritten.
///
/// This migration fixes both shapes (NULL/empty AND wrong-year) with
/// a single UPDATE that recomputes from `created_at` directly. We use
/// `substr(created_at, 1, 10)` because the first 10 decimal digits of
/// either a microsecond or a nanosecond Unix timestamp are the same
/// seconds-since-epoch value (microseconds = "sNNNNNN…", nanoseconds
/// = "sNNNNNNNNNN…", the `s` seconds prefix is identical). `CAST(...,
/// INTEGER)` then gives SQLite a clean integer for `datetime(..., 'unixepoch')`.
///
/// ## Wrong-year detection
///
/// `created_iso LIKE '19__-%' OR LIKE '20__-%'` matches valid years
/// from 1970–2099 (the plausible Unix‑epoch range for any
/// production data). Rows starting with `5850[7-9]-`, `5860-`, or
/// any other "year > 9999" are caught by the negation and
/// overwritten with the recompute. Pre‑2000 rows (e.g. `1999-12-31
/// ...`) are preserved because they're legitimate old data, not a
/// bug. `IS NULL` and `= ''` are kept for safety (matches the same
/// rows Migration 060 already fixed).
///
/// We use LIKE (not GLOB) for consistency with the rest of the
/// codebase. SQLite's LIKE treats `[0-9]` as literal chars (the
/// bracket is not a wildcard), so we use the `_` wildcard to mean
/// "any single character" — `'20__-%'` matches anything starting
/// with `20`, any 2 chars, `-`.
///
/// ## Idempotency
///
/// Re-running is safe: rows with already-correct `created_iso` are
/// untouched. Only rows that still need fixing get updated.
pub const Migration061FixCreatedIsoYear = struct {
    pub const version: u32 = 61;
    pub const name = "fix_llm_history_created_iso_year";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // UPDATE WHERE clause matches three categories:
        //   1. created_iso IS NULL
        //   2. created_iso = ''
        //   3. created_iso has a year that doesn't match any plausible
        //      Unix‑timestamp year — i.e. NOT in 19xx and NOT in 20xx
        //      (which catches '58507-07-26 ...' and other clearly
        //      wrong‑year rows).
        //
        // We use LIKE (not GLOB) for portability with the rest of
        // the codebase. LIKE wildcards are `%` (any sequence) and
        // `_` (any single char). SQLite's LIKE does NOT support
        // character classes like `[0-9]` — the bracket chars are
        // treated as literals, so the pattern would never match.
        // We accept 19xx AND 20xx to cover any plausible Unix‑epoch
        // year (1970–2099). Verified:
        //   '2026-07-15' LIKE '19__-%' OR LIKE '20__-%' → 1
        //   '1999-12-31' LIKE '19__-%' OR LIKE '20__-%' → 1
        //   '58507-07-26' LIKE '19__-%' OR LIKE '20__-%' → 0
        //
        // The recompute uses substr(created_at, 1, 10) to extract
        // the seconds prefix of the timestamp, which works for both
        // microsecond AND nanosecond stored values (the first 10
        // digits are seconds-since-epoch in either case).
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
            \\   OR (created_iso NOT LIKE '19__-%'
            \\       AND created_iso NOT LIKE '20__-%')
        , &[_][]const u8{});
    }
};
