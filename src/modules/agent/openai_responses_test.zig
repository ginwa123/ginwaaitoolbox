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

fn assistantMsgFull(text: ?[]const u8, reasoning: ?[]const u8, id: ?[]const u8, enc: ?[]const u8) agent.AgentMessage {
    return .{
        .role = .assistant,
        .content = text,
        .reasoning_content = reasoning,
        .reasoning_id = id,
        .reasoning_encrypted_content = enc,
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

test "buildJsonResponsesRequest: assistant with content and reasoning_content emits separate reasoning and message items" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        assistantMsg("final answer", "thinking trace"),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    // input[0]=user, input[1]=reasoning, input[2]=assistant message
    try testing.expectEqual(@as(usize, 3), input.items.len);
    const reasoning = input.items[1];
    try testing.expectEqualStrings("reasoning", reasoning.object.get("type").?.string);
    const summary = reasoning.object.get("summary").?.array;
    try testing.expectEqual(@as(usize, 1), summary.items.len);
    try testing.expectEqualStrings("summary_text", summary.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("thinking trace", summary.items[0].object.get("text").?.string);
    // reasoning item must NOT have role/content, and must NOT leak into message
    try testing.expect(reasoning.object.get("role") == null);
    try testing.expect(reasoning.object.get("content") == null);

    const assistant = input.items[2];
    try testing.expectEqualStrings("message", assistant.object.get("type").?.string);
    try testing.expectEqualStrings("assistant", assistant.object.get("role").?.string);
    const content = assistant.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content.items.len);
    try testing.expectEqualStrings("output_text", content.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("final answer", content.items[0].object.get("text").?.string);
    // assistant content must NOT contain reasoning
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"thinking trace\"") != null);
    // ensure reasoning is not represented as output_text inside message
    for (content.items) |c| {
        try testing.expect(!std.mem.eql(u8, c.object.get("text").?.string, "thinking trace"));
    }
}

test "buildJsonResponsesRequest: assistant with only content emits single message item" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        assistantMsg("only content", null),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 2), input.items.len);
    const assistant = input.items[1];
    try testing.expectEqualStrings("message", assistant.object.get("type").?.string);
    try testing.expectEqualStrings("assistant", assistant.object.get("role").?.string);
    const content = assistant.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content.items.len);
    try testing.expectEqualStrings("output_text", content.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("only content", content.items[0].object.get("text").?.string);
    // no reasoning item
    for (input.items) |item| {
        try testing.expect(!std.mem.eql(u8, item.object.get("type").?.string, "reasoning"));
    }
}

test "buildJsonResponsesRequest: assistant with only reasoning_content emits single reasoning item" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        assistantMsg(null, "only reasoning"),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 2), input.items.len);
    const reasoning = input.items[1];
    try testing.expectEqualStrings("reasoning", reasoning.object.get("type").?.string);
    const summary = reasoning.object.get("summary").?.array;
    try testing.expectEqual(@as(usize, 1), summary.items.len);
    try testing.expectEqualStrings("summary_text", summary.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("only reasoning", summary.items[0].object.get("text").?.string);
    // no message item for this assistant turn
    for (input.items) |item| {
        if (std.mem.eql(u8, item.object.get("type").?.string, "message")) {
            if (item.object.get("role")) |r| {
                if (std.mem.eql(u8, r.string, "assistant")) {
                    // the only assistant item should be reasoning, not message
                    try testing.expect(false); // should not reach
                }
            }
        }
    }
}

test "buildJsonResponsesRequest: assistant reasoning with id and encrypted_content emits them" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        .{
            .role = .assistant,
            .content = "final answer",
            .reasoning_content = "thinking trace",
            .reasoning_id = "rs_123",
            .reasoning_encrypted_content = "ENC...",
            .tool_calls = null,
            .tool_call_id = null,
            .content_parts = null,
        },
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 3), input.items.len);
    const reasoning = input.items[1];
    try testing.expectEqualStrings("reasoning", reasoning.object.get("type").?.string);
    try testing.expectEqualStrings("rs_123", reasoning.object.get("id").?.string);
    try testing.expectEqualStrings("ENC...", reasoning.object.get("encrypted_content").?.string);
    const summary = reasoning.object.get("summary").?.array;
    try testing.expectEqualStrings("thinking trace", summary.items[0].object.get("text").?.string);
}

test "buildJsonResponsesRequest: assistant reasoning without id omits id and encrypted_content" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        assistantMsg("final answer", "thinking trace"),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const reasoning = body.parsed.value.object.get("input").?.array.items[1];
    try testing.expectEqualStrings("reasoning", reasoning.object.get("type").?.string);
    try testing.expect(reasoning.object.get("id") == null);
    try testing.expect(reasoning.object.get("encrypted_content") == null);
    // raw should not contain empty id
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"id\":\"\"") == null);
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

