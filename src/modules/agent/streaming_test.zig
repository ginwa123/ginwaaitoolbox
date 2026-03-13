const std = @import("std");
const agent = @import("nalarcore").agent;
const logger = @import("nalarcore").logger;

test "StreamingAggregator - accumulate content chunks" {
    const allocator = std.testing.allocator;

    var aggregator = agent.StreamingAggregator.init(allocator);
    defer aggregator.deinit();

    // Process content chunks
    try aggregator.processChunk(.{ .content = "Hello" });
    try aggregator.processChunk(.{ .content = " " });
    try aggregator.processChunk(.{ .content = "World" });

    // Check accumulated content
    try std.testing.expectEqualStrings("Hello World", aggregator.content.items);
}

test "StreamingAggregator - accumulate reasoning content" {
    const allocator = std.testing.allocator;

    var aggregator = agent.StreamingAggregator.init(allocator);
    defer aggregator.deinit();

    // Process reasoning content chunks
    try aggregator.processChunk(.{ .reasoning_content = "Thinking..." });
    try aggregator.processChunk(.{ .reasoning_content = " More thinking." });

    try std.testing.expectEqualStrings("Thinking... More thinking.", aggregator.reasoning_content.items);
}

test "StreamingAggregator - accumulate tool call deltas" {
    const allocator = std.testing.allocator;

    var aggregator = agent.StreamingAggregator.init(allocator);
    defer aggregator.deinit();

    // Process tool call deltas
    const deltas1 = [_]agent.ToolCallDelta{
        .{ .index = 0, .id = "call_123" },
    };
    try aggregator.processChunk(.{ .tool_calls_delta = @as([]const agent.ToolCallDelta, &deltas1) });

    const deltas2 = [_]agent.ToolCallDelta{
        .{ .index = 0, .function_name = "bash" },
    };
    try aggregator.processChunk(.{ .tool_calls_delta = @as([]const agent.ToolCallDelta, &deltas2) });

    const deltas3 = [_]agent.ToolCallDelta{
        .{ .index = 0, .function_arguments = "{\"command\":\"ls\"}" },
    };
    try aggregator.processChunk(.{ .tool_calls_delta = @as([]const agent.ToolCallDelta, &deltas3) });

    // Finalize and check
    const response = try aggregator.finalize();
    defer response.deinit();

    try std.testing.expect(response.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_123", response.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("bash", response.tool_calls.?[0].function.name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", response.tool_calls.?[0].function.arguments);
}

test "StreamingAggregator - multiple tool calls" {
    const allocator = std.testing.allocator;

    var aggregator = agent.StreamingAggregator.init(allocator);
    defer aggregator.deinit();

    // Process first tool call
    const deltas1 = [_]agent.ToolCallDelta{
        .{ .index = 0, .id = "call_1", .function_name = "bash" },
    };
    try aggregator.processChunk(.{ .tool_calls_delta = @as([]const agent.ToolCallDelta, &deltas1) });

    // Process second tool call
    const deltas2 = [_]agent.ToolCallDelta{
        .{ .index = 1, .id = "call_2", .function_name = "set_agent_properties" },
    };
    try aggregator.processChunk(.{ .tool_calls_delta = @as([]const agent.ToolCallDelta, &deltas2) });

    // Add arguments to both
    const deltas3 = [_]agent.ToolCallDelta{
        .{ .index = 0, .function_arguments = "{\"cmd\":\"ls\"}" },
    };
    try aggregator.processChunk(.{ .tool_calls_delta = @as([]const agent.ToolCallDelta, &deltas3) });

    const deltas4 = [_]agent.ToolCallDelta{
        .{ .index = 1, .function_arguments = "{\"temperature\":0.7}" },
    };
    try aggregator.processChunk(.{ .tool_calls_delta = @as([]const agent.ToolCallDelta, &deltas4) });

    // Finalize and check
    const response = try aggregator.finalize();
    defer response.deinit();

    try std.testing.expect(response.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 2), response.tool_calls.?.len);

    // Tool calls should be sorted by index
    try std.testing.expectEqualStrings("call_1", response.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("bash", response.tool_calls.?[0].function.name);
    try std.testing.expectEqualStrings("call_2", response.tool_calls.?[1].id);
    try std.testing.expectEqualStrings("set_agent_properties", response.tool_calls.?[1].function.name);
}

test "StreamingAggregator - store finish reason and usage" {
    const allocator = std.testing.allocator;

    var aggregator = agent.StreamingAggregator.init(allocator);
    defer aggregator.deinit();

    try aggregator.processChunk(.{ .content = "Test" });
    try aggregator.processChunk(.{
        .finish_reason = .stop,
        .usage = .{
            .prompt_tokens = 100,
            .completion_tokens = 50,
            .total_tokens = 150,
        },
    });

    const response = try aggregator.finalize();
    defer response.deinit();

    try std.testing.expect(response.finish_reason != null);
    try std.testing.expectEqual(agent.FinishReason.stop, response.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 100), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(usize, 50), response.usage.completion_tokens);
    try std.testing.expectEqual(@as(usize, 150), response.usage.total_tokens);
}

