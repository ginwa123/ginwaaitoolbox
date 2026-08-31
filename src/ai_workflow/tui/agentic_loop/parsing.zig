const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const LLMHistory = @import("llm_history_row.zig").LLMHistory;

const agent = nalarcore.agent;
const json = std.json;

pub fn transformLLMHistoryToAgentMessage(allocator: std.mem.Allocator, message: LLMHistory) ![]agent.AgentMessage {
    var messages: std.ArrayList(agent.AgentMessage) = .empty;

    const role = agent.Role.from_str(message.role) orelse .assistant;

    // Handle tool result messages (role == "tool")
    // For tool messages, the tools column contains the tool_call_id string directly.
    // The `response_content` for a tool result is wrapped in a
    // `<tool><name>...</name><parameters>...</parameters><success>...</success><data>...</data></tool>`
    // envelope (produced by `tool_registry.wrapToolOutput`).
    // Strip the envelope and use only the inner payload (success: `<data>`,
    // failure: `<error>`) so the LLM sees the actual tool output rather than
    // the envelope metadata.
    if (role == .tool) {
        const agentMessage = agent.AgentMessage{
            .id = try allocator.dupe(u8, message.id),
            .role = .tool,
            .content = try stripToolEnvelope(allocator, message.response_content),
            .tool_call_id = try allocator.dupe(u8, message.tool_call_id orelse ""),
        };
        try messages.append(allocator, agentMessage);
        return messages.toOwnedSlice(allocator);
    }

    // Handle assistant/user/system messages - always create a message if role is valid
    // (but not tool role which is handled above)
    // const finishReason = agent.FinishReason.from_str(message.finish_reason);
    // const isToolCalls = finishReason == .tool_calls;

    // For assistant/user/system roles, always create a message (even if content is empty)
    // Tool role is handled separately above
    if (role != .tool) {
        var tool_calls: ?[]agent.ToolCall = null;
        const toolSource = if (message.tool_calls_json.len > 0) message.tool_calls_json else message.response_content;
        const tcParsed = json.parseFromSlice(json.Value, allocator, toolSource, .{}) catch null;
        if (tcParsed) |tcp| {
            defer tcp.deinit();
            if (tcp.value == .array and tcp.value.array.items.len > 0) {
                var calls = try allocator.alloc(agent.ToolCall, tcp.value.array.items.len);
                for (tcp.value.array.items, 0..) |tc_item, i| {
                    if (tc_item == .object) {
                        const id_raw = if (tc_item.object.get("id")) |id_val| id_val.string else "";
                        const func_obj = if (tc_item.object.get("function")) |f| f.object else null;
                        const name_raw = if (func_obj) |fo| if (fo.get("name")) |n| n.string else "" else "";
                        // Normalize: empty/missing arguments → "{}" (valid JSON object)
                        var args_raw: []const u8 = "{}";
                        if (func_obj) |fo| {
                            if (fo.get("arguments")) |a| {
                                if (a.string.len > 0) args_raw = a.string;
                            }
                        }
                        const safe_args = blk: {
                            if (args_raw.len == 0) break :blk "{}";
                            _ = std.json.parseFromSlice(std.json.Value, allocator, args_raw, .{}) catch {
                                break :blk "{}";
                            };
                            break :blk args_raw;
                        };
                        calls[i] = .{
                            .id = try allocator.dupe(u8, id_raw),
                            .function = .{
                                .name = try allocator.dupe(u8, name_raw),
                                .arguments = try allocator.dupe(u8, safe_args),
                            },
                        };
                    } else {
                        calls[i] = .{
                            .id = try allocator.dupe(u8, ""),
                            .function = .{
                                .name = try allocator.dupe(u8, ""),
                                .arguments = try allocator.dupe(u8, "{}"),
                            },
                        };
                    }
                }
                tool_calls = calls;
            }
        }

        const content = try allocator.dupe(u8, message.response_content);
        const reasoning_content: ?[]const u8 = if (message.reasoning_content) |rc| try allocator.dupe(u8, rc) else null;
        const reasoning_id: ?[]const u8 = if (message.reasoning_id) |rid| try allocator.dupe(u8, rid) else null;
        const reasoning_encrypted_content: ?[]const u8 = if (message.reasoning_encrypted_content) |rec| try allocator.dupe(u8, rec) else null;

        // Handle vision support: if image_urls is set, create content_parts with text and images
        var content_parts: ?[]agent.ContentPart = null;
        if (message.image_urls != null and message.image_urls.?.len > 0) {
            const image_count = message.image_urls.?.len;
            const has_text = content.len > 0;
            const total_parts = if (has_text) image_count + 1 else image_count;
            var parts = try allocator.alloc(agent.ContentPart, total_parts);
            var part_idx: usize = 0;
            // Text part (first) if there's text content
            if (has_text) {
                parts[part_idx] = .{
                    .part_type = "text",
                    .text = content,
                    .image_url = null,
                };
                part_idx += 1;
            }
            // Image URL parts
            for (message.image_urls.?) |image_url| {
                parts[part_idx] = .{
                    .part_type = "image_url",
                    .text = null,
                    .image_url = .{
                        .url = try allocator.dupe(u8, image_url),
                        .detail = null,
                    },
                };
                part_idx += 1;
            }
            content_parts = parts;
        } else {}

        const agentMessage = agent.AgentMessage{
            .id = try allocator.dupe(u8, message.id),
            .role = role,
            .content = if (content_parts != null) null else content,
            .content_parts = content_parts,
            .tool_calls = tool_calls,
            .reasoning_content = reasoning_content,
            .reasoning_id = reasoning_id,
            .reasoning_encrypted_content = reasoning_encrypted_content,
        };
        try messages.append(allocator, agentMessage);
    }

    return messages.toOwnedSlice(allocator);
}

