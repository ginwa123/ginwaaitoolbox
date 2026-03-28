const std = @import("std");
const testing = std.testing;
const response = @import("response.zig");

test "extract_content_result - another response tag" {
    const allocator = testing.allocator;
    const xml =
        \\<session_id>session_1774632601</session_id><model>MiniMax-M2.7</model><cwd>/home/ginwa/agentic_coding_zig/ginwaaitoolbox</cwd><content><think>
        \\I need to fix the handler to actually serialize the sessions into the JSON. The issue is on line 410 where it builds a response with an empty array. I need to iterate over result.sessions and build the JSON properly.
        \\Let me create a proper fix that builds the session list JSON.
        \\</think>
        \\</content><role>assistant</role><finish_reason>tool_calls</finish_reason><tool_call_id>1774632755520677278</tool_call_id><tool_name>text_replace</tool_name><agent_name>Agent</agent_name><session_name>okayy, fix that</session_name><loop_index>2</loop_index><temperature>0.5</temperature><is_thinking>true</is_thinking><is_input>true</is_input><is_output>false</is_output><parent_session_id>session_1774632601</parent_session_id><parent_id>session_1774632601</parent_id>
        \\
    ;

    const opt_result = try response.extract_content_result(allocator, xml);
    // XML has no <response>, <tool_result>, or <tool_call> tags
    // So content_results is empty and tool_calls is null
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expect(result.content_results.items.len == 0);
        try testing.expect(result.tool_calls == null);
    }
}

test "extract_content_result - another response tag test" {
    const allocator = testing.allocator;
    const xml =
        \\ <session_id>session_1774633854</session_id><model>MiniMax-M2.7</model><cwd>/home/ginwa/agentic_coding_zig/ginwaaitoolbox</cwd><content><think>
        \\Let me look at the Tauri main.rs to see how it's structured and what commands are available. I also need to understand the database connection pattern used in this app.
        \\</think>
        \\</content><role>assistant</role><finish_reason>tool_calls</finish_reason><tool_call_id>1774634065981844875</tool_call_id><tool_name>read_file,read_file,read_file</tool_name><agent_name>Agent</agent_name><session_name>src desktop app sidebar bar should load list a sessions</session_name><loop_index>4</loop_index><temperature>0.5</temperature><is_thinking>true</is_thinking><is_input>true</is_input><is_output>false</is_output><parent_session_id>session_1774633854</parent_session_id><parent_id>session_1774633854</parent_id>
        \\
    ;

    const opt_result = try response.extract_content_result(allocator, xml);
    // XML has no <response>, <tool_result>, or <tool_call> tags
    // So content_results is empty and tool_calls is null
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expect(result.content_results.items.len == 0);
        try testing.expect(result.tool_calls == null);
    }
}

test "extract_content_result - tool_calls are extracted" {
    const allocator = testing.allocator;
    const xml = "<tool_call><name>test</name><arguments>{\"test\": true}</arguments></tool_call>";

    const opt_result = try response.extract_content_result(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        // content_results is empty since XML has no <response> or <tool_result> tags
        try testing.expect(result.content_results.items.len == 0);
        // But tool_calls should be extracted
        try testing.expect(result.tool_calls != null);
        try testing.expectEqual(@as(usize, 1), result.tool_calls.?.len);
        try testing.expectEqualStrings("test", result.tool_calls.?[0].name);
        try testing.expectEqualStrings("{\"test\": true}", result.tool_calls.?[0].arguments);
        allocator.free(result.tool_calls.?);
    }
}

test "extract_content_result - basic response tag" {
    const allocator = testing.allocator;
    const xml = "<response><content>Hello World</content></response>";

    const opt_result = try response.extract_content_result(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), result.content_results.items.len);
        try testing.expectEqualStrings("Hello World", result.content_results.items[0].content);
        try testing.expect(result.content_results.items[0].xml_type == .content);
    }
}

test "extract_content_result - response with multiple content tags" {
    const allocator = testing.allocator;
    const xml = "<response><content>First</content><content>Second</content></response>";

    const opt_result = try response.extract_content_result(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), result.content_results.items.len);
        try testing.expectEqualStrings("First", result.content_results.items[0].content);
        try testing.expectEqualStrings("Second", result.content_results.items[1].content);
    }
}

test "extract_content_result - tool_result tag" {
    const allocator = testing.allocator;
    const xml = "<tool_result><content>Tool Output</content></tool_result>";

    const opt_result = try response.extract_content_result(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), result.content_results.items.len);
        try testing.expectEqualStrings("Tool Output", result.content_results.items[0].content);
        try testing.expect(result.content_results.items[0].xml_type == .content);
    }
}

test "extract_content_result - response with finish_reason" {
    const allocator = testing.allocator;
    const xml = "<response><content>Done</content></response><finish_reason>stop</finish_reason>";

    const opt_result = try response.extract_content_result(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqualStrings("stop", result.finish_reason.?);
    }
}

test "extract_content_result - multiple response tags" {
    const allocator = testing.allocator;
    const xml = "<response><content>Chunk 1</content></response><response><content>Chunk 2</content></response>";

    const opt_result = try response.extract_content_result(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), result.content_results.items.len);
        try testing.expectEqualStrings("Chunk 1", result.content_results.items[0].content);
        try testing.expectEqualStrings("Chunk 2", result.content_results.items[1].content);
    }
}

test "extract_content_result - empty content tag returns raw content as fallback" {
    const allocator = testing.allocator;
    // When <content></content> is empty, fallback to raw inner content
    const xml = "<response><content></content></response>";

    const opt_result = try response.extract_content_result(allocator, xml);
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

test "extract_content_result - no matching tags returns null" {
    const allocator = testing.allocator;
    const xml = "<someother><content>Test</content></someother>";

    const result = try response.extract_content_result(allocator, xml);
    try testing.expect(result == null);
}

test "extract_content_result - response without content tag uses raw content" {
    const allocator = testing.allocator;
    const xml = "<response>Raw text without content tag</response>";

    const opt_result = try response.extract_content_result(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), result.content_results.items.len);
        try testing.expectEqualStrings("Raw text without content tag", result.content_results.items[0].content);
        try testing.expect(result.content_results.items[0].xml_type == .response);
    }
}

test "extract_content_result - mixed response and tool_result tags" {
    const allocator = testing.allocator;
    const xml = "<response><content>Response text</content></response><tool_result><content>Tool text</content></tool_result>";

    const opt_result = try response.extract_content_result(allocator, xml);
    try testing.expect(opt_result != null);
    {
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), result.content_results.items.len);
        try testing.expectEqualStrings("Response text", result.content_results.items[0].content);
        try testing.expectEqualStrings("Tool text", result.content_results.items[1].content);
    }
}

test "extract_content_result - XmlType enum values" {
    const allocator = testing.allocator;

    // Test .response type
    {
        const opt_result = try response.extract_content_result(allocator, "<response>raw</response>");
        try testing.expect(opt_result != null);
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expect(result.content_results.items[0].xml_type == .response);
    }

    // Test .tool_result type
    {
        const opt_result = try response.extract_content_result(allocator, "<tool_result>raw</tool_result>");
        try testing.expect(opt_result != null);
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expect(result.content_results.items[0].xml_type == .tool_result);
    }

    // Test .content type
    {
        const opt_result = try response.extract_content_result(allocator, "<response><content>inner</content></response>");
        try testing.expect(opt_result != null);
        var result = opt_result.?;
        defer result.content_results.deinit(allocator);
        try testing.expect(result.content_results.items[0].xml_type == .content);
    }
}
