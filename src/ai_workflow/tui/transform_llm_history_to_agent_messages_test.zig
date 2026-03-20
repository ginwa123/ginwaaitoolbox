const std = @import("std");
const transform = @import("transform_llm_history_to_agent_messages.zig");
const TUIHistory = @import("models.zig").TUIHistory;

test "transform assistant message" {
    const allocator = std.testing.allocator;

    var history = TUIHistory{
        .id = try allocator.dupe(u8, "id1"),
        .session_id = try allocator.dupe(u8, "session1"),
        .model = try allocator.dupe(u8, "gpt-4"),
        .created_at = try allocator.dupe(u8, "2024-01-01"),
        .response_content = try allocator.dupe(u8, "Hello, world!"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "assistant"),
        .tools = try allocator.dupe(u8, ""),
        .agent = try allocator.dupe(u8, "GeneralAgent"),
        .session_name = try allocator.dupe(u8, ""),
        .loop_index = 0,
    };
    defer history.deinit(allocator);

    const messages = try transform.transform_llm_history_to_agent_message(allocator, history);
    defer {
        for (messages) |msg| {
            if (msg.content) |c| allocator.free(c);
            if (msg.tool_call_id) |tc| allocator.free(tc);
            if (msg.tool_calls) |tc| {
                for (tc) |t| {
                    allocator.free(t.id);
                    allocator.free(t.function.name);
                    allocator.free(t.function.arguments);
                }
                allocator.free(tc);
            }
            if (msg.reasoning_content) |rc| allocator.free(rc);
        }
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("Hello, world!", messages[0].content.?);
}

test "transform user message" {
    const allocator = std.testing.allocator;

    var history = TUIHistory{
        .id = try allocator.dupe(u8, "id1"),
        .session_id = try allocator.dupe(u8, "session1"),
        .model = try allocator.dupe(u8, "gpt-4"),
        .created_at = try allocator.dupe(u8, "2024-01-01"),
        .response_content = try allocator.dupe(u8, "User query"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "user"),
        .tools = try allocator.dupe(u8, ""),
        .agent = try allocator.dupe(u8, "GeneralAgent"),
        .session_name = try allocator.dupe(u8, ""),
        .loop_index = 0,
    };
    defer history.deinit(allocator);

    const messages = try transform.transform_llm_history_to_agent_message(allocator, history);
    defer {
        for (messages) |msg| {
            if (msg.content) |c| allocator.free(c);
            if (msg.tool_call_id) |tc| allocator.free(tc);
            if (msg.tool_calls) |tc| {
                for (tc) |t| {
                    allocator.free(t.id);
                    allocator.free(t.function.name);
                    allocator.free(t.function.arguments);
                }
                allocator.free(tc);
            }
            if (msg.reasoning_content) |rc| allocator.free(rc);
        }
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 1), messages.len);
}

test "transform tool message" {
    const allocator = std.testing.allocator;

    var history = TUIHistory{
        .id = try allocator.dupe(u8, "id1"),
        .session_id = try allocator.dupe(u8, "session1"),
        .model = try allocator.dupe(u8, "gpt-4"),
        .created_at = try allocator.dupe(u8, "2024-01-01"),
        .response_content = try allocator.dupe(u8, "Tool result"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "tool"),
        .tools = try allocator.dupe(u8, "call_123"),
        .agent = try allocator.dupe(u8, "GeneralAgent"),
        .session_name = try allocator.dupe(u8, ""),
        .loop_index = 0,
    };
    defer history.deinit(allocator);

    const messages = try transform.transform_llm_history_to_agent_message(allocator, history);
    defer {
        for (messages) |msg| {
            if (msg.content) |c| allocator.free(c);
            if (msg.tool_call_id) |tc| allocator.free(tc);
            if (msg.tool_calls) |tc| {
                for (tc) |t| {
                    allocator.free(t.id);
                    allocator.free(t.function.name);
                    allocator.free(t.function.arguments);
                }
                allocator.free(tc);
            }
            if (msg.reasoning_content) |rc| allocator.free(rc);
        }
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("Tool result", messages[0].content.?);
    try std.testing.expectEqualStrings("call_123", messages[0].tool_call_id.?);
}

test "transform empty content" {
    const allocator = std.testing.allocator;

    var history = TUIHistory{
        .id = try allocator.dupe(u8, "id1"),
        .session_id = try allocator.dupe(u8, "session1"),
        .model = try allocator.dupe(u8, "gpt-4"),
        .created_at = try allocator.dupe(u8, "2024-01-01"),
        .response_content = try allocator.dupe(u8, ""),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "assistant"),
        .tools = try allocator.dupe(u8, ""),
        .agent = try allocator.dupe(u8, "GeneralAgent"),
        .session_name = try allocator.dupe(u8, ""),
        .loop_index = 0,
    };
    defer history.deinit(allocator);

    const messages = try transform.transform_llm_history_to_agent_message(allocator, history);
    defer {
        for (messages) |msg| {
            if (msg.content) |c| allocator.free(c);
            if (msg.tool_call_id) |tc| allocator.free(tc);
            if (msg.tool_calls) |tc| {
                for (tc) |t| {
                    allocator.free(t.id);
                    allocator.free(t.function.name);
                    allocator.free(t.function.arguments);
                }
                allocator.free(tc);
            }
            if (msg.reasoning_content) |rc| allocator.free(rc);
        }
        allocator.free(messages);
    }

    // Empty content should still produce a message
    try std.testing.expectEqual(@as(usize, 1), messages.len);
}

test "transform with reasoning content" {
    const allocator = std.testing.allocator;

    var history = TUIHistory{
        .id = try allocator.dupe(u8, "id1"),
        .session_id = try allocator.dupe(u8, "session1"),
        .model = try allocator.dupe(u8, "gpt-4"),
        .created_at = try allocator.dupe(u8, "2024-01-01"),
        .response_content = try allocator.dupe(u8, "Final answer"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "assistant"),
        .tools = try allocator.dupe(u8, ""),
        .reasoning_content = try allocator.dupe(u8, "Let me think..."),
        .agent = try allocator.dupe(u8, "GeneralAgent"),
        .session_name = try allocator.dupe(u8, ""),
        .loop_index = 0,
    };
    defer history.deinit(allocator);

    const messages = try transform.transform_llm_history_to_agent_message(allocator, history);
    defer {
        for (messages) |msg| {
            if (msg.content) |c| allocator.free(c);
            if (msg.tool_call_id) |tc| allocator.free(tc);
            if (msg.tool_calls) |tc| {
                for (tc) |t| {
                    allocator.free(t.id);
                    allocator.free(t.function.name);
                    allocator.free(t.function.arguments);
                }
                allocator.free(tc);
            }
            if (msg.reasoning_content) |rc| allocator.free(rc);
        }
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(messages[0].reasoning_content != null);
    try std.testing.expectEqualStrings("Let me think...", messages[0].reasoning_content.?);
}
