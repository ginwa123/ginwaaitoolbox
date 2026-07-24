const std = @import("std");
const testing = std.testing;
const agent = @import("Agent.zig");

/// Hardcoded identifier — the value that every Anthropic + OpenAI call
/// from this fork of nalar sends. See `Agent.userIdentifier` default.
const HARDCODED_USER_ID = "AnakMagang";

fn makeAgent(user_id: []const u8) agent.Agent {
    var a = agent.Agent.init(testing.allocator, testing.io);
    a.model = "test-model";
    a.userIdentifier = user_id;
    return a;
}

test "Agent default userIdentifier is hardcoded to 'AnakMagang'" {
    var a = agent.Agent.init(testing.allocator, testing.io);
    defer a.deinit();
    try testing.expectEqualStrings("AnakMagang", a.userIdentifier);
}

test "buildJsonOpenAIRequest includes 'user' field when userIdentifier is set" {
    var a = makeAgent(HARDCODED_USER_ID);
    defer a.deinit();

    const params = agent.AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"user\":\"" ++ HARDCODED_USER_ID ++ "\"") != null);
}

test "buildJsonOpenAIRequest omits 'user' field when userIdentifier is empty" {
    var a = makeAgent("");
    defer a.deinit();

    const params = agent.AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"user\":") == null);
}

test "buildJsonAnthropicRequest includes metadata.user_id when userIdentifier is set" {
    var a = makeAgent(HARDCODED_USER_ID);
    a.UrlStyle = "anthropic";
    defer a.deinit();

    const params = agent.AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"metadata\":{\"user_id\":\"" ++ HARDCODED_USER_ID ++ "\"}") != null);
}

test "buildJsonAnthropicRequest omits metadata entirely when userIdentifier is empty" {
    var a = makeAgent("");
    a.UrlStyle = "anthropic";
    defer a.deinit();

    const params = agent.AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"metadata\"") == null);
}