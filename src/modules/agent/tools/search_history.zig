const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;
const helpers = @import("helpers");
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

pub const search_history_tool_system_prompt =
    \\## Search History Tool — Behavior
    \\Use `search_history` to search past conversation history (including compacted-out messages).
    \\- `mode="text"` for FTS search with `query`; `mode="session"` to fetch a session's messages.
    \\- Prefer filters (`tool_name`, `role`, `parent_session_id`) over broad queries. Paginate with `offset`/`limit`.
    \\
;

pub const search_history_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search_history",
        .description =
            \\Search the full conversation history stored on disk — including messages compacted out of the live context — either by full-text query or by fetching a specific session's messages.
            \\
            \\TWO MODES:
            \\- mode="text": full-text search over message content using SQLite FTS5. Provide `query`. Optionally scope to one `session_id`, filter by `role`/`tool_name`/`parent_session_id`/`agent`, time-bound via `since`/`until` (or the relative shortcuts `since_relative`/`until_relative`/`relative_window`), restrict to live or compacted rows via `live_only`/`compacted_only`, and paginate with `offset` + `limit`. Returns ranked matches with a preview snippet — use this when you remember *what* was said but not *where*. For long result sets, read <total_count> and call again with offset=N until offset + count >= total_count.
            \\- mode="session": list (or fetch) messages belonging to one `session_id`. Returns ALL messages for the session — both those still in your live context (`is_feed_to_llm=1`) and those dropped by compaction (`is_feed_to_llm=0`). Returns an index (id, role, created_at, preview) by default; pass specific `message_ids` (up to 50) to also get the full <content> body for those entries. Use `order="desc"` for most-recent-first. Use `since` / `until` to paginate forward.
            \\
            \\FTS QUERY SANITIZATION: queries with `.`, `-`, `:`, `*`, `^`, `(`, `)`, `"`, `+` are auto-sanitized — you can write `handle_tool.zig` or `AGENTS.md` without pre-escaping. Multi-word queries are joined with FTS5 OR (`a b` matches rows containing `a` OR `b`) for natural recall.
            \\
            \\Response shape (both modes):
            \\- <count>: number of entries in THIS response (page size).
            \\- <total_count>: total matching entries before pagination. Use to know whether more pages exist.
            \\- mode="session" with message_ids: per-message <content> is truncated to 16 KB; a `truncated="1"` attribute on <content> indicates there's more. Call again with a narrower message_ids list to fetch the rest.
            \\
            \\Filters (optional, apply to both modes unless noted):
            \\- role: "user", "assistant", or "tool" — exact match.
            \\- tool_name (mode="text"): exact-match filter on the tool that produced the row. Useful for "find every bash invocation that ran `cargo test`".
            \\- parent_session_id: exact-match filter on sub-agent sessions. Useful for "show me every message in the sub-agent that was spawned for X".
            \\- agent: exact-match filter on the agent name (e.g. "main", "planning", "compaction"). Useful when one session has multiple agents.
            \\- live_only / compacted_only (mutually exclusive): restrict to messages still in your live context (is_feed_to_llm=1) vs. dropped by compaction (is_feed_to_llm=0). Default returns both.
            \\- since / until: YYYY-MM-DD HH:MM:SS inclusive bounds on created_at.
            \\- since_relative / until_relative: shorthand like "1h", "30m", "2d", "1w". Mutually exclusive with `since`/`until`.
            \\- relative_window: sugar for "since = now - X, until = now". Mutually exclusive with all other time params.
            \\- limit: max rows to return (default 20, max 200).
            \\- offset: mode="text" only — skip first N matches for pagination.
            \\- order: mode="session" only — "asc" (chronological forward, default) or "desc" (most-recent-first).
            \\
            \\Example (text search): {"mode": "text", "query": "login bug fix"}
            \\Example (text search page 2): {"mode": "text", "query": "login bug", "offset": 20}
            \\Example (text search scoped): {"mode": "text", "query": "login bug", "session_id": "s_42"}
            \\Example (text search by tool): {"mode": "text", "query": "test", "tool_name": "bash"}
            \\Example (text search recent hour): {"mode": "text", "query": "error", "relative_window": "1h"}
            \\Example (text search live only): {"mode": "text", "query": "todo", "live_only": true}
            \\Example (session browse): {"mode": "session", "session_id": "s_42"}
            \\Example (session recent first): {"mode": "session", "session_id": "s_42", "order": "desc"}
            \\Example (session full fetch): {"mode": "session", "session_id": "s_42", "message_ids": "h_1781,h_1782"}
            \\Example (sub-agent trace): {"mode": "session", "session_id": "s_subA", "parent_session_id": "s_main"}
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "mode", .type = "string", .description = "'text' (FTS5 full-text search, default) or 'session' (fetch by session_id)." },
                .{ .name = "query", .type = "string", .description = "Required for mode='text'. FTS5 search query (auto-sanitized)." },
                .{ .name = "session_id", .type = "string", .description = "Required for mode='session'. Optional scope filter for mode='text'." },
                .{ .name = "message_ids", .type = "string", .description = "Comma-separated ids. mode='session': fetch full <content> for these ids. mode='text': fetch full <content> for these ids alongside the FTS hit snippets. Both modes capped at 50 per call — split into batches for more." },
                .{ .name = "role", .type = "string", .description = "Optional exact-match role filter: 'user', 'assistant', or 'tool'." },
                .{ .name = "tool_name", .type = "string", .description = "Optional exact-match filter on tool_name (mode='text'). Useful for finding every bash / read_file / search invocation." },
                .{ .name = "parent_session_id", .type = "string", .description = "Optional exact-match filter on parent_session_id. Useful for tracing a sub-agent's full session." },
                .{ .name = "agent", .type = "string", .description = "Optional exact-match filter on agent name (e.g. 'main', 'planning', 'compaction'). Useful when one session has multiple agents." },
                .{ .name = "live_only", .type = "boolean", .description = "If true, restrict to messages still in the LLM's live context (is_feed_to_llm=1). Mutually exclusive with compacted_only." },
                .{ .name = "compacted_only", .type = "boolean", .description = "If true, restrict to messages dropped by compaction (is_feed_to_llm=0). Mutually exclusive with live_only." },
                .{ .name = "since", .type = "string", .description = "Optional lower bound on created_at (inclusive). YYYY-MM-DD HH:MM:SS." },
                .{ .name = "until", .type = "string", .description = "Optional upper bound on created_at (inclusive)." },
                .{ .name = "since_relative", .type = "string", .description = "Optional relative lower bound (e.g. '1h', '30m', '2d', '1w'). Mutually exclusive with since." },
                .{ .name = "until_relative", .type = "string", .description = "Optional relative upper bound. Same units as since_relative." },
                .{ .name = "relative_window", .type = "string", .description = "Sugar for 'since = now - X, until = now'. Mutually exclusive with all other time params." },
                .{ .name = "limit", .type = "number", .description = "Max rows to return. Default 20, max 200." },
                .{ .name = "offset", .type = "number", .description = "mode='text' only. Skip first N matches for pagination. Combine with <total_count> in the response to walk through long result sets." },
                .{ .name = "order", .type = "string", .description = "mode='session' only. 'asc' (chronological forward, default) or 'desc' (most-recent-first)." },
            },
            .required = &.{},
        },
        .system_prompt = search_history_tool_system_prompt,
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

        // Optional: full <content> for specific ids alongside the FTS hits.
        // Same `message_ids` field as mode="session" — capped at
        // MAX_MESSAGE_IDS. Avoids the mode-switch dance when the LLM wants
        // both snippets AND bodies in one round-trip.
        const text_parsed_ids = try parseMessageIds(allocator, input.message_ids);
        defer {
            for (text_parsed_ids) |id| allocator.free(id);
            allocator.free(text_parsed_ids);
        }
        if (text_parsed_ids.len > MAX_MESSAGE_IDS) {
            const msg = try std.fmt.allocPrint(allocator,
                "Too many message_ids ({d} > max {d}). Split into batches of {d} or fewer.",
                .{ text_parsed_ids.len, MAX_MESSAGE_IDS, MAX_MESSAGE_IDS });
            defer allocator.free(msg);
            return errorXml(allocator, msg);
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
        try xml.appendSlice(allocator, "  </results>\n");

        // Full content block — only rendered when message_ids was provided.
        if (text_parsed_ids.len > 0) {
            // Lookup by id alone (no session_id filter). The LLM is asking
            // for specific ids — scoping by session would be wrong if the
            // LLM learned the id from a different scope (e.g. cross-session
            // search). Use getMessagesByIds, the new no-session-filter
            // helper.
            const full_messages = llm_history.getMessagesByIds(allocator, db, text_parsed_ids) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Database query failed: {s}", .{@errorName(err)});
                defer allocator.free(msg);
                return errorXml(allocator, msg);
            };
            defer {
                for (full_messages) |m| {
                    var copy = m;
                    copy.deinit(allocator);
                }
                allocator.free(full_messages);
            }

            // Index the requested ids for O(1) lookup of which body
            // corresponds to which request.
            var text_full_ids_set: std.StringHashMapUnmanaged(void) = .empty;
            defer text_full_ids_set.deinit(allocator);
            for (text_parsed_ids) |id| try text_full_ids_set.put(allocator, id, {});

            try xml.appendSlice(allocator, "  <full_contents>\n");
            for (full_messages) |m| {
                if (!text_full_ids_set.contains(m.id)) continue;
                const id_e = try xmlEscape(allocator, m.id);
                defer allocator.free(id_e);
                const role_e = try xmlEscape(allocator, m.role);
                defer allocator.free(role_e);

                try xml.appendSlice(allocator, "    <entry>\n");
                try xml.print(allocator, "      <id>{s}</id>\n", .{id_e});
                try xml.print(allocator, "      <session_id>{s}</session_id>\n", .{m.session_id});
                try xml.print(allocator, "      <role>{s}</role>\n", .{role_e});
                if (m.created_at.len > 0) {
                    const ca_e = try xmlEscape(allocator, m.created_at);
                    defer allocator.free(ca_e);
                    try xml.print(allocator, "      <created_at>{s}</created_at>\n", .{ca_e});
                }
                // Truncate to MAX_FULL_CONTENT_BYTES (same convention as mode="session").
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
                try xml.appendSlice(allocator, "    </entry>\n");
            }
            try xml.appendSlice(allocator, "  </full_contents>\n");
        }

        try xml.appendSlice(allocator, "</search_history>\n");
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

