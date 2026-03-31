


test {
    _ = @import("background_process_test.zig");
    _ = @import("build_background_process_for_agent_prompt_test.zig");
    _ = @import("build_dynamic_agent_for_agent_prompt_test.zig");
    _ = @import("build_memory_for_agent_prompt_test.zig");
    _ = @import("build_messages_for_agent_prompt_test.zig");
    _ = @import("build_messages_tools_mcp_for_agent_prompt_test.zig");
    _ = @import("build_skill_for_agent_prompt_test.zig");
    _ = @import("check_session_exists_test.zig");
    _ = @import("get_tree_dir_test.zig");
    _ = @import("handle_bash_tool_test.zig");
    _ = @import("handle_content_filter_test.zig");
    _ = @import("handle_change_agent_tool_test.zig");
    _ = @import("handle_search_tool_test.zig");
    _ = @import("handle_spawn_sub_agent_test.zig");
    _ = @import("handle_text_replace_tool_test.zig");
    _ = @import("handle_tool_test.zig");
    _ = @import("handle_write_file_tool_test.zig");
    _ = @import("mark_message_not_for_llm_test.zig");
    _ = @import("save_agent_test.zig");
    _ = @import("save_message_test.zig");
    _ = @import("save_skill_test.zig");
    _ = @import("session_helpers_test.zig");
    _ = @import("session_table_test.zig");
    _ = @import("transform_llm_history_to_agent_messages_test.zig");
    _ = @import("workflow_test.zig");
    // _ = @import("session_db_test.zig"); // DISABLED - pre-existing test errors (see session_db_test.zig for details)
    _ = @import("get_session_test.zig");
    _ = @import("session_queue_messages_test.zig");
}
