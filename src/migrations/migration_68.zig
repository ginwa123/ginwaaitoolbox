const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 068 — Add `llm_history.is_loading` column + partial
/// UNIQUE INDEX on `tool_call_id` (tool-call-loading-placeholder plan).
///
/// ## Why this migration exists
///
/// The OpenAI tool-call API contract requires every `tool_call_id`
/// declared in an assistant message's `tool_calls` array to have a
/// matching `role=tool` message in the next conversation payload, or
/// the API rejects with "Invalid function ID". If the agent crashes
/// mid-execution (long bash command, spawn_sub_agent dies, pabrik
/// process SIGKILL'd, network hang), the assistant message is
/// already in the DB but the per-tool result rows aren't — every
/// subsequent LLM call fails.
///
/// Fix: pre-create the placeholder `role=tool` rows BEFORE the
/// long-running tools execute (so the API contract is satisfied by
/// id), mark them `is_loading=1`, then UPDATE them in place after
/// the tool completes. A startup hook
/// (`resolveStaleLoadingToolResults`) replaces stranded placeholders
/// with a synthetic "interrupted" message.
///
/// ## What this does
///
/// 1. Add `is_loading INTEGER NOT NULL DEFAULT 0` to `llm_history`
///    via `addColumnIfMissing` — safe for both upgrade-from-v1 DBs
///    and fresh-DB installs (where the canonical CREATE TABLE in the
///    earlier migrations doesn't include the column yet).
///
/// 2. Backfill `is_loading = 0` for every existing row (the
///    canonical "not loading" sentinel — the migration runs before
///    any placeholder code path can land in the DB).
///
/// 3. Add a partial UNIQUE INDEX on `tool_call_id` so duplicate
///    placeholders for the same id are rejected at the DB level.
///    The partial WHERE clause excludes empty-string tool_call_ids
///    (the assistant message rows) so the assistant message's
///    `tool_call_id = ''` doesn't conflict with the placeholders'
///    `tool_call_id = 'tcA'` etc. Without this index, a dispatcher
///    race could create two placeholders for the same id.
///
/// ## Why `IF NOT EXISTS` on both
///
/// Both the column ADD and the INDEX CREATE use idempotent forms so
/// the migration is safe on re-run (per the project-wide
/// `migration-is-idempotent` invariant; see migration 020, 052, 054,
/// 065, 066 for prior art).
///
/// Plan: docs/superpowers/plans/2026-08-06-tool-call-loading-placeholder.md
/// Bug: task_1785784899843 ("invalid function ID tool call error")
pub const Migration068AddToolCallLoading = struct {
    pub const version: u32 = 68;
    pub const name = "add_tool_call_loading";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Add the `is_loading` column. Idempotent via
        //    `addColumnIfMissing` — safe for fresh-DB installs where
        //    the canonical CREATE TABLE in earlier migrations doesn't
        //    include it yet.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "is_loading",
            // name + type — `addColumnIfMissing` builds
            // `ALTER TABLE {table} ADD COLUMN {definition}`, so the
            // definition must include BOTH the column name AND the
            // type. Omitting the type would create a column literally
            // named "INTEGER NOT NULL DEFAULT 0" — see project memory
            // `addColumnIfMissing-requires-name-type`.
            "is_loading INTEGER NOT NULL DEFAULT 0",
        );

        // 2. Backfill every existing row to `is_loading = 0`. SQLite's
        //    ADD COLUMN with NOT NULL DEFAULT 0 *already* backfills
        //    legacy rows to 0 at the storage layer (DEFAULT applies to
        //    INSERT and backfill is part of ALTER TABLE ADD COLUMN),
        //    but we issue an explicit UPDATE here to make the sentinel
        //    intent obvious in the schema history. UPDATE is a no-op
        //    after the first run (every row already has 0).
        try db.exec(
            allocator,
            "UPDATE llm_history SET is_loading = 0 WHERE is_loading IS NULL OR is_loading != 0",
            &[_][]const u8{},
        );

        // 3. Partial UNIQUE INDEX on `tool_call_id`. The partial
        //    WHERE clause excludes empty-string tool_call_ids (the
        //    assistant message's `tool_call_id = ''`) so the assistant
        //    row doesn't conflict with the placeholder rows.
        //
        //    Name: `idx_llm_history_tool_call_id_loading` — the
        //    `_loading` suffix is intentional: future migrations may
        //    add a different UNIQUE INDEX for non-loading contexts
        //    (e.g. "current session feed" which needs the latest
        //    tool result per tool_call_id), and the name makes them
        //    easy to keep distinct.
        try db.exec(
            allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_llm_history_tool_call_id_loading " ++
                "ON llm_history(tool_call_id) " ++
                "WHERE tool_call_id IS NOT NULL AND tool_call_id != ''",
            &[_][]const u8{},
        );
    }
};
