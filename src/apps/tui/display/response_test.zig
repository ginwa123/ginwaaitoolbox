const std = @import("std");
const testing = std.testing;
const response = @import("response.zig");


/// test case is below input
<response><session_id>session_1774595966</session_id><model>MiniMax-M2.7</model><cwd>/home/ginwa/agentic_coding_zig/ginwaaitoolbox</cwd><content><think>
The user said "hii" which is a casual greeting. This is a simple interaction that doesn't require any technical work, skill loading, or complex problem-solving. It's just a greeting.
Let me respond in a friendly way in the same casual tone.
</think>
Hey! 👋
I'm here and ready to help. What would you like to work on? I can assist with:
- **Coding tasks** — Zig, TypeScript, or anything else
- **Building/fixing** — debug issues, write tests, implement features
- **Exploring** — reading code, understanding projects, finding patterns
- **Skills** — create, improve, or use specialized skills
- **Agents** — spawn sub-agents for parallel work
Just let me know what you're tackling! 🚀</content><role>assistant</role><finish_reason>stop</finish_reason><tool_name></tool_name><agent_name>Agent</agent_name><session_name>hii</session_name><loop_index>1</loop_index><temperature>0.5</temperature><is_thinking>true</is_thinking><is_input>false</is_input><is_output>false</is_output><parent_session_id>session_1774595966</parent_session_id><parent_id>session_1774595966</parent_id></response>

////
test "extractContentResult - new testcase" {
    const allocator = testing.allocator;
    const xml = "<response><content>Test</content></response>";

    const opt_result = try response.extractContentResult(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        // TODO: Add assertions
        _ = result;
    }
}

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
