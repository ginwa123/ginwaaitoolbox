//! Tests that `maybeCompactMessagesNew` honors its comptime dependency injection
//! contract — a caller passes a `CompactDeps` struct whose fn pointers route
//! every non-std-lib function call through a stub. This makes the function
//! fully testable in isolation: no LLM HTTP, no SQLite DB writes, no threshold
//! logic — the test decides what each dep does.
//!
//! Pattern: define a top-level `MockState` recorder, three mock fns matching
//! the three deps (`shouldCompact`, `callCompactAgent`, `compact_messages_in_memory`),
//! bundle them into a `CompactDeps`, then call `maybeCompactMessagesNew`
//! with that bundle. Production call sites pass `workflow.defaultCompactDeps`.
//!
//! IMPORTANT — Zig 0.16 quirk: module-level vars are SHARED across tests in
//! the same file. Each test MUST call `resetMockState()` at its start to avoid
//! cross-test contamination when the test runner shuffles order.

const std = @import("std");
const testing = std.testing;

const workflow = @import("workflow.zig");
const agentic_loop_mod = @import("mod.zig");
const agent = @import("nalarcore").agent;
const sqlite = @import("nalarcore").sqlite;
const config_mod = @import("nalarcore").config;
const logger_mod = @import("nalarcore").loggermod;

// ─── Mock infrastructure ────────────────────────────────────────────────────

/// Records what each mock saw on its last invocation, plus what to return on
/// the next call. Lives at module scope so the comptime fns can write to it
/// (comptime fns cannot capture locals).
const MockState = struct {
    // ─── shouldCompact mock ────────────────────────────────────────────
    should_compact_calls: u32 = 0,
    last_ctx_force: bool = undefined,
    last_ctx_total_tokens: u32 = undefined,
    last_ctx_model: []const u8 = undefined,
    should_compact_result: bool = true, // default: "yes, compact"

    // ─── callCompactAgent mock ────────────────────────────────────────
    call_compact_agent_calls: u32 = 0,
    last_agent_model: []const u8 = "",
    last_agent_api_key: []const u8 = "",
    last_agent_base_url: []const u8 = "",
    last_agent_messages_len: usize = 0,
    next_compact_xml: ?[]const u8 = null, // null → mock returns null

    // ─── compactMessagesInMemory mock ──────────────────────────────────
    compact_messages_in_memory_calls: u32 = 0,
    last_compacted_xml: []const u8 = "",
    last_compact_session_id: []const u8 = "",
    last_compact_model: []const u8 = "",
    /// If `compact_returns_null` is true, the mock returns error.Skip to
    /// propagate as a test signal. (Mock returns the messages list unchanged
    /// on success — the test owns them.)
    compact_skip: bool = false,
};

var mock_state: MockState = .{};

fn resetMockState() void {
    mock_state = .{};
}

// ─── Three mock fns (one per CompactDeps field) ───────────────────────────

fn mockShouldCompact(ctx: workflow.ThresholdCtx) bool {
    mock_state.should_compact_calls += 1;
    mock_state.last_ctx_force = ctx.force;
    mock_state.last_ctx_total_tokens = ctx.total_tokens;
    mock_state.last_ctx_model = ctx.model;
    return mock_state.should_compact_result;
}

fn mockCallCompactAgent(obj: agentic_loop_mod.CallCompactAgentInput) ?[]const u8 {
    mock_state.call_compact_agent_calls += 1;
    mock_state.last_agent_model = obj.model;
    mock_state.last_agent_api_key = obj.api_key;
    mock_state.last_agent_base_url = obj.base_url;
    mock_state.last_agent_messages_len = obj.messages.items.len;
    return mock_state.next_compact_xml;
}

fn mockCompactMessagesInMemory(
    allocator: std.mem.Allocator,
    messages: std.ArrayList(agent.AgentMessage),
    compacted_xml: []const u8,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *logger_mod.Logger,
) anyerror!std.ArrayList(agent.AgentMessage) {
    _ = allocator;
    _ = cwd;
    _ = db;
    _ = io;
    _ = logger;
    mock_state.compact_messages_in_memory_calls += 1;
    mock_state.last_compacted_xml = compacted_xml;
    mock_state.last_compact_session_id = session_id;
    mock_state.last_compact_model = model;
    if (mock_state.compact_skip) return error.Skip;
    // Return the messages unchanged. The test owns them — `messages.*` was
    // passed in by value from `maybeCompactMessagesNew`, and we don't want
    // to double-free or invalidate the test's `messages.items`.
    return messages;
}

/// The mock bundle wired into a `CompactDeps`. Pass this as the first arg
/// to `maybeCompactMessagesNew` from any test in this file.
const mockCompactDeps: workflow.CompactDeps = .{
    .should_compact = mockShouldCompact,
    .call_compact_agent = mockCallCompactAgent,
    .compact_messages_in_memory = mockCompactMessagesInMemory,
};

// ─── Test fixtures ──────────────────────────────────────────────────────────

