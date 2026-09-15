const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;
const workspace_scope = nalarcore.workspace_scope;
const helpers = @import("helpers");
const xmlEscape = helpers.xml_escape;

/// Input for read_workspace_session.
///
/// ONE tool, four behaviors selected by which params are set:
/// - neither `query` nor `session_id` → LIST sessions in my workspace.
/// - `query` only → SEARCH message content across my workspace (FTS5).
/// - `session_id` only → READ that session's messages (same-workspace gate).
/// - BOTH → SEARCH-WITHIN: FTS restricted to that one session (still gated).
///
/// Scope is derived server-side from the calling session — there is no
/// `workspace_id` param (a client-supplied id would be a spoofing vector).
pub const ReadWorkspaceSessionInput = struct {
    /// Target session for READ / SEARCH-WITHIN. Must belong to the same
    /// workspace as the calling session or the call is denied.
    session_id: []const u8 = "",
    /// FTS5 query for SEARCH / SEARCH-WITHIN (auto-sanitized, OR recall).
    query: []const u8 = "",
    /// Comma-separated message ids. Returns full <content> for these ids
    /// (capped at `MAX_MESSAGE_IDS`). In SEARCH the lookup is restricted
    /// to workspace sessions — ids from other workspaces are skipped.
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
    /// Max rows to return. Defaults to 20; capped at 200 (LIST caps at 50).
    limit: u32 = 20,
    /// Skip the first N results. SEARCH only — used to paginate through
    /// FTS results when there are more than `limit` matches. Combine with
    /// `<total_count>` to know when to stop. READ ignores this field (use
    /// `since`/`until` to paginate chronologically).
    offset: u32 = 0,
    /// Order direction for READ. "asc" (chronological forward, default) or
    /// "desc" (most-recent-first). SEARCH always orders by FTS rank.
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
/// so the LLM knows there's more. Default: 16 KB.
pub const MAX_FULL_CONTENT_BYTES: u32 = 16 * 1024;

/// Hard cap on LIST rows. Discovery should stay cheap — the LLM can
/// SEARCH once it knows what to look for.
pub const MAX_LIST_LIMIT: u32 = 50;

pub const read_workspace_session_tool_system_prompt =
    \\## Read Workspace Session Tool — Behavior
    \\Use `read_workspace_session` to discover, search, and read OTHER chat sessions in YOUR workspace.
    \\- No args → LIST sessions in your workspace (names + previews so you can pick one).
    \\- `query` → SEARCH message content across your workspace (FTS).
    \\- `session_id` → READ that session's messages. `query` + `session_id` → SEARCH-WITHIN one session.
    \\- Scope is automatic (your workspace only). Cross-workspace reads are denied, never leaked.
    \\
;

pub const read_workspace_session_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "read_workspace_session",
        .description =
            \\Discover, search, and read other chat sessions in YOUR workspace — including messages compacted out of the live context. Scope is derived server-side from your session: you can only ever see sessions in your own workspace. Reads of other workspaces' sessions are denied.
            \\
            \\FOUR BEHAVIORS (pick by params):
            \\- LIST (neither `query` nor `session_id`): sessions in your workspace with name, status, message count, last activity, and a preview of the latest human message. Your own session is excluded. Use this when you need to find "the conversation about X" but don't know its session id.
            \\- SEARCH (`query` only): full-text search over message content across your workspace using SQLite FTS5. Filter by `role`/`tool_name`/`parent_session_id`/`agent`, time-bound via `since`/`until`, restrict to live or compacted rows via `live_only`/`compacted_only`, paginate with `offset` + `limit`. Returns ranked matches with a preview snippet + owning session id/name. For long result sets, read <total_count> and call again with offset=N until offset + count >= total_count.
            \\- READ (`session_id` only): messages of one session in your workspace (live + compacted). Returns an index (id, role, created_at, preview); pass `message_ids` (up to 50) for full <content> bodies. Use `order="desc"` for most-recent-first, `since`/`until` to paginate forward.
            \\- SEARCH-WITHIN (both `query` and `session_id`): FTS restricted to that one session (which must be in your workspace).
            \\
            \\FTS QUERY SANITIZATION: queries with `.`, `-`, `:`, `*`, `^`, `(`, `)`, `"`, `+` are auto-sanitized — you can write `handle_tool.zig` or `AGENTS.md` without pre-escaping. Multi-word queries are joined with FTS5 OR (`a b` matches rows containing `a` OR `b`) for natural recall.
            \\
            \\Response shape:
            \\- <count>: number of entries in THIS response (page size).
            \\- <total_count>: total matching entries before pagination. Use to know whether more pages exist.
            \\- per-message <content> is truncated to 16 KB; a `truncated="1"` attribute on <content> indicates there's more. Call again with a narrower message_ids list to fetch the rest.
            \\- cross-workspace targets return <denied>, not content. Sessions outside your workspace are never listed, never searched, never read.
            \\
            \\Filters (optional, apply to SEARCH/READ/SEARCH-WITHIN unless noted):
            \\- role: "user", "assistant", or "tool" — exact match.
            \\- tool_name: exact-match filter on the tool that produced the row. Useful for "find every bash invocation that ran `cargo test`".
            \\- parent_session_id: exact-match filter on sub-agent sessions. Useful for tracing a sub-agent's full session.
            \\- agent: exact-match filter on the agent name (e.g. "main", "planning", "compaction").
            \\- live_only / compacted_only (mutually exclusive): restrict to messages still in your live context (is_feed_to_llm=1) vs. dropped by compaction (is_feed_to_llm=0). Default returns both.
            \\- since / until: YYYY-MM-DD HH:MM:SS inclusive bounds on created_at.
            \\- limit: max rows to return (default 20, max 200; LIST max 50).
            \\- offset: SEARCH only — skip first N matches for pagination.
            \\- order: READ only — "asc" (chronological forward, default) or "desc" (most-recent-first).
            \\
            \\Example (list): {}
            \\Example (search): {"query": "login bug fix"}
            \\Example (search page 2): {"query": "login bug", "offset": 20}
            \\Example (read): {"session_id": "s_42"}
            \\Example (read recent first): {"session_id": "s_42", "order": "desc"}
            \\Example (read full bodies): {"session_id": "s_42", "message_ids": "h_1781,h_1782"}
            \\Example (search within): {"session_id": "s_42", "query": "migration"}
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "session_id", .type = "string", .description = "Target session for READ / SEARCH-WITHIN. Must be in your workspace or the call is denied." },
                .{ .name = "query", .type = "string", .description = "FTS5 search query (auto-sanitized) for SEARCH / SEARCH-WITHIN." },
                .{ .name = "message_ids", .type = "string", .description = "Comma-separated ids. Returns full <content> for these ids (workspace-scoped). Capped at 50 per call — split into batches for more." },
                .{ .name = "role", .type = "string", .description = "Optional exact-match role filter: 'user', 'assistant', or 'tool'." },
                .{ .name = "tool_name", .type = "string", .description = "Optional exact-match filter on tool_name. Useful for finding every bash / read_file / search invocation." },
                .{ .name = "parent_session_id", .type = "string", .description = "Optional exact-match filter on parent_session_id. Useful for tracing a sub-agent's full session." },
                .{ .name = "agent", .type = "string", .description = "Optional exact-match filter on agent name (e.g. 'main', 'planning', 'compaction')." },
                .{ .name = "live_only", .type = "boolean", .description = "If true, restrict to messages still in the LLM's live context (is_feed_to_llm=1). Mutually exclusive with compacted_only." },
                .{ .name = "compacted_only", .type = "boolean", .description = "If true, restrict to messages dropped by compaction (is_feed_to_llm=0). Mutually exclusive with live_only." },
                .{ .name = "since", .type = "string", .description = "Optional lower bound on created_at (inclusive). YYYY-MM-DD HH:MM:SS." },
                .{ .name = "until", .type = "string", .description = "Optional upper bound on created_at (inclusive)." },
                .{ .name = "limit", .type = "number", .description = "Max rows to return. Default 20, max 200 (LIST max 50)." },
                .{ .name = "offset", .type = "number", .description = "SEARCH only. Skip first N matches for pagination." },
                .{ .name = "order", .type = "string", .description = "READ only. 'asc' (chronological forward, default) or 'desc' (most-recent-first)." },
            },
            .required = &.{},
        },
        .system_prompt = read_workspace_session_tool_system_prompt,
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
        "<read_workspace_session><error>{s}</error></read_workspace_session>",
        .{escaped});
}