const testing = std.testing;
const sh = @import("search_history.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  role TEXT,
        \\  tool_call_id TEXT,
        \\  tool_name TEXT,
        \\  is_feed_to_llm INTEGER DEFAULT 1,
        \\  agent TEXT,
        \\  created_at_nano TEXT DEFAULT (datetime('now')),
        \\  -- Mirrors Migration 059 in production: a regular TEXT column.
        \\  -- No INSERT trigger — production populates it from application
        \\  -- code in `saveMessage`. Default to `now` localtime so tests that
        \\  -- don't specify `created_iso` get a sensible value matching
        \\  -- `created_at`'s default of `datetime('now')`.
        \\  created_iso TEXT DEFAULT (strftime('%Y-%m-%d %H:%M:%S', 'now'))
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE VIRTUAL TABLE messages_fts USING fts5(
        \\    content
        \\)
    , &.{});
    // Sync triggers (same shape as Migration 058 in production).
    try db.exec(alloc,
        \\CREATE TRIGGER llm_history_ai AFTER INSERT ON llm_history BEGIN
        \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
        \\END
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "execute_search_history: mode=text returns FTS hits with snippets" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_1','user','the login bug needs fixing')", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "login bug",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<search_history mode=\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<query>login bug</query>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<snippet>") != null);
    // total_count is included in the text-mode header.
    try testing.expect(std.mem.indexOf(u8, xml, "<total_count>") != null);
}

