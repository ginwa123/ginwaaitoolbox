const std = @import("std");
const response = @import("nalarcore").tui_display_response;

test "extractContentResult - single content tag" {
    const allocator = std.testing.allocator;
    const xml = "<response><content>Hello World</content></response>";

    const result = response.extractContentResult(allocator, xml);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.content_results.items.len);
    try std.testing.expectEqualStrings("Hello World", result.?.content_results.items[0].content);
    try std.testing.expect(result.?.finish_reason == null);

    var mutable_result = result.?;
    mutable_result.content_results.deinit(allocator);
}

test "extractContentResult - multiple content tags (streaming)" {
    const allocator = std.testing.allocator;
    const xml = 
        \\<response>
        \\<content>First chunk</content>
        \\<content>Second chunk</content>
        \\<content>Third chunk</content>
        \\</response>
    ;

    const result = response.extractContentResult(allocator, xml);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 3), result.?.content_results.items.len);
    try std.testing.expectEqualStrings("First chunk", result.?.content_results.items[0].content);
    try std.testing.expectEqualStrings("Second chunk", result.?.content_results.items[1].content);
    try std.testing.expectEqualStrings("Third chunk", result.?.content_results.items[2].content);
    try std.testing.expect(result.?.finish_reason == null);

    var mutable_result = result.?;
    mutable_result.content_results.deinit(allocator);
}

test "extractContentResult - with finish_reason" {
    const allocator = std.testing.allocator;
    const xml = "<response><content>Answer is 42</content><finish_reason>stop</finish_reason></response>";

    const result = response.extractContentResult(allocator, xml);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.content_results.items.len);
    try std.testing.expectEqualStrings("Answer is 42", result.?.content_results.items[0].content);
    try std.testing.expect(result.?.finish_reason != null);
    try std.testing.expectEqualStrings("stop", result.?.finish_reason.?);

    var mutable_result = result.?;
    mutable_result.content_results.deinit(allocator);
}

test "extractContentResult - multiple finish_reason returns last" {
    const allocator = std.testing.allocator;
    const xml = 
        \\<response>
        \\<content>First</content>
        \\<finish_reason>error</finish_reason>
        \\<content>Second</content>
        \\<finish_reason>stop</finish_reason>
        \\</response>
    ;

    const result = response.extractContentResult(allocator, xml);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 2), result.?.content_results.items.len);
    try std.testing.expect(result.?.finish_reason != null);
    try std.testing.expectEqualStrings("stop", result.?.finish_reason.?); // Last one wins

    var mutable_result = result.?;
    mutable_result.content_results.deinit(allocator);
}

test "extractContentResult - empty content is skipped" {
    const allocator = std.testing.allocator;
    const xml = "<response><content></content><content>Valid content</content><content></content></response>";

    const result = response.extractContentResult(allocator, xml);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.content_results.items.len);
    try std.testing.expectEqualStrings("Valid content", result.?.content_results.items[0].content);

    var mutable_result = result.?;
    mutable_result.content_results.deinit(allocator);
}

test "extractContentResult - only finish_reason, no content" {
    const allocator = std.testing.allocator;
    const xml = "<response><finish_reason>stop</finish_reason></response>";

    const result = response.extractContentResult(allocator, xml);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.content_results.items.len);
    try std.testing.expect(result.?.finish_reason != null);
    try std.testing.expectEqualStrings("stop", result.?.finish_reason.?);

    var mutable_result = result.?;
    mutable_result.content_results.deinit(allocator);
}

test "extractContentResult - returns null when no content and no finish_reason" {
    const allocator = std.testing.allocator;
    const xml = "<response><other>something</other></response>";

    const result = response.extractContentResult(allocator, xml);
    try std.testing.expect(result == null);
}

test "extractContentResult - returns null for empty string" {
    const allocator = std.testing.allocator;
    const xml = "";

    const result = response.extractContentResult(allocator, xml);
    try std.testing.expect(result == null);
}

test "extractContentResult - content with special characters" {
    const allocator = std.testing.allocator;
    const xml = "<response><content>Hello <b>world</b> &amp; friends!</content><finish_reason>stop</finish_reason></response>";

    const result = response.extractContentResult(allocator, xml);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Hello <b>world</b> &amp; friends!", result.?.content_results.items[0].content);
    try std.testing.expectEqualStrings("stop", result.?.finish_reason.?);

    var mutable_result = result.?;
    mutable_result.content_results.deinit(allocator);
}

test "extractContentResult - content with newlines" {
    const allocator = std.testing.allocator;
    const xml = "<response><content>Line 1\nLine 2\nLine 3</content></response>";

    const result = response.extractContentResult(allocator, xml);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Line 1\nLine 2\nLine 3", result.?.content_results.items[0].content);

    var mutable_result = result.?;
    mutable_result.content_results.deinit(allocator);
}

test "extractContentResult - mixed XML with other tags" {
    const allocator = std.testing.allocator;
    const xml = 
        \\<response>
        \\<usage><prompt_tokens>100</prompt_tokens></usage>
        \\<content>Real content here</content>
        \\<other_tag>ignored</other_tag>
        \\<finish_reason>stop</finish_reason>
        \\</response>
    ;

    const result = response.extractContentResult(allocator, xml);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.content_results.items.len);
    try std.testing.expectEqualStrings("Real content here", result.?.content_results.items[0].content);
    try std.testing.expectEqualStrings("stop", result.?.finish_reason.?);

    var mutable_result = result.?;
    mutable_result.content_results.deinit(allocator);
}

test "extractContentResult - all finish_reason values" {
    const allocator = std.testing.allocator;

    const reasons = [_][]const u8{ "stop", "length", "content_filter", "tool_calls" };

    inline for (reasons) |reason| {
        const xml = "<response><content>test</content><finish_reason>" ++ reason ++ "</finish_reason></response>";
        const result = response.extractContentResult(allocator, xml);
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings(reason, result.?.finish_reason.?);
        var mutable_result = result.?;
        mutable_result.content_results.deinit(allocator);
    }
}
