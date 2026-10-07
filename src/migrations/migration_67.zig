const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 067 — Add `workspace_item_tasks.tags` column to support the
/// kanban task tags feature (free-form string list).
///
/// ## Why this migration exists
///
/// The kanban task tags feature adds user-defined labels per task
/// (e.g. "bug", "urgent", "frontend"). Tags are stored as a JSON-encode
/// array string (e.g. `'["bug","urgent","frontend"]'`); empty string
/// is the canonical "no tags" sentinel, matching the `description`
/// column (Migration 062) convention.
///
/// ## What this does
///
/// 1. Add `tags TEXT NOT NULL DEFAULT ''` to `workspace_item_tasks`
///    via `addColumnIfMissing` — safe for both upgrade-from-v1 DBs
///    (no column) AND fresh-DB installs where the canonical CREATE
///    TABLE in Migration 034 / 044 / 062 / 065 already declares the
///    column. The `addColumnIfMissing` helper checks
///    `pragma_table_info` before issuing the ALTER, so duplicate-
///    column errors are impossible.
/// 2. Leave existing rows at '' (the canonical "no tags" sentinel) —
///    we cannot retroactively know what tags the user wanted, and
///    any non-empty default would silently fabricate tags for
///    every legacy task.
///
/// ## Why a TEXT column (JSON-encode array string), not a `tags` table
///
/// No SQL-level filtering by tag is needed in v1 (the kanban board
/// has no filter UI yet). A managed `tags` table would add
/// vocabulary, color, and rename machinery without a current
/// consumer. Forward-compatible: a future migration can read the
/// JSON array via `json_each` and create proper tag rows + a join
/// table — the existing JSON column is the natural source of truth.
///
/// ## Why no index
///
/// The column stores JSON, which SQLite cannot index by JSON path
/// without the JSON1 extension (not used here). A LIKE index across
/// the JSON string would be expensive and useless until the column
/// is restructured. Defer until tag filtering is in scope.
///
/// Plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md (Task 1)
pub const Migration067AddTaskTags = struct {
    pub const version: u32 = 67;
    pub const name = "add_task_tags";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "tags",
            // `addColumnIfMissing` builds `ALTER TABLE {table} ADD COLUMN
            // {definition}`, so the definition must include BOTH the
            // column name AND the type. Omitting the type would create
            // a column literally named "TEXT" — see project memory
            // `addColumnIfMissing-requires-name-type`.
            "tags TEXT NOT NULL DEFAULT ''",
        );
    }
};
