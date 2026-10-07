const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 065 — Add `workspace_item_tasks.last_human_touched_at`.
///
/// Used by the kanban card UI to decide whether to show the "AI
/// finished — awaiting your review" orange dot or the green "reviewed"
/// checkmark. Stamped by every HTTP handler that mutates a task on
/// behalf of a human user (drag, rename, edit description, pin,
/// send chat message, open chat) — see docs/plans/2026-07-26-kanban-task-notification-icon.md.
///
/// Schema (nullable INTEGER, no DEFAULT): NULL is the canonical
/// "never touched" state. The `addColumnIfMissing` helper handles both
/// upgrade-from-v1 and fresh-DB-already-declares-it paths gracefully
/// (see memory `pabrik-data-and-routines.md` §"Migration #009-#052
/// fresh-DB cascade is fragile" for the failure mode this avoids).
///
/// Comparison happens against `sessions.updated_at` in the kanban
/// SELECT (not against `last_finish_reason` directly) so the
/// comparison denominator carries timezone-uniform seconds. The
/// frontend treats `last_human_touched_at == NULL` as "human has
/// never touched", which gives the "awaiting review" semantics for
/// every pre-migration task on a legacy DB.
pub const Migration065AddTaskHumanTouchedAt = struct {
    pub const version: u32 = 65;
    pub const name = "add_task_human_touched_at";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "last_human_touched_at",
            // name + type — `addColumnIfMissing` uses this verbatim as
            // `ALTER TABLE {table} ADD COLUMN {definition}`, so omitting
            // the column name would create a column literally named
            // "INTEGER". See memory `addColumnIfMissing-requires-name-type`.
            "last_human_touched_at INTEGER",
        );
    }
};
