// Behavioural tests for OpenAI Responses API (url_style = "openai-response").
// Covers buildJsonResponsesRequest + parse_responses_stream_chunk parity
// with the legacy chat-completions stack. Mirrors the shape of
// openai_reasoning_test.zig / parse_anthropic_sse_test.zig /
// anthropic_request_test.zig — arena allocator, substring + parsed JSON
// asserts, no network I/O.

const std = @import("std");
const testing = std.testing;
const agent = @import("Agent.zig");
const Agent = agent.Agent;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeResponsesAgent(opts: struct {
    reasoningEffort: ?[]const u8 = null,
    thinkingEnabled: bool = true,
    maxTokens: usize = 4096,
    model: []const u8 = "gpt-4o",
    baseUrl: []const u8 = "https://api.openai.com/v1",
    userIdentifier: []const u8 = "",
}) Agent {
    var a = Agent.init(testing.allocator, std.testing.io);
    a.model = opts.model;
    a.baseUrl = opts.baseUrl;
    a.UrlStyle = "openai-response";
    a.thinkingEnabled = opts.thinkingEnabled;
    a.reasoningEffort = opts.reasoningEffort;
    a.maxTokens = opts.maxTokens;
    a.userIdentifier = opts.userIdentifier;
    return a;
}

fn userMsg(text: []const u8) agent.AgentMessage {
    return .{
        .role = .user,
        .content = text,
        .content_parts = null,
        .tool_calls = null,
        .tool_call_id = null,
        .reasoning_content = null,
    };
}

fn sysMsg(text: []const u8) agent.AgentMessage {
    return .{
        .role = .system,
        .content = text,
        .content_parts = null,
        .tool_calls = null,
        .tool_call_id = null,
        .reasoning_content = null,
    };
}

fn assistantMsg(text: ?[]const u8, reasoning: ?[]const u8) agent.AgentMessage {
    return .{
        .role = .assistant,
        .content = text,
        .reasoning_content = reasoning,
        .tool_calls = null,
        .tool_call_id = null,
        .content_parts = null,
    };
}

fn buildResponsesBody(
    a: *Agent,
    messages: []const agent.AgentMessage,
    tools: []const agent.AgentTool,
    temperature: ?f32,
    max_tokens: ?usize,
    stream: bool,
) ![]u8 {
    const params = agent.AgentCall{
        .tools = tools,
        .messages = messages,
        .temperature = temperature,
        .max_tokens = max_tokens,
    };
    return try a.buildJsonResponsesRequest(params, stream);
}

const ParsedBody = struct {
    raw: []u8,
    parsed: std.json.Parsed(std.json.Value),
};

fn buildAndParse(
    a: *Agent,
    messages: []const agent.AgentMessage,
    tools: []const agent.AgentTool,
    temperature: ?f32,
    max_tokens: ?usize,
    stream: bool,
) !ParsedBody {
    const raw = try buildResponsesBody(a, messages, tools, temperature, max_tokens, stream);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    return .{ .raw = raw, .parsed = parsed };
}

fn freeBody(body: ParsedBody) void {
    testing.allocator.free(body.raw);
    body.parsed.deinit();
}

fn sampleTool() agent.AgentTool {
    return .{
        .type = "function",
        .function = .{
            .name = "get_weather",
            .description = "Get the weather",
            .parameters = .{
                .type = "object",
                .properties = &.{
                    .{ .name = "city", .type = "string", .description = "City name" },
                },
                .required = &.{"city"},
            },
        },
    };
}

// ---------------------------------------------------------------------------
// Builder: instructions from system messages
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: single system message becomes instructions" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        sysMsg("You are a helpful assistant."),
        userMsg("Hello."),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const ins = body.parsed.value.object.get("instructions");
    try testing.expect(ins != null);
    try testing.expect(ins.? == .string);
    try testing.expectEqualStrings("You are a helpful assistant.", ins.?.string);

    // system message must NOT appear in input[]
    const input = body.parsed.value.object.get("input").?.array;
    for (input.items) |item| {
        if (item.object.get("role")) |r| {
            try testing.expect(!std.mem.eql(u8, r.string, "system"));
        }
    }
    // input should have exactly 1 entry (the user message)
    try testing.expectEqual(@as(usize, 1), input.items.len);
}

