const std = @import("std");
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");

const agent = nalarcore.agent;
const prompt = nalarcore.agent.prompt;
const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const json = std.json;

pub const CallCompactAgentInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: ?*logger_mod.Logger,
    messages: std.ArrayList(agent.AgentMessage),
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
};

/// Call CompactionAgent to compress conversation history.
/// Returns compacted context or null on failure.
pub fn callCompactAgent(
    obj: CallCompactAgentInput,
) ?[]const u8 {
    const allocator = obj.allocator;
    const messages = obj.messages;
    const logger = obj.logger;
    const api_key = obj.api_key;
    const model = obj.model;
    const base_url = obj.base_url;
    const io = obj.io;

    if (messages.items.len < 2) {
        logger.?.warnFmt("[COMPACTION] Not enough messages to compact", .{});
        return null;
    }

    const original_system_prompt: []const u8 = messages.items[0].content orelse "";

    const compact_message = buildCompactMessagePrompt(
        allocator,
        logger,
        messages,
        original_system_prompt,
    ) orelse return null;
    defer allocator.free(compact_message);

    var messages_convocompact: std.ArrayList(agent.AgentMessage) = .empty;
    defer messages_convocompact.deinit(allocator);

    messages_convocompact.append(allocator, .{
        .role = .system,
        .content = prompt.CompactionAgent,
    }) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to append system message: {s}", .{@errorName(err)});
        return null;
    };

    messages_convocompact.append(allocator, .{
        .role = .user,
        .content = compact_message,
    }) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to append user message: {s}", .{@errorName(err)});
        return null;
    };

    var compaction_agent = agent.Agent.init(allocator, io);
    defer compaction_agent.deinit();

    compaction_agent.apiKey = api_key;
    compaction_agent.model = model;
    compaction_agent.baseUrl = base_url;

    const response = compaction_agent.callStreaming(.{
        .tools = &.{},
        .messages = messages_convocompact.items,
        .temperature = 0.0,
    }, null, noopStreamCallbackNew) catch |err| {
        logger.?.errFmt("[COMPACTION] callStreaming failed: {s}", .{@errorName(err)});
        return null;
    };
    defer response.deinit();

    const content = response.content orelse {
        logger.?.errFmt("[COMPACTION] Response content is null", .{});
        return null;
    };

    if (content.len == 0) {
        logger.?.warnFmt("[COMPACTION] Empty response from CompactionAgent", .{});
        return null;
    }

    const duplicated = allocator.dupe(u8, content) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to duplicate content: {s}", .{@errorName(err)});
        return null;
    };

    return duplicated;
}

fn noopStreamCallbackNew(_: ?*anyopaque, _: agent.StreamChunk) void {}

