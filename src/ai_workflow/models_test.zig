const std = @import("std");
const models = @import("models.zig");
const TUIHistory = models.TUIHistory;

test "TUIHistory struct creation and field access" {
    const allocator = std.testing.allocator;
    
    var history = TUIHistory{
        .id = try allocator.dupe(u8, "test-id-123"),
        .session_id = try allocator.dupe(u8, "session-456"),
        .model = try allocator.dupe(u8, "gpt-4"),
        .created = try allocator.dupe(u8, "2024-01-01T00:00:00Z"),
        .response_content = try allocator.dupe(u8, "Test response content"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "assistant"),
        .tools = try allocator.dupe(u8, "[]"),
        .reasoning_content = try allocator.dupe(u8, "Test reasoning"),
        .agent = try allocator.dupe(u8, "GeneralAgent"),
        .session_name = try allocator.dupe(u8, "Test Session"),
        .loop_index = 42,
    };
    defer history.deinit(allocator);
    
    // Verify all fields
    try std.testing.expectEqualStrings("test-id-123", history.id);
    try std.testing.expectEqualStrings("session-456", history.session_id);
    try std.testing.expectEqualStrings("gpt-4", history.model);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00Z", history.created);
    try std.testing.expectEqualStrings("Test response content", history.response_content);
    try std.testing.expectEqualStrings("stop", history.finish_reason);
    try std.testing.expectEqualStrings("assistant", history.role);
    try std.testing.expectEqualStrings("[]", history.tools);
    try std.testing.expectEqualStrings("Test reasoning", history.reasoning_content.?);
    try std.testing.expectEqualStrings("GeneralAgent", history.agent);
    try std.testing.expectEqualStrings("Test Session", history.session_name);
    try std.testing.expectEqual(@as(u32, 42), history.loop_index);
}

test "TUIHistory with null reasoning_content" {
    const allocator = std.testing.allocator;
    
    var history = TUIHistory{
        .id = try allocator.dupe(u8, "test-id"),
        .session_id = try allocator.dupe(u8, "session"),
        .model = try allocator.dupe(u8, "model"),
        .created = try allocator.dupe(u8, "2024-01-01"),
        .response_content = try allocator.dupe(u8, "content"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "user"),
        .tools = try allocator.dupe(u8, ""),
        .reasoning_content = null,
        .agent = try allocator.dupe(u8, "GeneralAgent"),
        .session_name = try allocator.dupe(u8, ""),
        .loop_index = 0,
    };
    defer history.deinit(allocator);
    
    try std.testing.expect(history.reasoning_content == null);
}

test "TUIHistory default values" {
    const allocator = std.testing.allocator;
    
    var history = TUIHistory{
        .id = try allocator.dupe(u8, "id"),
        .session_id = try allocator.dupe(u8, "session"),
        .model = try allocator.dupe(u8, "model"),
        .created = try allocator.dupe(u8, "created"),
        .response_content = try allocator.dupe(u8, "content"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "assistant"),
        .tools = try allocator.dupe(u8, ""),
        .agent = try allocator.dupe(u8, "GeneralAgent"),
        .session_name = try allocator.dupe(u8, ""),
        .loop_index = 0,
    };
    defer history.deinit(allocator);
    
    // Test default agent value
    try std.testing.expectEqualStrings("GeneralAgent", history.agent);
    // Test default session_name
    try std.testing.expectEqualStrings("", history.session_name);
    // Test default loop_index
    try std.testing.expectEqual(@as(u32, 0), history.loop_index);
}

test "TUIHistory deinit frees all memory" {
    const allocator = std.testing.allocator;
    
    var history = TUIHistory{
        .id = try allocator.dupe(u8, "test-id"),
        .session_id = try allocator.dupe(u8, "session"),
        .model = try allocator.dupe(u8, "model"),
        .created = try allocator.dupe(u8, "created"),
        .response_content = try allocator.dupe(u8, "content"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "role"),
        .tools = try allocator.dupe(u8, "tools"),
        .reasoning_content = try allocator.dupe(u8, "reasoning"),
        .agent = try allocator.dupe(u8, "agent"),
        .session_name = try allocator.dupe(u8, "session_name"),
        .loop_index = 1,
    };
    
    // This should not leak memory
    history.deinit(allocator);
}

test "TUIHistory deinit with null reasoning_content" {
    const allocator = std.testing.allocator;
    
    var history = TUIHistory{
        .id = try allocator.dupe(u8, "test-id"),
        .session_id = try allocator.dupe(u8, "session"),
        .model = try allocator.dupe(u8, "model"),
        .created = try allocator.dupe(u8, "created"),
        .response_content = try allocator.dupe(u8, "content"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "role"),
        .tools = try allocator.dupe(u8, "tools"),
        .reasoning_content = null,
        .agent = try allocator.dupe(u8, "agent"),
        .session_name = try allocator.dupe(u8, "session_name"),
        .loop_index = 1,
    };
    
    // This should not leak memory or crash
    history.deinit(allocator);
}
