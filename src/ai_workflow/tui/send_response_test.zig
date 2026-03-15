const std = @import("std");
const send_response = @import("send_response.zig");
const send_error = @import("send_error.zig");
const send_tool_result = @import("send_tool_result.zig");
const send_session_response = @import("send_session_response.zig");
const send_user_choice = @import("send_user_choice.zig");

test "send_error with valid inputs" {
    const allocator = std.testing.allocator;
    
    // Create a minimal logger for testing
    var logger = @import("../../modules/logger/logger.zig").Logger.init(allocator, .{
        .min_level = .trace,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger.deinit();
    
    // Test with invalid session_id (should return early without error)
    send_error.run(allocator, "invalid-session", &logger, "Test error message", "stop");
    
    // Test with null finish reason
    send_error.run(allocator, "invalid-session", &logger, "Another error", null);
}

test "send_tool_result" {
    const allocator = std.testing.allocator;
    
    var logger = @import("../../modules/logger/logger.zig").Logger.init(allocator, .{
        .min_level = .trace,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger.deinit();
    
    send_tool_result.SendToolResult(allocator, "invalid-session", &logger, "Command output", "call_123", "bash", "ls -la");
    
    // Test without command
    send_tool_result.SendToolResult(allocator, "invalid-session", &logger, "Output", "call_456", "list_skills", null);
}

test "send_user_choice" {
    const allocator = std.testing.allocator;
    
    var logger = @import("../../modules/logger/logger.zig").Logger.init(allocator, .{
        .min_level = .trace,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger.deinit();
    
    try send_user_choice.SendUserChoice(allocator, "invalid-session", &logger);
}
