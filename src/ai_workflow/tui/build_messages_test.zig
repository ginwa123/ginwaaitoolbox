const std = @import("std");
const build_messages = @import("build_messages_for_agent_prompt.zig");
const TUIHistory = @import("models.zig").TUIHistory;

test "buildMessages module imports" {
    // Test that the module can be imported without errors
    try std.testing.expect(true);
}

test "buildMessages function signature exists" {
    // Verify the function exists by checking it's callable
    const func_ptr = build_messages.buildMessages;
    _ = func_ptr;
    // Functions are valid, no need to check type
}

test "BuildSkillContent function exists" {
    // Verify BuildSkillContent function exists by checking it's callable
    const func_ptr = build_messages.BuildSkillContent;
    _ = func_ptr;
}

test "BuildMemoryForAgent function exists" {
    // Verify BuildMemoryForAgent function exists by checking it's callable
    const func_ptr = build_messages.BuildMemoryForAgent;
    _ = func_ptr;
}

test "BuildBackgroundProcessPrompt function exists" {
    // Verify BuildBackgroundProcessPrompt function exists by checking it's callable
    const func_ptr = build_messages.BuildBackgroundProcessPrompt;
    _ = func_ptr;
}

test "BuildDynamicAgentContent function exists" {
    // Verify BuildDynamicAgentContent function exists by checking it's callable
    const func_ptr = build_messages.BuildDynamicAgentContent;
    _ = func_ptr;
}

test "filterAndMergeTools function exists in workflow module" {
    // Verify filterAndMergeTools exists in workflow module by checking it's callable
    const workflow = @import("workflow.zig");
    const func_ptr = workflow.filterAndMergeTools;
    _ = func_ptr;
}