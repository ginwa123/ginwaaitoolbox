const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const agent = nalarcore.agent;
const testing = std.testing;
const LLMHistory = mod.LLMHistory;

const Parsing = @import("parsing.zig");

// ─── Helpers ───────────────────────────────────────────────────────────────

/// Build a minimal `LLMHistory` with `role = "tool"` and the given
/// `response_content`. Every owned slice is heap-allocated so the test
/// allocator's canary catches leaks / double-frees on `deinit`.
///
/// IMPORTANT: `LLMHistory.deinit` unconditionally frees `.agent`,
/// `.session_name`, and `.tool_name` even when they're at their
/// string-literal defaults (`"Agent"`, `""`, `""`). Calling `deinit`
/// on a partially-initialized `LLMHistory` therefore crashes with
/// `Invalid free`. This helper explicitly `dupe`s all three so the
/// resulting struct is safe to deinit.
fn makeToolMessage(allocator: std.mem.Allocator, response_content: []const u8) !LLMHistory {
    return LLMHistory{
        .id = try allocator.dupe(u8, "msg_test_001"),
        .session_id = try allocator.dupe(u8, "session_test"),
        .model = try allocator.dupe(u8, "test-model"),
        .created_at = try allocator.dupe(u8, "2025-01-01T00:00:00Z"),
        .response_content = try allocator.dupe(u8, response_content),
        .finish_reason = try allocator.dupe(u8, "tool_calls"),
        .role = try allocator.dupe(u8, "tool"),
        .agent = try allocator.dupe(u8, "Agent"),
        .session_name = try allocator.dupe(u8, ""),
        .tool_name = try allocator.dupe(u8, ""),
        .tool_calls_json = try allocator.dupe(u8, ""),
        .tool_call_id = try allocator.dupe(u8, "tool_call_abc"),
    };
}

/// Free the messages returned by `transformLLMHistoryToAgentMessage`.
fn freeMessages(allocator: std.mem.Allocator, msgs: []agent.AgentMessage) void {
    for (msgs) |*m| m.deinit(allocator);
    allocator.free(msgs);
}

// ─── Tests: success envelope (<data>) ──────────────────────────────────────

test "tool message strips <tool> envelope and returns only <data> value" {
    const allocator = testing.allocator;
    const envelope =
        "<tool><name>read_file</name><parameters><path>/foo</path></parameters>" ++
        "<success>true</success>" ++
        "<data><path>/foo</path><content>hello</content></data></tool>";
    var msg = try makeToolMessage(allocator, envelope);
    defer msg.deinit(allocator);

    const result = try Parsing.transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("<path>/foo</path><content>hello</content>", result[0].content.?);
    try testing.expect(result[0].role == .tool);
    try testing.expectEqualStrings("tool_call_abc", result[0].tool_call_id.?);
}

test "tool message success envelope with simple data value" {
    const allocator = testing.allocator;
    const envelope =
        "<tool><name>bash</name><parameters><command>echo hi</command></parameters>" ++
        "<success>true</success><data><stdout>hi</stdout></data></tool>";
    var msg = try makeToolMessage(allocator, envelope);
    defer msg.deinit(allocator);

    const result = try Parsing.transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("<stdout>hi</stdout>", result[0].content.?);
}

test "tool message success envelope with empty <data> returns empty content" {
    const allocator = testing.allocator;
    const envelope =
        "<tool><name>foo</name><parameters></parameters>" ++
        "<success>true</success><data></data></tool>";
    var msg = try makeToolMessage(allocator, envelope);
    defer msg.deinit(allocator);

    const result = try Parsing.transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("", result[0].content.?);
}

// ─── Tests: failure envelope (<error>) ─────────────────────────────────────

test "tool message with failure envelope returns <error> value" {
    const allocator = testing.allocator;
    const envelope =
        "<tool><name>read_file</name><parameters><path>/missing</path></parameters>" ++
        "<success>false</success><error>File not found</error></tool>";
    var msg = try makeToolMessage(allocator, envelope);
    defer msg.deinit(allocator);

    const result = try Parsing.transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("File not found", result[0].content.?);
}

test "tool message failure envelope with XML-escaped error keeps entities escaped" {
    // The wrapToolOutput path XML-escapes the error message (per
    // tool_registry.zig:1723), so the inner <error>...</error> text
    // legitimately contains &quot; / &lt; / &gt; entities. We do NOT
    // unescape — the LLM can read escaped XML fine, and the frontend
    // has its own unwrap+unescape logic in unwrapToolOutput.ts.
    const allocator = testing.allocator;
    const envelope =
        "<tool><name>read_file</name><parameters></parameters>" ++
        "<success>false</success>" ++
        "<error>File &quot;foo&quot; not &lt;found&gt;</error></tool>";
    var msg = try makeToolMessage(allocator, envelope);
    defer msg.deinit(allocator);

    const result = try Parsing.transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("File &quot;foo&quot; not &lt;found&gt;", result[0].content.?);
}

// ─── Tests: legacy / non-envelope fallback ─────────────────────────────────

test "tool message with plain-text legacy content falls back to full response_content" {
    const allocator = testing.allocator;
    var msg = try makeToolMessage(allocator, "hello plain text");
    defer msg.deinit(allocator);

    const result = try Parsing.transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("hello plain text", result[0].content.?);
}

test "tool message with empty string content returns empty content" {
    const allocator = testing.allocator;
    var msg = try makeToolMessage(allocator, "");
    defer msg.deinit(allocator);

    const result = try Parsing.transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("", result[0].content.?);
}

test "tool message with malformed envelope (starts but no </tool>) falls back to full content" {
    const allocator = testing.allocator;
    // Starts with <tool> but doesn't end with </tool> — malformed.
    var msg = try makeToolMessage(allocator, "<tool><name>foo</name>");
    defer msg.deinit(allocator);

    const result = try Parsing.transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("<tool><name>foo</name>", result[0].content.?);
}

test "tool message with envelope-but-no-data-no-error returns empty content" {
    const allocator = testing.allocator;
    // Envelope present but only has <name> — no <data> or <error>.
    var msg = try makeToolMessage(allocator, "<tool><name>foo</name></tool>");
    defer msg.deinit(allocator);

    const result = try Parsing.transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("", result[0].content.?);
}

test "tool message with empty <tool></tool> envelope returns empty content" {
    const allocator = testing.allocator;
    var msg = try makeToolMessage(allocator, "<tool></tool>");
    defer msg.deinit(allocator);

    const result = try Parsing.transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("", result[0].content.?);
}

// ─── Tests: data payload structure (inner XML preserved) ────────────────────

test "tool message data containing nested-looking tags keeps the inner payload intact" {
    // read_file's data is: <path>...</path><content>...</content>
    // The parser finds the OUTER <data>...</data>, so the inner XML
    // tags are preserved verbatim in .content.
    const allocator = testing.allocator;
    const inner = "<path>/home/user/file.txt</path>" ++
        "<content>line1\nline2\nline3</content>";
    const envelope =
        "<tool><name>read_file</name><parameters><path>/home/user/file.txt</path></parameters>" ++
        "<success>true</success><data>" ++ inner ++ "</data></tool>";
    var msg = try makeToolMessage(allocator, envelope);
    defer msg.deinit(allocator);

    const result = try Parsing.transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings(inner, result[0].content.?);
}