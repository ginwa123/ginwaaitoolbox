const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 062 — Add a `description` column to
/// `workspace_item_tasks` so every task (chat / routine / kanban)
/// can carry a free-form text note alongside its display name.
///
/// Why this migration exists
/// ──────────────────────────
/// Until now, the backend's `TaskCreateRequest.description` field
/// was parsed and accepted but **not persisted** — the comment at
/// `http_response.zig:103` literally said "the frontend holds the
/// authoritative copy", which is the wrong invariant (descriptions
/// vanished on page reload). The Kanban Task Detail Dialog
/// feature (frontend, Chunk 2) reads and writes the description;
/// this migration makes it durable.
///
/// Schema choice: `NOT NULL DEFAULT ''` so existing rows survive
/// the migration without a backfill and the empty string becomes
/// the canonical "no description" sentinel (the UI renders it as
/// an "Add a description…" placeholder, matching the
/// `kanban_columns.description` precedent from Migration 053).
///
/// Idempotency / fresh-DB safety: we use `addColumnIfMissing`
/// instead of raw `ALTER TABLE` so fresh-DB installs that re-play
/// the canonical schema (already declaring `description` in their
/// CREATE TABLE) don't crash on "duplicate column". See project
/// memory `pabrik-fresh-db-migration-cascade`.
///
/// Note: this migration is at version 62 because PR #99
/// (`Migration061FixCreatedIsoYear`) shipped on main before this
/// PR landed and reserved version 61. See the original
/// `Migration061AddTaskDescription` (now `Migration062`) commit
/// history for the previous v61 numbering.
///
/// Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md
///   (Chunk 1, Task 1.1)
pub const Migration062AddTaskDescription = struct {
    pub const version: u32 = 62;
    pub const name = "add_task_description";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "description",
            "description TEXT NOT NULL DEFAULT ''",
        );
    }
};
