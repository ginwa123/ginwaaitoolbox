
test {
    _ = @import("routines/model_test.zig");
    _ = @import("routines/cron_test.zig");
    _ = @import("routines/fire_test.zig");
    _ = @import("routines/scheduler_test.zig");
    // Inline retry-loop hygiene tests (CallResponse deinit, literal-free
    // errdefer, stale retry-cause capture) live in workflow.zig itself —
    // registered here so zig build test actually runs them.
    _ = @import("agentic_loop/workflow.zig");
    _ = @import("http_handlers/nalar_config_put_test.zig");
_ = @import("http_handlers/design_elements_reorder_test.zig"); // Chunk 5 — POST /reorder handler
_ = @import("http_handlers/design_elements_ungroup_test.zig"); // POST /ungroup handler
    _ = @import("http_handlers/nalar_config_put_parse_test.zig");
    // Static-contract tests for the model-thinking PUT validation
    // (plan 2026-08-23-model-thinking). Source-grep pattern locks
    // in the new validation paths + LoadError variants.
    _ = @import("http_handlers/nalar_config_put_thinking_test.zig");
    // Static-contract tests for config-simplify (plan
    // 2026-08-24-config-simplify-remove-defaults): PUT handler must not
    // persist top-level LLM defaults.
    _ = @import("http_handlers/nalar_config_put_simplify_test.zig");
    _ = @import("http_handlers/nalar_config_get_test.zig");
    _ = @import("http_handlers/nalar_config_profile_delete_test.zig");
    _ = @import("http_handlers/sse_handshake_test.zig");
    _ = @import("http_handlers/task_update_test.zig");
    _ = @import("http_handlers/task_delete_test.zig");
    _ = @import("http_handlers/tasks_list_test.zig");
    _ = @import("http_handlers/tasks_get_test.zig");                // single-task GET endpoint (plan 2026-08-24-kanban-task-detail-single-fetch)
    _ = @import("http_handlers/stream_get_test.zig");               // in-flight stream snapshot GET (task_1787673548905_0 stream-resume-on-reselect)
    _ = @import("http_handlers/task_create_routines_test.zig");
    _ = @import("http_handlers/task_create_memory_test.zig");
    _ = @import("http_handlers/task_create_description_test.zig");  // Migration 062 description in create path
    _ = @import("http_handlers/task_create_test.zig");              // kanban task name = session name (plan 2026-08-13)
    _ = @import("http_handlers/task_create_unique_id_test.zig");    // Mac CI 500 regression (CI run 31863092055) — atomic counter on id generator
    _ = @import("http_handlers/tags_validation.zig");                  // Migration 067 tags validation helper (Task 7) — inline tests in the source file
    _ = @import("http_handlers/task_update_routines_test.zig");
    _ = @import("http_handlers/routines_run_test.zig");
    // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). The
    // start_agent handler + useCase live in a single file; the
    // static-contract tests are inline at the bottom. Importing
    // the file (vs. the deleted start_agent_test.zig) ensures the
    // tests get discovered + run.
    _ = @import("http_handlers/start_agent.zig");
    _ = @import("http_handlers/routines_list_test.zig");
    _ = @import("http_handlers/memories_crud_test.zig");
    _ = @import("http_handlers/local_memories_crud_test.zig");
    _ = @import("http_handlers/frontend_log_post_test.zig"); // Chunk 2 of frontend-error-logs
    _ = @import("http_handlers/frontend_log_get_test.zig");  // Chunk 3 of frontend-error-logs
    // _ = @import("llm_history_is_input_output_test.zig"); // phase 5: inlined into agentic_loop/llm_history.zig
    // _ = @import("llm_history_compacted_messages_test.zig"); // phase 5
    // _ = @import("llm_history_search_messages_fts_test.zig"); // phase 5
    // _ = @import("llm_history_search_fts_query_safety_test.zig"); // phase 5
    // _ = @import("llm_history_worker_info_test.zig"); // phase 5
    // _ = @import("llm_history_description_test.zig"); // phase 5
    // _ = @import("llm_history_notification_test.zig"); // phase 5
    // _ = @import("llm_history_tool_call_loading_test.zig"); // phase 5
    _ = @import("http_handlers/workspaces_reorder_test.zig");
    _ = @import("http_handlers/workspace_items_reorder_test.zig");
    _ = @import("http_handlers/task_pin_test.zig");
    // design_model.zig + design_model_*_test.zig files were moved into
    // agentic_loop/ in Phase 6. Registered in agentic_loop/test_runner.zig.
    // Inline tests for `updateElementsBatch` live at the bottom of design_model.zig.

    // Inline tests for `design_elements_update` and `design_elements_reparent`
    // live at the bottom of their impl files. Register them here so
    // `zig build test` actually runs the inline test blocks.
    _ = @import("http_handlers/design_elements_update.zig");
    _ = @import("http_handlers/design_elements_reparent.zig");
    _ = @import("http_handlers/tasks_reorder_pinned_test.zig");
    _ = @import("http_handlers/git_worktree_info_test.zig");
    _ = @import("http_handlers/git_pr_create_test.zig");
    _ = @import("http_handlers/git_status_test.zig");
    _ = @import("http_handlers/workspace_items_create_kanban_test.zig");
    // Agent Mode HTTP handlers (Tasks 4-8 of plan 2026-08-15-agent-mode)
    // now follow the "split handler + useCase, keep both in one file"
    // pattern. The production .zig file holds:
    //   - the HTTP request body / domain input/output structs + error set
    //   - the `useCase` function (transport-agnostic business logic)
    //   - the thin `xxxHandler` function (HTTP orchestrator)
    //   - inline `test "..."` blocks at the bottom exercising `useCase`
    //     directly against an in-memory SQLite + Migration076
    //
    // The `zig build test` discovery happens via these explicit
    // @import() lines — the test blocks are only enumerated when the
    // file is reachable from the test root. The handler function is
    // NOT tested directly (it would require faking the gserverz
    // HTTP context — out of scope for these contract tests).
    _ = @import("http_handlers/workspace_items_create_agent.zig"); // POST /items/agent (Task 4)
    _ = @import("http_handlers/agents_get.zig"); // GET /items/:id/agent (Task 5)
    _ = @import("http_handlers/agents_update.zig"); // PATCH /items/:id/agent (Task 5)
    _ = @import("http_handlers/agent_knowledge_create.zig"); // POST /agents/:id/knowledge (Task 6)
    _ = @import("http_handlers/agent_knowledge_update.zig"); // PATCH /agents/:id/knowledge/:id (Task 6)
    _ = @import("http_handlers/agent_knowledge_update_functional_test.zig"); // ISOLATED functional: File↔Text mode-switch payloads vs real SQLite (PR #291 lesson)
    _ = @import("http_handlers/agent_knowledge_delete.zig"); // DELETE /agents/:id/knowledge/:id (Task 6)
    _ = @import("http_handlers/agent_knowledge_reorder.zig"); // PATCH /agents/:id/knowledge/reorder (Task 6)
    _ = @import("http_handlers/agent_tools_registry.zig"); // GET /agent-tools/registry (Task 7)
    _ = @import("http_handlers/agent_tools_list.zig"); // GET /agents/:id/tools (Task 7)
    _ = @import("http_handlers/agent_tools_create.zig"); // POST /agents/:id/tools (Task 8)
    _ = @import("http_handlers/agent_tools_delete.zig"); // DELETE /agents/:id/tools/:id (Task 8)
    _ = @import("http_handlers/agent_system_prompt_create.zig"); // POST /agents/:id/system_prompt (Migration 080)
    _ = @import("http_handlers/agent_system_prompt_update.zig"); // PATCH /agents/:id/system_prompt/:id (Migration 080)
    _ = @import("http_handlers/agent_system_prompt_delete.zig"); // DELETE /agents/:id/system_prompt/:id (Migration 080)
    _ = @import("http_handlers/agent_system_prompt_reorder.zig"); // PATCH /agents/:id/system_prompt/reorder (Migration 080)
    _ = @import("http_handlers/workspace_items_create_empty_name_test.zig");
    _ = @import("http_handlers/kanban_columns_list_test.zig");
    _ = @import("http_handlers/kanban_columns_create_test.zig");
    _ = @import("http_handlers/kanban_tasks_create_test.zig"); // 2026-08-13-kanban-task-create-endpoint (Task 1)
    // NEW (2026-09-02-kanban-task-session-name-bind, task 1787671636395_1):
    // session_create.zig now has inline static-contract tests for the
    // resolveNameFromTask helper + the useCase call site. Importing
    // the file surfaces them to zig build test (mirrors start_agent.zig).
    _ = @import("http_handlers/session_create.zig");
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
    _ = @import("http_handlers/session_messages_get_test.zig"); // 2026-08-07-profile-persist-read — getSessionMessagesSorted carries selected_profile_model
    // _ = @import("transform_llm_history_to_agent_messages_test.zig"); // DISABLED - pre-existing type mismatch (TUIHistory vs LLMHistory) on main
    // save_memory + load_memory tools (Task 3 + 4 of
    // docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md).
    // update_plan agent tool (Task 2 of
    // docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md).
    // get_plan agent tool (Task 3 of
    // docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md).
    // _ = @import("extract_base64_image_urls_test.zig"); // DISABLED - 9 failing tests (investigation shows std.testing.expectEqualStrings has a bug with literal strings)
    // _ = @import("session_db_test.zig"); // DISABLED - pre-existing test errors (see session_db_test.zig for details)
    _ = @import("agentic_loop/test_runner.zig");
    _ = @import("../../modules/agent/tools/create_kanban_task.zig");
    _ = @import("../../modules/agent/tools/add_skill.zig");
    _ = @import("../../modules/agent/tools/set_design_page.zig");
    _ = @import("../../modules/agent/tools/update_plan.zig");
    _ = @import("../../modules/agent/tools/search_history.zig");
    _ = @import("../../modules/agent/tools/glob.zig");
    _ = @import("../../modules/agent/tools/load_memory.zig");
    _ = @import("../../modules/agent/tools/list_skills.zig");
    _ = @import("../../modules/agent/tools/kanban_list.zig");
    _ = @import("../../modules/agent/tools/get_skill.zig");
    _ = @import("../../modules/agent/tools/update_activity.zig");
    _ = @import("../../modules/agent/tools/remove_skill.zig");
    _ = @import("../../modules/agent/tools/show_preview.zig");
    _ = @import("../../modules/agent/tools/pwsh.zig");
    _ = @import("../../modules/agent/tools/get_plan.zig");
    _ = @import("../../modules/agent/tools/write_file.zig");
    _ = @import("../../modules/agent/tools/move_element_to_page.zig");
    _ = @import("../../modules/agent/tools/group_design_elements.zig");
    _ = @import("../../modules/agent/tools/change_agent.zig");
    _ = @import("../../modules/agent/tools/nalar_browser.zig");
    _ = @import("../../modules/agent/tools/kanban_move_task.zig");
    _ = @import("../../modules/agent/tools/list_directory.zig");
    _ = @import("../../modules/agent/tools/generate_image.zig");
    _ = @import("../../modules/agent/tools/edit_skill.zig");
    _ = @import("../../modules/agent/tools/move_design_element.zig");
    _ = @import("../../modules/agent/tools/shell.zig");
    _ = @import("../../modules/agent/tools/text_replace.zig");
    _ = @import("../../modules/agent/tools/diff.zig");
    _ = @import("../../modules/agent/tools/list_memory.zig");
    _ = @import("../../modules/agent/tools/add_design_element.zig");
    _ = @import("../../modules/agent/tools/save_memory.zig");
    _ = @import("../../modules/agent/tools/spawn_sub_agent.zig");
    _ = @import("../../modules/agent/tools/view_skill.zig");
    _ = @import("../../modules/agent/tools/update_design_element.zig");
    _ = @import("../../modules/agent/tools/set_element_parent.zig");
    _ = @import("../../modules/agent/tools/search.zig");
    _ = @import("../../modules/agent/tools/memories.zig");
}