test "StreamingAggregator - done flag does not process" {
    const allocator = std.testing.allocator;

    var aggregator = agent.StreamingAggregator.init(allocator);
    defer aggregator.deinit();

    try aggregator.processChunk(.{ .content = "Before done" });
    try aggregator.processChunk(.{ .done = true, .content = "Should not appear" });

    try std.testing.expectEqualStrings("Before done", aggregator.content.items);
}

test "parseSseLine - valid data line" {
    var test_logger = logger.Logger.init(std.testing.allocator, .{});
    var test_agent = try agent.Agent.init(std.testing.allocator, &test_logger);
    defer test_agent.deinit();

    const line = "data: {\"test\":\"value\"}";
    const result = test_agent.parseSseLine(line);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"test\":\"value\"}", result.?);
}

test "parseSseLine - [DONE] marker" {
    var test_logger = logger.Logger.init(std.testing.allocator, .{});
    var test_agent = try agent.Agent.init(std.testing.allocator, &test_logger);
    defer test_agent.deinit();

    const line = "data: [DONE]";
    const result = test_agent.parseSseLine(line);

    try std.testing.expect(result == null);
}

test "parseSseLine - empty line" {
    var test_logger = logger.Logger.init(std.testing.allocator, .{});
    var test_agent = try agent.Agent.init(std.testing.allocator, &test_logger);
    defer test_agent.deinit();

    const result = test_agent.parseSseLine("");
    try std.testing.expect(result == null);
}

test "parseSseLine - non-data line" {
    var test_logger = logger.Logger.init(std.testing.allocator, .{});
    var test_agent = try agent.Agent.init(std.testing.allocator, &test_logger);
    defer test_agent.deinit();

    const line = ": comment";
    const result = test_agent.parseSseLine(line);

    try std.testing.expect(result == null);
}

test "parseStreamChunk - content delta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var test_logger = logger.Logger.init(std.testing.allocator, .{});
    var test_agent = try agent.Agent.init(std.testing.allocator, &test_logger);
    defer test_agent.deinit();

    const data = "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}";
    const chunk = test_agent.parseStreamChunk(data, arena_alloc);

    try std.testing.expect(chunk != null);
    try std.testing.expect(chunk.?.content != null);
    try std.testing.expectEqualStrings("Hello", chunk.?.content.?);
}

test "parseStreamChunk - finish reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var test_logger = logger.Logger.init(std.testing.allocator, .{});
    var test_agent = try agent.Agent.init(std.testing.allocator, &test_logger);
    defer test_agent.deinit();

    const data = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}";
    const chunk = test_agent.parseStreamChunk(data, arena_alloc);

    try std.testing.expect(chunk != null);
    try std.testing.expect(chunk.?.finish_reason != null);
    try std.testing.expectEqual(agent.FinishReason.stop, chunk.?.finish_reason.?);
}

test "parseStreamChunk - tool call delta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var test_logger = logger.Logger.init(std.testing.allocator, .{});
    var test_agent = try agent.Agent.init(std.testing.allocator, &test_logger);
    defer test_agent.deinit();

    const data = "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_123\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}]},\"finish_reason\":null}]}";
    const chunk = test_agent.parseStreamChunk(data, arena_alloc);

    try std.testing.expect(chunk != null);
    try std.testing.expect(chunk.?.tool_calls_delta != null);
    try std.testing.expectEqual(@as(usize, 1), chunk.?.tool_calls_delta.?.len);
    try std.testing.expectEqualStrings("call_123", chunk.?.tool_calls_delta.?[0].id.?);
    try std.testing.expectEqualStrings("bash", chunk.?.tool_calls_delta.?[0].function_name.?);
}

test "parseStreamChunk - usage in final chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var test_logger = logger.Logger.init(std.testing.allocator, .{});
    var test_agent = try agent.Agent.init(std.testing.allocator, &test_logger);
    defer test_agent.deinit();

    const data = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":50,\"total_tokens\":150}}";
    const chunk = test_agent.parseStreamChunk(data, arena_alloc);

    try std.testing.expect(chunk != null);
    try std.testing.expect(chunk.?.usage != null);
    try std.testing.expectEqual(@as(usize, 100), chunk.?.usage.?.prompt_tokens);
    try std.testing.expectEqual(@as(usize, 50), chunk.?.usage.?.completion_tokens);
    try std.testing.expectEqual(@as(usize, 150), chunk.?.usage.?.total_tokens);
}

test "StreamingAggregator - complete streaming flow" {
    const allocator = std.testing.allocator;

    var aggregator = agent.StreamingAggregator.init(allocator);
    defer aggregator.deinit();

    // Simulate a complete streaming flow
    // 1. First content chunk
    try aggregator.processChunk(.{ .content = "The " });
    try aggregator.processChunk(.{ .content = "answer " });
    try aggregator.processChunk(.{ .content = "is 42." });

    // 2. Finish reason
    try aggregator.processChunk(.{
        .finish_reason = .stop,
        .usage = .{
            .prompt_tokens = 10,
            .completion_tokens = 5,
            .total_tokens = 15,
        },
    });

    // 3. Done marker
    try aggregator.processChunk(.{ .done = true });

    // Finalize
    const response = try aggregator.finalize();
    defer response.deinit();

    try std.testing.expectEqualStrings("The answer is 42.", response.content.?);
    try std.testing.expectEqual(agent.FinishReason.stop, response.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 10), response.usage.prompt_tokens);
}