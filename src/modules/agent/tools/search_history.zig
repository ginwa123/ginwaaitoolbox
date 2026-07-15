const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;
const helpers = nalarcore.helpers;
const xmlEscape = helpers.xml_escape;

/// Input for search_history.
///
/// TWO MODES:
/// - "text" (default): FTS5 full-text search over message content.
///   Requires `query`. Optionally scope to `session_id`.
/// - "session": fetch messages for a specific `session_id`. Optional
///   `message_ids` to also return full <content> for those ids.
///
/// Why both modes in one tool: a single round-trip covers "find the
/// conversation about X" and "show me session N" — two related but
/// distinct needs. Splitting into two tools would add a second prompt
/// line for the LLM to learn.
pub const SearchHistoryInput = struct {
    /// "text" (FTS5 search) or "session" (fetch by session_id).
    mode: []const u8 = "text",
    /// Required for mode="text". FTS5 MATCH query string.
    query: []const u8 = "",
    /// Required for mode="session". Optional scope filter for mode="text".
    session_id: []const u8 = "",
    /// Comma-separated message ids. Only meaningful for mode="session":
    /// when non-empty, also returns full <content> for these ids.
    message_ids: []const u8 = "",
    /// Optional exact-match role filter.
    role: []const u8 = "",
    /// Optional lower bound on created_at (inclusive). YYYY-MM-DD HH:MM:SS.
    since: []const u8 = "",
    /// Optional upper bound on created_at (inclusive).
    until: []const u8 = "",
    /// Max rows to return. Defaults to 20; tool layer caps at 200.
    limit: u32 = 20,
};

pub const search_history_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search_history",
        .description =
            \\Search the full conversation history stored on disk — including messages compacted out of the live context — either by full-text query or by fetching a specific session's messages.
            \\
            \\TWO MODES:
            \\- mode="text": full-text search over message content using SQLite FTS5. Provide `query`. Optionally scope to one `session_id`, filter by `role`, `since`/`until`, and cap results with `limit`. Returns ranked matches with a preview snippet — use this when you remember *what* was said but not *where*.
            \\- mode="session": list (or fetch) messages belonging to one `session_id`. Returns ALL messages for the session — both those still in your live context (`is_feed_to_llm=1`) and those dropped by compaction (`is_feed_to_llm=0`). Returns an index (id, role, created_at, preview) by default; pass specific `message_ids` to also get the full <content> body for those entries. Use this when you know *which session* you need and want to browse or pull full text.
            \\
            \\Filters (optional, apply to both modes):
            \\- role: "user", "assistant", or "tool" — exact match.
            \\- since / until: YYYY-MM-DD HH:MM:SS (inclusive).
            \\- limit: max rows to return (default 20, max 200).
            \\
            \\Example (text search): {"mode": "text", "query": "login bug fix"}
            \\Example (text search scoped): {"mode": "text", "query": "login bug", "session_id": "s_42"}
            \\Example (session browse): {"mode": "session", "session_id": "s_42"}
            \\Example (session full fetch): {"mode": "session", "session_id": "s_42", "message_ids": "h_1781,h_1782"}
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "mode", .type = "string", .description = "'text' (FTS5 full-text search, default) or 'session' (fetch by session_id)." },
                .{ .name = "query", .type = "string", .description = "Required for mode='text'. FTS5 search query." },
                .{ .name = "session_id", .type = "string", .description = "Required for mode='session'. Optional scope filter for mode='text'." },
                .{ .name = "message_ids", .type = "string", .description = "mode='session' only. Comma-separated ids to also fetch full <content> for." },
                .{ .name = "role", .type = "string", .description = "Optional exact-match role filter: 'user', 'assistant', or 'tool'." },
                .{ .name = "since", .type = "string", .description = "Optional lower bound on created_at (inclusive). YYYY-MM-DD HH:MM:SS." },
                .{ .name = "until", .type = "string", .description = "Optional upper bound on created_at (inclusive)." },
                .{ .name = "limit", .type = "number", .description = "Max rows to return. Default 20, max 200." },
            },
            .required = &.{},
        },
    },
};

