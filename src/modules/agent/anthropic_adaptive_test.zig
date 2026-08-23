// Tests for the new Anthropic `thinking_budget_tokens` override +
// `type: "adaptive"` mode in `buildJsonAnthropicRequest`. Plan
// 2026-08-23-model-thinking.
//
// The pre-existing tests at `anthropic_request_test.zig` cover the
// default 50%-of-max_tokens heuristic; this file covers the NEW
// paths:
//   1. Explicit budget override (`Agent.thinkingBudgetTokens` set) →
//      emitted verbatim (still clamped to >=1024 and <max_tokens).
//   2. Explicit budget override below the 1024 floor → clamped to 1024.
//   3. Explicit budget override at the ceiling → clamped to max_tokens - 1.
//   4. No override + `thinkingAdaptive` = true → `type: "adaptive"`,
//      no `budget_tokens` field.
//   5. No override + `thinkingAdaptive` = false → falls back to the
//      50%-of-max heuristic (existing behavior, NOT covered here).
//   6. `thinkingEnabled` = false (regardless of override) → entire
//      `thinking` field omitted (existing behavior).

const std = @import("std");
const testing = std.testing;
const agent = @import("Agent.zig");
const Agent = agent.Agent;

const MakeOpts = struct {
    thinkingEnabled: bool = true,
    thinkingBudgetTokens: ?u32 = null,
    thinkingAdaptive: bool = false,
    maxTokens: usize = 16384,
};

fn makeAgent(opts: MakeOpts) Agent {
    var a = agent.Agent.init(testing.allocator, std.testing.io);
    a.apiKey = "test-key";
    a.model = "claude-sonnet-4-5";
    a.baseUrl = "https://api.minimax.io/anthropic";
    a.UrlStyle = "anthropic";
    a.thinkingEnabled = opts.thinkingEnabled;
    a.thinkingBudgetTokens = opts.thinkingBudgetTokens;
    a.thinkingAdaptive = opts.thinkingAdaptive;
    a.maxTokens = opts.maxTokens;
    a.temperature = 1.0;
    return a;
}

fn messagesList() []const agent.AgentMessage {
    return &.{
        .{
            .role = .user,
            .content = "hi",
        },
    };
}

fn emptyTools() []const agent.AgentTool {
    return &.{};
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens honored as exact budget" {
    // 16384 / 2 = 8192 (the heuristic). User wants 2048.
    // With override, the request body MUST carry budget_tokens=2048
    // and MUST emit type:enabled (not adaptive).
    var a = makeAgent(.{ .thinkingBudgetTokens = 2048 });
    defer a.deinit();

    const params = agent.AgentCall{
        .tools = emptyTools(),
        .messages = messagesList(),
        .max_tokens = 16384,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":2048") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"adaptive\"") == null);
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens below floor clamps to 1024" {
    // max_tokens=8192, override=512 (below the 1024 floor).
    // Anthropic requires budget_tokens >= 1024, so we MUST clamp.
    var a = makeAgent(.{ .thinkingBudgetTokens = 512, .maxTokens = 8192 });
    defer a.deinit();

    const params = agent.AgentCall{
        .tools = emptyTools(),
        .messages = messagesList(),
        .max_tokens = 8192,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":1024") != null);
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens above ceiling clamps to max_tokens - 1" {
    // max_tokens=2048, override=4096 (way above max_tokens).
    // Anthropic requires budget_tokens < max_tokens strictly, so
    // we MUST clamp to 2047.
    var a = makeAgent(.{ .thinkingBudgetTokens = 4096, .maxTokens = 2048 });
    defer a.deinit();

    const params = agent.AgentCall{
        .tools = emptyTools(),
        .messages = messagesList(),
        .max_tokens = 2048,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":2047") != null);
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens=null + thinkingAdaptive=true emits type:adaptive" {
    // User picked "auto" in the UI → workflow sets
    // thinkingAdaptive=true and leaves thinkingBudgetTokens=null.
    // The request body MUST emit type:adaptive with NO budget_tokens
    // field (Anthropic picks its own budget).
    var a = makeAgent(.{ .thinkingBudgetTokens = null, .thinkingAdaptive = true });
    defer a.deinit();

    const params = agent.AgentCall{
        .tools = emptyTools(),
        .messages = messagesList(),
        .max_tokens = 16384,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"adaptive\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "budget_tokens") == null);
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens=null + thinkingAdaptive=false falls back to 50% heuristic" {
    // User picked "on" in the UI → workflow sets thinkingAdaptive=false.
    // The request body MUST emit type:enabled with budget_tokens =
    // half of max_tokens (the existing 50%-of-max heuristic).
    var a = makeAgent(.{ .thinkingBudgetTokens = null, .thinkingAdaptive = false, .maxTokens = 8192 });
    defer a.deinit();

    const params = agent.AgentCall{
        .tools = emptyTools(),
        .messages = messagesList(),
        .max_tokens = 8192,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    // 8192 / 2 = 4096 — the heuristic value.
    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":4096") != null);
}

test "buildJsonAnthropicRequest: thinkingEnabled=false omits thinking entirely (override is ignored)" {
    // thinkingEnabled is the master gate — even with
    // thinkingBudgetTokens set, the entire `thinking` block is
    // omitted from the request body.
    var a = makeAgent(.{ .thinkingEnabled = false, .thinkingBudgetTokens = 4096 });
    defer a.deinit();

    const params = agent.AgentCall{
        .tools = emptyTools(),
        .messages = messagesList(),
        .max_tokens = 16384,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"thinking\"") == null);
    try testing.expect(std.mem.indexOf(u8, body, "budget_tokens") == null);
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens wins over thinkingAdaptive (precedence)" {
    // When both are set (which shouldn't happen in production but
    // could via a misconfigured profile), the explicit budget
    // wins. The adaptive flag is only consulted when budget is null.
    var a = makeAgent(.{ .thinkingBudgetTokens = 3000, .thinkingAdaptive = true });
    defer a.deinit();

    const params = agent.AgentCall{
        .tools = emptyTools(),
        .messages = messagesList(),
        .max_tokens = 16384,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":3000") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"adaptive\"") == null);
}