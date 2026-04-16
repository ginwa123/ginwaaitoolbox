const std = @import("std");
const llm_history = @import("llm_history.zig");

test "WorkerInfo struct exists and functions correctly" {
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