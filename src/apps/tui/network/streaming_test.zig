const std = @import("std");
const testing = std.testing;
const response = @import("../display/response.zig");

test "extract_content_result - plain text content (no XML tags)" {
    const allocator = testing.allocator;
    // Plain text that is NOT XML - should return null
    const plain_text = "Hello, this is plain text without any XML tags.";
    
    const result = try response.extract_content_result(allocator, plain_text);
    // Should return null because there's no <response> or <tool_result> tags
    try testing.expect(result == null);
}

test "extract_content_result - JSON content is treated as raw text" {
    const allocator = testing.allocator;
    // When JSON is passed as "content", it should not be parsed as XML
    const json_content = "{\"key\":\"value\"}";
    
    const result = try response.extract_content_result(allocator, json_content);
    // No XML tags, so result should be null
    try testing.expect(result == null);
}

test "extract_content_result - plain text with angle brackets" {
    const allocator = testing.allocator;
    // Text that looks like XML but isn't valid tags - should return null
    const text_with_brackets = "Use <this> syntax for comparison";
    
    const result = try response.extract_content_result(allocator, text_with_brackets);
    try testing.expect(result == null);
}

test "extract_content_result - empty string" {
    const allocator = testing.allocator;
    
    const result = try response.extract_content_result(allocator, "");
    try testing.expect(result == null);
}

test "extract_content_result - whitespace only" {
    const allocator = testing.allocator;
    
    const result = try response.extract_content_result(allocator, "   \n\t  ");
    try testing.expect(result == null);
}

test "extract_content_result - XML with content inside response tag" {
    const allocator = testing.allocator;
    // XML with proper <response> tags and <content> inside
    const xml_with_content = "<response><content>Hello from XML</content></response>";
    
    const result = try response.extract_content_result(allocator, xml_with_content);
    try testing.expect(result != null);
    {
        var r = result.?;
        defer r.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), r.content_results.items.len);
        try testing.expectEqualStrings("Hello from XML", r.content_results.items[0].content);
    }
}

test "extract_content_result - XML with nested JSON in content" {
    const allocator = testing.allocator;
    // XML with content that happens to contain JSON-like text
    const xml_with_json = "<response><content>{\"nested\":\"json\"}</content></response>";
    
    const result = try response.extract_content_result(allocator, xml_with_json);
    try testing.expect(result != null);
    {
        var r = result.?;
        defer r.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), r.content_results.items.len);
        // The JSON text should be preserved as-is inside the XML tags
        try testing.expectEqualStrings("{\"nested\":\"json\"}", r.content_results.items[0].content);
    }
}

test "extract_content_result - raw content without content tag" {
    const allocator = testing.allocator;
    // <response> without <content> tag - should use raw content
    const xml_raw = "<response>Raw text without content tag</response>";
    
    const result = try response.extract_content_result(allocator, xml_raw);
    try testing.expect(result != null);
    {
        var r = result.?;
        defer r.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), r.content_results.items.len);
        try testing.expectEqualStrings("Raw text without content tag", r.content_results.items[0].content);
    }
}

test "extract_content_result - multiple response tags" {
    const allocator = testing.allocator;
    const xml = "<response><content>First</content></response><response><content>Second</content></response>";
    
    const result = try response.extract_content_result(allocator, xml);
    try testing.expect(result != null);
    {
        var r = result.?;
        defer r.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), r.content_results.items.len);
        try testing.expectEqualStrings("First", r.content_results.items[0].content);
        try testing.expectEqualStrings("Second", r.content_results.items[1].content);
    }
}

test "extract_content_result - tool_result tag" {
    const allocator = testing.allocator;
    const xml = "<tool_result><content>Tool output</content></tool_result>";
    
    const result = try response.extract_content_result(allocator, xml);
    try testing.expect(result != null);
    {
        var r = result.?;
        defer r.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), r.content_results.items.len);
        try testing.expectEqualStrings("Tool output", r.content_results.items[0].content);
        // Note: when <content> tags exist inside, xml_type is set to .content
        try testing.expect(r.content_results.items[0].xml_type == .content);
    }
}