fn buildTestConfig(allocator: std.mem.Allocator) config_mod.LlmConfig {
    return .{
        .allocator = allocator,
        .api_key = "sk-test",
        .model = "test-model",
        .base_url = "https://test.example",
        .model_compaction_size_kb = 100,
        .mcpServers_parsed = null,
        .mcp_servers = config_mod.LlmConfig.McpServersMap.init(allocator),
        .profiles_models = config_mod.LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .url_style = "openai",
    };
}

/// Build a 6-message list like the production workflow. Returns ownership to
/// the caller — caller MUST `defer` cleanup of `messages.items` and `messages`.
fn buildMessages(allocator: std.mem.Allocator) !std.ArrayList(agent.AgentMessage) {
    var list: std.ArrayList(agent.AgentMessage) = .empty;
    try list.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, "sys") });
    try list.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u1") });
    try list.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "a1") });
    try list.append(allocator, .{ .role = .tool, .content = try allocator.dupe(u8, "t1"), .tool_call_id = try allocator.dupe(u8, "tc_1") });
    try list.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u2") });
    try list.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "a2") });
    return list;
}

fn freeMessages(allocator: std.mem.Allocator, messages: *std.ArrayList(agent.AgentMessage)) void {
    for (messages.items) |*m| m.deinit(allocator);
    var owned = messages.*;
    owned.deinit(allocator);
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test "shouldCompact dep is called with the right context (force, tokens, model)" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = false; // gate early-return path

    _ = try workflow.maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        123_456,
        "gpt-4o-mini",
        false,
        &messages,
        "sk-test",
        "https://test.example",
        "/tmp",
        "sess_mock",
        undefined, // db — not reached when shouldCompact=false
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectEqual(@as(u32, 1), mock_state.should_compact_calls);
    try testing.expectEqual(false, mock_state.last_ctx_force);
    try testing.expectEqual(@as(u32, 123_456), mock_state.last_ctx_total_tokens);
    try testing.expectEqualStrings("gpt-4o-mini", mock_state.last_ctx_model);
}

test "shouldCompact returning false short-circuits — no other deps called" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = false;

    const result = try workflow.maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        100,
        "test-model",
        false,
        &messages,
        "sk-test",
        "https://test.example",
        "/tmp",
        "sess_mock",
        undefined,
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectEqual(false, result);
    try testing.expectEqual(@as(u32, 1), mock_state.should_compact_calls);
    try testing.expectEqual(@as(u32, 0), mock_state.call_compact_agent_calls);
    try testing.expectEqual(@as(u32, 0), mock_state.compact_messages_in_memory_calls);
}

test "shouldCompact returning true routes through callCompactAgent" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = null; // callCompactAgent returns null → function returns false

    const result = try workflow.maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        100,
        "test-model",
        true, // force — shouldCompact mock just receives it; mock decides
        &messages,
        "sk-bespoke",
        "https://bespoke.example",
        "/tmp",
        "sess_mock",
        undefined, // db — not reached when callCompactAgent returns null
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectEqual(false, result);
    try testing.expectEqual(@as(u32, 1), mock_state.should_compact_calls);
    try testing.expectEqual(@as(u32, 1), mock_state.call_compact_agent_calls);
    // compact_messages_in_memory was NOT called (callCompactAgent returned null)
    try testing.expectEqual(@as(u32, 0), mock_state.compact_messages_in_memory_calls);
    // callCompactAgent received the right fields
    try testing.expectEqualStrings("test-model", mock_state.last_agent_model);
    try testing.expectEqualStrings("sk-bespoke", mock_state.last_agent_api_key);
    try testing.expectEqualStrings("https://bespoke.example", mock_state.last_agent_base_url);
    try testing.expectEqual(@as(usize, 6), mock_state.last_agent_messages_len);
}

test "callCompactAgent returning null short-circuits — compact_messages_in_memory not called" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = null;

    const result = try workflow.maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        100,
        "test-model",
        false,
        &messages,
        "sk-test",
        "https://test.example",
        "/tmp",
        "sess_mock",
        undefined,
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectEqual(false, result);
    try testing.expectEqual(@as(u32, 1), mock_state.call_compact_agent_calls);
    try testing.expectEqual(@as(u32, 0), mock_state.compact_messages_in_memory_calls);
}

test "full happy path: all three deps called, returns true" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: ship it\nNEXT ACTION: merge";

    const result = try workflow.maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "/tmp",
        "sess_bespoke",
        undefined, // db — mock doesn't touch it
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectEqual(true, result);
    try testing.expectEqual(@as(u32, 1), mock_state.should_compact_calls);
    try testing.expectEqual(@as(u32, 1), mock_state.call_compact_agent_calls);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    try testing.expectEqualStrings("GOAL: ship it\nNEXT ACTION: merge", mock_state.last_compacted_xml);
    try testing.expectEqualStrings("sess_bespoke", mock_state.last_compact_session_id);
    try testing.expectEqualStrings("test-model", mock_state.last_compact_model);
}

test "compact_messages_in_memory error propagates to caller" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "valid xml";
    mock_state.compact_skip = true; // mock returns error.Skip

    const result = workflow.maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "/tmp",
        "sess_mock",
        undefined,
        std.testing.io,
        &lg,
        &cfg,
    );

    try testing.expectError(error.Skip, result);
}
