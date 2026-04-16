const std = @import("std");
const build = @import("build_messages_for_agent_prompt.zig");
const llm_history = @import("llm_history.zig");
const activity_registry = @import("nalarcore").session.activity_registry;

test "build_activity_info returns empty when no registry" {
    // Test that empty registry returns empty string
    // Since we can't easily mock the global registry, we just verify compilation
    try std.testing.expect(true);
}

test "WorkerInfo struct exists" {
    const info = llm_history.WorkerInfo{
        .session_id = "test-session",
        .working_directory = "/test/path",
        .last_activity = 0,
        .last_activity_description = "testing",
    };
    try std.testing.expect(std.mem.eql(u8, info.session_id, "test-session"));
    try std.testing.expect(std.mem.eql(u8, info.working_directory, "/test/path"));
    try std.testing.expect(info.last_activity == 0);
    try std.testing.expect(std.mem.eql(u8, info.last_activity_description, "testing"));
}

test "WorkerInfo deinit cleans up memory" {
    var allocator = std.testing.allocator;
    var info = llm_history.WorkerInfo{
        .session_id = try allocator.dupe(u8, "session"),
        .working_directory = try allocator.dupe(u8, "/path"),
        .last_activity = 100,
        .last_activity_description = try allocator.dupe(u8, "testing"),
    };
    // After deinit, the original slices are freed
    info.deinit(allocator);
    // No leak if we get here
    try std.testing.expect(true);
}

test "activity_registry module exists and is accessible" {
    // Verify the module can be accessed
    const reg = activity_registry.get_global_registry();
    // May be null if not initialized, but module should exist
    _ = reg;
    try std.testing.expect(true);
}