test "buildJsonResponsesRequest: multiple system messages joined with \\n\\n into instructions" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        sysMsg("First part."),
        sysMsg("Second part."),
        userMsg("Hi."),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const ins = body.parsed.value.object.get("instructions").?.string;
    try testing.expectEqualStrings("First part.\n\nSecond part.", ins);
}

test "buildJsonResponsesRequest: no system message omits instructions field" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("Hello.")};
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    try testing.expect(body.parsed.value.object.get("instructions") == null);
    // also check raw has no "instructions" key
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"instructions\"") == null);
}

// ---------------------------------------------------------------------------
// Builder: input[] with input_text / input_image
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: user plain text becomes input message with input_text" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hello world")};
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 1), input.items.len);
    const item = input.items[0];
    try testing.expectEqualStrings("message", item.object.get("type").?.string);
    try testing.expectEqualStrings("user", item.object.get("role").?.string);
    const content = item.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content.items.len);
    try testing.expectEqualStrings("input_text", content.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("hello world", content.items[0].object.get("text").?.string);
}

test "buildJsonResponsesRequest: user content_parts with text+image emits input_text and input_image with detail default auto" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();

    const text_dup = try testing.allocator.dupe(u8, "what is this?");
    defer testing.allocator.free(text_dup);
    const url_dup = try testing.allocator.dupe(u8, "data:image/png;base64,abc123");
    defer testing.allocator.free(url_dup);

    const parts = try testing.allocator.alloc(agent.ContentPart, 2);
    defer testing.allocator.free(parts);
    parts[0] = .{ .part_type = "text", .text = text_dup, .image_url = null };
    parts[1] = .{ .part_type = "image_url", .text = null, .image_url = .{ .url = url_dup, .detail = null } };

    const messages = [_]agent.AgentMessage{
        .{ .role = .user, .content = null, .content_parts = parts, .tool_calls = null, .tool_call_id = null, .reasoning_content = null },
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 1), input.items.len);
    const content = input.items[0].object.get("content").?.array;
    try testing.expectEqual(@as(usize, 2), content.items.len);
    try testing.expectEqualStrings("input_text", content.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("what is this?", content.items[0].object.get("text").?.string);
    try testing.expectEqualStrings("input_image", content.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("data:image/png;base64,abc123", content.items[1].object.get("image_url").?.string);
    // detail defaults to "auto" when null
    try testing.expectEqualStrings("auto", content.items[1].object.get("detail").?.string);
}

test "buildJsonResponsesRequest: user content_parts image with explicit detail preserves it" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();

    const url_dup = try testing.allocator.dupe(u8, "data:image/jpeg;base64,xyz");
    defer testing.allocator.free(url_dup);
    const parts = try testing.allocator.alloc(agent.ContentPart, 1);
    defer testing.allocator.free(parts);
    parts[0] = .{ .part_type = "image_url", .text = null, .image_url = .{ .url = url_dup, .detail = "high" } };

    const messages = [_]agent.AgentMessage{
        .{ .role = .user, .content = null, .content_parts = parts, .tool_calls = null, .tool_call_id = null, .reasoning_content = null },
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const content = body.parsed.value.object.get("input").?.array.items[0].object.get("content").?.array;
    try testing.expectEqualStrings("high", content.items[0].object.get("detail").?.string);
}

// ---------------------------------------------------------------------------
// Builder: assistant output_text (content + reasoning_content)
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: assistant with content and reasoning_content emits both as output_text" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        assistantMsg("final answer", "thinking trace"),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    // input[0]=user, input[1]=assistant
    try testing.expectEqual(@as(usize, 2), input.items.len);
    const assistant = input.items[1];
    try testing.expectEqualStrings("assistant", assistant.object.get("role").?.string);
    const content = assistant.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 2), content.items.len);
    // reasoning_content first, then content (per builder order)
    try testing.expectEqualStrings("output_text", content.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("thinking trace", content.items[0].object.get("text").?.string);
    try testing.expectEqualStrings("output_text", content.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("final answer", content.items[1].object.get("text").?.string);
}

test "buildJsonResponsesRequest: assistant with only content emits single output_text" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        assistantMsg("only content", null),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const assistant = body.parsed.value.object.get("input").?.array.items[1];
    const content = assistant.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content.items.len);
    try testing.expectEqualStrings("output_text", content.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("only content", content.items[0].object.get("text").?.string);
}

