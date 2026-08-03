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
///   Requires `query`. Optionally scope to `session_id`, paginate via
///   `offset` + `limit`, and filter by role/time range.
/// - "session": fetch messages for a specific `session_id`. Optional
///   `message_ids` to also return full <content> for those ids (capped
///   at `MAX_MESSAGE_IDS` for context safety). Order by `order` to
///   browse chronologically forward or most-recent-first.
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
    /// Capped at `MAX_MESSAGE_IDS` (50) — passing more returns an error
    /// so the LLM can split the request.
    ///
    /// In mode="text", `message_ids` is also accepted: when non-empty,
    /// the response includes the full <content> for the matching ids
    /// alongside the FTS hit snippets. Avoids the mode-switch dance
    /// when the LLM wants both the snippet AND the full body.
    message_ids: []const u8 = "",
    /// Optional exact-match role filter.
    role: []const u8 = "",
    /// Optional lower bound on created_at (inclusive). YYYY-MM-DD HH:MM:SS.
    since: []const u8 = "",
    /// Optional upper bound on created_at (inclusive).
    until: []const u8 = "",
    /// When true, restrict to rows with `is_feed_to_llm = 1` (currently in
    /// the LLM's live context). Mutually exclusive with `compacted_only`.
    live_only: bool = false,
    /// When true, restrict to rows with `is_feed_to_llm = 0` (dropped from
    /// the LLM's context by compaction). Mutually exclusive with
    /// `live_only`.
    compacted_only: bool = false,
    /// Optional exact-match filter on `tool_name`. Useful for "find every
    /// bash invocation that ran `cargo test`".
    tool_name: []const u8 = "",
    /// Optional exact-match filter on `parent_session_id`. Useful for
    /// sub-agent debugging — find every message in any session whose parent
    /// is the given session_id.
    parent_session_id: []const u8 = "",
    /// Optional exact-match filter on `agent`. Useful when one session has
    /// multiple agents (planning vs chat vs sub-agent).
    agent: []const u8 = "",
    /// Optional relative lower bound, e.g. `"1h"`, `"30m"`, `"2d"`, `"1w"`.
    /// Mutually exclusive with `since`. Expanded to an absolute ISO string
    /// at the tool boundary.
    since_relative: []const u8 = "",
    /// Optional relative upper bound. Same units as `since_relative`.
    /// Mutually exclusive with `until`.
    until_relative: []const u8 = "",
    /// Sugar: `"1h"` resolves to `since = now - 1h`, `until = now`.
    /// Mutually exclusive with `since`, `until`, `since_relative`, and
    /// `until_relative`. Useful for "give me the last hour".
    relative_window: []const u8 = "",
    /// Max rows to return. Defaults to 20; tool layer caps at 200.
    limit: u32 = 20,
    /// Skip the first N results. mode="text" only — used to paginate
    /// through FTS results when there are more than `limit` matches.
    /// Combine with `<total_count>` in the response to know when to
    /// stop. mode="session" ignores this field (use `since` to paginate
    /// forward through chronological results).
    offset: u32 = 0,
    /// Order direction for mode="session". "asc" (chronological forward,
    /// default) or "desc" (most-recent-first — useful when browsing the
    /// tail of a long session). mode="text" always orders by FTS rank.
    order: []const u8 = "asc",
};

/// Hard cap on how many `message_ids` the LLM can request at once.
/// Prevents a single call from dumping megabytes of full <content>
/// into the context. If the LLM needs more, it should split into
/// batches — the response includes `<count>` + `<total_count>` so it
/// can paginate by hand.
pub const MAX_MESSAGE_IDS: u32 = 50;

/// Hard cap on bytes of full <content> per individual message. When a
/// requested message_id's content exceeds this, the response includes
/// the first `MAX_FULL_CONTENT_BYTES` bytes plus a `truncated="1"` flag
/// so the LLM knows there's more. Default: 16 KB — large enough for
/// most prose, small enough that 50 messages × 16 KB = 800 KB worst case
/// (still bounded).
pub const MAX_FULL_CONTENT_BYTES: u32 = 16 * 1024;