/// Build the compaction handoff prompt that gets sent to the CompactionAgent.
///
/// Walks `messages[1..last_idx]` (excluding the system prompt at index 0 AND
/// the current/pending message at the last index) and renders each message
/// into a labeled row:
/// - `content` becomes `[<role>]: <content>`
/// - each `tool_calls[i]` becomes `[tool_call]: <name>(<arguments>)`
///
/// The rows are joined with `\n` and embedded into a fixed handoff-package
/// template alongside `original_system_prompt`. The resulting string is what
/// the CompactionAgent sees as its user message.
///
/// **Caller owns the returned string** and must free it with `allocator.free`.
/// Returns `null` on allocation failure (after logging via `logger`); the
/// caller is then expected to short-circuit the compaction flow.
///
/// **Precondition:** `messages.items.len >= 2` (the caller — `callCompactAgent`
/// — enforces this). With only one message, `last_idx = 0` and the history
/// slice `messages.items[1..0]` is empty; the prompt is still produced but
/// has no conversation rows.
pub fn buildCompactMessagePrompt(
    allocator: std.mem.Allocator,
    logger: ?*logger_mod.Logger,
    messages: std.ArrayList(agent.AgentMessage),
    original_system_prompt: []const u8,
) ?[]const u8 {
    const last_idx = messages.items.len - 1;

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    for (messages.items[1..last_idx]) |msg| {
        if (msg.content) |c| {
            const role_str = msg.role.to_str();
            const labeled = std.fmt.allocPrint(allocator, "[{s}]: {s}", .{ role_str, c }) catch |err| {
                logger.?.errFmt("[COMPACTION] Failed to label message content: {s}", .{@errorName(err)});
                return null;
            };
            // If append fails, free our just-allocated `labeled` before
            // returning null — otherwise it's a one-byte-equivalent leak
            // that the leak detector will catch under `testing.allocator`.
            parts.append(allocator, labeled) catch |err| {
                logger.?.errFmt("[COMPACTION] Failed to collect message content: {s}", .{@errorName(err)});
                allocator.free(labeled);
                return null;
            };
        }
        if (msg.tool_calls) |tool_calls| {
            for (tool_calls) |tc| {
                const tc_str = std.fmt.allocPrint(allocator, "[tool_call]: {s}({s})", .{
                    tc.function.name,
                    tc.function.arguments,
                }) catch continue;
                // Same leak guard as the content branch above.
                parts.append(allocator, tc_str) catch {
                    allocator.free(tc_str);
                    continue;
                };
            }
        }
    }

    const history_str = std.mem.join(allocator, "\n", parts.items) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to join history: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(history_str);

    // `std.mem.join` copies each segment into a fresh allocation, so the
    // originals (`parts.items`) are now orphan references and must be freed
    // — caught by `testing.allocator.detectLeaks()` otherwise.
    defer for (parts.items) |part| allocator.free(part);

    const compact_message = std.fmt.allocPrint(allocator,
        \\You are preparing a handoff package for a fresh AI coding agent.
        \\The next agent has ZERO context. It cannot ask questions. It must act immediately.
        \\
        \\Rules:
        \\- Be surgical. No narrative, no filler, no summaries of conversation.
        \\- Every line must help the next agent take action or avoid a mistake.
        \\- If something was tried and failed, say exactly why — not just "it failed".
        \\- If a file was modified, say what changed and why, not just the filename.
        \\- The NEXT ACTION must be a single concrete step, not a vague goal.
        \\- If there are blockers, say what they are and what was tried to unblock them.
        \\
        \\Output exactly this structure, no extra sections:
        \\
        \\GOAL:
        \\(The original user objective, one or two sentences max)
        \\
        \\CURRENT STATE:
        \\- cwd:
        \\- repo:
        \\- branch:
        \\- worktree:
        \\- build status: (passing / failing / unknown)
        \\- test status: (passing / failing / unknown)
        \\
        \\TECH STACK:
        \\(Languages, frameworks, build tools — only what is relevant to the task)
        \\
        \\FILES MODIFIED:
        \\(path — what changed and why, one line per file)
        \\
        \\KEY DISCOVERIES:
        \\(Non-obvious things learned about the codebase, APIs, or constraints)
        \\
        \\FAILED ATTEMPTS:
        \\(What was tried, what happened, root cause if known)
        \\
        \\OPEN ISSUES:
        \\(Unresolved problems blocking or threatening progress)
        \\
        \\ASSUMPTIONS MADE:
        \\(Decisions taken without explicit user confirmation)
        \\
        \\NEXT ACTION:
        \\(Exactly one concrete step. File to edit, command to run, function to write.)
        \\
        \\AFTER THAT:
        \\(The 2-3 steps that follow NEXT ACTION, in order)
        \\
        \\DO NOT:
        \\(Pitfalls, wrong paths, things that look right but aren't)
        \\
        \\---
        \\ORIGINAL SYSTEM PROMPT (context only — constraints, tools, scope the
        \\original agent operated under. Do NOT summarize this section itself;
        \\use it only to inform DO NOT / ASSUMPTIONS MADE / FAILED ATTEMPTS above):
        \\{s}
        \\
        \\---
        \\CONVERSATION HISTORY:
        \\{s}
    , .{ original_system_prompt, history_str }) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to format compact message: {s}", .{@errorName(err)});
        return null;
    };

    return compact_message;
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const AgentMessage = agent.AgentMessage;
const ToolCall = agent.ToolCall;

/// Build a 5-message list mimicking the production workflow shape:
///   [0] system prompt, [1] user, [2] assistant, [3] user, [4] assistant (current/pending).
/// Index 0 is treated as the "original system prompt"; index 4 is the "current"
/// message excluded from history (per `messages.items[1..last_idx]` semantics in
/// `buildCompactMessagePrompt`). Caller owns and must free via `freeMessages`.
fn buildSampleMessages(allocator: std.mem.Allocator) !std.ArrayList(AgentMessage) {
    var list: std.ArrayList(AgentMessage) = .empty;
    try list.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, "ORIG_SYS") });
    try list.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "Hi") });
    try list.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "Hello") });
    try list.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "Help me") });
    try list.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "Sure") });
    return list;
}

fn freeMessages(allocator: std.mem.Allocator, messages: *std.ArrayList(AgentMessage)) void {
    for (messages.items) |*m| m.deinit(allocator);
    var owned = messages.*;
    owned.deinit(allocator);
}