test "execute_search_history: mode=session returns ALL messages (live + compacted) for session_id" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live_h','s_X','user','Fix login (live)',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact_h','s_X','assistant','On it (compacted)',0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('other_h','s_other','user','different session',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_X",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<search_history mode=\"session\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<session_id>s_X</session_id>") != null);
    // BOTH the live and compacted rows for s_X are present.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>live_h</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>compact_h</id>") != null);
    // Other session is excluded.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>other_h</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>2</count>") != null);
    // total_count reflects the count of rows that matched (same as count
    // here, since both rows fit in the default limit of 200).
    try testing.expect(std.mem.indexOf(u8, xml, "<total_count>2</total_count>") != null);
}

test "execute_search_history: mode=session with message_ids includes full <content>" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h1','s_X','user','Fix login bug',0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h2','s_X','assistant','On it now',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_X",
        .message_ids = "h1",
    });
    defer alloc.free(xml);

    // The full <content> is wrapped with a truncated="..." attribute
    // (the attribute is "0" because the content fits under MAX_FULL_CONTENT_BYTES).
    try testing.expect(std.mem.indexOf(u8, xml, "<content truncated=\"0\">Fix login bug</content>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h2</id>") == null);
}

test "execute_search_history: invalid mode returns error XML" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "bogus",
        .query = "anything",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "Invalid mode") != null);
}

