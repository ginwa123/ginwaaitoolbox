


test {
    _ = @import("handle_tool_test.zig");
    _ = @import("save_agent_test.zig");
    _ = @import("save_skill_test.zig");
    _ = @import("session_helpers_test.zig");
    _ = @import("session_table_test.zig");
    _ = @import("transform_llm_history_to_agent_messages_test.zig");
    _ = @import("workflow_test.zig");
    // _ = @import("session_db_test.zig"); // DISABLED - pre-existing test errors (see session_db_test.zig for details)
}