test "buildJsonResponsesRequest: assistant with only reasoning_content emits single output_text" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        assistantMsg(null, "only reasoning"),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const assistant = body.parsed.value.object.get("input").?.array.items[1];
    const content = assistant.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content.items.len);
    try testing.expectEqualStrings("only reasoning", content.items[0].object.get("text").?.string);
}

test "buildJsonResponsesRequest: empty assistant without tools emits output_text empty string" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        assistantMsg(null, null),
    };
    // also test with empty strings
    const messages2 = [_]agent.AgentMessage{
        userMsg("hi"),
        assistantMsg("", ""),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);
    const assistant = body.parsed.value.object.get("input").?.array.items[1];
    const content = assistant.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content.items.len);
    try testing.expectEqualStrings("output_text", content.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("", content.items[0].object.get("text").?.string);

    var body2 = try buildAndParse(&a, &messages2, &.{}, null, null, true);
    defer freeBody(body2);
    const assistant2 = body2.parsed.value.object.get("input").?.array.items[1];
    const content2 = assistant2.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content2.items.len);
    try testing.expectEqualStrings("", content2.items[0].object.get("text").?.string);
}

// ---------------------------------------------------------------------------
// Builder: function_call + function_call_output for tools
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: assistant tool_calls become function_call items" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();

    const tc_id = try testing.allocator.dupe(u8, "call_123");
    defer testing.allocator.free(tc_id);
    const tc_name = try testing.allocator.dupe(u8, "get_weather");
    defer testing.allocator.free(tc_name);
    const tc_args = try testing.allocator.dupe(u8, "{\"city\":\"Paris\"}");
    defer testing.allocator.free(tc_args);
    const tc_array = try testing.allocator.alloc(agent.ToolCall, 1);
    defer testing.allocator.free(tc_array);
    tc_array[0] = .{ .id = tc_id, .function = .{ .name = tc_name, .arguments = tc_args } };

    const messages = [_]agent.AgentMessage{
        userMsg("weather?"),
        .{ .role = .assistant, .content = null, .reasoning_content = null, .tool_calls = tc_array, .tool_call_id = null, .content_parts = null },
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    // user + function_call (no assistant message because content empty and has tool_calls)
    try testing.expectEqual(@as(usize, 2), input.items.len);
    const fc = input.items[1];
    try testing.expectEqualStrings("function_call", fc.object.get("type").?.string);
    try testing.expectEqualStrings("call_123", fc.object.get("call_id").?.string);
    try testing.expectEqualStrings("get_weather", fc.object.get("name").?.string);
    try testing.expectEqualStrings("{\"city\":\"Paris\"}", fc.object.get("arguments").?.string);
}

test "buildJsonResponsesRequest: assistant with content and tool_calls emits message + function_call" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();

    const tc_id = try testing.allocator.dupe(u8, "call_456");
    defer testing.allocator.free(tc_id);
    const tc_name = try testing.allocator.dupe(u8, "search");
    defer testing.allocator.free(tc_name);
    const tc_args = try testing.allocator.dupe(u8, "{\"q\":\"test\"}");
    defer testing.allocator.free(tc_args);
    const tc_array = try testing.allocator.alloc(agent.ToolCall, 1);
    defer testing.allocator.free(tc_array);
    tc_array[0] = .{ .id = tc_id, .function = .{ .name = tc_name, .arguments = tc_args } };

    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        .{ .role = .assistant, .content = "thinking", .reasoning_content = null, .tool_calls = tc_array, .tool_call_id = null, .content_parts = null },
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 3), input.items.len);
    // input[0]=user, input[1]=assistant message, input[2]=function_call
    try testing.expectEqualStrings("message", input.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("assistant", input.items[1].object.get("role").?.string);
    try testing.expectEqualStrings("function_call", input.items[2].object.get("type").?.string);
}