test "execute_search_history: mode=text with empty query returns error" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "requires non-empty query") != null);
}

test "execute_search_history: mode=session with empty session_id returns error" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "requires non-empty session_id") != null);
}

test "toXmlSuccess and toXmlError produce well-formed XML envelopes" {
    const alloc = testing.allocator;
    const inner = try sh.toXmlSuccess(alloc, "<inner/>");
    defer alloc.free(inner);
    try testing.expectEqualStrings("<inner/>", inner);

    const err_xml = try sh.toXmlError(alloc, "boom");
    defer alloc.free(err_xml);
    try testing.expect(std.mem.indexOf(u8, err_xml, "<search_history>") != null);
    try testing.expect(std.mem.indexOf(u8, err_xml, "<error>boom</error>") != null);
}

test "execute_search_history: mode=text response includes total_count" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 5 matching rows
    for (0..5) |i| {
        const id_buf = try std.fmt.allocPrint(alloc, "h{d}", .{i});
        defer alloc.free(id_buf);
        try s.db.exec(alloc,
            "INSERT INTO llm_history (id, session_id, role, response_content) " ++
            "VALUES (?, 's1', 'user', 'fix login bug')", &.{id_buf});
    }
    // 1 non-matching row (sanity check)
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('other','s1','user','unrelated text')", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "login bug",
    });
    defer alloc.free(xml);

    // 5 hits returned, total_count = 5 (same — all fit in the page)
    try testing.expect(std.mem.indexOf(u8, xml, "<count>5</count>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<total_count>5</total_count>") != null);
}

test "execute_search_history: mode=text offset paginates FTS results" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 5 matching rows
    for (0..5) |i| {
        const id_buf = try std.fmt.allocPrint(alloc, "h{d}", .{i});
        defer alloc.free(id_buf);
        try s.db.exec(alloc,
            "INSERT INTO llm_history (id, session_id, role, response_content) " ++
            "VALUES (?, 's1', 'user', 'fix login bug')", &.{id_buf});
    }

    // Page 1: limit=2, no offset → first 2 hits
    const page1 = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "login bug",
        .limit = 2,
    });
    defer alloc.free(page1);

    // Page 2: limit=2, offset=2 → next 2 hits (different ids)
    const page2 = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "login bug",
        .limit = 2,
        .offset = 2,
    });
    defer alloc.free(page2);

    // Both pages must show count=2 + total_count=5 (offset doesn't change total).
    try testing.expect(std.mem.indexOf(u8, page1, "<count>2</count>") != null);
    try testing.expect(std.mem.indexOf(u8, page1, "<total_count>5</total_count>") != null);
    try testing.expect(std.mem.indexOf(u8, page1, "offset=\"0\"") != null);
    try testing.expect(std.mem.indexOf(u8, page2, "<count>2</count>") != null);
    try testing.expect(std.mem.indexOf(u8, page2, "<total_count>5</total_count>") != null);
    try testing.expect(std.mem.indexOf(u8, page2, "offset=\"2\"") != null);

    // Pages must contain DIFFERENT ids (otherwise pagination didn't work).
    const p1_ids = [_][]const u8{ "<id>h0</id>", "<id>h1</id>", "<id>h2</id>", "<id>h3</id>", "<id>h4</id>" };
    var page1_first_id: ?[]const u8 = null;
    for (p1_ids) |needle| {
        if (std.mem.indexOf(u8, page1, needle) != null) {
            page1_first_id = needle;
            break;
        }
    }
    try testing.expect(page1_first_id != null);
    // The first id on page2 must be DIFFERENT from the first on page1
    // AND must be present on page2.
    var found_diff = false;
    for (p1_ids) |needle| {
        if (std.mem.eql(u8, needle, page1_first_id.?)) continue;
        if (std.mem.indexOf(u8, page2, needle) != null) {
            found_diff = true;
            break;
        }
    }
    try testing.expect(found_diff);
}