// ---------------------------------------------------------------------------
// Parser: terminal reasoning metadata (Task 4)
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: response.completed with reasoning item captures id/summary/encrypted_content" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data =
        "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_123\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"thinking trace\"}],\"encrypted_content\":\"ENC_DATA\"},{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"final answer\"}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_123", chunk.?.reasoning_id.?);
    try testing.expectEqualStrings("ENC_DATA", chunk.?.reasoning_encrypted_content.?);
    try testing.expectEqualStrings("thinking trace", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.completed with multiple summary entries joins with newline" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data =
        "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_456\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"step 1\"},{\"type\":\"summary_text\",\"text\":\"step 2\"},{\"type\":\"summary_text\",\"text\":\"step 3\"}],\"encrypted_content\":\"ENC2\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_456", chunk.?.reasoning_id.?);
    try testing.expectEqualStrings("ENC2", chunk.?.reasoning_encrypted_content.?);
    try testing.expectEqualStrings("step 1\nstep 2\nstep 3", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.completed without reasoning item has no reasoning metadata" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.reasoning_id == null);
    try testing.expect(chunk.?.reasoning_encrypted_content == null);
    try testing.expect(chunk.?.reasoning_content == null);
}

test "parse_responses_stream_chunk: response.completed reasoning item without encrypted_content still captures id and summary" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data =
        "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_789\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"only summary\"}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_789", chunk.?.reasoning_id.?);
    try testing.expect(chunk.?.reasoning_encrypted_content == null);
    try testing.expectEqualStrings("only summary", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.completed reasoning item with empty summary has no reasoning_content" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data =
        "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_empty\",\"summary\":[],\"encrypted_content\":\"ENC_EMPTY\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_empty", chunk.?.reasoning_id.?);
    try testing.expectEqualStrings("ENC_EMPTY", chunk.?.reasoning_encrypted_content.?);
    try testing.expect(chunk.?.reasoning_content == null);
}

// ---------------------------------------------------------------------------
// Aggregator: reasoning metadata via terminal chunk
// ---------------------------------------------------------------------------

test "StreamingAggregator: terminal reasoning chunk populates reasoning_id and encrypted_content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var agg = agent.StreamingAggregator.init(arena.allocator());
    defer agg.deinit();

    // Simulate delta reasoning
    try agg.process_chunk(.{ .reasoning_content = "delta thinking" });
    // Simulate terminal chunk with id/encrypted/summary fallback
    try agg.process_chunk(.{
        .reasoning_id = "rs_agg_1",
        .reasoning_encrypted_content = "ENC_AGG",
        .reasoning_content = "summary fallback",
        .finish_reason = .stop,
        .usage = .{ .prompt_tokens = 10, .completion_tokens = 5, .total_tokens = 15 },
    });

    var res = try agg.finalize();
    defer res.deinit();
    // Delta content wins over summary fallback
    try testing.expectEqualStrings("delta thinking", res.reasoning_content.?);
    try testing.expectEqualStrings("rs_agg_1", res.reasoning_id.?);
    try testing.expectEqualStrings("ENC_AGG", res.reasoning_encrypted_content.?);
}

test "StreamingAggregator: summary fallback used when no delta reasoning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var agg = agent.StreamingAggregator.init(arena.allocator());
    defer agg.deinit();

    try agg.process_chunk(.{
        .reasoning_id = "rs_fallback",
        .reasoning_encrypted_content = "ENC_FB",
        .reasoning_content = "summary only",
        .finish_reason = .stop,
    });

    var res = try agg.finalize();
    defer res.deinit();
    try testing.expectEqualStrings("summary only", res.reasoning_content.?);
    try testing.expectEqualStrings("rs_fallback", res.reasoning_id.?);
    try testing.expectEqualStrings("ENC_FB", res.reasoning_encrypted_content.?);
}

test "StreamingAggregator: no reasoning stays null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var agg = agent.StreamingAggregator.init(arena.allocator());
    defer agg.deinit();

    try agg.process_chunk(.{ .content = "hello", .finish_reason = .stop });
    var res = try agg.finalize();
    defer res.deinit();
    try testing.expect(res.reasoning_content == null);
    try testing.expect(res.reasoning_id == null);
    try testing.expect(res.reasoning_encrypted_content == null);
}

