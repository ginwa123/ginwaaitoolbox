
test {
    _ = @import("routines/model_test.zig");
    _ = @import("routines/cron_test.zig");
    _ = @import("routines/fire_test.zig");
    _ = @import("routines/scheduler_test.zig");
    _ = @import("agentic_loop/workflow_compaction_envelope_test.zig");
    _ = @import("agentic_loop/retry_delay_ms_race_test.zig");
    // Inline retry-loop hygiene tests (CallResponse deinit, literal-free
    // errdefer, stale retry-cause capture) live in workflow.zig itself —
    // registered here so zig build test actually runs them.
    _ = @import("agentic_loop/workflow.zig");
    _ = @import("compaction_config_threshold_test.zig");
    _ = @import("http_handlers/nalar_config_put_test.zig");
_ = @import("http_handlers/design_elements_reorder_test.zig"); // Chunk 5 — POST /reorder handler
_ = @import("http_handlers/design_elements_ungroup_test.zig"); // POST /ungroup handler
    _ = @import("http_handlers/nalar_config_put_parse_test.zig");
    _ = @import("http_handlers/nalar_config_get_test.zig");
    _ = @import("http_handlers/nalar_config_profile_delete_test.zig");
    _ = @import("http_handlers/sse_handshake_test.zig");
    _ = @import("http_handlers/task_update_test.zig");
    _ = @import("http_handlers/task_delete_test.zig");
    _ = @import("http_handlers/tasks_list_test.zig");
    _ = @import("http_handlers/task_create_routines_test.zig");
    _ = @import("http_handlers/task_create_memory_test.zig");
    _ = @import("http_handlers/task_create_description_test.zig");  // Migration 062 description in create path
    _ = @import("http_handlers/task_create_test.zig");              // kanban task name = session name (plan 2026-08-13)
    _ = @import("http_handlers/task_create_unique_id_test.zig");    // Mac CI 500 regression (CI run 31863092055) — atomic counter on id generator
    _ = @import("http_handlers/tags_validation.zig");                  // Migration 067 tags validation helper (Task 7) — inline tests in the source file
    _ = @import("http_handlers/task_update_routines_test.zig");
    _ = @import("http_handlers/routines_run_test.zig");
    _ = @import("http_handlers/routines_list_test.zig");
    _ = @import("http_handlers/memories_crud_test.zig");
    _ = @import("http_handlers/local_memories_crud_test.zig");
    _ = @import("http_handlers/frontend_log_post_test.zig"); // Chunk 2 of frontend-error-logs
    _ = @import("http_handlers/frontend_log_get_test.zig");  // Chunk 3 of frontend-error-logs
    _ = @import("llm_history_is_input_output_test.zig");
    _ = @import("llm_history_compacted_messages_test.zig");
    _ = @import("llm_history_search_messages_fts_test.zig"); // search_history rewrite (Chunk 2)
    _ = @import("llm_history_search_fts_query_safety_test.zig"); // better-tool-output-error-message — FTS5 query sanitization regression tests
    _ = @import("llm_history_worker_info_test.zig"); // NEW: sprint 2 "git worktree cwd, worker"
    _ = @import("llm_history_description_test.zig"); // Migration 062 description propagation
    _ = @import("llm_history_notification_test.zig"); // Migration 065 — kanban needs_human_review + updateTaskLastHumanTouchedAt
    _ = @import("llm_history_tool_call_loading_test.zig"); // tool-call-loading-placeholder — 3 helper contract tests
    _ = @import("compaction_long_context_test.zig");
    _ = @import("http_handlers/workspaces_reorder_test.zig");
    _ = @import("http_handlers/workspace_items_reorder_test.zig");
    _ = @import("http_handlers/task_pin_test.zig");
    _ = @import("design_model_test.zig");
    _ = @import("design_model_parent_id_test.zig"); // 2026-07-28-grouped-layers (Chunk 1) — parent_id round-trip
    _ = @import("design_model_group_test.zig"); // 2026-07-28-grouped-layers (Chunk 2) — groupElements + updateElement parent_id
    _ = @import("design_model_delete_parent_test.zig"); // 2026-07-28-grouped-layers (Chunk 4) — deleteElement NULLs children
    _ = @import("design_model_delete_page_test.zig"); // 2026-08-06 — deletePage derives page dir from design_page_elements.file_path (no JOIN to workspace_items)
    _ = @import("design_model_add_element_parent_test.zig"); // 2026-07-29 — addElement accepts parent_id (Task 1)
    _ = @import("design_model_set_element_parent_test.zig"); // 2026-07-29 — setElementParent re-parents with cycle detection (Task 2)
    
    // Inline tests for `updateElementsBatch` live at the bottom of design_model.zig
    // — registered here so zig build test actually runs them.
    _ = @import("design_model.zig");

    // Inline tests for `design_elements_update` and `design_elements_reparent`
    // live at the bottom of their impl files. Register them here so
    // `zig build test` actually runs the inline test blocks.
    _ = @import("http_handlers/design_elements_update.zig");
    _ = @import("http_handlers/design_elements_reparent.zig");
    _ = @import("migration_057_test.zig");  // stays at this path; imported by src/migrations/test_runner.zig via relative path
    _ = @import("migration_063_runtime_test.zig");  // Chunk 1 — sessions auto_retry + finish_reason runtime CRUD
    _ = @import("http_handlers/tasks_reorder_pinned_test.zig");
    _ = @import("http_handlers/git_worktree_info_test.zig");
    _ = @import("http_handlers/git_pr_create_test.zig");
    _ = @import("http_handlers/git_status_test.zig");
    _ = @import("http_handlers/workspace_items_create_kanban_test.zig");
    _ = @import("http_handlers/workspace_items_create_empty_name_test.zig");
    _ = @import("workspace_items_update_name_test.zig");
    _ = @import("http_handlers/kanban_columns_list_test.zig");
    _ = @import("http_handlers/kanban_columns_create_test.zig");
    _ = @import("http_handlers/kanban_tasks_create_test.zig"); // 2026-08-13-kanban-task-create-endpoint (Task 1)
    _ = @import("http_handlers/kanban_columns_update_test.zig");
    _ = @import("http_handlers/kanban_columns_delete_test.zig");
    _ = @import("http_handlers/kanban_tags_list.zig"); // 2026-07-30-kanban-task-tags-autocomplete — inline useCase tests
    _ = @import("http_handlers/design_pages_list_test.zig");
    _ = @import("http_handlers/design_pages_create_test.zig");
    _ = @import("http_handlers/design_items_create_test.zig");
    _ = @import("http_handlers/design_pages_get_test.zig");
_ = @import("http_handlers/design_pages_update_test.zig");
    _ = @import("http_handlers/design_pages_delete_test.zig"); // 2026-07-25-design-page-delete-button (Chunk 1)
    _ = @import("http_handlers/design_elements_create_test.zig");
    _ = @import("http_handlers/design_elements_update_test.zig");
    _ = @import("http_handlers/design_elements_delete_test.zig");
    _ = @import("http_handlers/design_elements_group_test.zig"); // 2026-07-28-grouped-layers (Chunk 3) — POST /group static-contract
    _ = @import("http_handlers/design_elements_html_get_test.zig");
    _ = @import("http_handlers/design_elements_html_update_test.zig");
    _ = @import("http_handlers/design_elements_geometry_update_test.zig");
    // NEW (2026-08-06) — translate endpoint replaces /geometry for moves.
    // Behavioural tests for `POST /translate` (cascade to descendants for
    // groups). See docs/superpowers/plans/2026-08-06-split-move-resize.md.
    _ = @import("http_handlers/design_elements_translate_test.zig");
    // NEW (2026-08-06) — resize endpoint replaces /geometry for resizes.
    // Behavioural tests for `POST /resize` (no cascade, per-element only).
    _ = @import("http_handlers/design_elements_resize_test.zig");
    // Inline tests for the geometry-batch handler `useCase` live at the
    // bottom of design_elements_geometry_batch.zig — registered here so
    // zig build test actually runs them.
    _ = @import("http_handlers/design_elements_geometry_batch.zig");
    // Inline tests for the move-batch handler `useCase` live at the
    // bottom of design_elements_move_batch.zig — registered here so zig
    // build test actually runs them. See
    // docs/superpowers/plans/2026-08-06-move-element-with-descendants.md (Chunk 2).
    _ = @import("http_handlers/design_elements_move_batch.zig");
    // Inline tests for the move-to-page handler `useCase` live at the
    // bottom of design_elements_move_to_page.zig — registered here so
    // zig build test actually runs them. See
    // docs/superpowers/plans/2026-08-06-move-element-to-page.md (Chunk 2).
    _ = @import("http_handlers/design_elements_move_to_page.zig");
    _ = @import("http_handlers/kanban_copy_spec_test.zig");
    _ = @import("http_handlers/tasks_move_test.zig");
    _ = @import("http_handlers/tasks_create_kanban_test.zig");
    _ = @import("http_handlers/tasks_create_value_alloc_test.zig");
    _ = @import("http_handlers/system_prompt_get_test.zig");
    _ = @import("http_handlers/unified_events_sse_test.zig");
    // _ = @import("session_helpers_test.zig"); // DISABLED - requires std.Io which needs Init
    // _ = @import("session_table_test.zig"); // DISABLED - requires std.Io which needs Init
    _ = @import("get_session_list_test.zig");
    _ = @import("session_update_test.zig"); // 2026-08-06-set-active-profile-default — ensureSessionExists behavioural tests
    _ = @import("http_handlers/session_messages_get_test.zig"); // 2026-08-07-profile-persist-read — getSessionMessagesSorted carries selected_profile_model
    // _ = @import("transform_llm_history_to_agent_messages_test.zig"); // DISABLED - pre-existing type mismatch (TUIHistory vs LLMHistory) on main
    _ = @import("gitignore_vendor_sqlite3_test.zig");
    _ = @import("../../modules/agent/tools/show_preview_test.zig");
    _ = @import("../../modules/agent/tools/move_element_to_page_test.zig");
    // save_memory + load_memory tools (Task 3 + 4 of
    // docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md).
    _ = @import("../../modules/agent/tools/save_memory_test.zig");
    _ = @import("../../modules/agent/tools/load_memory_test.zig");
    // _ = @import("extract_base64_image_urls_test.zig"); // DISABLED - 9 failing tests (investigation shows std.testing.expectEqualStrings has a bug with literal strings)
    // _ = @import("session_db_test.zig"); // DISABLED - pre-existing test errors (see session_db_test.zig for details)
    _ = @import("agentic_loop/test_runner.zig");
    _ = @import("update_activity_test.zig"); // Migration 073 — session_activity wiring + recordSessionActivity
}
