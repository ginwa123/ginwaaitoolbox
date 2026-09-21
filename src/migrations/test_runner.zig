//! Test runner for the migrations module.
//!
//! Aggregates all migration-level unit tests so they are discovered by the
//! project's top-level `zig build test` target (which imports this file via
//! `src/root.zig:446`).
//!
//! Follows the same convention as `src/ai_workflow/tui/test_runner.zig`:
//! every `_test.zig` sibling that exercises a real contract must be
//! imported here, otherwise its tests are silently compiled out and the
//! count stays at the pre-import baseline.
//!
//! `migration_performance_indexes_test.zig` is intentionally NOT imported
//! (the file is currently empty — a placeholder for a future PR).

test {
    _ = @import("migration_test.zig");
    _ = @import("migration_009_test.zig");
    _ = @import("migration_routines_test.zig");
    _ = @import("migration_chat_list_index_test.zig");
    _ = @import("migration_defensive_indexes_test.zig");
    _ = @import("migration_git_worktree_test.zig");
    _ = @import("migration_051_test.zig");
    _ = @import("migration_053_test.zig");
    _ = @import("migration_054_test.zig");
    _ = @import("migration_058_test.zig");  // FTS5 on llm_history for workspace history search
    _ = @import("migration_059_test.zig");  // created_iso STORED generated column (since/until fix)
    _ = @import("migration_060_test.zig");  // re-backfill for production DBs with NULL created_iso
    _ = @import("migration_061_test.zig");  // re-backfill wrong-year (58507-...) created_iso rows
    _ = @import("migration_062_test.zig");  // workspace_item_tasks.description (kanban task detail dialog, Chunk 1)
    _ = @import("migration_063_test.zig");  // sessions.is_auto_retry_until_stop + last_finish_reason (unattended long-running sessions)
    _ = @import("migration_064_test.zig");  // logs table for frontend error capture (frontend-error-logs, Chunk 1)
    _ = @import("migration_065_test.zig");  // workspace_item_tasks.last_human_touched_at (kanban task notification icon, Chunk 1)
    _ = @import("migration_066_test.zig");  // design_pages.workspace_item_task_id FK + backfill (design-page-task-fk plan, Task 1)
    _ = @import("migration_067_test.zig");  // workspace_item_tasks.tags (kanban task tags, Task 1)
    _ = @import("migration_068_test.zig");  // llm_history.is_loading + UNIQUE INDEX on tool_call_id (tool-call-loading-placeholder plan)
    _ = @import("migration_069_test.zig");  // workspace_item_tasks.image_urls (kanban-image-urls-column plan, 2026-08-06)
    _ = @import("migration_070_test.zig");  // agent_memories + agent_memories_fts FTS5 (save-load-memory-fts5 plan, 2026-08-06)
    _ = @import("migration_071_test.zig");  // workspace_item_tasks.cwd (kanban-cwd-session-optional plan, 2026-08-06)
    _ = @import("migration_072_test.zig");  // workspace_item_tasks → kanban table extraction (extract-kanban-columns plan, 2026-08-15)
    _ = @import("migration_073_test.zig");  // session_activity append-only log (new-table-session-activity plan, 2026-08-13)
    _ = @import("migration_074_test.zig");  // llm_history.cache_creation_input_tokens + cache_read_input_tokens (fix-anthropic-total-tokens plan, 2026-08-13)
    _ = @import("migration_075_test.zig");  // rename 5 timestamp columns to _nano suffix (rename-timestamp-columns-nano-suffix plan, 2026-08-16)
    _ = @import("migration_077_test.zig");  // users + user_companies + user_company_members + workspaces.user_id + sessions.user_id + user_system + backfill (users-rbac-foundation plan, 2026-08-21)
    _ = @import("migration_082_test.zig");  // sessions.last_human_touched_at_nano (chat-sidebar-last-human-touched plan, 2026-08-29)
    // Migration 078 tests live inline at the bottom of migration.zig
    // (impl + tests in one file — project convention for Agent Mode).
    // The @import below is what makes those top-level `test` blocks
    // discoverable by `zig build test`.
    _ = @import("migration.zig");
    _ = @import("migration_057_test.zig");  // v6 design element properties — moved into migrations/ in Phase 7
    _ = @import("migration_063_runtime_test.zig");  // sessions.is_auto_retry_until_stop + last_finish_reason (unattended long-running sessions) — moved into migrations/ in Phase 7
}