fn deniedXml(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, session_id);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<read_workspace_session><denied session_id=\"{s}\">Session is not in your workspace.</denied></read_workspace_session>",
        .{escaped});
}

/// Execute read_workspace_session. Returns an XML string for the LLM.
/// `caller_session_id` is the session invoking the tool (server-side,
/// from the dispatch context — never from LLM input).
pub fn execute_read_workspace_session(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: ReadWorkspaceSessionInput,
) ![]const u8 {
    _ = io; // Reserved for future streaming; not used in v1.

    if (input.live_only and input.compacted_only) {
        return errorXml(allocator,
            "live_only and compacted_only are mutually exclusive — pick one or neither.");
    }

    const feed_filter: llm_history.FeedFilter = if (input.live_only)
        .live_only
    else if (input.compacted_only)
        .compacted_only
    else
        .all;

    if (caller_session_id.len == 0) {
        return errorXml(allocator, "Missing caller session — cannot resolve workspace scope.");
    }

    const want_search = input.query.len > 0;
    const want_read = input.session_id.len > 0;

    if (!want_search and !want_read) {
        return executeList(allocator, db, caller_session_id, input);
    }

    // SEARCH / READ / SEARCH-WITHIN all need the caller's workspace.
    const ws = try workspace_scope.resolveWorkspaceId(allocator, db, caller_session_id);
    defer if (ws) |w| allocator.free(w);
    if (ws == null) {
        return errorXml(allocator,
            "Current session is not linked to any workspace — cross-session history is unavailable.");
    }

    if (want_search and !want_read) {
        const ws_ids = try workspace_scope.workspaceSessionIds(allocator, db, ws.?);
        defer workspace_scope.freeSessionIds(allocator, ws_ids);
        return executeSearch(allocator, db, ws_ids, null, feed_filter, input);
    }

    // READ or SEARCH-WITHIN: gate the target session first.
    const allowed = try workspace_scope.isSameWorkspace(allocator, db, caller_session_id, input.session_id);
    if (!allowed) {
        return deniedXml(allocator, input.session_id);
    }
    if (want_search) {
        return executeSearch(allocator, db, null, input.session_id, feed_filter, input);
    }
    return executeRead(allocator, db, input.session_id, feed_filter, input);
}

