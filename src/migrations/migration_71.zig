const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 071 — `workspace_item_tasks.cwd` (per-task cwd_session).
///
/// Adds a `cwd TEXT NOT NULL DEFAULT ''` column so each kanban task
/// can carry its own cwd override. The legacy `cwd_session` HTTP
/// field on `RequestSession` is unaffected — that one is the explicit
/// per-call cwd override the frontend sends with each chat message.
/// The new `cwd` column is the per-task default that the frontend
/// reads from the task list and threads into the runAgentOnNewTask
/// flow.
///
/// The name `cwd` (not `cwd_session`) was chosen to avoid confusion
/// with the legacy HTTP `cwd_session` field — the column belongs to
/// the task, the HTTP field belongs to the session create call.
/// Frontend wire field is `cwd` (matching the column).
///
/// Resolution priority (in `session_create.zig::useCase`):
///   1. RequestSession.cwd_session (explicit per-call, NEW behaviour
///      BEFORE this migration stays the same)
///   2. workspace_item_tasks.cwd     (this column — NEW)
///   3. workspace_items.path         (existing kanban-level fallback)
///   4. createSandbox(...)            (per-session TMPDIR fallback)
///
/// Empty string is the canonical "no per-task cwd" sentinel (NOT
/// NULL DEFAULT '' matches the `description` / `tags` / `image_urls`
/// pattern from Migrations 062 / 067 / 069). Existing rows backfill
/// to `''` (cwd-less legacy tasks) when the migration runs on an
/// existing DB.
///
/// Plan: docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md
/// Task: task_1785959915548 (kanban: sprint bulan juni →
///   "when user want to create a kanban, make cwd session as optional")
///
/// Renamed from Migration 070 during PR #200 merge (main already
/// used 070 for the agent_memories migration).
pub const Migration071AddTaskCwd = struct {
    pub const version: u32 = 71;
    pub const name = "add_task_cwd";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // `cwd TEXT NOT NULL DEFAULT ''` — the empty string is the
        // canonical "no per-task cwd" sentinel (matches the
        // description / tags / image_urls patterns from Migrations
        // 062 / 067 / 069). `addColumnIfMissing` constructs
        // `ALTER TABLE {table} ADD COLUMN {definition}`, so the
        // definition MUST include the column name AND the type —
        // omitting the type would create a column literally named
        // "TEXT NOT NULL DEFAULT ''". See project memory
        // `addColumnIfMissing-requires-name-type`.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "cwd",
            "cwd TEXT NOT NULL DEFAULT ''",
        );
    }
};
