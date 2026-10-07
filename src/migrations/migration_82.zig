const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 082 - Add `sessions.last_human_touched_at_nano`.
///
/// Sibling of Migration 065 (which added the same column shape to
/// `workspace_item_tasks`). Used by the chat sidebar to render the
/// "last human touched" time pill instead of the AI-tainted
/// `updated_at`. Stamped by:
///   - `app.zig::emit_run_agent` - every user-sends-a-message path
///     (chat send, kanban "create & run", kanban "Start agent", `+ Chat`)
///   - `session_update.zig::useCase` - user renames / changes profile /
///     toggles unattended mode
///   - `workflow.zig::saveRetryAttemptMessage` - "also when error too":
///     agent retry-catch / unexpected finish_reason / TooManyRetries bail
///
/// Schema (nullable INTEGER, no DEFAULT): NULL is the canonical
/// "never touched by a human" state - the frontend falls back to
/// `updated_at` for these rows so pre-migration sessions keep
/// displaying their existing time without a regression.
///
/// Column name uses the `_nano` suffix per the project-wide
/// convention from Migration 075 (uniform across 5 timestamp
/// columns; actual stored unit is unix-ms - see Migration 075
/// docstring). The wire / struct / JSON field
/// is the bare `last_human_touched_at` (no `_nano`) - the SELECT
/// aliases back via `... AS last_human_touched_at`.
///
/// The `addColumnIfMissing` helper handles both upgrade-from-v1
/// and fresh-DB-already-declares-it paths gracefully (see memory
/// `pabrik-data-and-routines.md` "Migration #009-#052 fresh-DB
/// cascade is fragile" for the failure mode this avoids).
///
/// Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
/// Task: task_1788004921757_1.
pub const Migration082AddSessionHumanTouchedAt = struct {
    pub const version: u32 = 82;
    pub const name = "add_session_human_touched_at";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            // The SQL column name and the `column` probe arg must match
            // exactly - `addColumnIfMissing` issues
            // `SELECT 1 FROM pragma_table_info('sessions') WHERE name = '<column>'`
            // first to decide whether to skip. The wire / struct / JSON
            // field is the bare `last_human_touched_at` (no `_nano`
            // suffix) - the SELECT in buildSessionListJson aliases the
            // SQL column back via `... AS last_human_touched_at`.
            "last_human_touched_at_nano",
            // name + type - `addColumnIfMissing` uses this verbatim as
            // `ALTER TABLE {table} ADD COLUMN {definition}`, so omitting
            // the column name would create a column literally named
            // "INTEGER". See memory `addColumnIfMissing-requires-name-type`.
            "last_human_touched_at_nano INTEGER",
        );
    }
};