const SessionMeta = struct {
    id: []u8,
    name: []u8,
    status: []u8,
    message_count: u32,
    last_activity: []u8,
    preview: []u8,

    fn deinit(self: *const SessionMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.status);
        allocator.free(self.last_activity);
        allocator.free(self.preview);
    }
};

fn executeList(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: ReadWorkspaceSessionInput,
) ![]const u8 {
    const ws = try workspace_scope.resolveWorkspaceId(allocator, db, caller_session_id);
    defer if (ws) |w| allocator.free(w);
    if (ws == null) {
        return errorXml(allocator,
            "Current session is not linked to any workspace — cross-session history is unavailable.");
    }

    const ws_ids = try workspace_scope.workspaceSessionIds(allocator, db, ws.?);
    defer workspace_scope.freeSessionIds(allocator, ws_ids);

    const list_limit = @min(input.limit, MAX_LIST_LIMIT);

    // Metadata for every workspace session except the caller's own.
    // Bound IN-list (never string-interpolated ids).
    var metas: std.ArrayList(SessionMeta) = .empty;
    errdefer {
        for (metas.items) |m| m.deinit(allocator);
        metas.deinit(allocator);
    }

    if (ws_ids.len > 0) {
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(allocator);
        try sql.appendSlice(allocator,
            \\SELECT s.id, COALESCE(s.name, ''), COALESCE(s.status, ''),
            \\  COUNT(h.id), COALESCE(MAX(h.created_at_nano), '')
            \\FROM sessions s LEFT JOIN llm_history h ON h.session_id = s.id
            \\WHERE s.id IN (
        );
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);
        for (ws_ids, 0..) |sid, i| {
            if (i > 0) try sql.append(allocator, ',');
            try sql.append(allocator, '?');
            try bind_values.append(allocator, sid);
        }
        try sql.appendSlice(allocator,
            \\)
            \\GROUP BY s.id
            \\ORDER BY COALESCE(MAX(h.created_at_nano), '') DESC, s.id ASC
        );

        var rows = try db.query(allocator, sql.items, bind_values.items);
        defer rows.deinit();
        while (try rows.next()) |row| {
            defer row.deinit(allocator);
            if (std.mem.eql(u8, row.values[0], caller_session_id)) continue;
            if (metas.items.len >= list_limit) break;
            const preview = try latestUserPreview(allocator, db, row.values[0]);
            errdefer allocator.free(preview);
            try metas.append(allocator, .{
                .id = try allocator.dupe(u8, row.values[0]),
                .name = try allocator.dupe(u8, row.values[1]),
                .status = try allocator.dupe(u8, row.values[2]),
                .message_count = std.fmt.parseInt(u32, row.values[3], 10) catch 0,
                .last_activity = try allocator.dupe(u8, row.values[4]),
                .preview = preview,
            });
        }
    }

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);
    try xml.print(allocator,
        "<read_workspace_session behavior=\"list\" limit=\"{d}\">\n" ++
        "  <count>{d}</count>\n" ++
        "  <total_count>{d}</total_count>\n" ++
        "  <sessions>\n",
        .{ list_limit, metas.items.len, metas.items.len });
    for (metas.items) |m| {
        const id_e = try xmlEscape(allocator, m.id);
        defer allocator.free(id_e);
        const name_e = try xmlEscape(allocator, m.name);
        defer allocator.free(name_e);
        const status_e = try xmlEscape(allocator, m.status);
        defer allocator.free(status_e);
        const la_e = try xmlEscape(allocator, m.last_activity);
        defer allocator.free(la_e);
        const preview_e = try xmlEscape(allocator, m.preview);
        defer allocator.free(preview_e);
        try xml.appendSlice(allocator, "    <session>\n");
        try xml.print(allocator, "      <id>{s}</id>\n", .{id_e});
        try xml.print(allocator, "      <name>{s}</name>\n", .{name_e});
        try xml.print(allocator, "      <status>{s}</status>\n", .{status_e});
        try xml.print(allocator, "      <message_count>{d}</message_count>\n", .{m.message_count});
        try xml.print(allocator, "      <last_activity>{s}</last_activity>\n", .{la_e});
        try xml.print(allocator, "      <preview>{s}</preview>\n", .{preview_e});
        try xml.appendSlice(allocator, "    </session>\n");
    }
    try xml.appendSlice(allocator, "  </sessions>\n</read_workspace_session>\n");

    for (metas.items) |m| m.deinit(allocator);
    metas.deinit(allocator);
    return try xml.toOwnedSlice(allocator);
}