// ---------------------------------------------------------------------------
// Task 6: Multi-turn replay — builder ordering with reasoning metadata
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: multi-turn replay preserves ordering reasoning before assistant per turn" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("first question"),
        assistantMsgFull("first answer", "first thinking", "rs_1", "ENC_1"),
        userMsg("second question"),
        assistantMsgFull("second answer", "second thinking", "rs_2", "ENC_2"),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    // Expected: [user, reasoning(rs_1), assistant(first answer), user, reasoning(rs_2), assistant(second answer)]
    try testing.expectEqual(@as(usize, 6), input.items.len);

    try testing.expectEqualStrings("message", input.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("user", input.items[0].object.get("role").?.string);

    try testing.expectEqualStrings("reasoning", input.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("rs_1", input.items[1].object.get("id").?.string);
    try testing.expectEqualStrings("ENC_1", input.items[1].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings("first thinking", input.items[1].object.get("summary").?.array.items[0].object.get("text").?.string);

    try testing.expectEqualStrings("message", input.items[2].object.get("type").?.string);
    try testing.expectEqualStrings("assistant", input.items[2].object.get("role").?.string);
    try testing.expectEqualStrings("first answer", input.items[2].object.get("content").?.array.items[0].object.get("text").?.string);

    try testing.expectEqualStrings("message", input.items[3].object.get("type").?.string);
    try testing.expectEqualStrings("user", input.items[3].object.get("role").?.string);

    try testing.expectEqualStrings("reasoning", input.items[4].object.get("type").?.string);
    try testing.expectEqualStrings("rs_2", input.items[4].object.get("id").?.string);
    try testing.expectEqualStrings("ENC_2", input.items[4].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings("second thinking", input.items[4].object.get("summary").?.array.items[0].object.get("text").?.string);

    try testing.expectEqualStrings("message", input.items[5].object.get("type").?.string);
    try testing.expectEqualStrings("assistant", input.items[5].object.get("role").?.string);
    try testing.expectEqualStrings("second answer", input.items[5].object.get("content").?.array.items[0].object.get("text").?.string);
}

test "buildJsonResponsesRequest: multi-turn replay reasoning not leaked into output_text" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("q1"),
        assistantMsgFull("a1", "thinking 1", "rs_1", "ENC_1"),
        userMsg("q2"),
        assistantMsgFull("a2", "thinking 2", "rs_2", "ENC_2"),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    for (input.items) |item| {
        if (std.mem.eql(u8, item.object.get("type").?.string, "message")) {
            if (item.object.get("role")) |r| {
                if (std.mem.eql(u8, r.string, "assistant")) {
                    const content = item.object.get("content").?.array;
                    for (content.items) |c| {
                        const t = c.object.get("text").?.string;
                        try testing.expect(!std.mem.eql(u8, t, "thinking 1"));
                        try testing.expect(!std.mem.eql(u8, t, "thinking 2"));
                    }
                }
            }
        }
    }
}

test "buildJsonResponsesRequest: multi-turn replay encrypted_content preserved verbatim" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const enc1 = "ENCRYPTED_DATA_TURN_1_!@#$%";
    const enc2 = "ENCRYPTED_DATA_TURN_2_^&*()";
    const messages = [_]agent.AgentMessage{
        userMsg("q1"),
        assistantMsgFull("a1", "t1", "rs_1", enc1),
        userMsg("q2"),
        assistantMsgFull("a2", "t2", "rs_2", enc2),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqualStrings(enc1, input.items[1].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings(enc2, input.items[4].object.get("encrypted_content").?.string);
}

test "buildJsonResponsesRequest: multi-turn replay ids preserved per turn" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("q1"),
        assistantMsgFull("a1", "t1", "rs_alpha", "ENC_A"),
        userMsg("q2"),
        assistantMsgFull("a2", "t2", "rs_beta", "ENC_B"),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqualStrings("rs_alpha", input.items[1].object.get("id").?.string);
    try testing.expectEqualStrings("rs_beta", input.items[4].object.get("id").?.string);
    // ids must not be swapped
    try testing.expect(!std.mem.eql(u8, input.items[1].object.get("id").?.string, "rs_beta"));
    try testing.expect(!std.mem.eql(u8, input.items[4].object.get("id").?.string, "rs_alpha"));
}

// ---------------------------------------------------------------------------
// Task 7: Tool-call replay — reasoning separate from function_call
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: tool-call replay reasoning separate from function_call" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();

    const tc_id = try testing.allocator.dupe(u8, "call_tool_1");
    defer testing.allocator.free(tc_id);
    const tc_name = try testing.allocator.dupe(u8, "search");
    defer testing.allocator.free(tc_name);
    const tc_args = try testing.allocator.dupe(u8, "{\"q\":\"test\"}");
    defer testing.allocator.free(tc_args);
    const tc_array = try testing.allocator.alloc(agent.ToolCall, 1);
    defer testing.allocator.free(tc_array);
    tc_array[0] = .{ .id = tc_id, .function = .{ .name = tc_name, .arguments = tc_args } };

    const messages = [_]agent.AgentMessage{
        userMsg("find info"),
        .{
            .role = .assistant,
            .content = null,
            .reasoning_content = "need to search",
            .reasoning_id = "rs_tool_1",
            .reasoning_encrypted_content = "ENC_TOOL_1",
            .tool_calls = tc_array,
            .tool_call_id = null,
            .content_parts = null,
        },
        .{ .role = .tool, .content = "tool result here", .tool_call_id = "call_tool_1", .tool_calls = null, .content_parts = null, .reasoning_content = null },
        assistantMsgFull("final answer", "final thinking", "rs_tool_2", "ENC_TOOL_2"),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    // Expected: [user, reasoning(rs_tool_1), function_call, function_call_output, reasoning(rs_tool_2), assistant(final answer)]
    try testing.expectEqual(@as(usize, 6), input.items.len);

    try testing.expectEqualStrings("message", input.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("user", input.items[0].object.get("role").?.string);

    try testing.expectEqualStrings("reasoning", input.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("rs_tool_1", input.items[1].object.get("id").?.string);
    try testing.expectEqualStrings("ENC_TOOL_1", input.items[1].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings("need to search", input.items[1].object.get("summary").?.array.items[0].object.get("text").?.string);

    try testing.expectEqualStrings("function_call", input.items[2].object.get("type").?.string);
    try testing.expectEqualStrings("call_tool_1", input.items[2].object.get("call_id").?.string);
    try testing.expectEqualStrings("search", input.items[2].object.get("name").?.string);

    try testing.expectEqualStrings("function_call_output", input.items[3].object.get("type").?.string);
    try testing.expectEqualStrings("call_tool_1", input.items[3].object.get("call_id").?.string);
    try testing.expectEqualStrings("tool result here", input.items[3].object.get("output").?.string);

    try testing.expectEqualStrings("reasoning", input.items[4].object.get("type").?.string);
    try testing.expectEqualStrings("rs_tool_2", input.items[4].object.get("id").?.string);
    try testing.expectEqualStrings("ENC_TOOL_2", input.items[4].object.get("encrypted_content").?.string);

    try testing.expectEqualStrings("message", input.items[5].object.get("type").?.string);
    try testing.expectEqualStrings("assistant", input.items[5].object.get("role").?.string);
    try testing.expectEqualStrings("final answer", input.items[5].object.get("content").?.array.items[0].object.get("text").?.string);
}

test "buildJsonResponsesRequest: tool-call replay reasoning not inside function_call" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();

    const tc_id = try testing.allocator.dupe(u8, "call_x");
    defer testing.allocator.free(tc_id);
    const tc_name = try testing.allocator.dupe(u8, "do_thing");
    defer testing.allocator.free(tc_name);
    const tc_args = try testing.allocator.dupe(u8, "{}");
    defer testing.allocator.free(tc_args);
    const tc_array = try testing.allocator.alloc(agent.ToolCall, 1);
    defer testing.allocator.free(tc_array);
    tc_array[0] = .{ .id = tc_id, .function = .{ .name = tc_name, .arguments = tc_args } };

    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        .{
            .role = .assistant,
            .content = null,
            .reasoning_content = "secret thinking",
            .reasoning_id = "rs_x",
            .reasoning_encrypted_content = "ENC_X",
            .tool_calls = tc_array,
            .tool_call_id = null,
            .content_parts = null,
        },
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    // function_call item must not contain reasoning text
    const input = body.parsed.value.object.get("input").?.array;
    for (input.items) |item| {
        if (std.mem.eql(u8, item.object.get("type").?.string, "function_call")) {
            // function_call has call_id/name/arguments, no summary/content with reasoning
            try testing.expect(item.object.get("summary") == null);
            try testing.expect(item.object.get("encrypted_content") == null);
            const args = item.object.get("arguments").?.string;
            try testing.expect(std.mem.indexOf(u8, args, "secret thinking") == null);
        }
    }
    // reasoning item must be separate
    var found_reasoning = false;
    for (input.items) |item| {
        if (std.mem.eql(u8, item.object.get("type").?.string, "reasoning")) {
            found_reasoning = true;
            try testing.expectEqualStrings("secret thinking", item.object.get("summary").?.array.items[0].object.get("text").?.string);
        }
    }
    try testing.expect(found_reasoning);
}

test "buildJsonResponsesRequest: tool-call replay final answer separate from reasoning" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();

    const tc_id = try testing.allocator.dupe(u8, "call_y");
    defer testing.allocator.free(tc_id);
    const tc_name = try testing.allocator.dupe(u8, "lookup");
    defer testing.allocator.free(tc_name);
    const tc_args = try testing.allocator.dupe(u8, "{\"id\":1}");
    defer testing.allocator.free(tc_args);
    const tc_array = try testing.allocator.alloc(agent.ToolCall, 1);
    defer testing.allocator.free(tc_array);
    tc_array[0] = .{ .id = tc_id, .function = .{ .name = tc_name, .arguments = tc_args } };

    const messages = [_]agent.AgentMessage{
        userMsg("q"),
        .{
            .role = .assistant,
            .content = null,
            .reasoning_content = "reasoning before tool",
            .reasoning_id = "rs_y1",
            .reasoning_encrypted_content = "ENC_Y1",
            .tool_calls = tc_array,
            .tool_call_id = null,
            .content_parts = null,
        },
        .{ .role = .tool, .content = "result", .tool_call_id = "call_y", .tool_calls = null, .content_parts = null, .reasoning_content = null },
        assistantMsgFull("done", "reasoning after tool", "rs_y2", "ENC_Y2"),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    // last item is assistant message with "done", not reasoning
    const last = input.items[input.items.len - 1];
    try testing.expectEqualStrings("message", last.object.get("type").?.string);
    try testing.expectEqualStrings("assistant", last.object.get("role").?.string);
    try testing.expectEqualStrings("done", last.object.get("content").?.array.items[0].object.get("text").?.string);
    // second-to-last is reasoning with "reasoning after tool"
    const second_last = input.items[input.items.len - 2];
    try testing.expectEqualStrings("reasoning", second_last.object.get("type").?.string);
    try testing.expectEqualStrings("reasoning after tool", second_last.object.get("summary").?.array.items[0].object.get("text").?.string);
    // assistant content must not contain reasoning text
    try testing.expect(!std.mem.eql(u8, last.object.get("content").?.array.items[0].object.get("text").?.string, "reasoning after tool"));
}

// ---------------------------------------------------------------------------
// Task 8: End-to-end — mock SSE stream through StreamingAggregator
// ---------------------------------------------------------------------------

test "StreamingAggregator: end-to-end reasoning delta + output delta + terminal completed with reasoning output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = makeResponsesAgent(.{});
    defer a.deinit();

    var agg = agent.StreamingAggregator.init(arena.allocator());
    defer agg.deinit();

    // Simulate reasoning delta
    {
        const data = "{\"type\":\"response.reasoning_text.delta\",\"delta\":\"thinking step 1 \"}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }
    {
        const data = "{\"type\":\"response.reasoning_text.delta\",\"delta\":\"thinking step 2\"}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }
    // Simulate output delta
    {
        const data = "{\"type\":\"response.output_text.delta\",\"delta\":\"final answer here\"}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }
    // Simulate terminal completed with reasoning output (id + encrypted_content + summary)
    {
        const data =
            "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_e2e_123\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"thinking step 1 thinking step 2\"}],\"encrypted_content\":\"ENC_E2E_DATA\"},{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"final answer here\"}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try testing.expectEqualStrings("rs_e2e_123", chunk.?.reasoning_id.?);
        try testing.expectEqualStrings("ENC_E2E_DATA", chunk.?.reasoning_encrypted_content.?);
        try agg.process_chunk(chunk.?);
    }

    var res = try agg.finalize();
    defer res.deinit();

    // Delta reasoning wins over summary fallback
    try testing.expectEqualStrings("thinking step 1 thinking step 2", res.reasoning_content.?);
    try testing.expectEqualStrings("rs_e2e_123", res.reasoning_id.?);
    try testing.expectEqualStrings("ENC_E2E_DATA", res.reasoning_encrypted_content.?);
    try testing.expectEqualStrings("final answer here", res.content.?);
    try testing.expectEqual(@as(?agent.FinishReason, .stop), res.finish_reason);
}

test "StreamingAggregator: end-to-end terminal summary fallback when no delta reasoning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = makeResponsesAgent(.{});
    defer a.deinit();

    var agg = agent.StreamingAggregator.init(arena.allocator());
    defer agg.deinit();

    // Only output delta, no reasoning delta
    {
        const data = "{\"type\":\"response.output_text.delta\",\"delta\":\"answer only\"}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }
    // Terminal with reasoning summary but no prior delta
    {
        const data =
            "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_fallback_e2e\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"fallback thinking\"}],\"encrypted_content\":\"ENC_FB_E2E\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }

    var res = try agg.finalize();
    defer res.deinit();

    try testing.expectEqualStrings("fallback thinking", res.reasoning_content.?);
    try testing.expectEqualStrings("rs_fallback_e2e", res.reasoning_id.?);
    try testing.expectEqualStrings("ENC_FB_E2E", res.reasoning_encrypted_content.?);
    try testing.expectEqualStrings("answer only", res.content.?);
}

test "StreamingAggregator: end-to-end DB round-trip simulation via builder replay" {
    // Simulate: aggregator finalizes -> CallResponse -> AgentMessage -> builder replay
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = makeResponsesAgent(.{});
    defer a.deinit();

    var agg = agent.StreamingAggregator.init(arena.allocator());
    defer agg.deinit();

    {
        const data = "{\"type\":\"response.reasoning_text.delta\",\"delta\":\"db thinking\"}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }
    {
        const data = "{\"type\":\"response.output_text.delta\",\"delta\":\"db answer\"}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }
    {
        const data =
            "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_db_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"db thinking\"}],\"encrypted_content\":\"ENC_DB_1\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }

    var res = try agg.finalize();
    defer res.deinit();

    // Simulate DB round-trip: CallResponse -> AgentMessage (as get_llm_histories would)
    const msg = agent.AgentMessage{
        .role = .assistant,
        .content = res.content,
        .reasoning_content = res.reasoning_content,
        .reasoning_id = res.reasoning_id,
        .reasoning_encrypted_content = res.reasoning_encrypted_content,
        .tool_calls = null,
        .tool_call_id = null,
        .content_parts = null,
    };

    // Replay via builder: [user, assistant+reasoning] -> input[] with reasoning separate
    const messages = [_]agent.AgentMessage{
        userMsg("original question"),
        msg,
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 3), input.items.len);
    try testing.expectEqualStrings("reasoning", input.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("rs_db_1", input.items[1].object.get("id").?.string);
    try testing.expectEqualStrings("ENC_DB_1", input.items[1].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings("db thinking", input.items[1].object.get("summary").?.array.items[0].object.get("text").?.string);
    try testing.expectEqualStrings("message", input.items[2].object.get("type").?.string);
    try testing.expectEqualStrings("db answer", input.items[2].object.get("content").?.array.items[0].object.get("text").?.string);
    // reasoning must not leak into assistant output_text
    try testing.expect(!std.mem.eql(u8, input.items[2].object.get("content").?.array.items[0].object.get("text").?.string, "db thinking"));
}

test "buildJsonResponsesRequest: regression task_1788204837101_1 — reasoning_id+encrypted persisted even when reasoning_content is NULL" {
    // Real DB row from task_1788204837101_1 (2026-09-01 03:17:31):
    // assistant: content="Reasoning ID saved but content empty — tracing the summary extraction."
    //   tool_calls=[bash call_01a05af8ce...], reasoning_content=NULL,
    //   reasoning_id="rs_6a9643abdb33701b240b4ff4:rs_01a05af855327e6083af347abb5c682e",
    //   reasoning_encrypted_content="Q-PaDgH1f..." (87k, truncated in test)
    // tool: role=tool, call_id=call_01a05..., output="<tool>...bash output...</tool>"
    // Builder must emit a separate reasoning item even when reasoning_content is NULL
    // so that store:false replay can reconstruct the reasoning block verbatim.
    var a = makeResponsesAgent(.{});
    defer a.deinit();

    const tc_id = try testing.allocator.dupe(u8, "call_01a05af8ce457620beb3a5990637e153");
    defer testing.allocator.free(tc_id);
    const tc_name = try testing.allocator.dupe(u8, "bash");
    defer testing.allocator.free(tc_name);
    const tc_args = try testing.allocator.dupe(u8, "{\"command\":\"timeout 10 git checkout main 2>&1 | tail -n 5\",\"cwd\":\"/home/ginwa/ginwaaitoolbox\"}");
    defer testing.allocator.free(tc_args);
    const tc_array = try testing.allocator.alloc(agent.ToolCall, 1);
    defer testing.allocator.free(tc_array);
    tc_array[0] = .{ .id = tc_id, .function = .{ .name = tc_name, .arguments = tc_args } };

    const enc = try testing.allocator.dupe(u8, "Q-PaDgH1f_g4UMio3N6QC9OP42jJO2-WMTCEw6alywPh84L9_64jRusfZspFIeQI7UiYTDzLT6yAPOOfM_e-dMhNZtGD0rjNmMB8DnDBCRxws-8fYmo0BJf8oKM4ze5");
    defer testing.allocator.free(enc);
    const rid = try testing.allocator.dupe(u8, "rs_6a9643abdb33701b240b4ff4:rs_01a05af855327e6083af347abb5c682e");
    defer testing.allocator.free(rid);

    const messages = [_]agent.AgentMessage{
        userMsg("trace the summary"),
        .{
            .role = .assistant,
            .content = "Reasoning ID saved but content empty \u{2014} tracing the summary extraction.",
            .reasoning_content = null,
            .reasoning_id = rid,
            .reasoning_encrypted_content = enc,
            .tool_calls = tc_array,
            .tool_call_id = null,
            .content_parts = null,
        },
        .{
            .role = .tool,
            .content = "<tool><name>bash</name><parameters><command>timeout 10 git checkout main</command></parameters><success>true</success><data>Already on 'main'</data></tool>",
            .tool_call_id = "call_01a05af8ce457620beb3a5990637e153",
            .tool_calls = null,
            .content_parts = null,
            .reasoning_content = null,
        },
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    // Expected: [user, reasoning(with id+enc, no summary), assistant message, function_call, function_call_output]
    try testing.expectEqual(@as(usize, 5), input.items.len);

    // input[0] = user
    try testing.expectEqualStrings("message", input.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("user", input.items[0].object.get("role").?.string);

    // input[1] = reasoning — must exist even though reasoning_content was NULL
    const reasoning = input.items[1];
    try testing.expectEqualStrings("reasoning", reasoning.object.get("type").?.string);
    try testing.expectEqualStrings("rs_6a9643abdb33701b240b4ff4:rs_01a05af855327e6083af347abb5c682e", reasoning.object.get("id").?.string);
    try testing.expectEqualStrings("Q-PaDgH1f_g4UMio3N6QC9OP42jJO2-WMTCEw6alywPh84L9_64jRusfZspFIeQI7UiYTDzLT6yAPOOfM_e-dMhNZtGD0rjNmMB8DnDBCRxws-8fYmo0BJf8oKM4ze5", reasoning.object.get("encrypted_content").?.string);
    // summary must be present as empty array when reasoning_content is NULL —
    // the upstream schema requires the field (omitting it → `missing required field summary`)
    try testing.expect(reasoning.object.get("summary") != null);
    try testing.expectEqual(@as(usize, 0), reasoning.object.get("summary").?.array.items.len);

    // input[2] = assistant message with original content, must NOT contain reasoning
    const assistant = input.items[2];
    try testing.expectEqualStrings("message", assistant.object.get("type").?.string);
    try testing.expectEqualStrings("assistant", assistant.object.get("role").?.string);
    try testing.expectEqualStrings("Reasoning ID saved but content empty \u{2014} tracing the summary extraction.", assistant.object.get("content").?.array.items[0].object.get("text").?.string);

    // input[3] = function_call
    try testing.expectEqualStrings("function_call", input.items[3].object.get("type").?.string);
    try testing.expectEqualStrings("call_01a05af8ce457620beb3a5990637e153", input.items[3].object.get("call_id").?.string);

    // input[4] = function_call_output
    try testing.expectEqualStrings("function_call_output", input.items[4].object.get("type").?.string);
    try testing.expectEqualStrings("call_01a05af8ce457620beb3a5990637e153", input.items[4].object.get("call_id").?.string);
}

test "buildJsonResponsesRequest: reasoning with id but no content emits empty summary array" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        assistantMsgFull(null, null, "rs_only_id", "ENC_ONLY"),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);
    const input = body.parsed.value.object.get("input").?.array;
    // user + reasoning (id+enc, empty summary array, no message) — provider requires summary field
    try testing.expectEqual(@as(usize, 2), input.items.len);
    const reasoning = input.items[1];
    try testing.expectEqualStrings("reasoning", reasoning.object.get("type").?.string);
    try testing.expectEqualStrings("rs_only_id", reasoning.object.get("id").?.string);
    try testing.expectEqualStrings("ENC_ONLY", reasoning.object.get("encrypted_content").?.string);
    try testing.expect(reasoning.object.get("summary") != null);
    try testing.expectEqual(@as(usize, 0), reasoning.object.get("summary").?.array.items.len);
    // raw must contain empty summary array (field present)
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"summary\":[]") != null);
}

test "parse_responses_stream_chunk: response.reasoning_summary_text.done captures reasoning_content" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.reasoning_summary_text.done\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"text\":\"final summary via done\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("final summary via done", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.reasoning_summary_part.added captures reasoning_content" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.reasoning_summary_part.added\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"part added text\"}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("part added text", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.output_item.done reasoning captures id/enc/summary" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_done_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"done summary\"}],\"encrypted_content\":\"ENC_DONE\"}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("done summary", chunk.?.reasoning_content.?);
    try testing.expectEqualStrings("rs_done_1", chunk.?.reasoning_id.?);
    try testing.expectEqualStrings("ENC_DONE", chunk.?.reasoning_encrypted_content.?);
}

test "parse_responses_stream_chunk: response.output_item.done reasoning without summary still captures id/enc" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_done_2\",\"summary\":[],\"encrypted_content\":\"ENC2\"}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_done_2", chunk.?.reasoning_id.?);
    try testing.expectEqualStrings("ENC2", chunk.?.reasoning_encrypted_content.?);
    try testing.expect(chunk.?.reasoning_content == null);
}

// ---------------------------------------------------------------------------
// Spec cases from OpenAI JSON response — output[] handling (user-provided)
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: case 1 normal answer — no reasoning item" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"id\":\"msg_123\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"The answer is 4.\",\"annotations\":[]}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.reasoning_id == null);
    try testing.expect(chunk.?.reasoning_content == null);
    try testing.expectEqual(@as(?agent.FinishReason, .stop), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: case 2 reasoning with empty summary" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_123\",\"summary\":[]},{\"type\":\"message\",\"id\":\"msg_123\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"The answer is 4.\",\"annotations\":[]}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_123", chunk.?.reasoning_id.?);
    try testing.expect(chunk.?.reasoning_content == null);
    try testing.expectEqual(@as(?agent.FinishReason, .stop), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: case 3 reasoning with summary + answer" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_123\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"The calculation requires adding 2 and 2.\"}]},{\"type\":\"message\",\"id\":\"msg_123\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"2 + 2 = 4.\",\"annotations\":[]}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_123", chunk.?.reasoning_id.?);
    try testing.expectEqualStrings("The calculation requires adding 2 and 2.", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: case 4 multiple reasoning items — iterates output[], does not assume [0]/[1]" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_001\",\"summary\":[]},{\"type\":\"reasoning\",\"id\":\"rs_002\",\"summary\":[]},{\"type\":\"message\",\"id\":\"msg_001\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"The answer is 42.\"}]}]}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    // parser keeps first id (current single-row model) but must not misinterpret indices
    try testing.expectEqualStrings("rs_001", chunk.?.reasoning_id.?);
    try testing.expect(chunk.?.reasoning_content == null);
}

test "parse_responses_stream_chunk: case 5 tool call" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"id\":\"fc_123\",\"call_id\":\"call_123\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Jakarta\\\"}\"}]}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?agent.FinishReason, .tool_calls), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: case 6 reasoning + tool_call and reasoning + answer are two separate responses" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data1 = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_001\",\"summary\":[]},{\"type\":\"function_call\",\"id\":\"fc_001\",\"call_id\":\"call_001\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Jakarta\\\"}\"}]}}";
    const c1 = a.parse_stream_chunk(data1, arena.allocator());
    try testing.expect(c1 != null);
    try testing.expectEqualStrings("rs_001", c1.?.reasoning_id.?);
    try testing.expectEqual(@as(?agent.FinishReason, .tool_calls), c1.?.finish_reason);
    const data2 = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_002\",\"summary\":[]},{\"type\":\"message\",\"id\":\"msg_001\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Jakarta is currently 30°C.\"}]}]}}";
    const c2 = a.parse_stream_chunk(data2, arena.allocator());
    try testing.expect(c2 != null);
    try testing.expectEqualStrings("rs_002", c2.?.reasoning_id.?);
    try testing.expectEqual(@as(?agent.FinishReason, .stop), c2.?.finish_reason);
}

test "parse_responses_stream_chunk: case 7 multiple content parts in one message — don't assume content[0]" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Here is the result:\"},{\"type\":\"output_text\",\"text\":\"2 + 2 = 4.\"}]}]}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.reasoning_id == null);
    try testing.expectEqual(@as(?agent.FinishReason, .stop), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: case 8 message containing annotations" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"According to the source, the answer is 42.\",\"annotations\":[{\"type\":\"url_citation\",\"url\":\"https://example.com\",\"title\":\"Example\"}]}]}]}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.reasoning_id == null);
    try testing.expectEqual(@as(?agent.FinishReason, .stop), chunk.?.finish_reason);
}

test "buildJsonResponsesRequest: case 2 reasoning empty summary replays as reasoning+message" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("q"),
        assistantMsgFull("The answer is 4.", null, "rs_123", null),
    };
    // reasoning_content null but id present -> should still emit reasoning with empty summary
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);
    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 3), input.items.len);
    try testing.expectEqualStrings("message", input.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("reasoning", input.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("rs_123", input.items[1].object.get("id").?.string);
    try testing.expectEqual(@as(usize, 0), input.items[1].object.get("summary").?.array.items.len);
    try testing.expectEqualStrings("message", input.items[2].object.get("type").?.string);
}

test "buildJsonResponsesRequest: iterates output — not output[0] reasoning assumption" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    // Simulate history with two reasoning turns collapsed into one row — builder emits one reasoning per row
    const messages = [_]agent.AgentMessage{
        userMsg("q"),
        assistantMsgFull("a", "summary text", "rs_123", "ENC"),
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);
    const input = body.parsed.value.object.get("input").?.array;
    // Must handle reasoning at any index, not fixed positions
    var found_reasoning = false;
    var found_message = false;
    for (input.items) |it| {
        const t = it.object.get("type").?.string;
        if (std.mem.eql(u8, t, "reasoning")) found_reasoning = true;
        if (std.mem.eql(u8, t, "message")) {
            if (it.object.get("role")) |r| {
                if (std.mem.eql(u8, r.string, "assistant")) found_message = true;
            }
        }
    }
    try testing.expect(found_reasoning);
    try testing.expect(found_message);
}

// ---------------------------------------------------------------------------
// Builder: function_call_output sanitization (input[N].output[M] rejection)
// ---------------------------------------------------------------------------
// Regression for: `input[20].output[0] did not match any supported type`
// (muse-spark via Console Go, url_style="openai-response"). A `bash` tool
// output containing a `cat` of an ELF binary embedded invalid UTF-8 bytes
// into `function_call_output.output`; std.json emits those bytes raw, so the
// request body was not valid UTF-8 JSON and the gateway rejected the item.

test "buildJsonResponsesRequest: tool output with invalid UTF-8 is sanitized" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    // ELF magic + invalid bytes, mimicking `cat` of a binary in tool stdout.
    const raw_output = "\x7fELF\x02\x01\x01\x00\xFF\xFEbinary\x80\x81done";
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        .{ .role = .tool, .content = raw_output, .tool_call_id = "call_elf", .tool_calls = null, .content_parts = null, .reasoning_content = null },
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    var found = false;
    for (input.items) |it| {
        if (!std.mem.eql(u8, it.object.get("type").?.string, "function_call_output")) continue;
        found = true;
        const out = it.object.get("output").?.string;
        // Raw invalid bytes must be gone; U+FFFD (EF BF BD) marks each one.
        try testing.expect(std.mem.indexOf(u8, out, "\xFF") == null);
        try testing.expect(std.mem.indexOf(u8, out, "\x80") == null);
        try testing.expect(std.mem.indexOf(u8, out, "\xEF\xBF\xBD") != null);
        // Body itself must be valid UTF-8 so the gateway can parse it.
        try testing.expect(std.unicode.utf8ValidateSlice(body.raw));
    }
    try testing.expect(found);
}