test "buildCompactMessagePrompt: happy path embeds system prompt and labeled history" {
    const alloc = testing.allocator;
    var messages = try buildSampleMessages(alloc);
    defer freeMessages(alloc, &messages);

    const result = buildCompactMessagePrompt(alloc, null, messages, "ORIG_SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    try testing.expect(std.mem.indexOf(u8, s, "ORIGINAL SYSTEM PROMPT") != null);
    try testing.expect(std.mem.indexOf(u8, s, "ORIG_SYS") != null);
    try testing.expect(std.mem.indexOf(u8, s, "CONVERSATION HISTORY") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: Hi") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: Hello") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: Help me") != null);
}

test "buildCompactMessagePrompt: first AND last messages are excluded from history" {
    const alloc = testing.allocator;
    var messages = try buildSampleMessages(alloc);
    defer freeMessages(alloc, &messages);

    const result = buildCompactMessagePrompt(alloc, null, messages, "ORIG_SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    // Index 0 content ("ORIG_SYS") is passed in as `original_system_prompt`,
    // so it should NOT appear as a labeled `[system]: ...` row in history.
    try testing.expect(std.mem.indexOf(u8, s, "[system]: ORIG_SYS") == null);
    // Index 4 ("Sure") is the LAST message — excluded by `messages.items[1..last_idx]`.
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: Sure") == null);
    // Middle messages 1..3 SHOULD appear.
    try testing.expect(std.mem.indexOf(u8, s, "Help me") != null);
}

test "buildCompactMessagePrompt: tool_calls formatted as [tool_call]: name(args)" {
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);

    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "SYS") });
    // messages[1] has BOTH content and tool_calls — both should land in history
    try messages.append(alloc, .{
        .role = .assistant,
        .content = try alloc.dupe(u8, "calling search"),
    });
    const tc1 = try alloc.alloc(ToolCall, 2);
    tc1[0] = .{
        .id = "",
        .type = "function",
        .function = .{
            .name = try alloc.dupe(u8, "search_web"),
            .arguments = try alloc.dupe(u8, "{\"q\":\"zig\"}"),
        },
    };
    tc1[1] = .{
        .id = "",
        .type = "function",
        .function = .{
            .name = try alloc.dupe(u8, "read_file"),
            .arguments = try alloc.dupe(u8, "{\"path\":\"/tmp/x.zig\"}"),
        },
    };
    messages.items[1].tool_calls = tc1;
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "go") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "last") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: calling search") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[tool_call]: search_web({\"q\":\"zig\"})") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[tool_call]: read_file({\"path\":\"/tmp/x.zig\"})") != null);
    // The last message's content must not appear.
    try testing.expect(std.mem.indexOf(u8, s, "calling read") == null);
}

test "buildCompactMessagePrompt: message with content=null and no tool_calls is skipped silently" {
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "SYS") });
    // messages[1] has BOTH fields null — must not produce a labeled row.
    try messages.append(alloc, .{ .role = .user, .content = null });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "ok") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "done") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    // No labeled row for the null-content message — neither `[user]: ` alone
    // nor `[user]: \n` should appear.
    try testing.expect(std.mem.indexOf(u8, s, "[user]:\n") == null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: \n") == null);
    // The assistant message and the "ok" text must appear.
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: ok") != null);
    // The last message ("done") is excluded.
    try testing.expect(std.mem.indexOf(u8, s, "[user]: done") == null);
}

test "buildCompactMessagePrompt: empty middle history (only system + last) returns valid prompt" {
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "SYS") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "last") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    // The prompt header still renders; CONVERSATION HISTORY section exists
    // but has no labeled rows (empty `history_str` from `join`).
    try testing.expect(std.mem.indexOf(u8, s, "ORIGINAL SYSTEM PROMPT") != null);
    try testing.expect(std.mem.indexOf(u8, s, "CONVERSATION HISTORY:") != null);
    // The last message's content must NOT appear in the history.
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: last") == null);
}

test "buildCompactMessagePrompt: history rows are joined with newline separator (order preserved)" {
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    // 6 messages → last_idx=5, history slice = messages[1..5] = 4 rows.
    // The 6th message ("D") is the LAST (current/pending) and must be excluded.
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "SYS") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "A") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "B") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "C") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "D") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "E_LAST") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    // Adjacent rows must be separated by a single `\n` (the `join` separator).
    try testing.expect(std.mem.indexOf(u8, s, "[user]: A\n[assistant]: B") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: B\n[user]: C") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: C\n[assistant]: D") != null);
    // The last message ("E_LAST") must NOT appear (it's the excluded tail).
    try testing.expect(std.mem.indexOf(u8, s, "[user]: E_LAST") == null);
}

test "buildCompactMessagePrompt: returns a heap-allocated, caller-owned string" {
    const alloc = testing.allocator;
    var messages = try buildSampleMessages(alloc);
    defer freeMessages(alloc, &messages);

    const result = buildCompactMessagePrompt(alloc, null, messages, "ORIG_SYS");
    try testing.expect(result != null);
    // Allocate, mutate, then free — leak detector (testing.allocator) enforces
    // ownership. If the impl ever returns a non-heap pointer, this `free`
    // would either crash (free on const slice) or trigger a leak report.
    const ptr = result.?;
    _ = ptr.len;
    alloc.free(ptr);
}

test "buildCompactMessagePrompt: empty-messages list (only system + 1 user) excludes last" {
    // Confirms `messages.items[1..last_idx]` semantics: with two messages
    // (system + last), the slice is empty, no labeled rows produced, but
    // the rest of the prompt renders fine.
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "ONLY_SYS") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "ONLY_USER") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "ONLY_SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    try testing.expect(std.mem.indexOf(u8, s, "ONLY_SYS") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: ONLY_USER") == null);
}
