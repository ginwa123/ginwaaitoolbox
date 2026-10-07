const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 075 — Rename 5 timestamp columns to use the `_nano` suffix,
/// making the column name self-document the stored unit (integer since
/// Unix epoch). This is a pure renaming pass — the stored values, column
/// types, and wire-format JSON field names are ALL preserved. SQLite's
/// `ALTER TABLE … RENAME COLUMN` (>= 3.25) handles the rename atomically
/// and auto-updates FK references; the only manual work is renaming the
/// two indexes whose name explicitly contains the old column name
/// (`idx_logs_created_at`, `idx_worker_last_activity`).
///
/// ## Why this migration exists
///
/// Today, the five columns have ambiguous names that don't document
/// their precision:
///
/// | Table | Column | Actual precision |
/// |---|---|---|
/// | `logs` | `created_at` | unix **ms** (i64) |
/// | `llm_history` | `created_at` | unix **ns** as TEXT (19 digits) |
/// | `session_skills` | `loaded_at` | unix **s** (i64) |
/// | `worker` | `last_activity` | unix **s** (i64) |
/// | `workspace_item_tasks` | `last_human_touched_at` | unix **ms** (i64) |
///
/// Migration 059 v1 (commit b6177842) used
/// `datetime(CAST(<microseconds> AS REAL) / 1000000, 'unixepoch', 'localtime')`
/// to populate `created_iso` from `created_at` — but the column
/// actually stored **nanoseconds**, so the trigger divided by 1e6
/// (microseconds→seconds) instead of 1e9 (nanoseconds→seconds). The
/// 1000× error produced rows that decoded to year 58,507. It took
/// two migration fixes (Migrations 060 + 061) to repair the damage.
///
/// Renaming the columns so each carries the `_nano` suffix makes this
/// kind of unit confusion impossible to repeat.
///
/// ## Naming choice — uniform `_nano` vs. mixed suffixes
///
/// The user requested `_nano` uniformly across all 5 columns. The
/// suffix here means "integer stored since Unix epoch" — a uniform
/// project convention, not a strict precision assertion. The actual
/// precision (ms / s / ns) per column is documented in each
/// column's doc-comment and the corresponding Zig model file
/// (`models/log.zig`, `models/llm_history.zig`, `models/session_skill.zig`,
/// `models/worker.zig`, `models/workspace_item_task.zig`).
///
/// ## Wire format preservation
///
/// The JSON field name on HTTP responses stays exactly the same:
/// `created_at`, `loaded_at`, `last_activity`, `last_human_touched_at`.
/// The Zig SELECT statements read from the new SQL column name and
/// alias it back to the old wire name (e.g.
/// `SELECT w.last_activity_nano AS last_activity FROM worker w`).
///
/// The Zig struct fields also keep the old name (`SessionInfo.created_at`,
/// `WorkerInfo.last_activity`, `SkillInfo.loaded_at`,
/// `WorkspaceItemTaskInfo.last_human_touched_at`,
/// `LogInfo.created_at`) so the JSON serializers / SSE payload structs
/// don't change.
///
/// ## Idempotency
///
/// `renameColumnIfExists` probes `pragma_table_info` first — if the
/// OLD column doesn't exist (fresh-DB install that already declares
/// the NEW column, or a re-run after the rename succeeded), the
/// helper returns silently. This matches the Migration 052 + 054
/// + 072 `dropColumnIfExists` pattern.
///
/// ## Index renaming
///
/// `idx_logs_created_at` and `idx_worker_last_activity` have the OLD
/// column name in their index name — rename them via
/// `DROP INDEX IF EXISTS old; CREATE INDEX IF NOT EXISTS new`. The
/// other two indexes that reference the renamed columns
/// (`idx_llm_history_session_created`, `idx_llm_history_created_session`)
/// use a generic `_created` suffix and are left as-is — SQLite
/// updates the index's INTERNAL column reference during the RENAME,
/// but the index's NAME stays unchanged.
///
/// Plan: docs/superpowers/plans/2026-08-16-rename-timestamp-columns-nano-suffix.md
/// Task: task_1786891244388_1.
pub const Migration075RenameTimestampColumnsToNanoSuffix = struct {
    pub const version: u32 = 75;
    pub const name = "rename_timestamp_columns_to_nano_suffix";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Wrap in a tx (db.begin/tx.exec/tx.commit) so the 5 renames + 2 index swaps are
        // atomic. A crash mid-migration would otherwise leave the DB
        // with some columns renamed and others not, breaking every
        // SQL site that targets the old names. SQLite auto-commits
        // each statement otherwise.
        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        // 5 column renames — order doesn't matter logically, but
        // keep the order alphabetical by table for diff readability.
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "llm_history", "created_at", "created_at_nano");
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "logs", "created_at", "created_at_nano");
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "session_skills", "loaded_at", "loaded_at_nano");
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "worker", "last_activity", "last_activity_nano");
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "workspace_item_tasks", "last_human_touched_at", "last_human_touched_at_nano");

        // 2 index renames — SQLite doesn't have `ALTER INDEX … RENAME
        // TO …`, and the index's auto-generated name doesn't auto-
        // update on the column rename. DROP + CREATE under the new
        // name. The `IF NOT EXISTS` on the CREATE is defensive
        // (after a re-run, the new index already exists).
        try tx.exec(allocator, "DROP INDEX IF EXISTS idx_logs_created_at", &.{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_logs_created_at_nano ON logs(created_at_nano DESC)",
            &.{});

        try tx.exec(allocator, "DROP INDEX IF EXISTS idx_worker_last_activity", &.{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_worker_last_activity_nano ON worker(last_activity_nano DESC)",
            &.{});

        // Commit the transaction. After this, Migration 075 is
        // "done" and the new schema is durable.
        try tx.commit();

        // ANALYZE so the query planner sees the renamed indexes
        // (mirrors Migration 041/042/043/051 pattern).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
