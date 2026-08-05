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
    _ = @import("migration_058_test.zig");  // FTS5 on llm_history for search-history rewrite
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
    _ = @import("../ai_workflow/tui/migration_057_test.zig");  // v6 design element properties — kept at old path on this branch
}
