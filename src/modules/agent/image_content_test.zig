const std = @import("std");
const agent = @import("nalarcore").agent;

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expect = std.testing.expect;

test "ContentPart - text part creation" {
    const part = agent.ContentPart{
        .part_type = "text",
        .text = try std.testing.allocator.dupe(u8, "Hello, world!"),
        .image_url = null,
    };
    defer {
        if (part.text) |t| std.testing.allocator.free(t);
    }

    try expectEqualStrings("text", part.part_type);
    try expectEqualStrings("Hello, world!", part.text.?);
    try expectEqual(@as(?agent.ImageUrl, null), part.image_url);
}

test "ContentPart - image_url part creation" {
    const url_str = try std.testing.allocator.dupe(u8, "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==");
    const part = agent.ContentPart{
        .part_type = "image_url",
        .text = null,
        .image_url = .{
            .url = url_str,
            .detail = null,
        },
    };
    defer {
        if (part.image_url) |img| {
            if (img.url) |u| std.testing.allocator.free(u);
        }
    }

    try expectEqualStrings("image_url", part.part_type);
    try expectEqual(@as(?[]const u8, null), part.text);
    try expect(part.image_url != null);
    try expect(std.mem.startsWith(u8, part.image_url.?.url.?, "data:image/png;base64,"));
}

test "ImageUrl - with detail option" {
    const url_str = try std.testing.allocator.dupe(u8, "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==");
    const img = agent.ImageUrl{
        .url = url_str,
        .detail = try std.testing.allocator.dupe(u8, "low"),
    };
    defer {
        if (img.url) |u| std.testing.allocator.free(u);
        if (img.detail) |d| std.testing.allocator.free(d);
    }

    try expect(img.url != null);
    try expectEqualStrings("low", img.detail.?);
}

test "AgentMessage - with content_parts (multimodal)" {
    const text_part = try std.testing.allocator.dupe(u8, "What is in this image?");
    const url_str = try std.testing.allocator.dupe(u8, "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==");
    
    const parts = try std.testing.allocator.alloc(agent.ContentPart, 2);
    parts[0] = .{
        .part_type = "text",
        .text = text_part,
        .image_url = null,
    };
    parts[1] = .{
        .part_type = "image_url",
        .text = null,
        .image_url = .{
            .url = url_str,
            .detail = null,
        },
    };

    const msg = agent.AgentMessage{
        .role = .user,
        .content = null,
        .content_parts = parts,
        .tool_calls = null,
        .tool_call_id = null,
        .reasoning_content = null,
    };
    defer msg.deinit(std.testing.allocator);

    try expectEqual(@as(?[]const u8, null), msg.content);
    try expect(msg.content_parts != null);
    try expectEqual(@as(usize, 2), msg.content_parts.?.len);
    try expectEqualStrings("text", msg.content_parts.?[0].part_type);
    try expectEqualStrings("image_url", msg.content_parts.?[1].part_type);
}

test "AgentMessage deinit handles content_parts correctly" {
    const text_part = try std.testing.allocator.dupe(u8, "Hello");
    const url_str = try std.testing.allocator.dupe(u8, "data:image/png;base64,abc123");
    
    const parts = try std.testing.allocator.alloc(agent.ContentPart, 1);
    parts[0] = .{
        .part_type = "text",
        .text = text_part,
        .image_url = .{
            .url = url_str,
            .detail = null,
        },
    };

    const msg = agent.AgentMessage{
        .role = .user,
        .content = null,
        .content_parts = parts,
        .tool_calls = null,
        .tool_call_id = null,
        .reasoning_content = null,
    };
    // deinit should free all allocated memory without leaking
    msg.deinit(std.testing.allocator);
    
    // If we get here without memory errors, the test passes
    try expect(true);
}

test "ContentPart - base64 image URL format validation" {
    // Test that we can create ContentPart with proper base64 data URL format
    // as expected by OpenAI API
    const base64_data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
    const url = try std.fmt.allocPrint(std.testing.allocator, "data:image/png;base64,{s}", .{base64_data});
    
    const part = agent.ContentPart{
        .part_type = "image_url",
        .text = null,
        .image_url = .{
            .url = url,
            .detail = null,
        },
    };
    defer {
        if (part.image_url) |img| {
            if (img.url) |u| std.testing.allocator.free(u);
        }
    }
    
    try expect(std.mem.startsWith(u8, part.image_url.?.url.?, "data:image/png;base64,"));
}

test "AgentMessage - legacy content field still works" {
    // Verify backward compatibility - AgentMessage with plain content
    const content = try std.testing.allocator.dupe(u8, "Hello, this is plain text content");
    
    const msg = agent.AgentMessage{
        .role = .user,
        .content = content,
        .content_parts = null,
        .tool_calls = null,
        .tool_call_id = null,
        .reasoning_content = null,
    };
    defer msg.deinit(std.testing.allocator);

    try expectEqualStrings("Hello, this is plain text content", msg.content.?);
    try expectEqual(@as(?[]const agent.ContentPart, null), msg.content_parts);
}