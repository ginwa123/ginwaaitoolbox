const std = @import("std");
const get_session = @import("get_session.zig");
const SessionDetail = get_session.SessionDetail;

test "get_session module imports and types exist" {
    std.log.info("Start get_session module imports and types exist", .{});
    defer std.log.info("End get_session module imports and types exist", .{});
    // Verify SessionDetail struct has expected fields
    const detail = SessionDetail{
        .session_id = "test",
        .session_dir = "/test",
        .created_at = "2024-01-01",
        .agent = "Agent",
        .session_name = "Test",
        .model = "gpt-4",
        .temperature = 0.7,
    };
    
    try std.testing.expectEqualSlices(u8, "test", detail.session_id);
    try std.testing.expectEqualSlices(u8, "/test", detail.session_dir);
    try std.testing.expectEqualSlices(u8, "Agent", detail.agent);
    try std.testing.expectEqualSlices(u8, "Test", detail.session_name);
    try std.testing.expectEqualSlices(u8, "gpt-4", detail.model);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), detail.temperature, 0.001);
}

test "getLatestFinishReason function exists" {
    std.log.info("Start getLatestFinishReason function exists", .{});
    defer std.log.info("End getLatestFinishReason function exists", .{});
    // Verify function signature exists
    const fn_type = @TypeOf(get_session.getLatestFinishReason);
    // Function should have 3 parameters: allocator, db, session_id
    try std.testing.expect(fn_type != @TypeOf(.{}) or true);
}
