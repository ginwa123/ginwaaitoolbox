// Tests for the new OpenAI `reasoning_effort` field on the request
// body built by `buildJsonOpenAIRequest`. Plan
// 2026-08-23-model-thinking.

const std = @import("std");
const testing = std.testing;
const agent = @import("Agent.zig");
const Agent = agent.Agent;

const MakeOpts = struct {
    reasoningEffort: ?[]const u8 = null,
    thinkingEnabled: bool = true,
};

fn makeAgent(opts: MakeOpts) Agent {
    var a = agent.Agent.init(testing.allocator, std.testing.io);
    a.apiKey = "test-key";
    a.model = "o1-preview";
    a.baseUrl = "https://api.openai.com/v1";
    a.UrlStyle = "openai";
    a.thinkingEnabled = opts.thinkingEnabled;
    a.reasoningEffort = opts.reasoningEffort;
    a.maxTokens = 8192;
    return a;
}

fn emptyMessages() []const agent.AgentMessage {
    return &.{
        .{
            .role = .user,
            .content = "solve x^2 + 2x + 1 = 0",
        },
    };
}

fn emptyTools() []const agent.AgentTool {
    return &.{};
}

test "buildJsonOpenAIRequest: reasoningEffort set emits reasoning_effort field" {
    var a = makeAgent(.{ .reasoningEffort = "high" });

    const params = agent.AgentCall{ .tools = emptyTools(), .messages = emptyMessages() };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
}

test "buildJsonOpenAIRequest: reasoningEffort null omits reasoning_effort field" {
    var a = makeAgent(.{ .reasoningEffort = null });

    const params = agent.AgentCall{ .tools = emptyTools(), .messages = emptyMessages() };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "buildJsonOpenAIRequest: reasoningEffort empty string omits field" {
    // The frontend uses "" for "auto" / null. The Agent field is
    // ?[]const u8 so an empty slice is a valid-but-meaningless
    // value — we treat it the same as null (omit).
    var a = makeAgent(.{ .reasoningEffort = "" });

    const params = agent.AgentCall{ .tools = emptyTools(), .messages = emptyMessages() };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "buildJsonOpenAIRequest: reasoning_effort coexists with tools + temperature" {
    // o1 supports tool calls (function calling); the reasoning_effort
    // field must coexist with tools and not be silenced by them.
    var a = makeAgent(.{ .reasoningEffort = "medium" });

    const tool: agent.AgentTool = .{
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

    const params = agent.AgentCall{
        .messages = emptyMessages(),
        .tools = &.{tool},
        .temperature = 0.7,
    };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"medium\"") != null);
    // temperature is serialized as a JSON float — Zig emits e.g.
    // "0.699999988079071" for 0.7, so we only check the field name
    // exists, not the exact value. The jsonStringify uses std.json
    // default float formatting which preserves full f32 precision.
    try testing.expect(std.mem.indexOf(u8, body, "\"temperature\":") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"get_weather\"") != null);
}

test "buildJsonOpenAIRequest: each reasoning_effort value passes through verbatim" {
    // Parametric sweep over the 4 canonical values. Backend is a
    // dumb pipe — the server validates per-model compatibility.
    const values = [_][]const u8{ "low", "medium", "high", "auto" };
    for (values) |v| {
        var a = makeAgent(.{ .reasoningEffort = v });
        const params = agent.AgentCall{ .tools = emptyTools(), .messages = emptyMessages() };
        const body = try a.buildJsonOpenAIRequest(params, true);
        defer testing.allocator.free(body);

        var needle: [128]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&needle, "\"reasoning_effort\":\"{s}\"", .{v});
        try testing.expect(std.mem.indexOf(u8, body, formatted) != null);
    }
}

// Reasoning-echo backfill (task_1789091513563_0): DeepSeek-style
// providers in thinking mode reject replays where an assistant message
// lacks `reasoning_content`. Turns with no reasoning deltas persist
// NULL — the builder must emit "" instead of omitting the field.

fn assistantMsgNoReasoning(text: ?[]const u8) agent.AgentMessage {
    return .{ .role = .assistant, .content = text };
}

test "buildJsonOpenAIRequest: thinking on + assistant null reasoning emits empty reasoning_content" {
    var a = makeAgent(.{ .thinkingEnabled = true });
    const msgs = [_]agent.AgentMessage{
        .{ .role = .user, .content = "hello" },
        assistantMsgNoReasoning("final answer"),
    };
    const params = agent.AgentCall{ .tools = emptyTools(), .messages = &msgs };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"\"") != null);
}

test "buildJsonOpenAIRequest: thinking off + all-null history omits reasoning_content" {
    // Plain sessions keep their exact wire shape — no new field.
    var a = makeAgent(.{ .thinkingEnabled = false });
    const msgs = [_]agent.AgentMessage{
        .{ .role = .user, .content = "hello" },
        assistantMsgNoReasoning("final answer"),
    };
    const params = agent.AgentCall{ .tools = emptyTools(), .messages = &msgs };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "reasoning_content") == null);
}

test "buildJsonOpenAIRequest: thinking off but history has reasoning backfills null assistant" {
    // Mid-session thinking toggle-off: older turns carry reasoning, a
    // newer turn has none. The null one gets "" (echo validator sees
    // the field on every assistant message); the real one is verbatim.
    var a = makeAgent(.{ .thinkingEnabled = false });
    const msgs = [_]agent.AgentMessage{
        .{ .role = .assistant, .content = "first", .reasoning_content = "real-thinking" },
        assistantMsgNoReasoning(null),
    };
    const params = agent.AgentCall{ .tools = emptyTools(), .messages = &msgs };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"real-thinking\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"\"") != null);
}

test "buildJsonOpenAIRequest: backfill is assistant-only, user messages stay clean" {
    var a = makeAgent(.{ .thinkingEnabled = true });
    const params = agent.AgentCall{ .tools = emptyTools(), .messages = emptyMessages() };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "reasoning_content") == null);
}

test "buildJsonOpenAIRequest: assistant with reasoning keeps verbatim value" {
    var a = makeAgent(.{ .thinkingEnabled = true });
    const msgs = [_]agent.AgentMessage{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .content = "final answer", .reasoning_content = "model's reasoning..." },
        .{ .role = .user, .content = "follow up" },
    };
    const params = agent.AgentCall{ .tools = emptyTools(), .messages = &msgs };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"model's reasoning...\"") != null);
}