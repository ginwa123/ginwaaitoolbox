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