test "buildJsonResponsesRequest: tool role becomes function_call_output" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        .{ .role = .assistant, .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = null, .content_parts = null },
        .{ .role = .tool, .content = "tool result", .tool_call_id = "call_123", .tool_calls = null, .content_parts = null, .reasoning_content = null },
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    // user + assistant(empty) + function_call_output
    try testing.expectEqual(@as(usize, 3), input.items.len);
    const fco = input.items[2];
    try testing.expectEqualStrings("function_call_output", fco.object.get("type").?.string);
    try testing.expectEqualStrings("call_123", fco.object.get("call_id").?.string);
    try testing.expectEqualStrings("tool result", fco.object.get("output").?.string);
}

// ---------------------------------------------------------------------------
// Builder: temperature, max_output_tokens, store, stream, user, tools
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: temperature is emitted" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hi")};
    var body = try buildAndParse(&a, &messages, &.{}, 0.7, null, true);
    defer freeBody(body);

    try testing.expect(body.parsed.value.object.get("temperature") != null);
    // f32 0.7 serializes as 0.699999988079071 or 0.7 depending on formatting
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"temperature\":") != null);
}

test "buildJsonResponsesRequest: max_output_tokens from params overrides self.maxTokens" {
    var a = makeResponsesAgent(.{ .maxTokens = 4096 });
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hi")};

    var body1 = try buildAndParse(&a, &messages, &.{}, null, 8192, true);
    defer freeBody(body1);
    try testing.expectEqual(@as(i64, 8192), body1.parsed.value.object.get("max_output_tokens").?.integer);

    var body2 = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body2);
    try testing.expectEqual(@as(i64, 4096), body2.parsed.value.object.get("max_output_tokens").?.integer);
}

test "buildJsonResponsesRequest: store is always false" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hi")};
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const store = body.parsed.value.object.get("store").?;
    try testing.expect(store == .bool);
    try testing.expectEqual(false, store.bool);
}

test "buildJsonResponsesRequest: stream true emits stream:true, stream false omits it" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hi")};

    var body_true = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body_true);
    try testing.expectEqual(true, body_true.parsed.value.object.get("stream").?.bool);

    var body_false = try buildAndParse(&a, &messages, &.{}, null, null, false);
    defer freeBody(body_false);
    // When stream=false, the field is omitted (jsonStringify only writes when self.stream is true)
    try testing.expect(body_false.parsed.value.object.get("stream") == null);
    try testing.expect(std.mem.indexOf(u8, body_false.raw, "\"stream\"") == null);
}

test "buildJsonResponsesRequest: user field present when identifier set, absent when empty" {
    var a_with = makeResponsesAgent(.{ .userIdentifier = "user-123" });
    defer a_with.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hi")};
    var body_with = try buildAndParse(&a_with, &messages, &.{}, null, null, true);
    defer freeBody(body_with);
    try testing.expectEqualStrings("user-123", body_with.parsed.value.object.get("user").?.string);

    var a_without = makeResponsesAgent(.{ .userIdentifier = "" });
    defer a_without.deinit();
    var body_without = try buildAndParse(&a_without, &messages, &.{}, null, null, true);
    defer freeBody(body_without);
    try testing.expect(body_without.parsed.value.object.get("user") == null);
}

test "buildJsonResponsesRequest: tools and tool_choice present when tools non-empty" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hi")};
    const tools = [_]agent.AgentTool{sampleTool()};
    var body = try buildAndParse(&a, &messages, &tools, null, null, true);
    defer freeBody(body);

    try testing.expect(body.parsed.value.object.get("tools") != null);
    const tools_arr = body.parsed.value.object.get("tools").?.array;
    try testing.expectEqual(@as(usize, 1), tools_arr.items.len);
    try testing.expectEqualStrings("get_weather", tools_arr.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("auto", body.parsed.value.object.get("tool_choice").?.string);
}

test "buildJsonResponsesRequest: tools absent omits tools and tool_choice" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hi")};
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    try testing.expect(body.parsed.value.object.get("tools") == null);
    try testing.expect(body.parsed.value.object.get("tool_choice") == null);
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"tool_choice\"") == null);
}