pub const search_history_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search_history",
        .description =
            \\Search the full conversation history stored on disk — including messages compacted out of the live context — either by full-text query or by fetching a specific session's messages.
            \\
            \\TWO MODES:
            \\- mode="text": full-text search over message content using SQLite FTS5. Provide `query`. Optionally scope to one `session_id`, filter by `role`, `since`/`until`, and paginate with `offset` + `limit`. Returns ranked matches with a preview snippet — use this when you remember *what* was said but not *where*. For long result sets, read <total_count> and call again with offset=N until offset + count >= total_count.
            \\- mode="session": list (or fetch) messages belonging to one `session_id`. Returns ALL messages for the session — both those still in your live context (`is_feed_to_llm=1`) and those dropped by compaction (`is_feed_to_llm=0`). Returns an index (id, role, created_at, preview) by default; pass specific `message_ids` (up to 50) to also get the full <content> body for those entries. Use `order="desc"` for most-recent-first. Use `since` / `until` to paginate forward.
            \\
            \\Response shape (both modes):
            \\- <count>: number of entries in THIS response (page size).
            \\- <total_count>: total matching entries before pagination. Use to know whether more pages exist.
            \\- mode="session" with message_ids: per-message <content> is truncated to 16 KB; a `truncated="1"` attribute on <content> indicates there's more. Call again with a narrower message_ids list to fetch the rest.
            \\
            \\Filters (optional, apply to both modes):
            \\- role: "user", "assistant", or "tool" — exact match.
            \\- since / until: YYYY-MM-DD HH:MM:SS (inclusive).
            \\- limit: max rows to return (default 20, max 200).
            \\- offset: mode="text" only — skip first N matches for pagination.
            \\- order: mode="session" only — "asc" (chronological forward, default) or "desc" (most-recent-first).
            \\
            \\Example (text search): {"mode": "text", "query": "login bug fix"}
            \\Example (text search page 2): {"mode": "text", "query": "login bug", "offset": 20}
            \\Example (text search scoped): {"mode": "text", "query": "login bug", "session_id": "s_42"}
            \\Example (session browse): {"mode": "session", "session_id": "s_42"}
            \\Example (session recent first): {"mode": "session", "session_id": "s_42", "order": "desc"}
            \\Example (session full fetch): {"mode": "session", "session_id": "s_42", "message_ids": "h_1781,h_1782"}
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "mode", .type = "string", .description = "'text' (FTS5 full-text search, default) or 'session' (fetch by session_id)." },
                .{ .name = "query", .type = "string", .description = "Required for mode='text'. FTS5 search query." },
                .{ .name = "session_id", .type = "string", .description = "Required for mode='session'. Optional scope filter for mode='text'." },
                .{ .name = "message_ids", .type = "string", .description = "mode='session' only. Comma-separated ids to also fetch full <content> for. Capped at 50 per call — split into batches for more." },
                .{ .name = "role", .type = "string", .description = "Optional exact-match role filter: 'user', 'assistant', or 'tool'." },
                .{ .name = "since", .type = "string", .description = "Optional lower bound on created_at (inclusive). YYYY-MM-DD HH:MM:SS." },
                .{ .name = "until", .type = "string", .description = "Optional upper bound on created_at (inclusive)." },
                .{ .name = "limit", .type = "number", .description = "Max rows to return. Default 20, max 200." },
                .{ .name = "offset", .type = "number", .description = "mode='text' only. Skip first N matches for pagination. Combine with <total_count> in the response to walk through long result sets." },
                .{ .name = "order", .type = "string", .description = "mode='session' only. 'asc' (chronological forward, default) or 'desc' (most-recent-first)." },
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

    // Validate: live_only / compacted_only are mutually exclusive.
    if (input.live_only and input.compacted_only) {
        return errorXml(allocator,
            "live_only and compacted_only are mutually exclusive — pick one or neither.");
    }

    // Resolve the effective feed filter from the two bool flags.
    const feed_filter: llm_history.FeedFilter = if (input.live_only)
        .live_only
    else if (input.compacted_only)
        .compacted_only
    else
        .all;

    const effective_limit = @min(input.limit, 200);

    if (is_text_mode) {
        const opts = llm_history.SearchOptions{
            .session_id = if (input.session_id.len > 0) input.session_id else null,
            .role = if (input.role.len > 0) input.role else null,
            .since = if (input.since.len > 0) input.since else null,
            .until = if (input.until.len > 0) input.until else null,
            .feed_filter = feed_filter,
            .tool_name = if (input.tool_name.len > 0) input.tool_name else null,
            .parent_session_id = if (input.parent_session_id.len > 0) input.parent_session_id else null,
            .agent = if (input.agent.len > 0) input.agent else null,
            .limit = effective_limit,
            .offset = if (input.offset > 0) input.offset else null,
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

        // `total_count` is the same on every row (it's COUNT(*) OVER ()
        // computed before LIMIT/OFFSET). Read it from the first hit;
        // fall back to 0 if the result set is empty.
        const total_count: u32 = if (hits.len > 0) hits[0].total_count else 0;

        var xml: std.ArrayList(u8) = .empty;
        errdefer xml.deinit(allocator);

        // The escaped-query string is bound to a local so the allocation
        // can be tracked and freed — passing the inline `try xmlEscape(...)`
        // directly as a {s} arg to xml.print would leak it (the result is
        // a heap-owned slice with no name to bind a defer to).
        const escaped_query = try xmlEscape(allocator, input.query);
        defer allocator.free(escaped_query);
        try xml.print(allocator,
            "<search_history mode=\"text\" offset=\"{d}\" limit=\"{d}\">\n" ++
            "  <query>{s}</query>\n" ++
            "  <count>{d}</count>\n" ++
            "  <total_count>{d}</total_count>\n" ++
            "  <results>\n",
            .{ input.offset, effective_limit, escaped_query, hits.len, total_count });
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

    // Context-safety cap: if the LLM asks for full content for too many
    // ids at once, the response can easily blow past the prompt budget.
    // Reject with a clear hint to split into batches.
    if (parsed_ids.len > MAX_MESSAGE_IDS) {
        const msg = try std.fmt.allocPrint(allocator,
            "Too many message_ids ({d} > max {d}). Split into batches of {d} or fewer.",
            .{ parsed_ids.len, MAX_MESSAGE_IDS, MAX_MESSAGE_IDS });
        defer allocator.free(msg);
        return errorXml(allocator, msg);
    }
    const want_full = parsed_ids.len > 0;

    // Parse `order` string. Default to `.asc` for empty/unknown — never
    // reject the call just because the LLM mistyped "desc" vs "descending".
    const order_enum: llm_history.CompactedMessagesOptions.Order = blk: {
        if (std.mem.eql(u8, input.order, "desc")) break :blk .desc;
        break :blk .asc; // covers "" (default) and any unknown value
    };

    const opts = llm_history.CompactedMessagesOptions{
        .message_ids = if (want_full) parsed_ids else null,
        .role = if (input.role.len > 0) input.role else null,
        .since = if (input.since.len > 0) input.since else null,
        .until = if (input.until.len > 0) input.until else null,
        .tool_name = if (input.tool_name.len > 0) input.tool_name else null,
        .parent_session_id = if (input.parent_session_id.len > 0) input.parent_session_id else null,
        .agent = if (input.agent.len > 0) input.agent else null,
        .limit = effective_limit,
        // mode="session" returns the FULL conversation history (live +
        // compacted), not just compacted messages. The agent may want
        // to re-read something still in its live context, or browse the
        // whole session regardless of compaction state. The `live_only` /
        // `compacted_only` flags override this default — when set, the
        // user is specifically asking for one or the other.
        .feed_filter = if (input.live_only)
            .live_only
        else if (input.compacted_only)
            .compacted_only
        else
            .all,
        .order = order_enum,
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

    // `total_count` is the same on every row. Read from the first hit
    // (or 0 if empty) — computed before LIMIT by `COUNT(*) OVER ()`.
    const total_count: u32 = if (messages.len > 0) messages[0].total_count else 0;

    var full_ids_set: std.StringHashMapUnmanaged(void) = .empty;
    defer full_ids_set.deinit(allocator);
    if (want_full) for (parsed_ids) |id| try full_ids_set.put(allocator, id, {});

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    // Bind escaped session_id to a local so the allocation can be freed —
    // same leak pattern as the text-mode header above.
    const escaped_session_id = try xmlEscape(allocator, input.session_id);
    defer allocator.free(escaped_session_id);
    try xml.print(allocator,
        "<search_history mode=\"session\" order=\"{s}\">\n" ++
        "  <session_id>{s}</session_id>\n" ++
        "  <count>{d}</count>\n" ++
        "  <total_count>{d}</total_count>\n" ++
        "  <message_index>\n",
        .{ @tagName(order_enum), escaped_session_id, messages.len, total_count });

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
            // Truncate full content to MAX_FULL_CONTENT_BYTES so a single
            // huge message can't blow the context budget. The `truncated`
            // attribute tells the LLM there's more (the next call with a
            // narrower message_ids set can fetch the rest, but for now we
            // keep it simple — 16 KB is enough for most prose responses).
            const was_truncated = m.content.len > MAX_FULL_CONTENT_BYTES;
            const content_src: []const u8 = if (was_truncated)
                m.content[0..MAX_FULL_CONTENT_BYTES]
            else
                m.content;
            const content_e = try xmlEscape(allocator, content_src);
            defer allocator.free(content_e);
            try xml.print(allocator,
                "      <content truncated=\"{c}\">{s}</content>\n",
                .{ @as(u8, if (was_truncated) '1' else '0'), content_e });
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