test "buildJsonResponsesRequest: tool without call_id is skipped, not emitted empty" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        .{ .role = .tool, .content = "orphan output", .tool_call_id = null, .tool_calls = null, .content_parts = null, .reasoning_content = null },
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    for (input.items) |it| {
        if (!std.mem.eql(u8, it.object.get("type").?.string, "function_call_output")) continue;
        const cid = it.object.get("call_id").?.string;
        // An empty call_id can never pair with a function_call — must not be sent.
        try testing.expect(cid.len > 0);
    }
}

test "buildJsonResponsesRequest: oversize tool output is truncated with marker" {
    var a = makeResponsesAgent(.{});
    defer a.deinit();
    const big = try testing.allocator.alloc(u8, 25_000);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const messages = [_]agent.AgentMessage{
        userMsg("hi"),
        .{ .role = .tool, .content = big, .tool_call_id = "call_big", .tool_calls = null, .content_parts = null, .reasoning_content = null },
    };
    var body = try buildAndParse(&a, &messages, &.{}, null, null, true);
    defer freeBody(body);

    const input = body.parsed.value.object.get("input").?.array;
    var found = false;
    for (input.items) |it| {
        if (!std.mem.eql(u8, it.object.get("type").?.string, "function_call_output")) continue;
        found = true;
        const out = it.object.get("output").?.string;
        try testing.expect(out.len < big.len);
        try testing.expect(std.mem.indexOf(u8, out, "[truncated") != null);
    }
    try testing.expect(found);
}
