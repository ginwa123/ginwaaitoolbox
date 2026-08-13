// Regression tests for the Anthropic request-builder bugs documented in
// `docs/superpowers/plans/<anthropic-request-fixes>.md`.
//
// These are unit tests of `Agent.buildJsonAnthropicRequest` — we exercise
// the request body that hits the wire, but without doing any actual
// network I/O. Companion to the SSE-parser tests in
// `parse_anthropic_sse_test.zig`.
//
// Why each test exists:
//   - System messages must move to a top-level `"system"` field
//     (Anthropic rejects `role: "system"` inside `messages` and 400s).
//   - `thinking: {type: "enabled"}` is missing the required
//     `budget_tokens` field — every call with thinkingEnabled=true 400s.
//   - `temperature` must be omitted (or exactly `1`) when
//     `thinking.type == "enabled"` — Anthropic 400s otherwise.
//   - The Anthropic serializer was emitting a bogus `stream_options`
//     block (copy-pasted from OpenAI). Anthropic has no such request
//     key — we already get usage on `message_start` / `message_delta`
//     SSE events unconditionally.

const std = @import("std");
const testing = std.testing;
const agent = @import("Agent.zig");

fn makeAgent(opts: struct {
    model: []const u8 = "claude-test",
    thinkingEnabled: bool = true,
    maxTokens: usize = 4096,
}) agent.Agent {
    var a = agent.Agent.init(testing.allocator, testing.io);
    a.model = opts.model;
    a.thinkingEnabled = opts.thinkingEnabled;
    a.maxTokens = opts.maxTokens;
    a.UrlStyle = "anthropic";
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

// Build and return the body. Caller frees with `freeAnthropicBody`.
// Don't bother parsing here — most assertions are simpler against the
// raw JSON text (substring match + length). One helper, `parseBody`,
// covers the cases that need parsed-shape inspection.
fn buildAnthropicBodyRaw(
    a: *agent.Agent,
    messages: []const agent.AgentMessage,
    temperature: ?f32,
    max_tokens: ?usize,
) ![]u8 {
    const params = agent.AgentCall{
        .tools = &.{},
        .messages = messages,
        .temperature = temperature,
        .max_tokens = max_tokens,
    };
    return try a.buildJsonAnthropicRequest(params, true);
}

const ParsedBody = struct {
    raw: []u8,
    parsed: std.json.Parsed(std.json.Value),
};

fn buildAndParse(
    a: *agent.Agent,
    messages: []const agent.AgentMessage,
    temperature: ?f32,
    max_tokens: ?usize,
) !ParsedBody {
    const raw = try buildAnthropicBodyRaw(a, messages, temperature, max_tokens);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    return .{ .raw = raw, .parsed = parsed };
}

fn freeBody(body: ParsedBody) void {
    testing.allocator.free(body.raw);
    body.parsed.deinit();
}

// ============================================================================
// Bug 1 — system messages go to top-level "system" field
// ============================================================================

test "buildJsonAnthropicRequest: system message moves to top-level 'system' field, not into messages" {
    var a = makeAgent(.{});
    defer a.deinit();

    const messages = [_]agent.AgentMessage{
        sysMsg("You are a helpful assistant."),
        userMsg("Hello."),
    };

    var body = try buildAndParse(&a, &messages, null, null);
    defer freeBody(body);

    // Top-level "system" string must match the system message content.
    try testing.expect(body.parsed.value.object.get("system") != null);
    const system_str = body.parsed.value.object.get("system").?;
    try testing.expect(system_str == .string);
    try testing.expectEqualStrings("You are a helpful assistant.", system_str.string);

    // No message inside `messages` should have role == "system" — the
    // only message remaining should be the user one.
    try testing.expect(body.parsed.value.object.get("messages") != null);
    const messages_arr = body.parsed.value.object.get("messages").?;
    try testing.expect(messages_arr == .array);
    try testing.expectEqual(@as(usize, 1), messages_arr.array.items.len);
    const only_msg = messages_arr.array.items[0];
    try testing.expect(only_msg.object.get("role") != null);
    try testing.expectEqualStrings("user", only_msg.object.get("role").?.string);
}

test "buildJsonAnthropicRequest: multiple system messages are joined with '\\n\\n' into top-level 'system'" {
    var a = makeAgent(.{});
    defer a.deinit();

    const messages = [_]agent.AgentMessage{
        sysMsg("First part."),
        sysMsg("Second part."),
        userMsg("Hi."),
    };

    var body = try buildAndParse(&a, &messages, null, null);
    defer freeBody(body);

    try testing.expect(body.parsed.value.object.get("system") != null);
    const system_str = body.parsed.value.object.get("system").?;
    try testing.expect(system_str == .string);
    try testing.expectEqualStrings("First part.\n\nSecond part.", system_str.string);

    const messages_arr = body.parsed.value.object.get("messages").?;
    try testing.expectEqual(@as(usize, 1), messages_arr.array.items.len);
}

test "buildJsonAnthropicRequest: no system message → top-level 'system' field absent" {
    var a = makeAgent(.{});
    defer a.deinit();

    const messages = [_]agent.AgentMessage{
        userMsg("Hello."),
    };

    var body = try buildAndParse(&a, &messages, null, null);
    defer freeBody(body);

    // Top-level "system" field must be omitted entirely (not null, not
    // empty string — Anthropic only has a system prompt when we send
    // one).
    try testing.expect(body.parsed.value.object.get("system") == null);
}

// ============================================================================
// Bug 2 — thinking.enabled must include budget_tokens
// ============================================================================

test "buildJsonAnthropicRequest: thinkingEnabled emits budget_tokens (>=1024 and <max_tokens)" {
    // Default Agent.maxTokens is 4096 → budget should be min(2048, 4095) = 2048.
    var a = makeAgent(.{ .maxTokens = 4096 });
    defer a.deinit();

    const messages = [_]agent.AgentMessage{userMsg("hi")};
    const raw = try buildAnthropicBodyRaw(&a, &messages, null, null);
    defer testing.allocator.free(raw);

    // Substring match on raw body — robust to JSON key order + whitespace.
    try testing.expect(std.mem.indexOf(u8, raw, "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":") != null);
    // Also check the value is exactly 2048 (50% of 4096 with the >=
    // 1024 floor satisfied and < max_tokens satisfied trivially).
    try testing.expect(std.mem.indexOf(u8, raw, "\"budget_tokens\":2048") != null);
}

test "buildJsonAnthropicRequest: budget_tokens is clamped to max_tokens-1 when max_tokens is small" {
    // maxTokens=1500 → budget floor of 1024 wins, must be < 1500 → budget=1024.
    var a = makeAgent(.{ .maxTokens = 1500 });
    defer a.deinit();

    const messages = [_]agent.AgentMessage{userMsg("hi")};
    const raw = try buildAnthropicBodyRaw(&a, &messages, null, null);
    defer testing.allocator.free(raw);

    try testing.expect(std.mem.indexOf(u8, raw, "\"budget_tokens\":1024") != null);
}

test "buildJsonAnthropicRequest: thinkingEnabled=false omits thinking field entirely" {
    var a = makeAgent(.{ .thinkingEnabled = false });
    defer a.deinit();

    const messages = [_]agent.AgentMessage{userMsg("hi")};
    const raw = try buildAnthropicBodyRaw(&a, &messages, null, null);
    defer testing.allocator.free(raw);

    try testing.expect(std.mem.indexOf(u8, raw, "\"thinking\"") == null);
}

// ============================================================================
// Bug 2 — small-max_tokens guard
// ============================================================================

test "buildJsonAnthropicRequest: thinkingEnabled=true with default max_tokens=1024 AUTO-BUMPS to 1025 (thinking fires, budget_tokens=1024 is valid)" {
    // When `params.max_tokens` is null and `self.maxTokens < 1025`,
    // the builder auto-bumps max_tokens to 1025 for this call so the
    // 1024 budget_tokens floor satisfies Anthropic's `< max_tokens`
    // constraint. `self.maxTokens` is NOT mutated.
    var a = makeAgent(.{ .maxTokens = 1024 });
    defer a.deinit();

    const messages = [_]agent.AgentMessage{userMsg("hi")};
    const raw = try buildAnthropicBodyRaw(&a, &messages, null, null);
    defer testing.allocator.free(raw);

    // thinking IS enabled...
    try testing.expect(std.mem.indexOf(u8, raw, "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":") != null);
    // budget_tokens = 1024 (the floor) since (1025/2) = 512 < 1024...
    try testing.expect(std.mem.indexOf(u8, raw, "\"budget_tokens\":1024") != null);
    // ...and max_tokens was bumped to 1025 (one above the 1024 floor
    // so budget_tokens=1024 satisfies `< max_tokens`).
    try testing.expect(std.mem.indexOf(u8, raw, "\"max_tokens\":1025") != null);
}

test "buildJsonAnthropicRequest: thinkingEnabled=true with EXPLICIT max_tokens=1024 forces thinking off (respects caller constraint)" {
    // When the caller passes an explicit small max_tokens via
    // `AgentCall.max_tokens`, we don't bump it (would surprise the
    // caller); instead we force thinking off and warn.
    var a = makeAgent(.{ .maxTokens = 4096 });
    defer a.deinit();

    const messages = [_]agent.AgentMessage{userMsg("hi")};
    // Caller explicitly pins max_tokens=1024 via AgentCall.
    const raw = try a.buildJsonAnthropicRequest(
        .{ .tools = &.{}, .messages = &messages, .temperature = null, .max_tokens = 1024 },
        true,
    );
    defer testing.allocator.free(raw);

    // thinking IS forced off...
    try testing.expect(std.mem.indexOf(u8, raw, "\"thinking\"") == null);
    // ...and max_tokens = 1024 (the caller's value, NOT bumped).
    try testing.expect(std.mem.indexOf(u8, raw, "\"max_tokens\":1024") != null);
}

test "buildJsonAnthropicRequest: thinkingEnabled=true with EXPLICIT max_tokens=4096 keeps max_tokens=4096 (no bump needed)" {
    // Sanity: explicit max_tokens that ALREADY satisfies the floor
    // doesn't get bumped. (The bump only fires for max_tokens < 1025.)
    var a = makeAgent(.{ .maxTokens = 4096 });
    defer a.deinit();

    const messages = [_]agent.AgentMessage{userMsg("hi")};
    const raw = try a.buildJsonAnthropicRequest(
        .{ .tools = &.{}, .messages = &messages, .temperature = null, .max_tokens = 4096 },
        true,
    );
    defer testing.allocator.free(raw);

    // No bump — max_tokens stays at 4096.
    try testing.expect(std.mem.indexOf(u8, raw, "\"max_tokens\":4096") != null);
    // thinking is on with budget_tokens = 4096/2 = 2048.
    try testing.expect(std.mem.indexOf(u8, raw, "\"budget_tokens\":2048") != null);
}

// ============================================================================
// Bug 3 — temperature must not be sent alongside thinking.enabled
// ============================================================================

test "buildJsonAnthropicRequest: temperature is omitted when thinkingEnabled=true (even if caller set it)" {
    var a = makeAgent(.{ .thinkingEnabled = true });
    defer a.deinit();

    const messages = [_]agent.AgentMessage{userMsg("hi")};
    const raw = try buildAnthropicBodyRaw(&a, &messages, 0.7, null);
    defer testing.allocator.free(raw);

    // thinking is ON...
    try testing.expect(std.mem.indexOf(u8, raw, "\"thinking\":") != null);
    // ...and temperature is NOT sent.
    try testing.expect(std.mem.indexOf(u8, raw, "\"temperature\"") == null);
}

test "buildJsonAnthropicRequest: temperature is emitted when thinkingEnabled=false" {
    var a = makeAgent(.{ .thinkingEnabled = false });
    defer a.deinit();

    const messages = [_]agent.AgentMessage{userMsg("hi")};
    const raw = try buildAnthropicBodyRaw(&a, &messages, 0.7, null);
    defer testing.allocator.free(raw);

    try testing.expect(std.mem.indexOf(u8, raw, "\"thinking\"") == null);
    // `temperature` is emitted. Match the wire shape exactly:
    //   - `std.json.fmt` renders `f32` 0.7 as `0.699999988079071`
    //     (0.7 is not exactly representable in IEEE-754 binary32), so
    //     we accept either "0.699999988079071" or a literal "0.7".
    const temp_present = std.mem.indexOf(u8, raw, "\"temperature\":") != null;
    try testing.expect(temp_present);
    const temp_value_ok =
        std.mem.indexOf(u8, raw, "\"temperature\":0.699999988079071") != null or
        std.mem.indexOf(u8, raw, "\"temperature\":0.7") != null;
    try testing.expect(temp_value_ok);
}

// ============================================================================
// Bug 4 — Anthropic doesn't accept stream_options
// ============================================================================

test "buildJsonAnthropicRequest: stream=true emits 'stream':true and does NOT emit 'stream_options'" {
    var a = makeAgent(.{});
    defer a.deinit();

    const messages = [_]agent.AgentMessage{userMsg("hi")};
    // stream=true (third arg is bool `stream`).
    const raw = try a.buildJsonAnthropicRequest(
        .{ .tools = &.{}, .messages = &messages, .temperature = null, .max_tokens = null },
        true,
    );
    defer testing.allocator.free(raw);

    try testing.expect(std.mem.indexOf(u8, raw, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"stream_options\"") == null);
}

// ============================================================================
// Regression: OpenAI path is unaffected
// ============================================================================

test "regression: buildJsonOpenAIRequest keeps 'stream_options.include_usage' verbatim" {
    var a = makeAgent(.{});
    defer a.deinit();
    // Ensure anthropic is NOT selected.
    a.UrlStyle = "openai";

    const messages = [_]agent.AgentMessage{userMsg("hi")};
    const body = try a.buildJsonOpenAIRequest(
        .{ .tools = &.{}, .messages = &messages, .temperature = 0.5, .max_tokens = null },
        true,
    );
    defer testing.allocator.free(body);

    // OpenAI keeps stream_options.include_usage=true.
    try testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
}