test "execute_search_history: mode=session order=desc returns most recent first" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 3 messages with explicit, increasing created_at to make order deterministic.
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm, created_at_nano) " ++
        "VALUES ('first','s_Z','user','first msg',1,'2026-01-01 10:00:00')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm, created_at_nano) " ++
        "VALUES ('middle','s_Z','user','middle msg',1,'2026-01-02 10:00:00')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm, created_at_nano) " ++
        "VALUES ('last','s_Z','user','last msg',1,'2026-01-03 10:00:00')", &.{});

    const xml_asc = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_Z",
    });
    defer alloc.free(xml_asc);
    const xml_desc = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_Z",
        .order = "desc",
    });
    defer alloc.free(xml_desc);

    // Order attribute is rendered in the header.
    try testing.expect(std.mem.indexOf(u8, xml_asc, "order=\"asc\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml_desc, "order=\"desc\"") != null);

    // Asc: <id>first appears BEFORE <id>middle in the XML
    const asc_first_pos = std.mem.indexOf(u8, xml_asc, "<id>first</id>").?;
    const asc_middle_pos = std.mem.indexOf(u8, xml_asc, "<id>middle</id>").?;
    const asc_last_pos = std.mem.indexOf(u8, xml_asc, "<id>last</id>").?;
    try testing.expect(asc_first_pos < asc_middle_pos);
    try testing.expect(asc_middle_pos < asc_last_pos);

    // Desc: <id>last appears BEFORE <id>middle BEFORE <id>first
    const desc_last_pos = std.mem.indexOf(u8, xml_desc, "<id>last</id>").?;
    const desc_middle_pos = std.mem.indexOf(u8, xml_desc, "<id>middle</id>").?;
    const desc_first_pos = std.mem.indexOf(u8, xml_desc, "<id>first</id>").?;
    try testing.expect(desc_last_pos < desc_middle_pos);
    try testing.expect(desc_middle_pos < desc_first_pos);
}

test "execute_search_history: mode=session message_ids > MAX_MESSAGE_IDS returns error XML" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Insert 60 messages so we can request 51 ids.
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const id_buf = try std.fmt.allocPrint(alloc, "h{d}", .{i});
        defer alloc.free(id_buf);
        try s.db.exec(alloc,
            "INSERT INTO llm_history (id, session_id, role, response_content) " ++
            "VALUES (?, 's_big', 'user', 'msg')", &.{id_buf});
    }

    // Build a CSV of 51 ids (one over the cap of 50). Each id is at most
    // 3 chars + 1 comma, so 51 * 4 = 204 bytes max.
    var csv_buf: [256]u8 = undefined;
    var csv_len: usize = 0;
    i = 0;
    while (i < 51) : (i += 1) {
        const part = try std.fmt.bufPrint(csv_buf[csv_len..], "{s}h{d}", .{
            if (i > 0) "," else "",
            i,
        });
        csv_len += part.len;
    }
    const csv: []const u8 = csv_buf[0..csv_len];

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_big",
        .message_ids = csv,
    });
    defer alloc.free(xml);

    // Should be an error, not a normal session response.
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "Too many message_ids") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<message_index>") == null);
}

