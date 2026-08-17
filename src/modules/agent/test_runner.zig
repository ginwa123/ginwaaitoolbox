test {
    // LLMModels tests (14 existing getModelTokenCount/isDoCompact + 6 new wrappers)
    _ = @import("LLMModels_test.zig");

    // Image content tests
    _ = @import("image_content_test.zig");

    // callStreaming deadline / network-disconnect regression tests
    _ = @import("call_streaming_test.zig");

    // Anthropic /v1/messages SSE parser + raw-error-surfacing tests
    _ = @import("parse_anthropic_sse_test.zig");

    // Agent request-body userIdentifier tests
    _ = @import("agent_request_user_id_test.zig");

    // Anthropic request-body shape tests (system/top-level, budget_tokens,
// temperature/thinking conflict, stream_options removal)
    _ = @import("anthropic_request_test.zig");

    // Prompt builder tests
    _ = @import("prompts_test.zig");

    // Tool tests
    _ = @import("tools/change_agent_test.zig");
    _ = @import("tools/diff_test.zig");
    _ = @import("tools/text_replace_test.zig");
    _ = @import("tools/list_skills_test.zig");
    _ = @import("tools/list_memory_test.zig");
    _ = @import("tools/memories_test.zig");
    _ = @import("tools/get_skill_test.zig");
    _ = @import("tools/glob_test.zig");
    _ = @import("tools/add_skill_test.zig");
    _ = @import("tools/edit_skill_test.zig");
    _ = @import("tools/remove_skill_test.zig");
    _ = @import("tools/spawn_sub_agent_test.zig");
    _ = @import("tools/view_skill_test.zig");
    _ = @import("tools/nalar_browser_test.zig");
    _ = @import("tools/set_git_worktree_test.zig");
    _ = @import("tools/search_history_test.zig");
    _ = @import("tools/kanban_list_test.zig");
    _ = @import("tools/kanban_move_task_test.zig");
    _ = @import("tools/create_kanban_task_test.zig");
    _ = @import("tools/set_design_page_test.zig");
    _ = @import("tools/add_design_element_test.zig");
    _ = @import("tools/update_design_element_test.zig");
    _ = @import("tools/group_design_elements_test.zig");
    _ = @import("tools/set_element_parent_test.zig"); // 2026-07-29 — re-parents existing element to new group/frame (Task 5)
    _ = @import("tools/move_design_element_test.zig"); // 2026-08-06 — moves element by (dx, dy) with optional cascade to descendants (Plan: docs/superpowers/plans/2026-08-06-move-element-with-descendants.md)

    // Bash tool cross-platform tests
    _ = @import("tools/bash_test.zig");

    // Shared shell core + pwsh tool tests (Task 1 + 3 of 2026-08-14-pwsh-tool.md)
    _ = @import("tools/shell_test.zig");
    _ = @import("tools/pwsh_test.zig");

    // Search tool edge cases (validation + behavioral + static-contract)
    _ = @import("tools/search_test.zig");

    // Write file tool edge cases (sanity + content shape + path shape +
    // ownership + XML serialization + tool schema contract)
    _ = @import("tools/write_file_test.zig");

    // generate_image tool tests (DALL-E 2/3, gpt-image-1 via OpenAI Images API)
    // Plan: docs/superpowers/plans/2026-08-14-generate-image-tool.md
    _ = @import("tools/generate_image_test.zig");

    // update_activity helper tests — moved from tui/update_activity_test.zig
    // to modules/agent/tools/update_activity_test.zig in Phase 7 of
    // docs/superpowers/plans/2026-08-14-flatten-tui-into-agentic-loop.md.
    // Migration 073 — session_activity wiring + recordSessionActivity.
    _ = @import("tools/update_activity_test.zig");

    // 2026-08-14 — shared absolute-path validator + cwd resolver
    // (Plan: docs/superpowers/plans/2026-08-14-ban-absolute-paths.md,
    // Task 1). Used by every tool's exec wrapper.
    _ = @import("tools/path_security_test.zig");

    // 2026-08-14 — list_directory agent tool tests (Task 5 of the same plan).
    _ = @import("tools/list_directory_test.zig");
}
