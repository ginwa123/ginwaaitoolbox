const std = @import("std");
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");

const agent = nalarcore.agent;
const prompt = nalarcore.agent.prompt;
const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const json = std.json;

// `buildCompactMessagePrompt` lives in `workflow_compact_message.zig` (consolidated
// there with the DB-fetch / envelope-enrich helpers). We only re-export it here
// because `callCompactAgent` is the one call site that consumes it.
const buildCompactMessagePrompt = @import("workflow_compact_message.zig").buildCompactMessagePrompt;

pub const CallCompactAgentInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: ?*logger_mod.Logger,
    messages: std.ArrayList(agent.AgentMessage),
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    /// URL style of the calling profile (`"openai"` or `"anthropic"`).
    /// The CompactionAgent must use the SAME wire format as the main
    /// agent loop — otherwise an Anthropic-style base_url receives an
    /// OpenAI-shaped JSON request and rejects it, silently dropping
    /// the compaction. Mirrors the propagation pattern from
    /// `effective_url_style` in workflow.zig. Defaults to `"openai"`
    /// for callers that haven't been updated yet (back-compat with
    /// existing in-flight sessions). Plan: this file's task card.
    url_style: []const u8 = "openai",
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
    const url_style = obj.url_style;
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
    // Wire format must match the upstream endpoint. Without this set,
    // Agent defaults to "openai" — which means an `url_style: "anthropic"`
    // profile (e.g. "900 ribu antropic") sends an OpenAI-shaped JSON
    // body to https://api.minimax.io/anthropic, the upstream returns
    // an error, `callStreaming` returns an error, and `callCompactAgent`
    // silently returns null. The threshold check still fires (and the
    // session still balloons to 497K+ tokens) — the compaction just
    // never completes. This propagation fixes that.
    compaction_agent.UrlStyle = url_style;

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