test "execute_search_history: mode=session full <content> > MAX_FULL_CONTENT_BYTES is truncated with truncated=\"1\"" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Build a single message with content > 16 KB.
    const huge_content = try alloc.alloc(u8, sh.MAX_FULL_CONTENT_BYTES + 1024);
    defer alloc.free(huge_content);
    @memset(huge_content, 'x');

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('big','s_big','assistant',?,0)", &.{huge_content});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_big",
        .message_ids = "big",
    });
    defer alloc.free(xml);

    // truncated="1" must be set when content exceeds MAX_FULL_CONTENT_BYTES.
    try testing.expect(std.mem.indexOf(u8, xml, "<content truncated=\"1\">") != null);

    // The serialized <content> body should be at most MAX_FULL_CONTENT_BYTES
    // bytes (the body is escaped, so just count the opening tag → closing tag
    // distance via finding the substring '<content truncated="1">' and the
    // next '</content>'). The exact escape length is MAX_FULL_CONTENT_BYTES
    // (no special chars in 'x' * N).
    const start_tag = "<content truncated=\"1\">";
    const end_tag = "</content>";
    const start = std.mem.indexOf(u8, xml, start_tag).? + start_tag.len;
    const end = std.mem.indexOf(u8, xml, end_tag).?;
    const body_len = end - start;
    try testing.expect(body_len == sh.MAX_FULL_CONTENT_BYTES);
}

test "execute_search_history: mode=session full <content> < MAX_FULL_CONTENT_BYTES sets truncated=\"0\"" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Small content (< 100 bytes — well under MAX_FULL_CONTENT_BYTES).
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('small','s_X','user','short content',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_X",
        .message_ids = "small",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<content truncated=\"0\">short content</content>") != null);
}

// =============================================================================
// Chunk 1 — is_feed_to_llm filter (live_only / compacted_only)
// =============================================================================

test "execute_search_history: mode=text live_only=true returns only live rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 1 live + 1 compacted + 1 live (different session) — query is "keyword"
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live1','s_H','user','keyword hit live',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact1','s_H','user','keyword hit compacted',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "keyword",
        .live_only = true,
    });
    defer alloc.free(xml);

    // Only live row is in the result.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>live1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>compact1</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>1</count>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<total_count>1</total_count>") != null);
}

test "execute_search_history: mode=text compacted_only=true returns only compacted rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live1','s_H','user','keyword hit live',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact1','s_H','user','keyword hit compacted',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "keyword",
        .compacted_only = true,
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<id>live1</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>compact1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>1</count>") != null);
}

test "execute_search_history: mode=session live_only=true returns only live rows for session" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live1','s_H','user','live msg',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact1','s_H','assistant','compacted msg',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_H",
        .live_only = true,
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<id>live1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>compact1</id>") == null);
}

test "execute_search_history: mode=session compacted_only=true returns only compacted rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live1','s_H','user','live msg',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact1','s_H','assistant','compacted msg',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_H",
        .compacted_only = true,
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<id>live1</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>compact1</id>") != null);
}

test "execute_search_history: mode=text live_only and compacted_only both true returns error XML" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "anything",
        .live_only = true,
        .compacted_only = true,
    });
    defer alloc.free(xml);

    // Mutually exclusive — error and no <results> block.
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "mutually exclusive") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<results>") == null);
}

// =============================================================================
// Chunk 2 — tool_name filter
// =============================================================================

test "execute_search_history: mode=text tool_name=bash returns only bash rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 1 bash tool + 1 read_file tool + 1 user (no tool_name) — all match the query.
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, tool_name) " ++
        "VALUES ('bash_h','s_J','tool','grep result for keyword', 'bash')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, tool_name) " ++
        "VALUES ('read_h','s_J','tool','file contents keyword', 'read_file')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, tool_name) " ++
        "VALUES ('user_h','s_J','user','keyword in user msg', '')", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "keyword",
        .tool_name = "bash",
    });
    defer alloc.free(xml);

    // Only the bash row is in the result.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>bash_h</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>read_h</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>user_h</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>1</count>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<total_count>1</total_count>") != null);
}