// ---------------------------------------------------------------------------
// Builder: reasoning.effort
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: reasoningEffort set emits reasoning.effort" {
    var a = makeResponsesAgent(.{ .reasoningEffort = "high" });
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hi")};
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const reasoning = body.parsed.value.object.get("reasoning").?;
    try testing.expect(reasoning == .object);
    try testing.expectEqualStrings("high", reasoning.object.get("effort").?.string);
}

test "buildJsonResponsesRequest: reasoningEffort null omits reasoning field" {
    var a = makeResponsesAgent(.{ .reasoningEffort = null });
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hi")};
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    try testing.expect(body.parsed.value.object.get("reasoning") == null);
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"reasoning\"") == null);
}

test "buildJsonResponsesRequest: reasoningEffort empty string omits reasoning field" {
    var a = makeResponsesAgent(.{ .reasoningEffort = "" });
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hi")};
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    try testing.expect(body.parsed.value.object.get("reasoning") == null);
}

test "buildJsonResponsesRequest: reasoningEffort each value passes through verbatim" {
    const values = [_][]const u8{ "low", "medium", "high", "auto" };
    for (values) |v| {
        var a = makeResponsesAgent(.{ .reasoningEffort = v });
        defer a.deinit();
        const messages = [_]agent.AgentMessage{userMsg("hi")};
        var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
        defer freeBody(body);

        const reasoning = body.parsed.value.object.get("reasoning").?;
        try testing.expectEqualStrings(v, reasoning.object.get("effort").?.string);
    }
}

test "buildJsonResponsesRequest: reasoningEffort null + thinkingEnabled true omits reasoning (no auto fallback)" {
    // Regression: must NOT auto-map thinkingEnabled -> reasoning.effort "medium"
    var a = makeResponsesAgent(.{ .reasoningEffort = null, .thinkingEnabled = true });
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hi")};
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    try testing.expect(body.parsed.value.object.get("reasoning") == null);
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"reasoning\"") == null);
}

test "buildJsonResponsesRequest: reasoningEffort null + thinkingEnabled false omits reasoning" {
    var a = makeResponsesAgent(.{ .reasoningEffort = null, .thinkingEnabled = false });
    defer a.deinit();
    const messages = [_]agent.AgentMessage{userMsg("hi")};
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    try testing.expect(body.parsed.value.object.get("reasoning") == null);
}

// ---------------------------------------------------------------------------
// Parser: response.output_text.delta -> content
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: response.output_text.delta populates content" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.output_text.delta\",\"delta\":\"hello world\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("hello world", chunk.?.content.?);
    try testing.expect(chunk.?.reasoning_content == null);
    try testing.expect(chunk.?.tool_calls_delta == null);
}

test "parse_responses_stream_chunk: response.output_text.delta empty string returns null" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.output_text.delta\",\"delta\":\"\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk == null);
}

// ---------------------------------------------------------------------------
// Parser: reasoning deltas -> reasoning_content
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: response.reasoning_text.delta populates reasoning_content" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.reasoning_text.delta\",\"delta\":\"step 1\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("step 1", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.reasoning_summary_text.delta populates reasoning_content" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"summary\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("summary", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.reasoning.delta populates reasoning_content" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.reasoning.delta\",\"delta\":\"reasoning chunk\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("reasoning chunk", chunk.?.reasoning_content.?);
}

// ---------------------------------------------------------------------------
// Parser: tool call deltas
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: response.output_item.added function_call emits tool_calls_delta with id+name" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_abc\",\"name\":\"get_weather\",\"arguments\":\"\"}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.tool_calls_delta != null);
    try testing.expectEqual(@as(usize, 1), chunk.?.tool_calls_delta.?.len);
    try testing.expectEqual(@as(usize, 0), chunk.?.tool_calls_delta.?[0].index);
    try testing.expectEqualStrings("call_abc", chunk.?.tool_calls_delta.?[0].id.?);
    try testing.expectEqualStrings("get_weather", chunk.?.tool_calls_delta.?[0].function_name.?);
}

test "parse_responses_stream_chunk: response.output_item.added non-function_call returns null" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"role\":\"assistant\"}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk == null);
}

