// Test runner for the `agentic_loop/` directory.
//
// IMPORTANT: Zig's test runner only auto-discovers `test "..." { ... }` blocks
// in files that are **directly `@import`ed** here. A transitive import via
// `mod.zig` does NOT count — `mod.zig` is reachable but its descendants'
// `test` blocks are NOT automatically registered.
//
// Whenever you add a new `test "..." { ... }` block to an implementation file
// in this directory, ALSO add `_ = @import("your_file.zig");` to the list
// below. The README explains this in more detail.

test {
    // ─── Files with inline tests ──────────────────────────────────────────
    _ = @import("sse.zig");
    _ = @import("llm_history.zig");
    _ = @import("llm_history_is_input_output_test.zig");
    _ = @import("llm_history_compacted_messages_test.zig");
    _ = @import("llm_history_search_messages_fts_test.zig");
    _ = @import("llm_history_search_fts_query_safety_test.zig");
    _ = @import("llm_history_worker_info_test.zig");
    _ = @import("llm_history_description_test.zig");
    _ = @import("llm_history_notification_test.zig");
    _ = @import("llm_history_tool_call_loading_test.zig");
    _ = @import("session_skills.zig");
    _ = @import("is_session_kanban.zig");
    _ = @import("is_worker_running.zig");
    _ = @import("is_worker_cancelled.zig");
    _ = @import("has_queue_messagge.zig");
    _ = @import("get_queue_message.zig");
    _ = @import("update_worker.zig");
    _ = @import("delete_worker.zig");
    _ = @import("insert_queue_message.zig");
    _ = @import("delete_queue_worker.zig");
    _ = @import("insert_llm_histories.zig");
    _ = @import("get_llm_histories.zig");
    _ = @import("sse_send_event_worker.zig");
    _ = @import("sse_on_event_send_llm_history.zig");
    _ = @import("sse_on_event_send_session.zig"); // task_1786507100896 — behavioural tests for wire-format event_type_name mapping
    _ = @import("parsing.zig");
    _ = @import("workflow.zig");
    _ = @import("save_agent.zig"); // Phase 1 — save_agent module imports smoke test (was save_agent_test.zig)
    _ = @import("on_event_sent.zig"); // Phase 2 — inlined 7 tests from on_event_sent_sanitize_test.zig
    _ = @import("on_event_sent_design.zig"); // Phase 2 — inlined 5 tests from on_event_sent_design_test.zig
    _ = @import("inherited_context.zig"); // Phase 3 — inlined tests from inherited_context_test.zig
    _ = @import("agent_memories.zig"); // Phase 3 — inlined tests from agent_memories_test.zig
    _ = @import("kanban_model.zig"); // Phase 4 — inlined tests from 3 kanban_model_*_test.zig files
    _ = @import("design_io.zig"); // Phase 4 — inlined tests from design_io_test.zig
    _ = @import("design_model.zig"); // Phase 6 — inline updateElementsBatch + indexOf tests
    _ = @import("design_model_test.zig");
    _ = @import("design_model_parent_id_test.zig");
    _ = @import("design_model_group_test.zig");
    _ = @import("design_model_delete_parent_test.zig");
    _ = @import("design_model_delete_page_test.zig");
    _ = @import("design_model_add_element_parent_test.zig");
    _ = @import("design_model_set_element_parent_test.zig");
    _ = @import("session_update_test.zig"); // Phase 7 — kept as separate _test.zig (inlining would push llm_history.zig over the 256KB static-contract test file-size limit)
    _ = @import("workspace_items_update_name_test.zig"); // Phase 7 — same reason
    // design_model_reorder_test.zig — NOT registered. Pre-existing
    // schema/setup issues (5 tests crash with SIGABRT, 2 fail with
    // assertion errors) — the file was orphaned at tui/ before
    // this refactor and was never run. Per the refactor's
    // behaviour-preserving invariant, leave it orphaned. Address
    // the test failures in a follow-up.
    _ = @import("handle_tool.zig"); // 2026-08-06-fix-refactor-zig-imports — 16 inline parseDiffViewFromResult tests
    _ = @import("tools_wrap_output.zig");
    _ = @import("workflow_commpact_message.zig");
    _ = @import("workflow_compact_message.zig"); // 2026-08-14-consolidate-compaction-message — buildCompactMessagePrompt (8) + compaction_context helpers (22) = 30 inline tests
    _ = @import("workflow_compact_call_agent_test.zig"); // regression test for url_style propagation to CompactionAgent (fix-compact-url-style plan)
    _ = @import("prompts_make_working_directory_context.zig"); // never-create-memory-md — makeWorkingDirectoryContext must never force-create AGENTS.md / CLAUDE.md / NALAR.md (inline tests at the bottom of the impl file)
    // impl + tests are in the same .zig file for Agent Mode helpers.
    // No separate _test.zig imports needed here — the test blocks
    // inside agent_tools_allowed.zig and prompts_make_agent_knowledge.zig
    // are discovered automatically by `zig build test`.
}