test "execute_search_history: mode=session tool_name=read_file returns only read_file rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, tool_name) " ++
        "VALUES ('bash_h','s_K','tool','bash result', 'bash')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, tool_name) " ++
        "VALUES ('read_h','s_K','tool','file result', 'read_file')", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_K",
        .tool_name = "read_file",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<id>read_h</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>bash_h</id>") == null);
}

// =============================================================================
// Chunk 3 — parent_session_id filter
// =============================================================================
// The `parent_session_id` column is added to the test schema during the
// `addColumnIfMissing` style helpers used in higher-level fixtures. For our
// minimal test schema we add it via `ALTER TABLE` in each test that uses
// it (keeps the shared `setupDb()` from drifting).
//
// Note: the production schema does have the column. See Migration 012.

test "execute_search_history: mode=text parent_session_id filter restricts to sub-agent rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Add the parent_session_id column (production schema has it via Migration 012).
    try s.db.exec(alloc,
        "ALTER TABLE llm_history ADD COLUMN parent_session_id TEXT DEFAULT ''",
        &.{});

    // 1 sub-agent row + 1 main-agent row + 1 sub-agent of a different parent — all match query.
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, parent_session_id) " ++
        "VALUES ('sub_a1','s_subA','user','keyword in subA','s_parent')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, parent_session_id) " ++
        "VALUES ('main_h','s_main','user','keyword in main','')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, parent_session_id) " ++
        "VALUES ('sub_b1','s_subB','user','keyword in subB','s_other_parent')", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "keyword",
        .parent_session_id = "s_parent",
    });
    defer alloc.free(xml);

    // Only the row whose parent_session_id matches.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>sub_a1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>main_h</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>sub_b1</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>1</count>") != null);
}

// =============================================================================
// Chunk 4 — full content in mode="text"
// =============================================================================
// `message_ids` accepted in mode="text". When non-empty, the response
// includes full <content> for those ids alongside the FTS hit snippets.

test "execute_search_history: mode=text with message_ids includes full content for those ids" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 2 hits, 1 non-hit
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h1','s_T','user','fix login bug',0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h2','s_T','assistant','on it now',0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h3','s_T','user','unrelated',0)", &.{});

    // Ask for full content for h1 + h2 (both match + non-match would still
    // be returned if requested). h3 is NOT in message_ids — full content
    // is omitted even though it could match the FTS query (it doesn't).
    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "login",
        .message_ids = "h1,h2",
    });
    defer alloc.free(xml);

    // mode="text" header still includes the FTS hit count (only h1 matches "login").
    try testing.expect(std.mem.indexOf(u8, xml, "<count>1</count>") != null);
    // h1 is a FTS hit AND a requested message_id → present in <results>.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h1</id>") != null);
    // h3 is NOT a requested id → never appears.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h3</id>") == null);
    // The full_contents block IS rendered when message_ids is provided.
    // Per-row content rendering is exercised by separate unit tests on
    // `getMessagesByIds` in `llm_history_messages_by_ids_test.zig`.
    try testing.expect(std.mem.indexOf(u8, xml, "<full_contents>") != null);
}

test "execute_search_history: mode=text message_ids > MAX_MESSAGE_IDS returns error XML" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 60 messages
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const id_buf = try std.fmt.allocPrint(alloc, "h{d}", .{i});
        defer alloc.free(id_buf);
        try s.db.exec(alloc,
            "INSERT INTO llm_history (id, session_id, role, response_content) " ++
            "VALUES (?, 's_M', 'user', 'keyword hit')", &.{id_buf});
    }

    // 51 ids
    var csv_buf: [256]u8 = undefined;
    var csv_len: usize = 0;
    i = 0;
    while (i < 51) : (i += 1) {
        const part = try std.fmt.bufPrint(csv_buf[csv_len..], "{s}h{d}", .{
            if (i > 0) "," else "",
            i,
        });
        csv_len += part.len;
    }
    const csv: []const u8 = csv_buf[0..csv_len];

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "keyword",
        .message_ids = csv,
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "Too many message_ids") != null);
}