/// First 100 chars of the latest user message in a session ("" when none).
fn latestUserPreview(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]u8 {
    var rows = try db.query(allocator,
        \\SELECT substr(COALESCE(response_content, ''), 1, 100) FROM llm_history
        \\WHERE session_id = ? AND role = 'user'
        \\ORDER BY rowid DESC LIMIT 1
    , &.{session_id});
    defer rows.deinit();
    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return try allocator.dupe(u8, "");
}

fn executeSearch(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    ws_ids: ?[][]u8,
    within_session_id: ?[]const u8,
    feed_filter: llm_history.FeedFilter,
    input: ReadWorkspaceSessionInput,
) ![]const u8 {
    const effective_limit = @min(input.limit, 200);

    const opts = llm_history.SearchOptions{
        .session_id = within_session_id,
        .session_ids = if (ws_ids) |ids| ids else null,
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

    const parsed_ids = try parseMessageIds(allocator, input.message_ids);
    defer {
        for (parsed_ids) |id| allocator.free(id);
        allocator.free(parsed_ids);
    }
    if (parsed_ids.len > MAX_MESSAGE_IDS) {
        const msg = try std.fmt.allocPrint(allocator,
            "Too many message_ids ({d} > max {d}). Split into batches of {d} or fewer.",
            .{ parsed_ids.len, MAX_MESSAGE_IDS, MAX_MESSAGE_IDS });
        defer allocator.free(msg);
        return errorXml(allocator, msg);
    }

    // Session names for the hits (readability — the LLM picks sessions by name).
    var names = try sessionNames(allocator, db, hits);
    defer {
        var it = names.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        names.deinit(allocator);
    }

    const total_count: u32 = if (hits.len > 0) hits[0].total_count else 0;
    const behavior: []const u8 = if (within_session_id != null) "search-within" else "search";

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    const escaped_query = try xmlEscape(allocator, input.query);
    defer allocator.free(escaped_query);
    try xml.print(allocator,
        "<read_workspace_session behavior=\"{s}\" offset=\"{d}\" limit=\"{d}\">\n" ++
        "  <query>{s}</query>\n",
        .{ behavior, input.offset, effective_limit, escaped_query });
    if (within_session_id) |sid| {
        const sid_e = try xmlEscape(allocator, sid);
        defer allocator.free(sid_e);
        try xml.print(allocator, "  <session_id>{s}</session_id>\n", .{sid_e});
    }
    try xml.print(allocator,
        "  <count>{d}</count>\n" ++
        "  <total_count>{d}</total_count>\n" ++
        "  <results>\n",
        .{ hits.len, total_count });
    for (hits) |h| {
        const id_e = try xmlEscape(allocator, h.id);
        defer allocator.free(id_e);
        const sid_e = try xmlEscape(allocator, h.session_id);
        defer allocator.free(sid_e);
        const role_e = try xmlEscape(allocator, h.role);
        defer allocator.free(role_e);
        const snip_e = try xmlEscape(allocator, h.snippet);
        defer allocator.free(snip_e);
        const sname_e = if (names.get(h.session_id)) |n| try xmlEscape(allocator, n) else try allocator.dupe(u8, "");
        defer allocator.free(sname_e);

        try xml.appendSlice(allocator, "    <entry>\n");
        try xml.print(allocator, "      <id>{s}</id>\n", .{id_e});
        try xml.print(allocator, "      <session_id>{s}</session_id>\n", .{sid_e});
        try xml.print(allocator, "      <session_name>{s}</session_name>\n", .{sname_e});
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

    // Full content block — workspace-scoped: ids resolving outside the
    // workspace are skipped, never leaked.
    if (parsed_ids.len > 0) {
        const full_messages = llm_history.getMessagesByIds(allocator, db, parsed_ids) catch |err| {
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

        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        defer wanted.deinit(allocator);
        for (parsed_ids) |id| try wanted.put(allocator, id, {});

        try xml.appendSlice(allocator, "  <full_contents>\n");
        for (full_messages) |m| {
            if (!wanted.contains(m.id)) continue;
            if (!isIdInWorkspace(ws_ids, within_session_id, m.session_id)) continue;
            const id_e = try xmlEscape(allocator, m.id);
            defer allocator.free(id_e);
            const sid_e = try xmlEscape(allocator, m.session_id);
            defer allocator.free(sid_e);
            const role_e = try xmlEscape(allocator, m.role);
            defer allocator.free(role_e);

            try xml.appendSlice(allocator, "    <entry>\n");
            try xml.print(allocator, "      <id>{s}</id>\n", .{id_e});
            try xml.print(allocator, "      <session_id>{s}</session_id>\n", .{sid_e});
            try xml.print(allocator, "      <role>{s}</role>\n", .{role_e});
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

    try xml.appendSlice(allocator, "</read_workspace_session>\n");
    return try xml.toOwnedSlice(allocator);
}

/// True when `session_id` belongs to the search scope: the workspace id
/// set, or the single within-session.
fn isIdInWorkspace(
    ws_ids: ?[][]u8,
    within_session_id: ?[]const u8,
    session_id: []const u8,
) bool {
    if (within_session_id) |sid| return std.mem.eql(u8, sid, session_id);
    if (ws_ids) |ids| {
        for (ids) |id| {
            if (std.mem.eql(u8, id, session_id)) return true;
        }
    }
    return false;
}

fn sessionNames(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    hits: []const llm_history.SearchHit,
) !std.StringHashMapUnmanaged([]u8) {
    var map: std.StringHashMapUnmanaged([]u8) = .empty;
    errdefer {
        var it = map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        map.deinit(allocator);
    }
    // Distinct session ids only.
    var distinct: std.ArrayList([]const u8) = .empty;
    defer distinct.deinit(allocator);
    for (hits) |h| {
        var seen = false;
        for (distinct.items) |d| {
            if (std.mem.eql(u8, d, h.session_id)) {
                seen = true;
                break;
            }
        }
        if (!seen) try distinct.append(allocator, h.session_id);
    }
    if (distinct.items.len == 0) return map;

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "SELECT id, COALESCE(name, '') FROM sessions WHERE id IN (");
    var bind_values: std.ArrayList([]const u8) = .empty;
    defer bind_values.deinit(allocator);
    for (distinct.items, 0..) |sid, i| {
        if (i > 0) try sql.append(allocator, ',');
        try sql.append(allocator, '?');
        try bind_values.append(allocator, sid);
    }
    try sql.append(allocator, ')');

    var rows = try db.query(allocator, sql.items, bind_values.items);
    defer rows.deinit();
    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const k = try allocator.dupe(u8, row.values[0]);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, row.values[1]);
        try map.put(allocator, k, v);
    }
    return map;
}

fn executeRead(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    feed_filter: llm_history.FeedFilter,
    input: ReadWorkspaceSessionInput,
) ![]const u8 {
    const parsed_ids = try parseMessageIds(allocator, input.message_ids);
    defer {
        for (parsed_ids) |id| allocator.free(id);
        allocator.free(parsed_ids);
    }
    if (parsed_ids.len > MAX_MESSAGE_IDS) {
        const msg = try std.fmt.allocPrint(allocator,
            "Too many message_ids ({d} > max {d}). Split into batches of {d} or fewer.",
            .{ parsed_ids.len, MAX_MESSAGE_IDS, MAX_MESSAGE_IDS });
        defer allocator.free(msg);
        return errorXml(allocator, msg);
    }
    const want_full = parsed_ids.len > 0;

    const order_enum: llm_history.CompactedMessagesOptions.Order = blk: {
        if (std.mem.eql(u8, input.order, "desc")) break :blk .desc;
        break :blk .asc;
    };

    const effective_limit = @min(input.limit, 200);

    const opts = llm_history.CompactedMessagesOptions{
        .message_ids = if (want_full) parsed_ids else null,
        .role = if (input.role.len > 0) input.role else null,
        .since = if (input.since.len > 0) input.since else null,
        .until = if (input.until.len > 0) input.until else null,
        .tool_name = if (input.tool_name.len > 0) input.tool_name else null,
        .parent_session_id = if (input.parent_session_id.len > 0) input.parent_session_id else null,
        .agent = if (input.agent.len > 0) input.agent else null,
        .limit = effective_limit,
        .feed_filter = feed_filter,
        .order = order_enum,
    };

    const messages = llm_history.getCompactedMessages(allocator, db, session_id, opts) catch |err| {
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

    const total_count: u32 = if (messages.len > 0) messages[0].total_count else 0;

    var full_ids_set: std.StringHashMapUnmanaged(void) = .empty;
    defer full_ids_set.deinit(allocator);
    if (want_full) for (parsed_ids) |id| try full_ids_set.put(allocator, id, {});

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    const escaped_session_id = try xmlEscape(allocator, session_id);
    defer allocator.free(escaped_session_id);
    try xml.print(allocator,
        "<read_workspace_session behavior=\"read\" order=\"{s}\">\n" ++
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

    try xml.appendSlice(allocator, "  </message_index>\n</read_workspace_session>\n");
    return try xml.toOwnedSlice(allocator);
}

pub fn toXmlSuccess(allocator: std.mem.Allocator, inner: []const u8) ![]u8 {
    return allocator.dupe(u8, inner);
}

pub fn toXmlError(allocator: std.mem.Allocator, err_msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, err_msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<read_workspace_session><error>{s}</error></read_workspace_session>",
        .{escaped});
}

const testing = std.testing;
const rws = @import("read_workspace_session.zig");

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
        \\  created_iso TEXT DEFAULT (strftime('%Y-%m-%d %H:%M:%S', 'now'))
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE VIRTUAL TABLE messages_fts USING fts5(
        \\    content
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TRIGGER llm_history_ai AFTER INSERT ON llm_history BEGIN
        \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
        \\END
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT DEFAULT 'active',
        \\  cwd TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    // Workspace w1: task-linked s1 + plain-chat s3 (cwd under /proj/a).
    // Workspace w2: task-linked s2.
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('i1', 'w1', 'kanban', 'A', '/proj/a', 1),
        \\       ('i2', 'w2', 'kanban', 'B', '/proj/b', 1)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id)
        \\VALUES ('s1', 'T1', 'i1'), ('s2', 'T2', 'i2')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO sessions (id, name, status, cwd) VALUES
        \\  ('s1', 'Task one', 'active', '/proj/a'),
        \\  ('s2', 'Task two', 'active', '/proj/b'),
        \\  ('s3', 'Plain chat', 'active', '/proj/a/sub')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm)
        \\VALUES ('h1', 's1', 'user', 'the login bug needs fixing', 1),
        \\       ('h2', 's3', 'user', 'login page redesign notes', 0),
        \\       ('h3', 's2', 'user', 'unrelated deployment checklist', 1)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "read_workspace_session: LIST shows workspace peers, excludes self and other workspaces" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    const xml = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{});
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<read_workspace_session behavior=\"list\"") != null);
    // s3 (same workspace) listed with metadata.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>s3</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<name>Plain chat</name>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "login page redesign notes") != null);
    // Own session excluded, other workspace excluded.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>s1</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>s2</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>1</count>") != null);
}

