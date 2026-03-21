const std = @import("std");
const testing = std.testing;
const response = @import("response.zig");

test "extractContentResult - basic response tag" {
    const allocator = testing.allocator;
    const xml = "<response><content>Hello World</content></response>";
    
    const opt_result = try response.extractContentResult(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), result.content_results.items.len);
        try testing.expectEqualStrings("Hello World", result.content_results.items[0].content);
        try testing.expect(result.content_results.items[0].xml_type == .content);
    }
}

test "extractContentResult - response with multiple content tags" {
    const allocator = testing.allocator;
    const xml = "<response><content>First</content><content>Second</content></response>";
    
    const opt_result = try response.extractContentResult(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), result.content_results.items.len);
        try testing.expectEqualStrings("First", result.content_results.items[0].content);
        try testing.expectEqualStrings("Second", result.content_results.items[1].content);
    }
}

test "extractContentResult - tool_result tag" {
    const allocator = testing.allocator;
    const xml = "<tool_result><content>Tool Output</content></tool_result>";
    
    const opt_result = try response.extractContentResult(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), result.content_results.items.len);
        try testing.expectEqualStrings("Tool Output", result.content_results.items[0].content);
        try testing.expect(result.content_results.items[0].xml_type == .content);
    }
}

test "extractContentResult - response with finish_reason" {
    const allocator = testing.allocator;
    const xml = "<response><content>Done</content></response><finish_reason>stop</finish_reason>";
    
    const opt_result = try response.extractContentResult(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqualStrings("stop", result.finish_reason.?);
    }
}

test "extractContentResult - multiple response tags" {
    const allocator = testing.allocator;
    const xml = "<response><content>Chunk 1</content></response><response><content>Chunk 2</content></response>";
    
    const opt_result = try response.extractContentResult(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), result.content_results.items.len);
        try testing.expectEqualStrings("Chunk 1", result.content_results.items[0].content);
        try testing.expectEqualStrings("Chunk 2", result.content_results.items[1].content);
    }
}

test "extractContentResult - empty content tag returns raw content as fallback" {
    const allocator = testing.allocator;
    // When <content></content> is empty, fallback to raw inner content
    const xml = "<response><content></content></response>";
    
    const opt_result = try response.extractContentResult(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        // Falls back to raw content since inner content tag is empty
        try testing.expectEqual(@as(usize, 1), result.content_results.items.len);
        try testing.expectEqualStrings("<content></content>", result.content_results.items[0].content);
        try testing.expect(result.content_results.items[0].xml_type == .response);
    }
}

test "extractContentResult - no matching tags returns null" {
    const allocator = testing.allocator;
    const xml = "<someother><content>Test</content></someother>";
    
    const result = try response.extractContentResult(allocator, xml);
    try testing.expect(result == null);
}

test "extractContentResult - response without content tag uses raw content" {
    const allocator = testing.allocator;
    const xml = "<response>Raw text without content tag</response>";
    
    const opt_result = try response.extractContentResult(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), result.content_results.items.len);
        try testing.expectEqualStrings("Raw text without content tag", result.content_results.items[0].content);
        try testing.expect(result.content_results.items[0].xml_type == .response);
    }
}

test "extractContentResult - mixed response and tool_result tags" {
    const allocator = testing.allocator;
    const xml = "<response><content>Response text</content></response><tool_result><content>Tool text</content></tool_result>";
    
    const opt_result = try response.extractContentResult(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), result.content_results.items.len);
        try testing.expectEqualStrings("Response text", result.content_results.items[0].content);
        try testing.expectEqualStrings("Tool text", result.content_results.items[1].content);
    }
}

test "extractContentResult - XmlType enum values" {
    const allocator = testing.allocator;
    
    // Test .response type
    {
        const opt_result = try response.extractContentResult(allocator, "<response>raw</response>");
        try testing.expect(opt_result != null);
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expect(result.content_results.items[0].xml_type == .response);
    }
    
    // Test .tool_result type  
    {
        const opt_result = try response.extractContentResult(allocator, "<tool_result>raw</tool_result>");
        try testing.expect(opt_result != null);
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expect(result.content_results.items[0].xml_type == .tool_result);
    }
    
    // Test .content type
    {
        const opt_result = try response.extractContentResult(allocator, "<response><content>inner</content></response>");
        try testing.expect(opt_result != null);
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expect(result.content_results.items[0].xml_type == .content);
    }
}
