const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;

// Import the modules under test
const transform = @import("transform_llm_history_to_agent_messages.zig");
const TUIHistory = @import("models.zig").TUIHistory;

// =============================================================================
// extractBase64ImageUrl tests
// =============================================================================

test "extractBase64ImageUrl - valid PNG base64 image" {
    const message = "Check this image: data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
    const result = extractBase64ImageUrl(message);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.startsWith(u8, result.?, "data:image/png;base64,"));
}

test "extractBase64ImageUrl - valid JPEG base64 image" {
    const message = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMC";
    const result = extractBase64ImageUrl(message);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.startsWith(u8, result.?, "data:image/jpeg;base64,"));
}

test "extractBase64ImageUrl - valid WEBP base64 image" {
    const message = "data:image/webp;base64,UklGRlYAAABXRUJQVlA4WAoAAAAQAAAAAAAAAAAA";
    const result = extractBase64ImageUrl(message);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.startsWith(u8, result.?, "data:image/webp;base64,"));
}

test "extractBase64ImageUrl - no image returns null" {
    const message = "This is just plain text without any image";
    const result = extractBase64ImageUrl(message);
    try std.testing.expect(result == null);
}

test "extractBase64ImageUrl - empty string returns null" {
    const message = "";
    const result = extractBase64ImageUrl(message);
    try std.testing.expect(result == null);
}

test "extractBase64ImageUrl - malformed image URL returns null" {
    const message = "data:img;base64,ABC123";
    const result = extractBase64ImageUrl(message);
    try std.testing.expect(result == null);
}

test "extractBase64ImageUrl - image followed by space" {
    const message = "Look at this: data:image/png;base64,ABC123 def more text";
    const result = extractBase64ImageUrl(message);
    try std.testing.expect(result != null);
    // Stops at first whitespace
    const expected = "data:image/png;base64,ABC123";
    try std.testing.expect(std.mem.eql(u8, result.?, expected));
}

test "extractBase64ImageUrl - image followed by newline" {
    const message = "Look at this: data:image/png;base64,ABC123\nnext line";
    const result = extractBase64ImageUrl(message);
    try std.testing.expect(result != null);
    const expected = "data:image/png;base64,ABC123";
    try std.testing.expect(std.mem.eql(u8, result.?, expected));
}

test "extractBase64ImageUrl - image followed by tab" {
    const message = "Look at this: data:image/png;base64,ABC123\tnext";
    const result = extractBase64ImageUrl(message);
    try std.testing.expect(result != null);
    const expected = "data:image/png;base64,ABC123";
    try std.testing.expect(std.mem.eql(u8, result.?, expected));
}

test "extractBase64ImageUrl - only image URL" {
    const message = "data:image/png;base64,ABCDEFGH";
    const result = extractBase64ImageUrl(message);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?, message));
}

// =============================================================================
// transform_llm_history_to_agent_message with image_url tests
// =============================================================================

test "transform - message with image_url creates content_parts" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = TUIHistory{
        .id = try allocator.dupe(u8, "msg-1"),
        .session_id = try allocator.dupe(u8, "session-1"),
        .model = try allocator.dupe(u8, "gpt-4o"),
        .created_at = try allocator.dupe(u8, "2025-01-01"),
        .response_content = try allocator.dupe(u8, "Look at this screenshot"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "user"),
        .tools = try allocator.dupe(u8, ""),
        .image_urls = blk: {
            const arr = try std.heap.c_allocator.alloc([]const u8, 1);
            arr[0] = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
            break :blk arr;
        },
    };
    defer history.deinit(allocator);

    const agentMessages = try transform.transform_llm_history_to_agent_message(allocator, history);
    defer allocator.free(agentMessages);

    try std.testing.expect(agentMessages.len == 1);
    const msg = agentMessages[0];
    try std.testing.expect(msg.role == .user);
    // content should be null when content_parts is set
    try std.testing.expect(msg.content == null);
    try std.testing.expect(msg.content_parts != null);
    try std.testing.expect(msg.content_parts.?.len == 2);
    // First part is text
    try std.testing.expect(std.mem.eql(u8, msg.content_parts.?[0].part_type, "text"));
    try std.testing.expect(msg.content_parts.?[0].text != null);
    try std.testing.expect(std.mem.eql(u8, msg.content_parts.?[0].text.?, "Look at this screenshot"));
    try std.testing.expect(msg.content_parts.?[0].image_url == null);
    // Second part is image_url
    try std.testing.expect(std.mem.eql(u8, msg.content_parts.?[1].part_type, "image_url"));
    try std.testing.expect(msg.content_parts.?[1].text == null);
    try std.testing.expect(msg.content_parts.?[1].image_url != null);
    try std.testing.expect(msg.content_parts.?[1].image_url.?.url != null);
}