test "read_workspace_session: SEARCH is workspace-scoped" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    const xml = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .query = "login",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "behavior=\"search\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h2</id>") != null);
    // h3 lives in w2 — never surfaced.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h3</id>") == null);

    // A term that exists ONLY in the other workspace returns zero hits.
    const xml2 = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .query = "deployment",
    });
    defer alloc.free(xml2);
    try testing.expect(std.mem.indexOf(u8, xml2, "<count>0</count>") != null);
}

test "read_workspace_session: READ same-workspace works, cross-workspace denied" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    const xml = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s3",
    });
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "behavior=\"read\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h2</id>") != null);

    const denied = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s2",
    });
    defer alloc.free(denied);
    try testing.expect(std.mem.indexOf(u8, denied, "<denied") != null);
    // No content leaks through the denial.
    try testing.expect(std.mem.indexOf(u8, denied, "deployment") == null);
}

test "read_workspace_session: SEARCH-WITHIN gates the session first" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    const xml = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s3",
        .query = "redesign",
    });
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "behavior=\"search-within\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h2</id>") != null);

    const denied = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s2",
        .query = "deployment",
    });
    defer alloc.free(denied);
    try testing.expect(std.mem.indexOf(u8, denied, "<denied") != null);
}

test "read_workspace_session: caller without workspace gets a clean error" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO sessions (id, name, status, cwd) VALUES ('sx', 'Lost', 'active', '/nowhere')",
        &.{});
    const xml = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "sx", .{});
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "not linked to any workspace") != null);
}

test "read_workspace_session: self-read allowed, guards enforced" {
    var s = try setupDb();
    defer {
        s.db.deinit();
        s.threaded.deinit();
    }
    const alloc = testing.allocator;

    // Reading your own session always works (no leak possible).
    const self = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s1",
    });
    defer alloc.free(self);
    try testing.expect(std.mem.indexOf(u8, self, "<id>h1</id>") != null);

    // live_only + compacted_only rejected.
    const both = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s3",
        .live_only = true,
        .compacted_only = true,
    });
    defer alloc.free(both);
    try testing.expect(std.mem.indexOf(u8, both, "mutually exclusive") != null);

    // message_ids cap enforced.
    const caps = try rws.execute_read_workspace_session(alloc, s.threaded.io(), &s.db, "s1", .{
        .session_id = "s3",
        .message_ids = "a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z,a1,b1,c1,d1,e1,f1,g1,h1,i1,j1,k1,l1,m1,n1,o1,p1,q1,r1,s1,t1,u1,v1,w1,x1,y1,z1,zz",
    });
    defer alloc.free(caps);
    try testing.expect(std.mem.indexOf(u8, caps, "Too many message_ids") != null);
}