/// Parse `message_ids_csv` ("h_123,h_456") into a `[]const []const u8`.
fn parseMessageIds(allocator: std.mem.Allocator, csv: []const u8) ![]const []const u8 {
    if (csv.len == 0) return &.{};
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |id| {
        const trimmed = std.mem.trim(u8, id, " \t");
        if (trimmed.len > 0) {
            try ids.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }
    return try ids.toOwnedSlice(allocator);
}

fn errorXml(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<search_history><error>{s}</error></search_history>",
        .{escaped});
}

/// Execute search_history. Returns an XML string for the LLM.
pub fn execute_search_history(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    input: SearchHistoryInput,
) ![]const u8 {
    _ = io; // Reserved for future streaming; not used in v1.

    // Validate mode.
    const is_text_mode = blk: {
        if (std.mem.eql(u8, input.mode, "text") or input.mode.len == 0) break :blk true;
        if (std.mem.eql(u8, input.mode, "session")) break :blk false;
        const msg = try std.fmt.allocPrint(allocator,
            "Invalid mode '{s}'. Must be 'text' or 'session'.",
            .{input.mode});
        defer allocator.free(msg);
        return errorXml(allocator, msg);
    };

    if (is_text_mode and input.query.len == 0) {
        return errorXml(allocator, "mode='text' requires non-empty query.");
    }
    if (!is_text_mode and input.session_id.len == 0) {
        return errorXml(allocator, "mode='session' requires non-empty session_id.");
    }

    const effective_limit = @min(input.limit, 200);

    if (is_text_mode) {
        const opts = llm_history.SearchOptions{
            .session_id = if (input.session_id.len > 0) input.session_id else null,
            .role = if (input.role.len > 0) input.role else null,
            .since = if (input.since.len > 0) input.since else null,
            .until = if (input.until.len > 0) input.until else null,
            .limit = effective_limit,
        };

        const hits = llm_history.searchMessagesFts(allocator, db, input.query, opts) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "FTS search failed: {s}", .{@errorName(err)});
            defer allocator.free(msg);
            return errorXml(allocator, msg);
        };
        defer {
            for (hits) |h| {
                var copy = h;
                copy.deinit(allocator);
            }
            allocator.free(hits);
        }

        var xml: std.ArrayList(u8) = .empty;
        errdefer xml.deinit(allocator);

        try xml.print(allocator, "<search_history mode=\"text\">\n  <query>{s}</query>\n  <count>{d}</count>\n  <results>\n",
            .{ try xmlEscape(allocator, input.query), hits.len });
        for (hits) |h| {
            const id_e = try xmlEscape(allocator, h.id);
            defer allocator.free(id_e);
            const sid_e = try xmlEscape(allocator, h.session_id);
            defer allocator.free(sid_e);
            const role_e = try xmlEscape(allocator, h.role);
            defer allocator.free(role_e);
            const snip_e = try xmlEscape(allocator, h.snippet);
            defer allocator.free(snip_e);

            try xml.appendSlice(allocator, "    <entry>\n");
            try xml.print(allocator, "      <id>{s}</id>\n", .{id_e});
            try xml.print(allocator, "      <session_id>{s}</session_id>\n", .{sid_e});
            try xml.print(allocator, "      <role>{s}</role>\n", .{role_e});
            if (h.created_at.len > 0) {
                const ca_e = try xmlEscape(allocator, h.created_at);
                defer allocator.free(ca_e);
                try xml.print(allocator, "      <created_at>{s}</created_at>\n", .{ca_e});
            }
            try xml.print(allocator, "      <snippet>{s}</snippet>\n", .{snip_e});
            try xml.appendSlice(allocator, "    </entry>\n");
        }
        try xml.appendSlice(allocator, "  </results>\n</search_history>\n");
        return try xml.toOwnedSlice(allocator);
    }

    // mode="session"
    const parsed_ids = try parseMessageIds(allocator, input.message_ids);
    defer {
        for (parsed_ids) |id| allocator.free(id);
        allocator.free(parsed_ids);
    }
    const want_full = parsed_ids.len > 0;

    const opts = llm_history.CompactedMessagesOptions{
        .message_ids = if (want_full) parsed_ids else null,
        .role = if (input.role.len > 0) input.role else null,
        .since = if (input.since.len > 0) input.since else null,
        .until = if (input.until.len > 0) input.until else null,
        .limit = effective_limit,
        // mode="session" returns the FULL conversation history (live +
        // compacted), not just compacted messages. The agent may want
        // to re-read something still in its live context, or browse the
        // whole session regardless of compaction state.
        .include_all = true,
    };

    const messages = llm_history.getCompactedMessages(allocator, db, input.session_id, opts) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Database query failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return errorXml(allocator, msg);
    };
    defer {
        for (messages) |m| {
            var copy = m;
            copy.deinit(allocator);
        }
        allocator.free(messages);
    }

    var full_ids_set: std.StringHashMapUnmanaged(void) = .empty;
    defer full_ids_set.deinit(allocator);
    if (want_full) for (parsed_ids) |id| try full_ids_set.put(allocator, id, {});

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.print(allocator, "<search_history mode=\"session\">\n  <session_id>{s}</session_id>\n  <count>{d}</count>\n  <message_index>\n",
        .{ try xmlEscape(allocator, input.session_id), messages.len });

    for (messages) |m| {
        const id_e = try xmlEscape(allocator, m.id);
        defer allocator.free(id_e);
        const role_e = try xmlEscape(allocator, m.role);
        defer allocator.free(role_e);
        const preview_src: []const u8 = if (m.content.len > 100) m.content[0..100] else m.content;
        const preview_e = try xmlEscape(allocator, preview_src);
        defer allocator.free(preview_e);

        try xml.appendSlice(allocator, "    <entry>\n");
        try xml.print(allocator, "      <id>{s}</id>\n", .{id_e});
        try xml.print(allocator, "      <role>{s}</role>\n", .{role_e});
        if (m.created_at.len > 0) {
            const ca_e = try xmlEscape(allocator, m.created_at);
            defer allocator.free(ca_e);
            try xml.print(allocator, "      <created_at>{s}</created_at>\n", .{ca_e});
        }
        try xml.print(allocator, "      <preview>{s}</preview>\n", .{preview_e});
        if (std.mem.eql(u8, m.role, "tool")) {
            if (m.tool_call_id) |tcid| {
                const tcid_e = try xmlEscape(allocator, tcid);
                defer allocator.free(tcid_e);
                try xml.print(allocator, "      <tool_call_id>{s}</tool_call_id>\n", .{tcid_e});
            }
            if (m.tool_name) |tn| {
                const tn_e = try xmlEscape(allocator, tn);
                defer allocator.free(tn_e);
                try xml.print(allocator, "      <tool_name>{s}</tool_name>\n", .{tn_e});
            }
        }
        if (want_full and full_ids_set.contains(m.id)) {
            const content_e = try xmlEscape(allocator, m.content);
            defer allocator.free(content_e);
            try xml.print(allocator, "      <content>{s}</content>\n", .{content_e});
        }
        try xml.appendSlice(allocator, "    </entry>\n");
    }

    try xml.appendSlice(allocator, "  </message_index>\n</search_history>\n");
    return try xml.toOwnedSlice(allocator);
}

pub fn toXmlSuccess(allocator: std.mem.Allocator, inner: []const u8) ![]u8 {
    return allocator.dupe(u8, inner);
}

pub fn toXmlError(allocator: std.mem.Allocator, err_msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, err_msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<search_history><error>{s}</error></search_history>",
        .{escaped});
}