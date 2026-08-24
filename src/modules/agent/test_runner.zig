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

    // Anthropic thinking_budget_tokens override + type:adaptive mode
    // (plan 2026-08-23-model-thinking.md)
    _ = @import("anthropic_adaptive_test.zig");

    // OpenAI reasoning_effort field on the request body
    // (plan 2026-08-23-model-thinking.md)
    _ = @import("openai_reasoning_test.zig");

    // Prompt builder tests
    _ = @import("prompts_test.zig");

    // Tool tests
    _ = @import("tools/set_git_worktree_test.zig");

    // Bash tool cross-platform tests
    _ = @import("tools/bash_test.zig");

    // Shared shell core + pwsh tool tests (Task 1 + 3 of 2026-08-14-pwsh-tool.md)

    // Search tool edge cases (validation + behavioral + static-contract)

    // Write file tool edge cases (sanity + content shape + path shape +
    // ownership + XML serialization + tool schema contract)

    // generate_image tool tests (DALL-E 2/3, gpt-image-1 via OpenAI Images API)
    // Plan: docs/superpowers/plans/2026-08-14-generate-image-tool.md

    // update_activity helper tests — moved from tui/update_activity_test.zig
    // to modules/agent/tools/update_activity_test.zig in Phase 7 of
    // docs/superpowers/plans/2026-08-14-flatten-tui-into-agentic-loop.md.
    // Migration 073 — session_activity wiring + recordSessionActivity.


    // 2026-08-14 — list_directory agent tool tests (Task 5 of the same plan).
    _ = @import("tools/create_kanban_task.zig");
    _ = @import("tools/add_skill.zig");
    _ = @import("tools/set_design_page.zig");
    _ = @import("tools/update_plan.zig");
    _ = @import("tools/search_history.zig");
    _ = @import("tools/glob.zig");
    _ = @import("tools/load_memory.zig");
    _ = @import("tools/list_skills.zig");
    _ = @import("tools/kanban_list.zig");
    _ = @import("tools/get_skill.zig");
    _ = @import("tools/update_activity.zig");
    _ = @import("tools/remove_skill.zig");
    _ = @import("tools/show_preview.zig");
    _ = @import("tools/pwsh.zig");
    _ = @import("tools/get_plan.zig");
    _ = @import("tools/write_file.zig");
    _ = @import("tools/move_element_to_page.zig");
    _ = @import("tools/group_design_elements.zig");
    _ = @import("tools/change_agent.zig");
    _ = @import("tools/nalar_browser.zig");
    _ = @import("tools/kanban_move_task.zig");
    _ = @import("tools/list_directory.zig");
    _ = @import("tools/generate_image.zig");
    _ = @import("tools/edit_skill.zig");
    _ = @import("tools/move_design_element.zig");
    _ = @import("tools/shell.zig");
    _ = @import("tools/text_replace.zig");
    _ = @import("tools/diff.zig");
    _ = @import("tools/list_memory.zig");
    _ = @import("tools/add_design_element.zig");
    _ = @import("tools/save_memory.zig");
    _ = @import("tools/delete_memory.zig"); // 2026-08-24-delete-memory-agent-tool
    _ = @import("tools/spawn_sub_agent.zig");
    _ = @import("tools/view_skill.zig");
    _ = @import("tools/update_design_element.zig");
    _ = @import("tools/set_element_parent.zig");
    _ = @import("tools/search.zig");
    _ = @import("tools/memories.zig");
}
