const std = @import("std");
const testing = std.testing;
const agent = @import("Agent.zig");

const TEST_USER_ID = "550e8400-e29b-41d4-a716-446655440000";

fn makeAgent(user_id: []const u8) agent.Agent {
    var a = agent.Agent.init(testing.allocator, testing.io) catch unreachable;
    a.model = "test-model";
    a.userIdentifier = user_id;
    return a;
}

test "buildJsonOpenAIRequest includes 'user' field when userIdentifier is set" {
    var a = makeAgent(TEST_USER_ID);
    defer a.deinit();

    const params = agent.AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"user\":\"" ++ TEST_USER_ID ++ "\"") != null);
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
    var a = makeAgent(TEST_USER_ID);
    a.UrlStyle = "anthropic";
    defer a.deinit();

    const params = agent.AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"metadata\":{\"user_id\":\"" ++ TEST_USER_ID ++ "\"}") != null);
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