test "parse_responses_stream_chunk: response.function_call_arguments.delta emits tool_calls_delta arguments" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"city\\\":\\\"Paris\\\"}\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.tool_calls_delta != null);
    try testing.expectEqual(@as(usize, 1), chunk.?.tool_calls_delta.?.len);
    try testing.expectEqualStrings("{\"city\":\"Paris\"}", chunk.?.tool_calls_delta.?[0].function_arguments.?);
    try testing.expectEqual(@as(usize, 0), chunk.?.tool_calls_delta.?[0].index);
}

test "parse_responses_stream_chunk: response.function_call_arguments.delta with output_index 1" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"partial\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(usize, 1), chunk.?.tool_calls_delta.?[0].index);
}

// ---------------------------------------------------------------------------
// Parser: terminal events — finish_reason + usage + tool_calls override
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: response.completed without function_call => finish_reason stop" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?agent.FinishReason, .stop), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: response.completed with function_call output => finish_reason tool_calls" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call_123\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Paris\\\"}\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?agent.FinishReason, .tool_calls), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: response.completed with mixed output containing function_call => tool_calls" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]},{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"search\",\"arguments\":\"{}\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?agent.FinishReason, .tool_calls), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: response.completed usage maps input_tokens->prompt_tokens etc" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":42,\"output_tokens\":7,\"total_tokens\":49}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.usage != null);
    try testing.expectEqual(@as(u32, 42), chunk.?.usage.?.prompt_tokens);
    try testing.expectEqual(@as(u32, 7), chunk.?.usage.?.completion_tokens);
    try testing.expectEqual(@as(u32, 49), chunk.?.usage.?.total_tokens);
}

test "parse_responses_stream_chunk: response.completed usage with cached_tokens via input_tokens_details" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":100,\"output_tokens\":20,\"total_tokens\":120,\"input_tokens_details\":{\"cached_tokens\":30}}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(u32, 30), chunk.?.usage.?.cache_read_input_tokens);
}

test "parse_responses_stream_chunk: response.completed usage without total_tokens computes prompt+completion" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(u32, 15), chunk.?.usage.?.total_tokens);
}

test "parse_responses_stream_chunk: response.incomplete with max_output_tokens => finish_reason length" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?agent.FinishReason, .length), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: response.failed => finish_reason content_filter" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"total_tokens\":10}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?agent.FinishReason, .content_filter), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: response.incomplete without max_output_tokens reason => stop" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"content_filter\"},\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"total_tokens\":10}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?agent.FinishReason, .stop), chunk.?.finish_reason);
}

// ---------------------------------------------------------------------------
// Parser: ignored lifecycle events return null
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: ignored events return null" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();

    const ignored = [_][]const u8{
        "{\"type\":\"response.output_text.done\",\"output_index\":0,\"text\":\"hi\"}",
        "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_123\"}}",
        "{\"type\":\"response.in_progress\",\"response\":{\"id\":\"resp_123\"}}",
        "{\"type\":\"response.queued\",\"response\":{\"id\":\"resp_123\"}}",
        "{\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\"}}",
        "{\"type\":\"response.output_item.done\",\"output_index\":0}",
        "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"arguments\":\"{}\"}",
        "{\"type\":\"response.reasoning_text.done\"}",
        "{\"type\":\"response.refusal.done\"}",
    };
    for (ignored) |data| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk == null);
    }
}

test "parse_responses_stream_chunk: response.refusal.delta populates content" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.refusal.delta\",\"delta\":\"I cannot do that\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("I cannot do that", chunk.?.content.?);
}

// ---------------------------------------------------------------------------
// Parser: dispatch via UrlStyle
// ---------------------------------------------------------------------------

test "parse_stream_chunk dispatches to Responses parser when UrlStyle is openai-response" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // This is Responses-shaped, should parse via Responses parser
    const data = "{\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("hello", chunk.?.content.?);
}

test "parse_stream_chunk dispatches to OpenAI parser when UrlStyle is openai" {
    var a = Agent.init(testing.allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "openai";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"id\":\"chatcmpl-x\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"}}]}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("hello", chunk.?.content.?);
}
