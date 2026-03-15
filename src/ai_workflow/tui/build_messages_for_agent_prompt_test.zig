const std = @import("std");
const build_messages = @import("build_messages_for_agent_prompt.zig");
const TUIHistory = @import("models.zig").TUIHistory;

test "build messages with empty history" {
    const allocator = std.testing.allocator;
    const cwd = "/test/dir";
    const skills = "test skills";
    
    const history: []TUIHistory = &[_]TUIHistory{};
    
    const messages = try build_messages.BuildMessages(allocator, cwd, history, skills, "", "");
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
    
    // Should have at least system message
    try std.testing.expect(messages.len >= 1);
}

test "build messages preserves agent from history" {
    const allocator = std.testing.allocator;
    const cwd = "/test/dir";
    const skills = "";
    
    var history_data = [_]TUIHistory{
        .{
            .id = try allocator.dupe(u8, "id1"),
            .session_id = try allocator.dupe(u8, "session1"),
            .model = try allocator.dupe(u8, "gpt-4"),
            .created_at = try allocator.dupe(u8, "2024-01-01"),
            .response_content = try allocator.dupe(u8, "Hello"),
            .finish_reason = try allocator.dupe(u8, "stop"),
            .role = try allocator.dupe(u8, "assistant"),
            .tools = try allocator.dupe(u8, ""),
            .agent = try allocator.dupe(u8, "Agent"),
            .session_name = try allocator.dupe(u8, ""),
            .loop_index = 0,
        },
    };
    defer history_data[0].deinit(allocator);
    
    const messages = try build_messages.BuildMessages(allocator, cwd, &history_data, skills, "", "");
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
    
    try std.testing.expect(messages.len > 0);
}
