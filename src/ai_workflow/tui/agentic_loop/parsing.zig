const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const LLMHistory = mod.LLMHistory;
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