/// Strip the `<tool><name>...</name><parameters>...</parameters><success>...</success><data>...</data></tool>`
/// envelope produced by `tool_registry.wrapToolOutput` and return just the
/// inner payload.
///
/// On success envelopes (contain `<success>true</success>`), returns the
/// contents of `<data>...</data>`. On failure envelopes
/// (`<success>false</success>`), returns the contents of `<error>...</error>`.
/// If the envelope is present but contains neither tag, returns an empty
/// string.
///
/// Returns the input UNCHANGED (heap-duplicated) if it doesn't look like a
/// tool envelope — this keeps backwards compatibility with old
/// `response_content` rows that pre-date the envelope format.
///
/// Mirrors `apps/desktop/src/helpers/unwrapToolOutput.ts` (which uses
/// `tryUnwrapToolOutput` for the same fallback semantics).
fn stripToolEnvelope(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return stripToolEnvelopeImpl(allocator, raw) catch |err| {
        // Use the project's custom Logger (nalarcore.loggermod) — it has its
        // own formatter and does NOT route through std.log, so it won't
        // increment the test runner's `log_err_count`. Mirrors the
        // `startup.zig` "Failed to ... {s}" convention for errFmt messages.
        // `getGlobal()` returns null if the logger hasn't been initialized
        // (e.g. inside a unit test) — guard with `if (...) |logger|` so we
        // never crash in that case.
        if (nalarcore.loggermod.getGlobal()) |logger| {
            logger.warnFmt(
                "[stripToolEnvelope] Agent Nalar System error, the actual error is ->>>> {s} (input_len={d}, starts_with_tool={any})",
                .{
                    @errorName(err),
                    raw.len,
                    std.mem.startsWith(u8, raw, "<tool>"),
                },
            );
        }
        return err;
    };
}

fn stripToolEnvelopeImpl(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, raw, "<tool>")) return try allocator.dupe(u8, raw);
    if (!std.mem.endsWith(u8, raw, "</tool>")) return try allocator.dupe(u8, raw);

    if (extractTag(raw, "data")) |inner| return try allocator.dupe(u8, inner);
    if (extractTag(raw, "error")) |inner| return try allocator.dupe(u8, inner);
    // Envelope present but no <data> and no <error> — empty payload.
    return try allocator.dupe(u8, "");
}

/// Find the first `<tag>...</tag>` block in `haystack` and return the inner
/// slice (borrowed from `haystack` — caller must copy if needed).
/// Returns null if the tag is not present.
fn extractTag(haystack: []const u8, comptime tag: []const u8) ?[]const u8 {
    const open_seq = "<" ++ tag ++ ">";
    const close_seq = "</" ++ tag ++ ">";
    const open_idx = std.mem.indexOf(u8, haystack, open_seq) orelse return null;
    const value_start = open_idx + open_seq.len;
    const tail = haystack[value_start..];
    const close_local = std.mem.indexOf(u8, tail, close_seq) orelse return null;
    return tail[0..close_local];
}

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

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
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

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
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

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
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

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
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

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("File &quot;foo&quot; not &lt;found&gt;", result[0].content.?);
}

// ─── Tests: legacy / non-envelope fallback ─────────────────────────────────

test "tool message with plain-text legacy content falls back to full response_content" {
    const allocator = testing.allocator;
    var msg = try makeToolMessage(allocator, "hello plain text");
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("hello plain text", result[0].content.?);
}

test "tool message with empty string content returns empty content" {
    const allocator = testing.allocator;
    var msg = try makeToolMessage(allocator, "");
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("", result[0].content.?);
}

test "tool message with malformed envelope (starts but no </tool>) falls back to full content" {
    const allocator = testing.allocator;
    // Starts with <tool> but doesn't end with </tool> — malformed.
    var msg = try makeToolMessage(allocator, "<tool><name>foo</name>");
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("<tool><name>foo</name>", result[0].content.?);
}

test "tool message with envelope-but-no-data-no-error returns empty content" {
    const allocator = testing.allocator;
    // Envelope present but only has <name> — no <data> or <error>.
    var msg = try makeToolMessage(allocator, "<tool><name>foo</name></tool>");
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("", result[0].content.?);
}

test "tool message with empty <tool></tool> envelope returns empty content" {
    const allocator = testing.allocator;
    var msg = try makeToolMessage(allocator, "<tool></tool>");
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
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

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings(inner, result[0].content.?);
}