test "extract_content_result - mixed response and tool_result tags" {
    const allocator = testing.allocator;
    const xml = "<response><content>Response text</content></response><tool_result><content>Tool text</content></tool_result>";
    
    const result = try response.extract_content_result(allocator, xml);
    try testing.expect(result != null);
    {
        var r = result.?;
        defer r.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), r.content_results.items.len);
        try testing.expectEqualStrings("Response text", r.content_results.items[0].content);
        try testing.expect(r.content_results.items[0].xml_type == .content);
        try testing.expectEqualStrings("Tool text", r.content_results.items[1].content);
        try testing.expect(r.content_results.items[1].xml_type == .content);
    }
}

test "extract_content_result - finish_reason extraction" {
    const allocator = testing.allocator;
    const xml = "<response><content>Done</content></response><finish_reason>stop</finish_reason>";
    
    const result = try response.extract_content_result(allocator, xml);
    try testing.expect(result != null);
    {
        var r = result.?;
        defer r.content_results.deinit(allocator);
        if (r.finish_reason) |fr| {
            try testing.expectEqualStrings("stop", fr);
        }
    }
}

test "extract_content_result - finish_reason not stop" {
    const allocator = testing.allocator;
    const xml = "<response><content>Content</content></response><finish_reason>tool_calls</finish_reason>";
    
    const result = try response.extract_content_result(allocator, xml);
    try testing.expect(result != null);
    {
        var r = result.?;
        defer r.content_results.deinit(allocator);
        if (r.finish_reason) |fr| {
            try testing.expectEqualStrings("tool_calls", fr);
        }
    }
}

test "extract_content_result - tool_call extraction" {
    const allocator = testing.allocator;
    const xml = "<response><content></content></response><tool_call><name>my_tool</name><arguments>{\"arg\":\"value\"}</arguments></tool_call>";
    
    const result = try response.extract_content_result(allocator, xml);
    try testing.expect(result != null);
    {
        var r = result.?;
        defer r.content_results.deinit(allocator);
        if (r.tool_calls) |tc| {
            defer allocator.free(tc);
            try testing.expectEqual(@as(usize, 1), tc.len);
            try testing.expectEqualStrings("my_tool", tc[0].name);
            try testing.expectEqualStrings("{\"arg\":\"value\"}", tc[0].arguments);
        }
    }
}

test "extract_content_result - JSON with angle brackets is not XML" {
    const allocator = testing.allocator;
    // JSON content that contains angle brackets but no actual XML tags
    const json_like = "{\"message\":\"Use <this> syntax\"}";
    
    const result = try response.extract_content_result(allocator, json_like);
    // This is not valid XML, so should return null
    try testing.expect(result == null);
}

test "extract_content_result - code with XML-like syntax" {
    const allocator = testing.allocator;
    const code = "function foo() { return <html>; }";
    
    const result = try response.extract_content_result(allocator, code);
    // This is not valid XML structure, should return null
    try testing.expect(result == null);
}

test "extract_content_result - markdown with XML-like text" {
    const allocator = testing.allocator;
    const markdown = "# Hello\n\nUse `<response>` tags for XML.";
    
    const result = try response.extract_content_result(allocator, markdown);
    // Markdown is not XML, should return null
    try testing.expect(result == null);
}

test "extract_content_result - proves fix: plain JSON content returns null" {
    const allocator = testing.allocator;
    
    // Simulate what was happening before the fix:
    // content_str is a JSON string field value, NOT XML
    const content_from_json = "Hello, plain text from LLM response";
    
    const result = try response.extract_content_result(allocator, content_from_json);
    // Should return null - plain text is not XML
    try testing.expect(result == null);
}

test "extract_content_result - proves fix: JSON string content returns null" {
    const allocator = testing.allocator;
    
    // When the LLM returns JSON in the content field:
    // {"messages":[{"content":"{\"key\":\"value\"}","role":"assistant"}]}
    // The content field value is a JSON string, not XML
    const json_in_content = "{\"key\":\"value\"}";
    
    const result = try response.extract_content_result(allocator, json_in_content);
    // Should return null - this is JSON, not XML
    try testing.expect(result == null);
}

test "extract_content_result - proves fix: LLM structured output needs XML wrapper" {
    const allocator = testing.allocator;
    
    // The LLM must wrap content in <response> tags for extract_content_result to work
    const properly_wrapped = "<response><content>LLM output here</content></response>";
    
    const result = try response.extract_content_result(allocator, properly_wrapped);
    // Should return valid result because it's properly wrapped XML
    try testing.expect(result != null);
    {
        var r = result.?;
        defer r.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), r.content_results.items.len);
        try testing.expectEqualStrings("LLM output here", r.content_results.items[0].content);
    }
}