test "transform - message without image_url uses content field" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = TUIHistory{
        .id = try allocator.dupe(u8, "msg-1"),
        .session_id = try allocator.dupe(u8, "session-1"),
        .model = try allocator.dupe(u8, "gpt-4o"),
        .created_at = try allocator.dupe(u8, "2025-01-01"),
        .response_content = try allocator.dupe(u8, "Hello world"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "user"),
        .tools = try allocator.dupe(u8, ""),
        .image_urls = null,
    };
    defer history.deinit(allocator);

    const agentMessages = try transform.transform_llm_history_to_agent_message(allocator, history);
    defer allocator.free(agentMessages);

    try std.testing.expect(agentMessages.len == 1);
    const msg = agentMessages[0];
    try std.testing.expect(msg.role == .user);
    // content should be set when no image_url
    try std.testing.expect(msg.content != null);
    try std.testing.expect(std.mem.eql(u8, msg.content.?, "Hello world"));
    try std.testing.expect(msg.content_parts == null);
}

test "transform - assistant message with image_url creates content_parts" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = TUIHistory{
        .id = try allocator.dupe(u8, "msg-1"),
        .session_id = try allocator.dupe(u8, "session-1"),
        .model = try allocator.dupe(u8, "gpt-4o"),
        .created_at = try allocator.dupe(u8, "2025-01-01"),
        .response_content = try allocator.dupe(u8, "I can see the screenshot shows a login form"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "assistant"),
        .tools = try allocator.dupe(u8, ""),
        .image_urls = blk: {
            const arr = try std.heap.c_allocator.alloc([]const u8, 1);
            arr[0] = "data:image/png;base64,ABCD";
            break :blk arr;
        },
    };
    defer history.deinit(allocator);

    const agentMessages = try transform.transform_llm_history_to_agent_message(allocator, history);
    defer allocator.free(agentMessages);

    try std.testing.expect(agentMessages.len == 1);
    const msg = agentMessages[0];
    try std.testing.expect(msg.role == .assistant);
    try std.testing.expect(msg.content == null);
    try std.testing.expect(msg.content_parts != null);
    try std.testing.expect(msg.content_parts.?.len == 2);
}

test "transform - tool message ignores image_url" {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = TUIHistory{
        .id = try allocator.dupe(u8, "msg-1"),
        .session_id = try allocator.dupe(u8, "session-1"),
        .model = try allocator.dupe(u8, "gpt-4o"),
        .created_at = try allocator.dupe(u8, "2025-01-01"),
        .response_content = try allocator.dupe(u8, "Tool result here"),
        .finish_reason = try allocator.dupe(u8, "tool"),
        .role = try allocator.dupe(u8, "tool"),
        .tools = try allocator.dupe(u8, "tool_call_id_123"),
        .image_urls = blk: {
            const arr = try std.heap.c_allocator.alloc([]const u8, 1);
            arr[0] = "data:image/png;base64,ABCD";
            break :blk arr;
        },
    };
    defer history.deinit(allocator);

    const agentMessages = try transform.transform_llm_history_to_agent_message(allocator, history);
    defer allocator.free(agentMessages);

    // Tool messages are handled specially - they don't use content_parts
    try std.testing.expect(agentMessages.len == 1);
    const msg = agentMessages[0];
    try std.testing.expect(msg.role == .tool);
    try std.testing.expect(msg.content != null);
    try std.testing.expect(msg.content_parts == null);
    try std.testing.expect(msg.tool_call_id != null);
    try std.testing.expect(std.mem.eql(u8, msg.tool_call_id.?, "tool_call_id_123"));
}

// =============================================================================
// Helper function copy for testing (mirrors workflow.zig implementation)
// =============================================================================

fn extractBase64ImageUrl(message: []const u8) ?[]const u8 {
    const prefix = "data:image/";
    const base64_marker = ";base64,";
    
    const data_start = std.mem.indexOf(u8, message, prefix) orelse return null;
    const base64_idx = std.mem.indexOf(u8, message[data_start..], base64_marker) orelse return null;
    const marker_start = data_start + base64_idx;
    
    const data_start_pos = marker_start + base64_marker.len;
    const remaining = message[data_start_pos..];
    
    var end_idx: usize = remaining.len;
    for (remaining, 0..) |byte, i| {
        if (byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t') {
            end_idx = i;
            break;
        }
    }
    
    return message[data_start..data_start_pos + end_idx];
}