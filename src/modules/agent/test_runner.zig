test {
    // LLMModels tests (14 existing getModelTokenCount/isDoCompact + 6 new wrappers)
    _ = @import("LLMModels_test.zig");

    // Image content tests
    _ = @import("image_content_test.zig");

    // callStreaming deadline / network-disconnect regression tests
    _ = @import("call_streaming_test.zig");

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
    _ = @import("tools/read_compacted_messages_test.zig");
    _ = @import("tools/kanban_list_test.zig");
    _ = @import("tools/kanban_move_task_test.zig");
    _ = @import("tools/set_design_page_test.zig");
    _ = @import("tools/add_design_element_test.zig");

    // Bash tool cross-platform tests
    _ = @import("tools/bash_test.zig");
}
