const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const agent = nalarcore.agent;
const logger_mod = nalarcore.loggermod;
const helpers = nalarcore.helpers;
const TUIHistory = @import("models.zig").TUIHistory;
const llm_models = @import("nalarcore").llm_models;
const ai_mod = @import("mod.zig");
const on_event_sent = ai_mod.on_event_sent;
const routines_model = @import("routines/model.zig");

/// Session info for list view
pub const SessionInfo = struct {
    session_id: []const u8,
    session_name: []const u8,
    status: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    agent: []const u8,
    selected_profile_model: []const u8,
    /// Migration 063 — "0" / "1" opt-in flag for unattended mode. Matches
    /// the SQL `is_auto_retry_until_stop` column convention. COALESCE'd to
    /// "0" at the SELECT boundary so callers always see a defined value.
    is_auto_retry_until_stop: []const u8,
    /// Migration 063 — denormalized cache of the most recent finish_reason
    /// the workflow observed for this session. Empty string until the
    /// first successful turn; never NULL at the API edge.
    last_finish_reason: []const u8,

    pub fn deinit(self: *const SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.session_name);
        allocator.free(self.status);
        allocator.free(self.cwd);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        allocator.free(self.agent);
        allocator.free(self.selected_profile_model);
        allocator.free(self.is_auto_retry_until_stop);
        allocator.free(self.last_finish_reason);
    }
};

/// Sort specification for session list
pub const SessionSortField = enum { created_at, session_name, agent, updated_at };
pub fn enumFromString(comptime T: type, s: []const u8) !T {
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (std.mem.eql(u8, s, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return error.UnknownValue;
}
pub const SessionSortDirection = enum { asc, desc };

/// Sort field for the paginated workspace-item tasks endpoint
/// (`GET /api/workspaces/:wid/items/:iid/tasks`). Mirrors
/// `SessionSortField` (above) so the API surface is consistent.
/// `name` is included for completeness even though the default UI
/// sorts by `updated_at` — the user can sort by name later if they
/// want an alphabetical fallback.
pub const TaskSortField = enum { created_at, updated_at, name };

/// Sort direction for workspace-item tasks. Asc/desc. Mirrors
/// `SessionSortDirection` (above).
pub const TaskSortDirection = enum { asc, desc };

/// Detailed session info
pub const SessionDetail = struct {
    session_id: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    agent: []const u8,
    session_name: []const u8,
    model: []const u8,
    temperature: f32,
    updated_at: []const u8,

    pub fn deinit(self: *const SessionDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.cwd);
        allocator.free(self.created_at);
        allocator.free(self.agent);
        allocator.free(self.session_name);
        allocator.free(self.model);
        allocator.free(self.updated_at);
    }
};

/// Session info for SSE broadcast (lightweight)
pub const SessionBroadcastInfo = struct {
    session_id: []const u8,
    session_name: []const u8,
    status: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    agent: []const u8,
    selected_profile_model: []const u8,
    git_worktree_cwd: []const u8,
    /// Migration 063 — opt-in flag for unattended mode.
    is_auto_retry_until_stop: []const u8,
    /// Migration 063 — most recent finish_reason the workflow observed.
    last_finish_reason: []const u8,
};

/// Get a list of sessions from the database
pub fn getSessionList(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    status: ?[]const u8,
    agent_type: ?[]const u8,
    limit: u32,
    offset: u32,
) !struct { sessions: []SessionInfo, total: u32 } {
    _ = status;
    _ = agent_type;

    // Rewritten to use idx_llm_history_created_session(created_at DESC,
    // session_id) — see Migration 048. The inner subquery groups
    // session_id + MAX(created_at) and applies LIMIT/OFFSET so the
    // planner can walk the covering index in created_at DESC order and
    // stop at LIMIT. The outer query LEFT JOINs sessions for cwd/name,
    // and a correlated subquery picks the agent of the LATEST message
    // in the session (fixes the original's loose-GROUP-BY agent
    // semantics, which were implementation-defined).
    const sql =
        \\SELECT sub.session_id,
        \\       sub.created_at,
        \\       COALESCE(s.cwd, '') AS cwd,
        \\       COALESCE(s.name, '') AS session_name,
        \\       COALESCE(
        \\         (SELECT h2.agent
        \\            FROM llm_history h2
        \\           WHERE h2.session_id = sub.session_id
        \\           ORDER BY h2.created_at DESC
        \\           LIMIT 1),
        \\         'Agent'
        \\       ) AS agent,
        \\       COALESCE(s.is_auto_retry_until_stop, '0') AS is_auto_retry_until_stop,
        \\       COALESCE(s.last_finish_reason, '') AS last_finish_reason
        \\FROM (
        \\  SELECT h.session_id, MAX(h.created_at) AS created_at
        \\    FROM llm_history h
        \\   GROUP BY h.session_id
        \\   ORDER BY created_at DESC
        \\   LIMIT ? OFFSET ?
        \\) sub
        \\LEFT JOIN sessions s ON s.id = sub.session_id
        \\ORDER BY sub.created_at DESC
    ;

    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    const offset_str = try std.fmt.allocPrint(allocator, "{d}", .{offset});
    defer {
        allocator.free(limit_str);
        allocator.free(offset_str);
    }

    var rows = try db.query(allocator, sql, &.{ limit_str, offset_str });
    defer rows.deinit();

    var sessions = std.ArrayList(SessionInfo).empty;
    errdefer {
        for (sessions.items) |s| s.deinit(allocator);
        sessions.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .cwd = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
            .agent = try allocator.dupe(u8, row.values[3]),
            .session_name = try allocator.dupe(u8, row.values[4]),
        };
        try sessions.append(allocator, session);
        row.deinit(allocator);
    }

    // Get total count
    const count_sql = "SELECT COUNT(DISTINCT session_id) FROM llm_history";
    var count_rows = try db.query(allocator, count_sql, &.{});
    defer count_rows.deinit();

    var total: u32 = 0;
    if (try count_rows.next()) |row| {
        total = std.fmt.parseInt(u32, row.values[0], 10) catch 0;
        row.deinit(allocator);
    }

    return .{
        .sessions = try sessions.toOwnedSlice(allocator),
        .total = total,
    };
}

/// Get a list of sessions with cursor-based pagination
/// Queries from sessions table with LEFT JOIN to llm_history
pub fn getSessionListWithCursor(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    status: ?[]const u8,
    agent_type: ?[]const u8,
    cwd: ?[]const u8,
    limit: u32,
    cursor: ?[]const u8,
    sort_field: SessionSortField,
    sort_direction: SessionSortDirection,
) !struct { sessions: []SessionInfo, total: u32 } {
    _ = status;
    _ = agent_type;

    // Build dynamic WHERE clause from optional filters
    var where_parts = std.ArrayList([]const u8).empty;
    defer where_parts.deinit(allocator);

    try where_parts.append(allocator, "s.id NOT LIKE '%subagent%'");

    if (cwd) |dir| {
        try where_parts.append(allocator, try std.fmt.allocPrint(allocator, "s.cwd = '{s}'", .{dir}));
    }

    if (cursor) |c| {
        _ = c;
        // Cursor filtering is done via subquery below
    }

    const where_clause = try std.mem.join(allocator, " AND ", where_parts.items);
    defer allocator.free(where_clause);

    // Build ORDER BY clause based on sort field and direction
    const sort_order = switch (sort_direction) {
        .asc => "ASC",
        .desc => "DESC",
    };
    const order_by = switch (sort_field) {
        .created_at => try std.fmt.allocPrint(allocator, "s.created_at {s}", .{sort_order}),
        .session_name => try std.fmt.allocPrint(allocator, "COALESCE(s.name, '') {s}", .{sort_order}),
        .agent => try std.fmt.allocPrint(allocator, "COALESCE(h.agent, 'Agent') {s}", .{sort_order}),
        .updated_at => try std.fmt.allocPrint(allocator, "s.updated_at {s}", .{sort_order}),
    };
    defer allocator.free(order_by);

    // Build cursor filter
    const cursor_filter = if (cursor) |c|
        try std.fmt.allocPrint(allocator, " AND s.created_at {s} '{s}'", .{ if (sort_direction == .asc) ">" else "<", c })
    else
        try allocator.dupe(u8, "");
    defer allocator.free(cursor_filter);

    const where_with_cursor = try std.fmt.allocPrint(allocator, "{s}{s}", .{ where_clause, cursor_filter });
    defer allocator.free(where_with_cursor);

    const sql_final = try std.fmt.allocPrint(allocator,
        \\SELECT s.id, s.name, s.status, s.cwd, COALESCE(s.created_at, ''),
        \\COALESCE(s.updated_at, ''),
        \\COALESCE(h.agent, 'Agent'),
        \\COALESCE(s.selected_profile_model, ''),
        \\COALESCE(s.is_auto_retry_until_stop, '0'),
        \\COALESCE(s.last_finish_reason, '')
        \\FROM sessions s
        \\LEFT JOIN llm_history h ON s.id = h.session_id
        \\WHERE {s}
        \\GROUP BY s.id ORDER BY {s} LIMIT {d}
    , .{ where_with_cursor, order_by, limit });
    defer allocator.free(sql_final);

    var rows = try db.query(allocator, sql_final, &.{});
    defer rows.deinit();

    var sessions = std.ArrayList(SessionInfo).empty;
    errdefer {
        for (sessions.items) |s| s.deinit(allocator);
        sessions.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
            .cwd = try allocator.dupe(u8, row.values[3]),
            .created_at = try allocator.dupe(u8, row.values[4]),
            .updated_at = try allocator.dupe(u8, row.values[5]),
            .agent = try allocator.dupe(u8, row.values[6]),
            .selected_profile_model = try allocator.dupe(u8, row.values[7]),
            // Migration 063 — the SELECT adds 2 trailing columns, so
            // the index shifts by 2. row.values[8] = is_auto_retry_until_stop,
            // row.values[9] = last_finish_reason.
            .is_auto_retry_until_stop = try allocator.dupe(u8, row.values[8]),
            .last_finish_reason = try allocator.dupe(u8, row.values[9]),
        };
        try sessions.append(allocator, session);
        row.deinit(allocator);
    }

    // Build count query with cwd filter
    const count_sql: []u8 = if (cwd) |dir|
        try std.fmt.allocPrint(allocator, "SELECT COUNT(*) FROM sessions WHERE id NOT LIKE '%subagent%' AND cwd = '{s}'", .{dir})
    else
        try allocator.dupe(u8, "SELECT COUNT(*) FROM sessions WHERE id NOT LIKE '%subagent%'");
    defer allocator.free(count_sql);

    var count_rows = try db.query(allocator, count_sql, &.{});
    defer count_rows.deinit();

    var total: u32 = 0;
    if (try count_rows.next()) |row| {
        total = std.fmt.parseInt(u32, row.values[0], 10) catch 0;
        row.deinit(allocator);
    }

    return .{
        .sessions = try sessions.toOwnedSlice(allocator),
        .total = total,
    };
}

/// Session list JSON response structure
pub const SessionListJsonResponse = struct {
    sessions: []const SessionInfoJson,
    total: u32,
    has_more: bool,
    next_cursor: ?[]const u8 = null,
};

/// Session info for JSON serialization
pub const SessionInfoJson = struct {
    session_id: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    agent: []const u8,
    session_name: []const u8,
    selected_profile_model: []const u8,
    /// Migration 063 — opt-in flag for unattended mode (Migration 063).
    is_auto_retry_until_stop: []const u8 = "",
    /// Migration 063 — most recent finish_reason (Migration 063).
    last_finish_reason: []const u8 = "",
};

/// Build JSON response for a list of sessions with cursor pagination
pub fn buildSessionListJson(
    allocator: std.mem.Allocator,
    sessions: []const SessionInfo,
    total: u32,
    has_more: bool,
    next_cursor: ?[]const u8,
) ![]u8 {
    // Convert SessionInfo to SessionInfoJson for serialization
    var json_sessions = std.ArrayList(SessionInfoJson).empty;
    defer json_sessions.deinit(allocator);

    for (sessions) |sess| {
        try json_sessions.append(allocator, .{
            .session_id = sess.session_id,
            .cwd = sess.cwd,
            .created_at = sess.created_at,
            .updated_at = sess.updated_at,
            .agent = sess.agent,
            .session_name = sess.session_name,
            .selected_profile_model = sess.selected_profile_model,
            // Migration 063 — pass through. `SessionInfo` already
            // populates both fields from `row.values[8..10]`; the JSON
            // layer just needs to forward them so the API response
            // carries them to the frontend.
            .is_auto_retry_until_stop = sess.is_auto_retry_until_stop,
            .last_finish_reason = sess.last_finish_reason,
        });
    }

    const response = SessionListJsonResponse{
        .sessions = json_sessions.items,
        .total = total,
        .has_more = has_more,
        .next_cursor = next_cursor,
    };

    return try std.json.Stringify.valueAlloc(allocator, response, .{});
}

/// Append escaped JSON string (with quotes) to an ArrayList
fn jsonAppendEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    try out.append(allocator, '"');
    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

/// Get a single session by ID
pub fn get_session(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?SessionDetail {
    const sql =
        \\SELECT DISTINCT
        \\    h.session_id,
        \\    COALESCE(s.cwd, ''),
        \\    s.created_at as created_at,
        \\    COALESCE(h.agent, 'Agent'),
        \\    COALESCE(s.name, ''),
        \\    COALESCE(h.model, 'gpt-4'),
        \\    COALESCE(h.temperature, 0.2),
        \\    s.updated_at as updated_at
        \\FROM llm_history h
        \\LEFT JOIN sessions s ON h.session_id = s.id
        \\WHERE h.session_id = ?
        \\GROUP BY h.session_id
    ;
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const session = SessionDetail{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .cwd = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
            .agent = try allocator.dupe(u8, row.values[3]),
            .session_name = try allocator.dupe(u8, row.values[4]),
            .model = try allocator.dupe(u8, row.values[5]),
            .temperature = std.fmt.parseFloat(f32, row.values[6]) catch 0.2,
            .updated_at = try allocator.dupe(u8, row.values[7]),
        };
        row.deinit(allocator);
        return session;
    }

    return null;
}

/// Get the latest finish_reason for a session from the database
/// Returns the most recent finish_reason value (e.g., "stop", "tool_calls", "length", etc.)
/// Returns null if no history exists for the session
pub fn getLatestFinishReason(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?[]const u8 {
    const sql = "SELECT finish_reason FROM llm_history WHERE session_id = ? AND finish_reason IS NOT NULL AND finish_reason != '' ORDER BY created_at DESC LIMIT 1";

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const finish_reason = try allocator.dupe(u8, row.values[0]);
        row.deinit(allocator);
        return finish_reason;
    }

    return null;
}

/// Chat message for a session
pub const SessionMessage = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    timestamp: []const u8,
    /// Wire-format boolean. Emitted as JSON `true`/`false` by
    /// `buildSessionMessagesJson` (manual format) and by
    /// `makeSessionMessagesResponse` (via `std.json.Stringify.valueAlloc`).
    /// Matches the SSE `SseEventLLMHistory.is_input` shape and the
    /// TypeScript `is_input?: boolean` type. The DB column is
    /// `INTEGER` (0/1); the SQL read site converts with `parseRowBool`.
    /// See docs/plans/2026-07-01-is-input-output-bool-consistency.md.
    is_input: bool,
    is_output: bool,
    tool_name: []const u8,
    finish_reason: []const u8,
    reasoning_content: []const u8,
    diffview_before: ?[]const u8 = null,
    diffview_after: ?[]const u8 = null,
    image_urls: ?[][]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls_json: ?[]const u8 = null,

    pub fn deinit(self: *const SessionMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.role);
        allocator.free(self.content);
        allocator.free(self.timestamp);
        // is_input / is_output are bool (not slices) — no free needed
        allocator.free(self.tool_name);
        allocator.free(self.finish_reason);
        allocator.free(self.reasoning_content);
        if (self.diffview_before) |dv| allocator.free(dv);
        if (self.diffview_after) |da| allocator.free(da);
        if (self.image_urls) |iums| {
            for (iums) |img| allocator.free(img);
            allocator.free(iums);
        }
        if (self.tool_call_id) |tci| allocator.free(tci);
        if (self.tool_calls_json) |tcj| allocator.free(tcj);
    }
};

/// Response for session messages with cursor pagination
pub const SessionMessageResponse = struct {
    messages: []SessionMessage,
    has_more: bool,
    next_cursor: ?[]const u8,
    cwd: ?[]const u8 = null,
    /// Session's bound git worktree path (NULL/empty when no worktree is
    /// bound). Mirrors `sessions.git_worktree_cwd`. Added by Chunk 1 of
    /// the git-worktree-cwd-pr plan so the frontend can render the
    /// worktree's branch/path in the chat status bar from the moment
    /// the chat loads (not just after the user re-fetches).
    git_worktree_cwd: ?[]const u8 = null,
    max_total_tokens: u32 = 0,
    max_capacity_total_tokens: u32 = 0,
    total_count: ?u32 = null, // Total count of messages in session (for VirtualScroller)
    skills: ?[]const SkillInfo = null, // Skills loaded for this session
};

/// Sort direction
pub const SortDirection = enum { asc, desc };

/// Sort specification with field and direction combined
pub const SortSpec = union(enum) {
    created_at_asc: void,
    created_at_desc: void,
    id_asc: void,
    id_desc: void,
    role_asc: void,
    role_desc: void,
};

/// Parse a SQLite INTEGER column value (returned by the SQL binder
/// as a `[]const u8` slice) into a bool. Empty string is `false`
/// (matches `COALESCE(col, 0)` semantics). Used for `is_input` /
/// `is_output` which the SQL binder returns as `[]const u8` slices
/// but the in-memory struct expects as `bool`.
fn parseRowBool(s: []const u8) bool {
    if (s.len == 0) return false;
    return s[0] == '1';
}

/// Get messages for a session with cursor-based pagination and sorting
pub fn getSessionMessagesSorted(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    limit: u32,
    cursor: ?[]const u8,
    sort_spec: SortSpec,
) !SessionMessageResponse {
    // Query limit + 1 to check if more results exist
    const query_limit = limit + 1;
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{query_limit});
    defer allocator.free(limit_str);

    var sql: []u8 = undefined;
    var argv: []const []const u8 = undefined;

    if (cursor) |c| {
        const is_asc = switch (sort_spec) {
            .created_at_asc, .role_asc, .id_asc => true,
            else => false,
        };
        // Use h.created_at (message time) for cursor, not s.created_at (session time)
        const cursor_cmp = if (is_asc) " AND h.created_at > ?" else " AND h.created_at < ?";

        const order_part = switch (sort_spec) {
            .created_at_asc => " ORDER BY h.created_at ASC, h.id ASC",
            .created_at_desc => " ORDER BY h.created_at DESC, h.id DESC",
            .id_asc => " ORDER BY h.created_at ASC, h.id ASC",
            .id_desc => " ORDER BY h.created_at DESC, h.id DESC",
            .role_asc => " ORDER BY h.role ASC, h.created_at ASC, h.id ASC",
            .role_desc => " ORDER BY h.role DESC, h.created_at DESC, h.id DESC",
        };
        sql = try std.fmt.allocPrint(allocator,
            \\SELECT h.id, h.session_id, h.role, h.response_content, h.created_at,
            \\       COALESCE(h.is_input, 0), COALESCE(h.is_output, 0), COALESCE(h.tool_name, ''),
            \\       COALESCE(h.finish_reason, ''), COALESCE(s.cwd, ''), COALESCE(s.git_worktree_cwd, ''), COALESCE(h.reasoning_content, ''),
            \\       COALESCE(h.diffview_before, ''), COALESCE(h.diffview_after, ''), COALESCE(h.image_url, ''), COALESCE(h.tool_call_id, ''), COALESCE(h.tool_calls_json, '')
            \\FROM llm_history h LEFT JOIN sessions s ON h.session_id = s.id
            \\WHERE h.session_id = ?{s}{s} LIMIT ?
        , .{ cursor_cmp, order_part });
        argv = &.{ session_id, c, limit_str };
    } else {
        const order_part = switch (sort_spec) {
            .created_at_asc => " ORDER BY s.created_at ASC, h.id ASC",
            .created_at_desc => " ORDER BY s.created_at DESC, h.id DESC",
            .id_asc => " ORDER BY h.id ASC",
            .id_desc => " ORDER BY h.id DESC",
            .role_asc => " ORDER BY h.role ASC, s.created_at ASC, h.id ASC",
            .role_desc => " ORDER BY h.role DESC, s.created_at DESC, h.id DESC",
        };
        sql = try std.fmt.allocPrint(allocator,
            \\SELECT h.id, h.session_id, h.role, h.response_content, h.created_at,
            \\       COALESCE(h.is_input, 0), COALESCE(h.is_output, 0), COALESCE(h.tool_name, ''),
            \\       COALESCE(h.finish_reason, ''), COALESCE(s.cwd, ''), COALESCE(s.git_worktree_cwd, ''), COALESCE(h.reasoning_content, ''),
            \\       COALESCE(h.diffview_before, ''), COALESCE(h.diffview_after, ''), COALESCE(h.image_url, ''), COALESCE(h.tool_call_id, ''), COALESCE(h.tool_calls_json, '')
            \\FROM llm_history h LEFT JOIN sessions s ON h.session_id = s.id
            \\WHERE h.session_id = ?{s} LIMIT ?
        , .{order_part});
        argv = &.{ session_id, limit_str };
    }
    defer allocator.free(sql);

    var rows = try db.query(allocator, sql, argv);
    defer rows.deinit();

    var messages = std.ArrayList(SessionMessage).empty;
    errdefer {
        for (messages.items) |m| m.deinit(allocator);
        messages.deinit(allocator);
    }

    // Get cwd from first row (same for all rows since we filter by session_id)
    var cwd: ?[]u8 = null;
    var git_worktree_cwd: ?[]u8 = null;

    while (try rows.next()) |row| {
        // Extract cwd + git_worktree_cwd from the first row (same for all
        // rows since we filter by session_id). Column indices match the
        // SELECT list above: cwd at 9, git_worktree_cwd at 10,
        // reasoning_content at 11, diffview_before at 12, ...
        if (cwd == null) {
            const cwd_val = row.values[9];
            if (cwd_val.len > 0) {
                cwd = try allocator.dupe(u8, cwd_val);
            }
        }
        if (git_worktree_cwd == null) {
            const wt_val = row.values[10];
            if (wt_val.len > 0) {
                git_worktree_cwd = try allocator.dupe(u8, wt_val);
            }
        }

        const msg = SessionMessage{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .role = try allocator.dupe(u8, row.values[2]),
            .content = try allocator.dupe(u8, row.values[3]),
            .timestamp = try allocator.dupe(u8, row.values[4]),
            .is_input = parseRowBool(row.values[5]),
            .is_output = parseRowBool(row.values[6]),
            .tool_name = try allocator.dupe(u8, row.values[7]),
            .finish_reason = try allocator.dupe(u8, row.values[8]),
            .reasoning_content = try allocator.dupe(u8, row.values[11]),
            .diffview_before = if (row.values[12].len > 0) try allocator.dupe(u8, row.values[12]) else null,
            .diffview_after = if (row.values[13].len > 0) try allocator.dupe(u8, row.values[13]) else null,
            .image_urls = if (row.values[14].len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, row.values[14], '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .tool_call_id = if (row.values[15].len > 0) try allocator.dupe(u8, row.values[15]) else null,
            .tool_calls_json = if (row.values[16].len > 0) try allocator.dupe(u8, row.values[16]) else null,
        };
        try messages.append(allocator, msg);
        row.deinit(allocator);
    }

    // Check if there are more results
    const has_more = messages.items.len > @as(usize, limit);

    // Get next cursor from last message if has_more
    // Use created_at timestamp as cursor for proper pagination
    const next_cursor: ?[]const u8 = if (has_more and messages.items.len > 0)
        messages.items[@as(usize, limit) - 1].timestamp
    else
        null;

    // Return only limit messages if has_more
    const result_messages = if (has_more) messages.items[0..limit] else messages.items;

    // Get total count of messages for this session
    const total_count = getTotalMessageCountForSession(db, session_id);

    // Get skills loaded for this session
    const session_skills = getSessionSkills(allocator, db, session_id) catch null;

    return SessionMessageResponse{
        .messages = result_messages,
        .has_more = has_more,
        .next_cursor = next_cursor,
        .cwd = cwd,
        .git_worktree_cwd = git_worktree_cwd,
        .max_total_tokens = getMaxTotalTokensForSession(allocator, db, session_id) catch 0,
        .max_capacity_total_tokens = blk: {
            // Resolve the per-config override when the singleton is alive,
            // otherwise fall back to the built-in per-model default. The
            // override applies regardless of which model is being used —
            // it's a global "treat this session as if the model had a
            // context window of N tokens" knob.
            const di_opt = nalarcore.getSingleton() catch null;
            if (di_opt) |di| {
                const cfg = nalarcore.getLlmConfig(di);
                // No profile/sub-agent in scope at this call site — pass
                // null for both. Pass `cfg` as the defaults arg so
                // the top-level `max_capacity_token_model` override
                // (Defaults tab) flows through to this session view.
                break :blk cfg.maxCapacityForModel(null, null, cfg, cfg.model);
            }
            break :blk llm_models.getModelTokenCount("");
        },
        .total_count = total_count,
        .skills = session_skills,
    };
}

/// Get the total count of messages for a session
fn getTotalMessageCountForSession(
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ?u32 {
    const sql = "SELECT COUNT(*) FROM llm_history WHERE session_id = ?";

    var rows = db.query(std.heap.page_allocator, sql, &.{session_id}) catch return null;
    defer rows.deinit();

    const row = rows.next() catch return null;
    if (row) |r| {
        const count = std.fmt.parseInt(u32, r.values[0], 10) catch return null;
        return count;
    }
    return null;
}

/// Get the maximum total_tokens for a session (from messages with is_feed_to_llm = 1)
fn getMaxTotalTokensForSession(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !u32 {
    const sql =
        \\SELECT COALESCE(MAX(total_tokens), 0)
        \\FROM llm_history
        \\WHERE session_id = ? AND (is_feed_to_llm = 1 OR is_feed_to_llm IS NULL)
    ;

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const max_tokens = std.fmt.parseInt(u32, row.values[0], 10) catch 0;
        row.deinit(allocator);
        return max_tokens;
    }
    return 0;
}

/// Escape JSON special characters for safe string output
fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            '\x08' => try result.appendSlice(allocator, "\\b"), // backspace
            '\x0C' => try result.appendSlice(allocator, "\\f"), // form feed
            // Escape other control characters (0x00-0x1F except those above) as \u00XX
            0x00...0x07, 0x0E...0x1F => {
                var buf: [6]u8 = undefined;
                const hex_str = std.fmt.bufPrint(&buf, "\\u00{X}", .{c}) catch unreachable;
                try result.appendSlice(allocator, hex_str);
            },
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Build JSON response for session messages with pagination info
pub fn buildSessionMessagesJson(
    allocator: std.mem.Allocator,
    response: *const SessionMessageResponse,
) ![]u8 {
    var json_messages = std.ArrayList(u8).empty;
    errdefer json_messages.deinit(allocator);

    try json_messages.appendSlice(allocator, "[");
    for (response.messages, 0..) |msg, i| {
        if (i > 0) try json_messages.append(allocator, ',');

        // Escape all string fields for JSON safety
        const escaped_id = try jsonEscape(allocator, msg.id);
        defer allocator.free(escaped_id);
        const escaped_session_id = try jsonEscape(allocator, msg.session_id);
        defer allocator.free(escaped_session_id);
        const escaped_role = try jsonEscape(allocator, msg.role);
        defer allocator.free(escaped_role);
        const escaped_content = try jsonEscape(allocator, msg.content);
        defer allocator.free(escaped_content);
        const escaped_timestamp = try jsonEscape(allocator, msg.timestamp);
        defer allocator.free(escaped_timestamp);
        const escaped_tool_name = try jsonEscape(allocator, msg.tool_name);
        defer allocator.free(escaped_tool_name);
        const escaped_finish_reason = try jsonEscape(allocator, msg.finish_reason);
        defer allocator.free(escaped_finish_reason);
        const escaped_reasoning_content = try jsonEscape(allocator, msg.reasoning_content);
        defer allocator.free(escaped_reasoning_content);

        // is_input / is_output are bool — emit as JSON booleans (not strings).
        // `"is_input":"1"` is the old wrong format; `"is_input":true` is correct.
        const is_input_str = if (msg.is_input) "true" else "false";
        const is_output_str = if (msg.is_output) "true" else "false";
        const msg_json = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","session_id":"{s}","role":"{s}","content":"{s}","timestamp":"{s}",
            \\"is_input":{s},"is_output":{s},"tool_name":"{s}","finish_reason":"{s}","reasoning_content":"{s}"}}
        , .{ escaped_id, escaped_session_id, escaped_role, escaped_content, escaped_timestamp, is_input_str, is_output_str, escaped_tool_name, escaped_finish_reason, escaped_reasoning_content });
        defer allocator.free(msg_json);
        try json_messages.appendSlice(allocator, msg_json);
    }
    try json_messages.append(allocator, ']');

    // Build pagination fields
    const has_more_str = if (response.has_more) "true" else "false";
    const next_cursor_str = if (response.next_cursor) |c|
        try std.fmt.allocPrint(allocator, "\"{s}\"", .{c})
    else
        try std.fmt.allocPrint(allocator, "null", .{});
    defer allocator.free(next_cursor_str);

    // Build cwd field
    const cwd_str = if (response.cwd) |c|
        try std.fmt.allocPrint(allocator, "\"{s}\"", .{c})
    else
        try std.fmt.allocPrint(allocator, "null", .{});
    defer allocator.free(cwd_str);

    // Build max_total_tokens field
    const max_total_tokens_str = try std.fmt.allocPrint(allocator, "{d}", .{response.max_total_tokens});
    defer allocator.free(max_total_tokens_str);

    // Build max_capacity_total_tokens field
    const max_capacity_total_tokens_str = try std.fmt.allocPrint(allocator, "{d}", .{response.max_capacity_total_tokens});
    defer allocator.free(max_capacity_total_tokens_str);

    const result = try std.fmt.allocPrint(allocator, "{{\"messages\":{s},\"has_more\":{s},\"next_cursor\":{s},\"cwd\":{s},\"max_total_tokens\":{s},\"max_capacity_total_tokens\":{s}}}", .{ json_messages.items, has_more_str, next_cursor_str, cwd_str, max_total_tokens_str, max_capacity_total_tokens_str });
    json_messages.deinit(allocator);
    return result;
}

/// Escape XML special characters for safe output
pub fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Build XML response for session messages with pagination info
pub fn buildSessionMessagesXml(
    allocator: std.mem.Allocator,
    response: *const SessionMessageResponse,
) ![]u8 {
    var xml_messages = std.ArrayList(u8).empty;
    errdefer xml_messages.deinit(allocator);

    try xml_messages.appendSlice(allocator, "<messages>");
    for (response.messages) |msg| {
        const escaped_id = try xmlEscape(allocator, msg.id);
        defer allocator.free(escaped_id);
        const escaped_session_id = try xmlEscape(allocator, msg.session_id);
        defer allocator.free(escaped_session_id);
        const escaped_role = try xmlEscape(allocator, msg.role);
        defer allocator.free(escaped_role);
        const escaped_content = try xmlEscape(allocator, msg.content);
        defer allocator.free(escaped_content);
        const escaped_timestamp = try xmlEscape(allocator, msg.timestamp);
        defer allocator.free(escaped_timestamp);
        const escaped_tool_name = try xmlEscape(allocator, msg.tool_name);
        defer allocator.free(escaped_tool_name);
        const escaped_finish_reason = try xmlEscape(allocator, msg.finish_reason);
        defer allocator.free(escaped_finish_reason);
        const escaped_reasoning_content = try xmlEscape(allocator, msg.reasoning_content);
        defer allocator.free(escaped_reasoning_content);

        // is_input / is_output as XML text content. Match the JSON wire
        // format: emit "true" / "false" (not "1" / "0") so the LLM
        // consumers (read_messages tool etc.) see the same shape on both
        // the JSON and the XML paths.
        const is_input_str = if (msg.is_input) "true" else "false";
        const is_output_str = if (msg.is_output) "true" else "false";
        const msg_xml = try std.fmt.allocPrint(allocator,
            \\<message id="{s}">
            \\<session_id>{s}</session_id>
            \\<role>{s}</role>
            \\<content>{s}</content>
            \\<timestamp>{s}</timestamp>
            \\<is_input>{s}</is_input>
            \\<is_output>{s}</is_output>
            \\<tool_name>{s}</tool_name>
            \\<finish_reason>{s}</finish_reason>
            \\<reasoning_content>{s}</reasoning_content>
            \\</message>
        , .{ escaped_id, escaped_session_id, escaped_role, escaped_content, escaped_timestamp, is_input_str, is_output_str, escaped_tool_name, escaped_finish_reason, escaped_reasoning_content });
        defer allocator.free(msg_xml);
        try xml_messages.appendSlice(allocator, msg_xml);
    }

    // Add pagination info
    const has_more_str = if (response.has_more) "true" else "false";
    try xml_messages.appendSlice(allocator, "<has_more>");
    try xml_messages.appendSlice(allocator, has_more_str);
    try xml_messages.appendSlice(allocator, "</has_more>");
    try xml_messages.appendSlice(allocator, "<next_cursor>");
    if (response.next_cursor) |c| {
        try xml_messages.appendSlice(allocator, c);
    }
    try xml_messages.appendSlice(allocator, "</next_cursor>");
    try xml_messages.appendSlice(allocator, "<cwd>");
    if (response.cwd) |c| {
        try xml_messages.appendSlice(allocator, c);
    }
    try xml_messages.appendSlice(allocator, "</cwd>");
    try xml_messages.appendSlice(allocator, "<max_total_tokens>");
    const max_tokens_str = try std.fmt.allocPrint(allocator, "{d}", .{response.max_total_tokens});
    defer allocator.free(max_tokens_str);
    try xml_messages.appendSlice(allocator, max_tokens_str);
    try xml_messages.appendSlice(allocator, "</max_total_tokens>");
    try xml_messages.appendSlice(allocator, "<max_capacity_total_tokens>");
    const max_cap_tokens_str = try std.fmt.allocPrint(allocator, "{d}", .{response.max_capacity_total_tokens});
    defer allocator.free(max_cap_tokens_str);
    try xml_messages.appendSlice(allocator, max_cap_tokens_str);
    try xml_messages.appendSlice(allocator, "</max_capacity_total_tokens>");
    try xml_messages.appendSlice(allocator, "</messages>");

    return try xml_messages.toOwnedSlice(allocator);
}

// =============================================================================
// Session Creation
// =============================================================================

/// Create a new session in the database
pub fn createSession(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    agent_type: []const u8,
    model: []const u8,
    temperature: f32,
    session_name: []const u8,
) ![]const u8 {
    // Generate session ID
    var session_id_buf: [64]u8 = undefined;
    // `std.time.timestamp` was removed in Zig 0.16. Use the cross-platform
    // `helpers.unixTimestamp()` helper (POSIX gettimeofday / Win32
    // GetSystemTimeAsFileTime, no `io: std.Io` required — this function
    // doesn't take an io parameter).
    const session_id = try std.fmt.bufPrint(&session_id_buf, "kerjabot_{}", .{helpers.unixTimestamp()});

    // Insert into sessions table first (for JOIN queries)
    const session_sql = "INSERT INTO sessions (id, name, status) VALUES (?, ?, 'active')";
    const copy_session_name = try allocator.dupe(u8, session_name);
    defer allocator.free(copy_session_name);
    try db.exec(allocator, session_sql, &.{ session_id, copy_session_name });

    // Insert session into llm_history table
    const insert_sql = "INSERT INTO llm_history (id, session_id, model, response_content, role, agent, temperature, created_at, is_input, is_output, tool_name) VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'), ?, ?, ?)";

    const temp_str = try std.fmt.allocPrint(allocator, "{d}", .{temperature});
    defer allocator.free(temp_str);

    try db.exec(allocator, insert_sql, &.{ session_id, session_id, model, "", "system", agent_type, temp_str, "0", "0", "" });

    return session_id;
}

// =============================================================================
// Save Message Functions
// =============================================================================

/// Serialize tool_calls array to JSON string
pub fn serializeToolCalls(allocator: std.mem.Allocator, tool_calls: []agent.ToolCall) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    try aw.writer.print("{f}", .{std.json.fmt(tool_calls, .{})});
    return aw.toOwnedSlice();
}

pub const SaveMessageInput = struct {
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
    role: ?[]const u8,
    finish_reason: ?[]const u8,
    tool_calls: ?[]agent.ToolCall,
    tool_call_id: ?[]const u8,
    tool_name: ?[]const u8 = null,
    agent_name: ?[]const u8,
    loop_index: u32,
    temperature: f32,
    is_thinking: bool,
    is_input: bool = false,
    is_output: bool = false,
    parent_session_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
    diffview_before: ?[]const u8 = null,
    diffview_after: ?[]const u8 = null,
    image_urls: ?[][]const u8 = null,
    is_feed_to_llm: bool = true,
};

pub fn saveMessage(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    input: SaveMessageInput,
) !void {
    // Get the current timestamp ONCE (two separate `Timestamp.now` calls
    // can return nanoseconds that differ by 1+, which would make `id`
    // and `created_at` disagree). We use it for both fields.
    //
    // The `llm_history.created_at` column is documented as Unix
    // microseconds since the epoch (see Migration 059 header), but the
    // stdlib exposes `Timestamp.now(...).nanoseconds` (an i96, 19
    // decimal digits for any post‑1970 timestamp). We divide by
    // `std.time.ns_per_us` (1000) to convert nanoseconds → microseconds
    // so the column matches its documented format.
    const id =try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(id);
    const created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(created_at);

    // Compute `created_iso` (the UTC‑formatted ISO string for the
    // `since`/`until` filter columns) IN APPLICATION CODE rather than
    // via SQLite triggers. See Migration 059 header for why.
    //
    // `helpers.currentTimeIsoLocal` gets the current UTC time itself
    // (no parameter) — semantically the same value `created_at_us`
    // would produce (both come from the same `now_ns` source a few
    // lines above), but the helper hides the conversion details.
    const created_iso = try helpers.currentTimeIsoLocal(allocator,io);
    defer allocator.free(created_iso);

    const contentStr = input.content orelse "";
    const finishReasonStr = input.finish_reason orelse "null";
    const roleStr = input.role orelse "assistant";
    const reasoningStr = input.reasoning_content orelse "";
    const agentStr = input.agent_name orelse "Agent";

    // tool_calls_json holds ONLY the serialized tool_calls array (assistant message wire format).
    // For tool result messages, the tool_call_id lives in the dedicated tool_call_id column —
    // do NOT overload tool_calls_json with the id. That overload caused the 2013 bug where the
    // transform could not tell a JSON array from a plain id string.
    var toolCallsJson: []const u8 = "";
    var toolCallsOwned: ?[]u8 = null;
    if (input.tool_calls) |tc| {
        toolCallsOwned = try serializeToolCalls(allocator, tc);
        toolCallsJson = toolCallsOwned.?;
    }
    defer if (toolCallsOwned) |tcj| allocator.free(tcj);

    const sql =
        \\INSERT INTO llm_history (
        \\    id,
        \\    session_id,
        \\    model,
        \\    response_content,
        \\    finish_reason,
        \\    role,
        \\    tool_calls_json,
        \\    tool_call_id,
        \\    reasoning_content,
        \\    is_feed_to_llm,
        \\    agent,
        \\    loop_index,
        \\    temperature,
        \\    is_thinking,
        \\    created_at,
        \\    created_iso,
        \\    parent_session_id,
        \\    parent_id,
        \\    prompt_tokens,
        \\    completion_tokens,
        \\    total_tokens,
        \\    is_input,
        \\    is_output,
        \\    tool_name,
        \\    diffview_before,
        \\    diffview_after,
        \\    image_url
        \\) VALUES (
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        \\    ?, ?, ?, ?, ?, ?, ?
        \\)
    ;

    const copy_session_id = try allocator.dupe(u8, input.session_id);
    defer allocator.free(copy_session_id);
    const copy_model = try allocator.dupe(u8, input.model);
    defer allocator.free(copy_model);
    const copy_content = try allocator.dupe(u8, contentStr);
    defer allocator.free(copy_content);
    const copy_finish_reason = try allocator.dupe(u8, finishReasonStr);
    defer allocator.free(copy_finish_reason);
    const copy_role = try allocator.dupe(u8, roleStr);
    defer allocator.free(copy_role);
    const copy_tool_calls = try allocator.dupe(u8, toolCallsJson);
    defer allocator.free(copy_tool_calls);
    const copy_reasoning = try allocator.dupe(u8, reasoningStr);
    defer allocator.free(copy_reasoning);
    const copy_agent = try allocator.dupe(u8, agentStr);
    defer allocator.free(copy_agent);
    const loop_index_str = try std.fmt.allocPrint(allocator, "{}", .{input.loop_index});
    defer allocator.free(loop_index_str);
    const temperature_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{input.temperature});
    defer allocator.free(temperature_str);
    const is_thinking_str = if (input.is_thinking) "1" else "0";
    const copy_parent_session_id = try allocator.dupe(u8, input.parent_session_id orelse "");
    defer allocator.free(copy_parent_session_id);
    const copy_parent_id = try allocator.dupe(u8, input.parent_id orelse "");
    defer allocator.free(copy_parent_id);
    const copy_tool_name = try allocator.dupe(u8, input.tool_name orelse "");
    defer allocator.free(copy_tool_name);
    const copy_tool_call_id = try allocator.dupe(u8, input.tool_call_id orelse "");
    defer allocator.free(copy_tool_call_id);
    const prompt_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.prompt_tokens});
    defer allocator.free(prompt_tokens_str);
    const completion_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.completion_tokens});
    defer allocator.free(completion_tokens_str);
    const total_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.total_tokens});
    defer allocator.free(total_tokens_str);
    const copy_diffview_before = try allocator.dupe(u8, input.diffview_before orelse "");
    defer allocator.free(copy_diffview_before);
    const copy_diffview_after = try allocator.dupe(u8, input.diffview_after orelse "");
    defer allocator.free(copy_diffview_after);

    const copy_is_feed_to_llm = try allocator.dupe(u8, if (input.is_feed_to_llm) "1" else "0");
    defer allocator.free(copy_is_feed_to_llm);

    // Join multiple image URLs with || delimiter
    var image_urls_str: []const u8 = "";
    var copy_image_urls: ?[]u8 = null;
    if (input.image_urls) |urls| {
        if (urls.len > 0) {
            var combined = std.ArrayList(u8).empty;
            defer combined.deinit(allocator);
            for (urls, 0..) |url, i| {
                if (i > 0) try combined.appendSlice(allocator, "||");
                try combined.appendSlice(allocator, url);
            }
            copy_image_urls = try allocator.dupe(u8, combined.items);
            image_urls_str = copy_image_urls.?;
        }
    }
    defer if (copy_image_urls) |c| allocator.free(c);

    const sqlArgs = &.{ id, copy_session_id, copy_model, copy_content, copy_finish_reason, copy_role, copy_tool_calls, copy_tool_call_id, copy_reasoning, copy_is_feed_to_llm, copy_agent, loop_index_str, temperature_str, is_thinking_str, created_at, created_iso, copy_parent_session_id, copy_parent_id, prompt_tokens_str, completion_tokens_str, total_tokens_str, if (input.is_input) "1" else "0", if (input.is_output) "1" else "0", copy_tool_name, copy_diffview_before, copy_diffview_after, image_urls_str };

    try db.exec(allocator, sql, sqlArgs);

    // Update the session's cwd in the sessions table
    const copy_cwd = try allocator.dupe(u8, input.cwd);
    defer allocator.free(copy_cwd);
    try db.exec(allocator, "UPDATE sessions SET cwd = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?", &.{ copy_cwd, copy_session_id });
}
// =============================================================================
// Get Messages Functions
// =============================================================================

pub fn getMessages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]TUIHistory {
    var results: std.ArrayList(TUIHistory) = .empty;

    const sql =
        \\SELECT
        \\    h.id, h.session_id, h.model, h.created_at,
        \\    h.response_content, h.finish_reason,
        \\    COALESCE(h.role, 'assistant'),
        \\    COALESCE(h.tool_calls_json, ''),
        \\    COALESCE(h.reasoning_content, ''),
        \\    COALESCE(h.agent, 'Agent'),
        \\    COALESCE(s.name, ''),
        \\    COALESCE(h.loop_index, 0),
        \\    COALESCE(h.tool_name, ''),
        \\    COALESCE(h.parent_session_id, ''),
        \\    COALESCE(h.temperature, 0.2),
        \\    COALESCE(h.is_thinking, 0),
        \\    COALESCE(h.prompt_tokens, 0),
        \\    COALESCE(h.completion_tokens, 0),
        \\    COALESCE(h.total_tokens, 0),
        \\    COALESCE(h.is_input, 0),
        \\    COALESCE(h.is_output, 0),
        \\    COALESCE(h.diffview_before, ''),
        \\    COALESCE(h.diffview_after, ''),
        \\    COALESCE(h.image_url, ''),
        \\    COALESCE(h.tool_call_id, '')
        \\FROM llm_history h
        \\LEFT JOIN sessions s ON h.session_id = s.id
        \\WHERE h.session_id = ?
        \\AND (h.is_feed_to_llm = 1 OR h.is_feed_to_llm IS NULL)
        \\ORDER BY h.created_at ASC
    ;

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    while (try rows.next()) |row| {
        const parent_session_id_str = row.values[13];
        const diffview_before_str = row.values[21];
        const diffview_after_str = row.values[22];
        const image_url_str = row.values[23];
        const history = TUIHistory{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .model = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
            .response_content = try allocator.dupe(u8, row.values[4]),
            .finish_reason = try allocator.dupe(u8, row.values[5]),
            .role = try allocator.dupe(u8, row.values[6]),
            .tools = try allocator.dupe(u8, row.values[7]),
            .reasoning_content = if (row.values[8].len > 0) try allocator.dupe(u8, row.values[8]) else null,
            .agent = try allocator.dupe(u8, row.values[9]),
            .session_name = try allocator.dupe(u8, row.values[10]),
            .loop_index = std.fmt.parseInt(u32, row.values[11], 10) catch 0,
            .tool_name = try allocator.dupe(u8, row.values[12]),
            .parent_session_id = if (parent_session_id_str.len > 0) try allocator.dupe(u8, parent_session_id_str) else null,
            .temperature = std.fmt.parseFloat(f32, row.values[14]) catch 0.2,
            .is_thinking = std.mem.eql(u8, row.values[15], "1"),
            .prompt_tokens = std.fmt.parseInt(u32, row.values[16], 10) catch 0,
            .completion_tokens = std.fmt.parseInt(u32, row.values[17], 10) catch 0,
            .total_tokens = std.fmt.parseInt(u32, row.values[18], 10) catch 0,
            .is_input = parseRowBool(row.values[19]),
            .is_output = parseRowBool(row.values[20]),
            .diffview_before = if (diffview_before_str.len > 0) try allocator.dupe(u8, diffview_before_str) else null,
            .diffview_after = if (diffview_after_str.len > 0) try allocator.dupe(u8, diffview_after_str) else null,
            .image_urls = if (image_url_str.len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, image_url_str, '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .tool_call_id = if (row.values[24].len > 0) try allocator.dupe(u8, row.values[24]) else null,
        };
        try results.append(allocator, history);
        row.deinit(allocator);
    }

    return results.toOwnedSlice(allocator);
}

// =============================================================================
// Compacted Messages Query (is_feed_to_llm = 0)
// =============================================================================

/// Options for filtering `getCompactedMessages`.
pub const CompactedMessagesOptions = struct {
    /// When non-null, only return messages whose id is in this list.
    /// Used by `search_history` (mode="session", message_ids=[...]).
    message_ids: ?[]const []const u8 = null,
    /// When non-null, only return messages with `role` matching this value
    /// (e.g. "user", "assistant", "tool").
    role: ?[]const u8 = null,
    /// When non-null, only return messages with `created_at >= since`.
    since: ?[]const u8 = null,
    /// When non-null, only return messages with `created_at <= until`.
    until: ?[]const u8 = null,
    /// Max number of rows to return. Defaults to 100 for safety — the
    /// caller can request up to 1000 explicitly. The `search_history`
    /// tool wraps this in its own user-facing limit parameter.
    limit: ?u32 = 100,
    /// When `true`, include ALL messages for the session regardless of
    /// `is_feed_to_llm` (live + compacted). When `false` (default),
    /// restrict to `is_feed_to_llm = 0` (compacted only) — the original
    /// semantic, preserved for compaction-test callers.
    ///
    /// Used by `search_history mode="session"` to return the full
    /// conversation history. The LLM may want to re-read messages
    /// still in its live context (e.g. "show me what I said earlier
    /// today"), not just compacted ones.
    include_all: bool = false,
    /// Sort direction for `created_at`. Default `.asc` (chronological
    /// forward). `.desc` returns most-recent-first — useful for
    /// `search_history mode="session"` when the LLM wants to browse
    /// the tail of a long session.
    ///
    /// Pagination with `.desc` works the same way as `.asc`: pass the
    /// last-seen `created_at` as `since` (or `until` in the desc case)
    /// and re-query.
    order: Order = .asc,

    /// Named enum so callers can reference it as
    /// `llm_history.CompactedMessagesOptions.Order` and use
    /// `@tagName(...)` to render it as a string for the wire format.
    pub const Order = enum { asc, desc };
};

/// Lighter-weight return struct than `TUIHistory` — only the fields the
/// `search_history` tool actually surfaces. Avoids the
/// ~30-field TUIHistory struct, which has columns that don't exist
/// in a minimal test schema (e.g. `diffview_before`) and would force
/// every test to seed them.
pub const CompactedMessage = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8,
    tool_name: ?[]const u8,
    model: []const u8,
    agent: []const u8,
    created_at: []const u8,
    /// Total number of rows that matched the WHERE clause (before LIMIT).
    /// Surfaced via `COUNT(*) OVER ()` so it's computed in the same query.
    /// Every row in the result carries the same value — the LLM uses it
    /// to know whether more pages exist without re-querying.
    total_count: u32,

    pub fn deinit(self: *const CompactedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.role);
        allocator.free(self.content);
        allocator.free(self.model);
        allocator.free(self.agent);
        allocator.free(self.created_at);
        if (self.tool_call_id) |t| allocator.free(t);
        if (self.tool_name) |t| allocator.free(t);
    }
};

/// Options for `searchMessagesFts`. Mirrors the shape of
/// `CompactedMessagesOptions` so callers can build either kind of query
/// with a consistent input.
pub const SearchOptions = struct {
    /// When non-null, only return hits whose `llm_history.session_id` equals this.
    /// Useful for "search within this conversation only".
    session_id: ?[]const u8 = null,
    /// When non-null, exact-match filter on `llm_history.role` ("user", "assistant", "tool").
    role: ?[]const u8 = null,
    /// When non-null, lower bound on `created_at` (inclusive, lex-sort = chrono-sort).
    since: ?[]const u8 = null,
    /// When non-null, upper bound on `created_at` (inclusive).
    until: ?[]const u8 = null,
    /// Max rows to return. Defaults to 20 for safety; the caller can
    /// request up to 200 (the tool layer caps there). The FTS ranking
    /// does the rest of the filtering.
    limit: ?u32 = 20,
    /// Skip the first N results. Used by `search_history mode="text"`
    /// to walk forward through FTS results that exceed `limit`. Combined
    /// with `total_count` on the result, the LLM can paginate until
    /// `offset + hits.len >= total_count`.
    offset: ?u32 = null,
};

/// One FTS hit. Mirrors `CompactedMessage` but adds `snippet` (the
/// FTS5-generated preview with `[match]` markers around matched tokens).
pub const SearchHit = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    snippet: []const u8,
    tool_call_id: ?[]const u8,
    tool_name: ?[]const u8,
    created_at: []const u8,
    /// Total number of rows that matched the WHERE clause (before LIMIT
    /// and OFFSET). Surfaced via `COUNT(*) OVER ()` so it's computed in
    /// the same query. Every row in the result carries the same value.
    /// Used by the LLM to decide whether to paginate further.
    total_count: u32,

    pub fn deinit(self: *const SearchHit, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.role);
        allocator.free(self.snippet);
        allocator.free(self.created_at);
        if (self.tool_call_id) |t| allocator.free(t);
        if (self.tool_name) |t| allocator.free(t);
    }
};

/// Return messages for the given session.
///
/// Default behavior (when `opts.include_all == false`): returns ONLY
/// messages marked `is_feed_to_llm = 0` — the ones dropped from the
/// live LLM context by compaction. This is the inverse of `getMessages`
/// (line 1076).
///
/// With `opts.include_all == true`: returns ALL messages for the
/// session regardless of `is_feed_to_llm`. Used by `search_history`
/// `mode="session"` to browse the full conversation history.
///
/// Filter semantics (identical regardless of `include_all`):
/// - `message_ids`: when non-null, IN-clause filter (skipped if empty).
/// - `role`: exact match on `llm_history.role`.
/// - `since` / `until`: lexicographic comparison on the
///   `created_iso` string (which is a regular TEXT column populated by
///   INSERT/UPDATE triggers installed by Migration 059 — they compute
///   `datetime(CAST(created_at AS REAL) / 1000000, 'unixepoch',
///   'localtime')` — in `YYYY-MM-DD HH:MM:SS` format, so
///   lex-sort = chrono-sort). NOTE: we filter on `created_iso`, NOT
///   `created_at`, because `created_at` stores Unix microseconds as a
///   TEXT string (e.g. `"1784119389936251112"`) and lex-comparing that
///   against a user-supplied date string like `"2026-07-15 00:00:00"`
///   silently returns 0 rows (since `'1' < '2'`). The column is
///   indexable so the filter is O(log n). See
///   `docs/superpowers/plans/2026-07-15-search-history-since-until-bug.md`.
/// - `limit`: clamps the row count (defaults to 100).
///
/// Returned slice's elements are heap-allocated via `allocator.dupe`;
/// caller must call `result[i].deinit(allocator)` for each and
/// `allocator.free(results)` to free the outer slice.
pub fn getCompactedMessages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    opts: CompactedMessagesOptions,
) ![]CompactedMessage {
    const effective_limit = opts.limit orelse 100;

    // Build the WHERE clause incrementally. Each filter appends
    // AND <clause> to the base `h.session_id = ?`.
    // `is_feed_to_llm = 0` is appended UNLESS `opts.include_all` is set;
    // `search_history` mode="session" passes include_all=true to browse
    // the full conversation history.
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator,
        \\SELECT
        \\    h.id, h.session_id, COALESCE(h.role, 'assistant'),
        \\    COALESCE(h.response_content, ''),
        \\    h.tool_call_id, h.tool_name,
        \\    COALESCE(h.model, ''), COALESCE(h.agent, ''),
        \\    COALESCE(h.created_at, ''),
        \\    COUNT(*) OVER () AS total
        \\FROM llm_history h
        \\WHERE h.session_id = ?
    );

    if (!opts.include_all) {
        try sql.appendSlice(allocator, " AND h.is_feed_to_llm = 0");
    }

    var bind_values: std.ArrayList([]const u8) = .empty;
    defer bind_values.deinit(allocator);
    try bind_values.append(allocator, session_id);

    if (opts.message_ids) |ids| {
        if (ids.len > 0) {
            try sql.appendSlice(allocator, " AND h.id IN (");
            for (ids, 0..) |id, i| {
                if (i > 0) try sql.append(allocator, ',');
                try sql.append(allocator, '?');
                try bind_values.append(allocator, id);
            }
            try sql.append(allocator, ')');
        }
    }

    if (opts.role) |r| {
        try sql.appendSlice(allocator, " AND h.role = ?");
        try bind_values.append(allocator, r);
    }

    if (opts.since) |s| {
        try sql.appendSlice(allocator, " AND h.created_iso >= ?");
        try bind_values.append(allocator, s);
    }

    if (opts.until) |u| {
        try sql.appendSlice(allocator, " AND h.created_iso <= ?");
        try bind_values.append(allocator, u);
    }

    try sql.print(allocator, " ORDER BY h.created_at {s}", .{@tagName(opts.order)});

    // Bind the limit at the end. Format inline since we know it's u32.
    try sql.print(allocator, " LIMIT {d}", .{effective_limit});

    var rows = try db.query(allocator, sql.items, bind_values.items);
    defer rows.deinit();

    var results: std.ArrayList(CompactedMessage) = .empty;
    errdefer {
        for (results.items) |m| {
            var copy = m;
            copy.deinit(allocator);
        }
        results.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        // `total` is column index 9 (COUNT(*) OVER ()) — computed before
        // LIMIT/OFFSET so it represents the total count of rows that
        // matched the WHERE clause, not the returned page size.
        const total_count: u32 = std.fmt.parseInt(u32, row.values[9], 10) catch 0;
        const msg = CompactedMessage{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .role = try allocator.dupe(u8, row.values[2]),
            .content = try allocator.dupe(u8, row.values[3]),
            .tool_call_id = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .tool_name = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .model = try allocator.dupe(u8, row.values[6]),
            .agent = try allocator.dupe(u8, row.values[7]),
            .created_at = try allocator.dupe(u8, row.values[8]),
            .total_count = total_count,
        };
        try results.append(allocator, msg);
    }

    return try results.toOwnedSlice(allocator);
}

/// Full-text search over `llm_history.response_content` using SQLite FTS5.
///
/// Joins the `messages_fts` virtual table to `llm_history` and returns
/// ranked hits with a 10-token snippet around each match. Ranking is
/// FTS5's default BM25.
///
/// Filter semantics mirror `getCompactedMessages`:
/// - `session_id`: exact match on `llm_history.session_id`
/// - `role`: exact match on `llm_history.role`
/// - `since`/`until`: lex-sort = chrono-sort on `created_at`
/// - `limit`: clamps the row count (defaults to 20)
///
/// Caller owns the returned slice. Free with `hit[i].deinit(allocator)`
/// for each hit and `allocator.free(hits)` for the outer slice.
pub fn searchMessagesFts(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    query: []const u8,
    opts: SearchOptions,
) ![]SearchHit {
    const effective_limit = opts.limit orelse 20;

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    // Wrap FTS5 access in a subquery so the COUNT(*) OVER () window
    // function runs over the regular subquery result, not directly over
    // the FTS5 virtual table. FTS5 virtual tables have restrictions on
    // what SQL features they accept (notably window functions), but the
    // outer query works fine.
    try sql.appendSlice(allocator,
        \\SELECT
        \\    id, session_id, role, snippet, tool_call_id, tool_name, created_at,
        \\    COUNT(*) OVER () AS total
        \\FROM (
        \\    SELECT
        \\        h.id AS id, h.session_id AS session_id,
        \\        COALESCE(h.role, 'assistant') AS role,
        \\        snippet(messages_fts, 0, '[', ']', '...', 10) AS snippet,
        \\        h.tool_call_id AS tool_call_id,
        \\        h.tool_name AS tool_name,
        \\        COALESCE(h.created_at, '') AS created_at,
        \\        rank AS fts_rank
        \\    FROM messages_fts
        \\    JOIN llm_history h ON h.rowid = messages_fts.rowid
        \\    WHERE messages_fts MATCH ?
    );

    var bind_values: std.ArrayList([]const u8) = .empty;
    defer bind_values.deinit(allocator);
    try bind_values.append(allocator, query);

    if (opts.session_id) |sid| {
        try sql.appendSlice(allocator, " AND h.session_id = ?");
        try bind_values.append(allocator, sid);
    }

    if (opts.role) |r| {
        try sql.appendSlice(allocator, " AND h.role = ?");
        try bind_values.append(allocator, r);
    }

    if (opts.since) |s| {
        try sql.appendSlice(allocator, " AND h.created_iso >= ?");
        try bind_values.append(allocator, s);
    }

    if (opts.until) |u| {
        try sql.appendSlice(allocator, " AND h.created_iso <= ?");
        try bind_values.append(allocator, u);
    }

    // Close the subquery, then ORDER BY the aliased rank column from inside it.
    try sql.appendSlice(allocator, ") AS hits ORDER BY fts_rank");
    try sql.print(allocator, " LIMIT {d}", .{effective_limit});
    if ((opts.offset orelse 0) > 0) {
        try sql.print(allocator, " OFFSET {d}", .{opts.offset.?});
    }

    var rows = try db.query(allocator, sql.items, bind_values.items);
    defer rows.deinit();

    var results: std.ArrayList(SearchHit) = .empty;
    errdefer {
        for (results.items) |h| {
            var copy = h;
            copy.deinit(allocator);
        }
        results.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        // `total` is column index 7 (COUNT(*) OVER ()) — computed
        // before LIMIT/OFFSET so it represents the total count of rows
        // that matched the WHERE clause, not the returned page size.
        const total_count: u32 = std.fmt.parseInt(u32, row.values[7], 10) catch 0;
        const hit = SearchHit{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .role = try allocator.dupe(u8, row.values[2]),
            .snippet = try allocator.dupe(u8, row.values[3]),
            .tool_call_id = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .tool_name = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .created_at = try allocator.dupe(u8, row.values[6]),
            .total_count = total_count,
        };
        try results.append(allocator, hit);
    }

    return try results.toOwnedSlice(allocator);
}

pub fn getLatestMessage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?TUIHistory {
    const sql =
        \\SELECT
        \\    h.id, h.session_id, h.model, h.created_at,
        \\    h.response_content, h.finish_reason,
        \\    COALESCE(h.role, 'assistant'),
        \\    COALESCE(h.tool_calls_json, ''),
        \\    COALESCE(h.reasoning_content, ''),
        \\    COALESCE(h.agent, 'Agent'),
        \\    COALESCE(s.name, ''),
        \\    COALESCE(h.loop_index, 0),
        \\    COALESCE(h.tool_name, ''),
        \\    COALESCE(h.parent_session_id, ''),
        \\    COALESCE(h.temperature, 0.2),
        \\    COALESCE(h.is_thinking, 0),
        \\    COALESCE(h.prompt_tokens, 0),
        \\    COALESCE(h.completion_tokens, 0),
        \\    COALESCE(h.total_tokens, 0),
        \\    COALESCE(h.is_input, 0),
        \\    COALESCE(h.is_output, 0),
        \\    COALESCE(h.diffview_before, ''),
        \\    COALESCE(h.diffview_after, ''),
        \\    COALESCE(h.image_url, ''),
        \\    COALESCE(h.tool_call_id, '')
        \\FROM llm_history h
        \\LEFT JOIN sessions s ON h.session_id = s.id
        \\WHERE h.session_id = ?
        \\AND (h.is_feed_to_llm = 1 OR h.is_feed_to_llm IS NULL)
        \\ORDER BY h.created_at DESC
        \\LIMIT 1
    ;

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const parent_session_id_str = row.values[13];
        const diffview_before_str = row.values[21];
        const diffview_after_str = row.values[22];
        const image_url_str = row.values[23];
        const history = TUIHistory{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .model = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
            .response_content = try allocator.dupe(u8, row.values[4]),
            .finish_reason = try allocator.dupe(u8, row.values[5]),
            .role = try allocator.dupe(u8, row.values[6]),
            .tools = try allocator.dupe(u8, row.values[7]),
            .reasoning_content = if (row.values[8].len > 0) try allocator.dupe(u8, row.values[8]) else null,
            .agent = try allocator.dupe(u8, row.values[9]),
            .session_name = try allocator.dupe(u8, row.values[10]),
            .loop_index = std.fmt.parseInt(u32, row.values[11], 10) catch 0,
            .tool_name = try allocator.dupe(u8, row.values[12]),
            .parent_session_id = if (parent_session_id_str.len > 0) try allocator.dupe(u8, parent_session_id_str) else null,
            .temperature = std.fmt.parseFloat(f32, row.values[14]) catch 0.2,
            .is_thinking = std.mem.eql(u8, row.values[15], "1"),
            .prompt_tokens = std.fmt.parseInt(u32, row.values[16], 10) catch 0,
            .completion_tokens = std.fmt.parseInt(u32, row.values[17], 10) catch 0,
            .total_tokens = std.fmt.parseInt(u32, row.values[18], 10) catch 0,
            .is_input = parseRowBool(row.values[19]),
            .is_output = parseRowBool(row.values[20]),
            .diffview_before = if (diffview_before_str.len > 0) try allocator.dupe(u8, diffview_before_str) else null,
            .diffview_after = if (diffview_after_str.len > 0) try allocator.dupe(u8, diffview_after_str) else null,
            .image_urls = if (image_url_str.len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, image_url_str, '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .tool_call_id = if (row.values[24].len > 0) try allocator.dupe(u8, row.values[24]) else null,
        };
        row.deinit(allocator);
        return history;
    }

    return null;
}

// =============================================================================
// Get Sessions By Directory Functions
// =============================================================================

pub fn get_sessions_by_dir(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
) ![]SessionInfo {
    var results: std.ArrayList(SessionInfo) = .empty;

    const sql = "SELECT h.session_id, COALESCE(s.cwd, ''), MAX(h.created_at) as created_at FROM llm_history h LEFT JOIN sessions s ON h.session_id = s.id WHERE s.cwd = ? GROUP BY h.session_id ORDER BY MAX(h.created_at) DESC LIMIT 10";
    var rows = try db.query(allocator, sql, &[_][]const u8{cwd});
    defer rows.deinit();

    while (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .cwd = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
            .agent = try allocator.dupe(u8, ""),
            .session_name = try allocator.dupe(u8, ""),
        };
        try results.append(allocator, session);
        row.deinit(allocator);
    }

    return results.toOwnedSlice(allocator);
}

/// Get the latest session for a given directory
/// Returns null if no sessions exist for that directory
pub fn getLatestSessionByDir(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
) !?SessionInfo {
    const sql = "SELECT s.id, s.name, s.status, s.cwd, COALESCE(s.created_at, ''), COALESCE(s.updated_at, ''), COALESCE(h.agent, '') FROM sessions s LEFT JOIN llm_history h ON s.id = h.session_id WHERE s.cwd = ? GROUP BY s.id ORDER BY s.created_at DESC LIMIT 1";
    var rows = try db.query(allocator, sql, &[_][]const u8{cwd});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
            .cwd = try allocator.dupe(u8, row.values[3]),
            .created_at = try allocator.dupe(u8, row.values[4]),
            .updated_at = try allocator.dupe(u8, row.values[5]),
            .agent = try allocator.dupe(u8, row.values[6]),
        };
        row.deinit(allocator);
        return session;
    }

    return null;
}

// =============================================================================
// Get Current Agent By Session ID Functions
// =============================================================================

pub const AgentState = struct {
    agent: []const u8,
    temperature: f32,
    is_thinking: bool,
};

pub fn get_current_agent_by_session_id(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !AgentState {
    const sql = "SELECT COALESCE(agent, 'Agent'), COALESCE(temperature, 0), COALESCE(is_thinking, 1) FROM llm_history WHERE session_id = ? ORDER BY created_at DESC LIMIT 1";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        const agent_name = try allocator.dupe(u8, row.values[0]);
        const temperature = try std.fmt.parseFloat(f32, row.values[1]);
        const is_thinking = std.mem.eql(u8, row.values[2], "1");
        return AgentState{
            .agent = agent_name,
            .temperature = temperature,
            .is_thinking = is_thinking,
        };
    } else {
        return AgentState{
            .agent = try allocator.dupe(u8, "Agent"),
            .temperature = 0,
            .is_thinking = true,
        };
    }
}

// =============================================================================
// WORKER INFO - For activity registry display
// =============================================================================

/// Worker info for displaying in agent prompts
pub const WorkerInfo = struct {
    session_id: []const u8,
    working_directory: []const u8,
    last_activity: i64,
    last_activity_description: []const u8,
    /// Bound git worktree path for this worker's session (empty
    /// when no worktree is bound). Mirrors `sessions.git_worktree_cwd`.
    /// Populated by `getActiveWorker` / `getWorkerBySessionId` via a
    /// LEFT JOIN on `sessions`. Rendered into the system prompt's
    /// `## Active Workers` section so LLM agents see the actual
    /// working tree the other worker is operating in (not just the
    /// session's nominal cwd). See plan: doc-less chunk of the
    /// sprint 2 "git worktree cwd, worker" task.
    git_worktree_cwd: []const u8,

    pub fn deinit(self: *const WorkerInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.working_directory);
        allocator.free(self.last_activity_description);
        allocator.free(self.git_worktree_cwd);
    }

    /// Determine if this worker is a sub-agent by checking if session_id contains "subagent"
    pub fn isSubAgent(self: *const WorkerInfo) bool {
        return std.mem.indexOf(u8, self.session_id, "subagent") != null;
    }
};

/// Get all active workers with their info.
///
/// Selects every `worker` row joined to its `sessions` row (if any)
/// so callers can render the full agent-prompt "## Active Workers"
/// block — including the bound git worktree path. The LEFT JOIN
/// preserves workers whose session row has been deleted (a worker
/// row may outlive its session), falling back to `''` for
/// `git_worktree_cwd` (mirrors the COALESCE-on-NULL convention used
/// for `cwd`, `name`, etc. throughout the codebase).
pub fn getActiveWorker(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
) ![]WorkerInfo {
    const sql =
        \\SELECT
        \\    w.session_id,
        \\    COALESCE(w.working_directory, ''),
        \\    w.last_activity,
        \\    COALESCE(w.last_activity_description, ''),
        \\    COALESCE(s.git_worktree_cwd, '')
        \\FROM worker w
        \\LEFT JOIN sessions s ON s.id = w.session_id
        \\ORDER BY w.last_activity DESC
    ;

    var rows = try db.query(allocator, sql, &.{});
    defer rows.deinit();

    var workers = std.ArrayList(WorkerInfo).empty;
    errdefer {
        for (workers.items) |w| w.deinit(allocator);
        workers.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const last_activity = std.fmt.parseInt(i64, row.values[2], 10) catch 0;
        const worker = WorkerInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .working_directory = try allocator.dupe(u8, row.values[1]),
            .last_activity = last_activity,
            .last_activity_description = try allocator.dupe(u8, row.values[3]),
            .git_worktree_cwd = try allocator.dupe(u8, row.values[4]),
        };
        try workers.append(allocator, worker);
        row.deinit(allocator);
    }

    return try workers.toOwnedSlice(allocator);
}

/// Update worker's last activity timestamp with description
pub fn updateWorkerActivityWithDescription(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    worker_id: []const u8,
    description: []const u8,
) !void {
    const sql = "UPDATE worker SET last_activity = strftime('%s', 'now'), last_activity_description = ? WHERE id = ?";
    try db.exec(allocator, sql, &.{ description, worker_id });

    // Emit worker update event
    const now_timestamp: i64 = helpers.unixTimestamp();
    on_event_sent.onEventSendWorkers(allocator, .{
        .action = "updated",
        .id = worker_id,
        .session_id = "",
        .working_directory = "",
        .last_activity = now_timestamp,
        .last_activity_description = description,
        .created_at = "",
    }) catch {};
}

/// Remove a worker
pub fn removeWorker(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    worker_id: []const u8,
) !void {
    const sql = "DELETE FROM worker WHERE id = ?";
    try db.exec(allocator, sql, &.{worker_id});

    // Emit worker deleted event
    on_event_sent.onEventSendWorkers(allocator, .{
        .action = "deleted",
        .id = worker_id,
        .session_id = "",
        .working_directory = "",
        .last_activity = 0,
        .last_activity_description = "",
        .created_at = "",
    }) catch {};
}

pub fn deleteAllWorkers(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) !void {
    const sql = "DELETE FROM worker";
    try db.exec(allocator, sql, &.{});
}

/// Delete a worker by session_id and emit SSE "deleted" event for each affected row
pub fn deleteWorkerBySessionId(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !void {
    // Capture affected worker IDs BEFORE deleting so we can emit one event per row
    const select_sql = "SELECT id FROM worker WHERE session_id = ?";
    var rows = try db.query(allocator, select_sql, &.{session_id});
    defer rows.deinit();

    var affected_ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (affected_ids.items) |id| allocator.free(id);
        affected_ids.deinit(allocator);
    }

    while (try rows.next()) |row| {
        try affected_ids.append(allocator, try allocator.dupe(u8, row.values[0]));
    }

    const delete_sql = "DELETE FROM worker WHERE session_id = ?";
    try db.exec(allocator, delete_sql, &.{session_id});

    // Emit one worker deleted event per affected row
    for (affected_ids.items) |worker_id| {
        on_event_sent.onEventSendWorkers(allocator, .{
            .action = "deleted",
            .id = worker_id,
            .session_id = "",
            .working_directory = "",
            .last_activity = 0,
            .last_activity_description = "",
            .created_at = "",
        }) catch {};
    }
}

pub fn deleteAllQueuedMessages(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) !void {
    const sql = "DELETE FROM session_queue_messages";
    try db.exec(allocator, sql, &.{});
}

/// Delete all queued messages for a session
pub fn deleteQueuedMessagesBySessionId(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !void {
    const sql = "DELETE FROM session_queue_messages WHERE session_id = ?";
    try db.exec(allocator, sql, &.{session_id});
}

/// Get a worker by session_id
///
/// Returns `null` when no worker row matches `session_id` (e.g. when
/// no LLM call has been issued yet for this session, or when the
/// session/worker has been cancelled). Selects `git_worktree_cwd`
/// from the matching `sessions` row so callers (e.g. `worker_get`
/// HTTP handler) can show the bound worktree path; falls back to
/// `''` when the worker row exists but its session row was deleted.
pub fn getWorkerBySessionId(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?WorkerInfo {
    const sql =
        \\SELECT
        \\    w.session_id,
        \\    COALESCE(w.working_directory, ''),
        \\    w.last_activity,
        \\    COALESCE(w.last_activity_description, ''),
        \\    COALESCE(s.git_worktree_cwd, '')
        \\FROM worker w
        \\LEFT JOIN sessions s ON s.id = w.session_id
        \\WHERE w.session_id = ?
    ;

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const last_activity = std.fmt.parseInt(i64, row.values[2], 10) catch 0;
        const worker = WorkerInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .working_directory = try allocator.dupe(u8, row.values[1]),
            .last_activity = last_activity,
            .last_activity_description = try allocator.dupe(u8, row.values[3]),
            .git_worktree_cwd = try allocator.dupe(u8, row.values[4]),
        };
        row.deinit(allocator);
        return worker;
    }
    return null;
}

/// Check if a task is currently running (a worker row exists for it).
///
/// The nalar convention is `task.id == session.id`, so the worker
/// table's `session_id` column holds the task's id. If a row exists,
/// the task is currently being processed by a worker (its LLM call is
/// in-flight or streaming). Tasks in this state cannot be deleted —
/// use cases that delete a task should check this first and refuse.
///
/// The companion `isSessionRunning` checks the `worker.id` (primary
/// key) column; this helper checks the `worker.session_id` foreign
/// key. They are intentionally separate so callers that already have
/// one or the other can pick the cheap query.
pub fn isTaskRunning(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    task_id: []const u8,
) bool {
    const sql = "SELECT 1 FROM worker WHERE session_id = ? LIMIT 1";
    var rows = db.query(allocator, sql, &.{task_id}) catch return false;
    defer rows.deinit();
    return (rows.next() catch return false) != null;
}

/// Cancel a session (set cancelled flag)
pub fn cancelSession(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !void {
    const sql = "UPDATE worker SET cancelled = 1 WHERE id = ?";
    try db.exec(allocator, sql, &.{session_id});
}

/// Struct to hold queued message data including image_url
pub const QueuedMessage = struct {
    message: []const u8,
    image_url: []const u8,
};

/// Returns null if no messages queued
/// Caller must free the returned slice
pub fn getQueueMessages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?std.ArrayList(QueuedMessage) {
    const select_sql = "SELECT message, image_url FROM session_queue_messages WHERE session_id = ? ORDER BY created_at ASC";
    var rows = try db.query(allocator, select_sql, &.{session_id});
    defer rows.deinit();

    var messages = std.ArrayList(QueuedMessage).empty;
    errdefer {
        for (messages.items) |msg| {
            allocator.free(msg.message);
            allocator.free(msg.image_url);
        }
        messages.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const msg = try allocator.dupe(u8, row.values[0]);
        const image_url = try allocator.dupe(u8, row.values[1]);
        try messages.append(allocator, .{ .message = msg, .image_url = image_url });
    }

    if (messages.items.len == 0) {
        messages.deinit(allocator);
        return null;
    }

    return messages;
}

// =============================================================================
// Session Table Functions (migrated from session_table.zig)
// =============================================================================

/// Session info for CRUD operations (from session_table.zig)
pub const SessionTableInfo = struct {
    id: []u8,
    name: []u8,
    status: []u8,
    cwd: []u8,
    created_at: []u8,
    updated_at: []u8,
    selected_profile_model: []u8,
    git_worktree_cwd: []u8,
    /// Migration 063 — opt-in flag for unattended mode. Stored as text
    /// ("0" / "1") to match `is_auto_retry_until_stop`'s INTEGER column
    /// convention used by the rest of the codebase.
    is_auto_retry_until_stop: []u8,
    /// Migration 063 — most recent `finish_reason` the workflow observed
    /// for this session. Empty string before the first successful turn.
    last_finish_reason: []u8,

    pub fn deinit(self: SessionTableInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.status);
        allocator.free(self.cwd);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        allocator.free(self.selected_profile_model);
        allocator.free(self.git_worktree_cwd);
        allocator.free(self.is_auto_retry_until_stop);
        allocator.free(self.last_finish_reason);
    }
};

/// Create a new session with status set to 'active'
///
/// `is_auto_retry_until_stop`: "1" enables unattended mode for this
/// session (workflow keeps retrying past the 10-attempt TooManyRetries
/// bail). Empty string OR anything other than "1" coerces to "0" via
/// the SQL binding default (matches the NOT NULL DEFAULT 0 schema).
pub fn create_session(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    name: []const u8,
    is_auto_retry_until_stop: []const u8,
) !SessionTableInfo {
    const flag = if (std.mem.eql(u8, is_auto_retry_until_stop, "1")) "1" else "0";
    const sql =
        "INSERT INTO sessions (id, name, status, created_at, updated_at, is_auto_retry_until_stop) " ++
        "VALUES (?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?)";
    try db.exec(allocator, sql, &.{ id, name, flag });

    // Broadcast session created event — carry the new columns in the
    // SSE payload so ChatsList updates live without a refetch.
    ai_mod.on_event_sent.onEventSendSessions(allocator, .{
        .action = "created",
        .id = id,
        .name = name,
        .status = "active",
        .cwd = "",
        .created_at = "",
        .updated_at = "",
        .selected_profile_model = "",
        .git_worktree_cwd = "",
        .is_auto_retry_until_stop = flag,
        .last_finish_reason = "",
    }) catch {};

    return SessionTableInfo{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .status = try allocator.dupe(u8, "active"),
        // cwd is intentionally empty in create_session — the worker
        // upserts the cwd on the first llm_history insert (see
        // insert_llm_histories.zig:183). Pre-existing pattern; the
        // previous version of this literal also initialized cwd = ""
        // but the lazy-analysis of `zig build test` didn't catch the
        // missing field. The install target (which compiled fine
        // before) now flags it because the struct grew by 2 fields
        // and the missing `.cwd` slipped past the original code path.
        .cwd = try allocator.dupe(u8, ""),
        .created_at = try allocator.dupe(u8, ""),
        .updated_at = try allocator.dupe(u8, ""),
        .selected_profile_model = try allocator.dupe(u8, ""),
        .git_worktree_cwd = try allocator.dupe(u8, ""),
        // Migration 063 — populated with the just-bound value for the
        // flag; last_finish_reason is empty until the workflow writes
        // the first value (Chunk 2 Task 2.1).
        .is_auto_retry_until_stop = try allocator.dupe(u8, flag),
        .last_finish_reason = try allocator.dupe(u8, ""),
    };
}

/// Get a session by id
pub fn getSession(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !?SessionTableInfo {
    const sql =
        \\SELECT s.id, s.name, s.status, COALESCE(s.cwd, ''),
        \\       COALESCE(s.created_at, ''), COALESCE(s.updated_at, ''),
        \\       COALESCE(s.selected_profile_model, ''), COALESCE(s.git_worktree_cwd, ''),
        \\       COALESCE(s.is_auto_retry_until_stop, '0'), COALESCE(s.last_finish_reason, '')
        \\FROM sessions s WHERE s.id = ?
    ;

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const session = SessionTableInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
            .cwd = try allocator.dupe(u8, row.values[3]),
            .created_at = try allocator.dupe(u8, row.values[4]),
            .updated_at = try allocator.dupe(u8, row.values[5]),
            .selected_profile_model = try allocator.dupe(u8, row.values[6]),
            .git_worktree_cwd = try allocator.dupe(u8, row.values[7]),
            // Migration 063 — row.values[8] = is_auto_retry_until_stop
            // (COALESCE'd to '0'); row.values[9] = last_finish_reason
            // (COALESCE'd to '').
            .is_auto_retry_until_stop = try allocator.dupe(u8, row.values[8]),
            .last_finish_reason = try allocator.dupe(u8, row.values[9]),
        };
        row.deinit(allocator);
        return session;
    }

    return null;
}

/// Update session status
pub fn update_session_status(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    new_status: []const u8,
) !void {
    const sql = "UPDATE sessions SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ new_status, id });

    // Get updated session data and broadcast
    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        ai_mod.on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
        }) catch {};
    }
}

/// Update session name
pub fn updateSessionName(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    new_name: []const u8,
) !void {
    const sql = "UPDATE sessions SET name = ? WHERE id = ?";
    try db.exec(allocator, sql, &.{ new_name, id });

    // Get updated session data and broadcast
    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        ai_mod.on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
        }) catch {};
    }
}

/// Rename a workspace item task. The rename cascades to the linked
/// session via `updateSessionName`, which itself emits a
/// `session.updated` SSE event so subscribers (e.g. the ChatsList
/// sidebar) see the new name in real time. The cascade target is
/// the task's own id (per the `task.id == session_id` convention;
/// the redundant `session_id` column was dropped in Migration 052).
///
/// This is the rename path used by `PUT /api/workspaces/tasks/:task_id`
/// and `PUT /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id`.
pub fn updateTaskName(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    new_name: []const u8,
) !void {
    // 1) Update the task row.
    const task_sql = "UPDATE workspace_item_tasks SET name = ?, updated_at = datetime('now') WHERE id = ?";
    try db.exec(allocator, task_sql, &.{ new_name, id });

    // 2) Verify the task exists. If not (rare — e.g. the caller's
    // id is wrong) there's nothing to cascade. Return early; the
    // UPDATE above is a no-op in that case.
    const task = (getWorkspaceItemTask(allocator, db, id) catch null) orelse return;
    defer task.deinit(allocator);

    // 3) The task IS the session id. Always cascade.
    const session_id = id;

    // 4) Cascade the rename to the linked session. `updateSessionName`
    // also re-reads the session row and broadcasts a `session.updated`
    // SSE event with the new name, which is the ChatsList hook.
    // A failure here is non-fatal — the task row is the source of
    // truth for the sidebar, and the next rename will reconcile.
    updateSessionName(allocator, db, session_id, new_name) catch {};
}

/// Update the unattended-mode flag for an existing session (Migration 063).
///
/// `value` must be "1" or "0" — handler layer validates the input shape.
/// Empty string is rejected here (treated as no-op) so a malformed PUT
/// doesn't accidentally flip the flag. The schema's NOT NULL DEFAULT 0
/// keeps existing rows consistent.
///
/// Broadcasts an "updated" SSE event so the ChatsList `🔁 unattended`
/// badge updates live without a refetch.
pub fn updateSessionAutoRetryUntilStop(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    value: []const u8,
) !void {
    const normalized: []const u8 = if (std.mem.eql(u8, value, "1")) "1" else "0";
    const sql =
        "UPDATE sessions SET is_auto_retry_until_stop = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ normalized, id });

    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        ai_mod.on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
            .is_auto_retry_until_stop = s.is_auto_retry_until_stop,
            .last_finish_reason = s.last_finish_reason,
        }) catch {};
    }
}

/// Update the most-recent `finish_reason` cache for an existing session
/// (Migration 063). Called by `workflow.zig` after every LLM call so a
/// future workflow invocation (e.g., after a server restart) starts
/// from the right state without re-querying `llm_history.finish_reason`.
///
/// No SSE broadcast — `last_finish_reason` is an internal cache, not a
/// UI surface (the ChatView shows the live SSE-streamed reason; this
/// column only backs the unattended-soft-bail logic in workflow.zig).
pub fn updateSessionLastFinishReason(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    finish_reason: []const u8,
) !void {
    const sql =
        "UPDATE sessions SET last_finish_reason = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ finish_reason, id });
}

/// Stamp `last_human_touched_at = <unix_ms>` on a task. Called by
/// every HTTP handler that mutates a task or its chat session on
/// behalf of a human user (drag, rename, edit description, pin, send
/// message, open chat). The kanban card query then compares against
/// `sessions.updated_at` (denormalized by `updateSessionLastFinishReason`)
/// to decide whether to show the "AI finished — awaiting review" dot
/// or the "reviewed" checkmark.
///
/// Cheaper than per-action auditing — we just need a monotonic
/// timestamp. Idempotent: a second call overwrites the first.
///
/// Schema: `workspace_item_tasks.last_human_touched_at INTEGER NULL`
/// (Migration 065). We format the unix-ms integer to a string and
/// bind via `?` per the project's SqliteBackend convention
/// (`db.exec` only binds TEXT; see memory
/// `sqlite-backend-exec-binds-text-only`).
///
/// The `now_unix_ms` arg lets callers override the stamp time (useful
/// for tests). When null, we read the real current time via libc
/// `gettimeofday` (Zig 0.16 removed `std.time.timestamp` per project
/// memory `zig-0.16-stdlib-changes`).
pub fn updateTaskLastHumanTouchedAt(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    task_id: []const u8,
    now_unix_ms: ?i64,
) !void {
    const now_ms = now_unix_ms orelse unixMillisNow();
    const touched_at_str = try std.fmt.allocPrint(
        allocator,
        "{d}",
        .{now_ms},
    );
    defer allocator.free(touched_at_str);

    const sql =
        "UPDATE workspace_item_tasks SET last_human_touched_at = ? WHERE id = ?";
    try db.exec(allocator, sql, &.{ touched_at_str, task_id });
}

/// Current Unix epoch time in milliseconds. Used by
/// `updateTaskLastHumanTouchedAt` as the default timestamp; can also
/// be called directly by handlers that need a unix-ms stamp.
///
/// Replaces Zig 0.16-removed `std.time.timestamp()`. We use libc
/// `gettimeofday` directly — matches the pattern in
/// `src/helpers/...` and avoids the Zig 0.16 `std.Io` runtime
/// dependency for a one-shot monotonic stamp.
///
/// `extern "c"` MUST be at module scope in Zig 0.16 (per project
/// memory `zig-language-quirks` §"extern c declarations — symbol
/// name rules"). `c_long` is platform-sized — use the project's
/// `Clong` alias pattern (LP64 vs LLP64).
const builtin = @import("builtin");
const Clong = if (@bitSizeOf(usize) == 64 and builtin.os.tag != .windows)
    i64
else
    i32;

extern "c" fn gettimeofday(tv: ?*PosixTimeval, tz: ?*anyopaque) c_int;

const PosixTimeval = extern struct {
    sec: Clong,
    usec: Clong,
};

pub fn unixMillisNow() i64 {
    var tv: PosixTimeval = undefined;
    _ = gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1000 + @divFloor(@as(i64, tv.usec), 1000);
}

/// Update session selected_profile_model (the name of a profile in
/// LlmConfig.profiles_models). Pass empty string or null to clear.
pub fn updateSessionSelectedProfileModel(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    selected_profile_model: ?[]const u8,
) !void {
    const effective: []const u8 = selected_profile_model orelse "";
    const sql = "UPDATE sessions SET selected_profile_model = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ effective, id });

    // Re-read and broadcast the updated session
    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        ai_mod.on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
        }) catch {};
    }
}

/// Update session git_worktree_cwd. Pass empty string or null to clear.
/// When the value changes, broadcast a session.updated SSE event so the
/// ChatsList sidebar updates its 🌳 badge in real time.
pub fn updateSessionGitWorktreeCwd(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    git_worktree_cwd: ?[]const u8,
) !void {
    const effective: []const u8 = git_worktree_cwd orelse "";
    const sql = "UPDATE sessions SET git_worktree_cwd = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ effective, id });

    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        ai_mod.on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
        }) catch {};
    }
}

/// Delete a session by id
pub fn delete_session(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !void {
    const sql = "DELETE FROM sessions WHERE id = ?";
    try db.exec(allocator, sql, &.{id});

    // Broadcast session deleted event
    ai_mod.on_event_sent.onEventSendSessions(allocator, .{
        .action = "deleted",
        .id = id,
        .name = "",
        .status = "",
        .cwd = "",
        .created_at = "",
        .updated_at = "",
        .selected_profile_model = "",
        .git_worktree_cwd = "",
    }) catch {};
}

/// List all sessions
pub fn list_sessions(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
) ![]SessionTableInfo {
    const sql = "SELECT id, name, status, COALESCE(selected_profile_model, '') FROM sessions ORDER BY id";

    var rows = try db.query(allocator, sql, &.{});
    defer rows.deinit();

    var sessions = std.ArrayList(SessionTableInfo).empty;
    errdefer {
        for (sessions.items) |s| s.deinit(allocator);
        sessions.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const session = SessionTableInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
            .selected_profile_model = try allocator.dupe(u8, row.values[3]),
        };
        try sessions.append(allocator, session);
        row.deinit(allocator);
    }

    return try sessions.toOwnedSlice(allocator);
}

// =============================================================================
// Session Skills Functions (migrated from session_skills.zig)
// =============================================================================

/// Check if a skill is already loaded in the database
pub fn isSkillLoaded(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    skill_name: []const u8,
) !bool {
    if (session_id.len == 0) return false;

    const sql = "SELECT 1 FROM session_skills WHERE session_id = ? AND skill_name = ? LIMIT 1";
    var rows = try db.query(allocator, sql, &.{ session_id, skill_name });
    defer rows.deinit();

    if (try rows.next()) |row| {
        row.deinit(allocator);
        return true;
    }
    return false;
}

/// Save a loaded skill to the database for persistence
pub fn saveSkill(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    skill_name: []const u8,
    content: []const u8,
) !void {
    // Skip if session_id is empty
    if (session_id.len == 0) return;

    const sql = "INSERT OR REPLACE INTO session_skills (session_id, skill_name, content, loaded_at) VALUES (?, ?, ?, strftime('%s', 'now'))";
    try db.exec(allocator, sql, &.{ session_id, skill_name, content });
    logger.debugFmt("Skill '{s}' saved to database for session {s}", .{ skill_name, session_id });
}

/// Skill info for session_skills table
pub const SkillInfo = struct {
    skill_name: []u8,
    content: []u8,
    loaded_at: ?i64 = null,

    pub fn deinit(self: SkillInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.skill_name);
        allocator.free(self.content);
    }
};

/// Get all skills loaded for a session
pub fn getSessionSkills(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]SkillInfo {
    if (session_id.len == 0) return &.{};

    const sql = "SELECT skill_name, content, loaded_at FROM session_skills WHERE session_id = ?";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    var skills = std.ArrayList(SkillInfo).empty;
    errdefer {
        for (skills.items) |*s| s.deinit(allocator);
        skills.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const skill_name = row.values[0];
        const content = row.values[1];
        const loaded_at = if (row.values[2].len > 0) std.fmt.parseInt(i64, row.values[2], 10) catch null else null;

        try skills.append(allocator, .{
            .skill_name = try allocator.dupe(u8, skill_name),
            .content = try allocator.dupe(u8, content),
            .loaded_at = loaded_at,
        });
        row.deinit(allocator);
    }

    return try skills.toOwnedSlice(allocator);
}

// =============================================================================
// Workspace Items Functions (migrated from workspace_items_table.zig)
// =============================================================================

/// WorkspaceItem info for CRUD operations
pub const WorkspaceItemInfo = struct {
    id: []u8,
    workspace_id: []u8,
    item_type: []u8,
    name: ?[]u8 = null,
    path: ?[]u8 = null,
    created_at: ?[]u8 = null,
    updated_at: ?[]u8 = null,

    pub fn deinit(self: WorkspaceItemInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.workspace_id);
        allocator.free(self.item_type);
        if (self.name) |n| allocator.free(n);
        if (self.path) |p| allocator.free(p);
        if (self.created_at) |ca| allocator.free(ca);
        if (self.updated_at) |ua| allocator.free(ua);
    }
};

/// Create a new workspace item
pub fn createWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
) !WorkspaceItemInfo {
    const sql = "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES (?, ?, ?)";
    try db.exec(allocator, sql, &.{ id, workspace_id, item_type });

    return WorkspaceItemInfo{
        .id = try allocator.dupe(u8, id),
        .workspace_id = try allocator.dupe(u8, workspace_id),
        .item_type = try allocator.dupe(u8, item_type),
    };
}

/// Get a workspace item by id
pub fn getWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !?WorkspaceItemInfo {
    const sql = "SELECT id, workspace_id, item_type, name, path, created_at, updated_at FROM workspace_items WHERE id = ?";

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const item = WorkspaceItemInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_id = try allocator.dupe(u8, row.values[1]),
            .item_type = try allocator.dupe(u8, row.values[2]),
            .name = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .path = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .created_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .updated_at = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else null,
        };
        row.deinit(allocator);
        return item;
    }

    return null;
}

/// Update workspace item
pub fn updateWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
) !void {
    const sql = "UPDATE workspace_items SET workspace_id = ?, item_type = ?, updated_at = datetime('now') WHERE id = ?";
    try db.exec(allocator, sql, &.{ workspace_id, item_type, id });
}

/// Update only the `path` column of a workspace item. Used by
/// the kanban "Set project root" banner to backfill the path on
/// existing kanbans that were created before the path field
/// existed on the create endpoint. Pass `null` to clear the
/// path; pass a non-empty slice to set it. The empty-string
/// coercion is handled at the caller (handlers map `""` → `null`
/// to match the column's nullable contract).
pub fn updateWorkspaceItemPath(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    path: ?[]const u8,
) !void {
    if (path) |p| {
        const sql = "UPDATE workspace_items SET path = ?, updated_at = datetime('now') WHERE id = ?";
        try db.exec(allocator, sql, &.{ p, id });
    } else {
        const sql = "UPDATE workspace_items SET path = NULL, updated_at = datetime('now') WHERE id = ?";
        try db.exec(allocator, sql, &.{id});
    }
}

/// Update only the `name` column of a workspace item. Used by the
/// Kanban Settings dialog (and the KanbanView header pencil) to
/// rename a workspace item — typically a kanban whose title the
/// user wants to change (e.g. "kanban sprint 1" → "Sprint 12").
///
/// The pattern mirrors `updateWorkspaceItemPath` (single-column
/// UPDATE + `updated_at = datetime('now')`). Both columns could
/// theoretically be batched into a single UPDATE, but the rest of
/// the project uses single-column setters (see `updateWorkspaceItem`
/// above + `updateWorkspaceItemPath`) — keeping the same shape
/// makes the model layer easy to reason about and matches the
/// handler's per-field `if (presence)` branching.
///
/// Pass a non-null, non-empty slice to set the name. The handler
/// layer rejects empty strings with a 400 BEFORE reaching this
/// function; passing `""` here would write the empty string into
/// the DB (the column has no `NOT NULL DEFAULT ''` constraint — it's
/// nullable).
///
/// Why the column is nullable (instead of NOT NULL DEFAULT ''):
/// earlier migration (`migration.zig:484`) added `name TEXT` without
/// a NOT NULL constraint, so existing rows pre-migration retain
/// `name = NULL`. The frontend renders `null` and `""` indistinguishably
/// via `{{ item.name ?? '' }}` or `column.name ?? ''`. Changing this
/// to NOT NULL DEFAULT '' is out of scope (would require a backfill
/// migration on every row + every referenced field).
pub fn updateWorkspaceItemName(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    name: []const u8,
) !void {
    const sql = "UPDATE workspace_items SET name = ?, updated_at = datetime('now') WHERE id = ?";
    try db.exec(allocator, sql, &.{ name, id });
}

/// Delete a workspace item by id
pub fn deleteWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !void {
    const sql = "DELETE FROM workspace_items WHERE id = ?";
    try db.exec(allocator, sql, &.{id});
}

/// List all workspace items by workspace_id.
///
/// Sorted by `wi.position DESC, wi.id ASC`. The `position` column is
/// the drag-and-drop sort key (added by Migration 045). The `id ASC`
/// tiebreaker makes the order deterministic when two items share a
/// position (shouldn't happen post-reorder, but defense-in-depth).
/// Uses the project's "always alias tables in SQL" convention
/// (see ~/.config/nalar/memories/) — the `wi` alias matches the
/// short-single-letter pattern used elsewhere (`h` for
/// `llm_history`, `s` for `sessions`, `t` for `workspace_item_tasks`).
pub fn listWorkspaceItems(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
) ![]WorkspaceItemInfo {
    const sql = "SELECT wi.id, wi.workspace_id, wi.item_type, wi.name, wi.path, wi.created_at, wi.updated_at FROM workspace_items wi WHERE wi.workspace_id = ? ORDER BY wi.position DESC, wi.id ASC";

    var rows = try db.query(allocator, sql, &.{workspace_id});
    defer rows.deinit();

    var items = std.ArrayList(WorkspaceItemInfo).empty;
    errdefer {
        for (items.items) |item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const item = WorkspaceItemInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_id = try allocator.dupe(u8, row.values[1]),
            .item_type = try allocator.dupe(u8, row.values[2]),
            .name = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .path = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .created_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .updated_at = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else null,
        };
        try items.append(allocator, item);
        row.deinit(allocator);
    }

    return try items.toOwnedSlice(allocator);
}

/// List ALL workspace items (for N+1 fix). Same sort as the
/// per-workspace list: `wi.position DESC, wi.id ASC`. New items get
/// position = MAX(position) + 1 (scoped by workspace_id) at insert
/// time, so the per-workspace "newest at top" visual order is
/// preserved here too. Uses the project's "always alias tables
/// in SQL" convention — see `listWorkspaceItems` for details.
pub fn listAllWorkspaceItems(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
) ![]WorkspaceItemInfo {
    const sql = "SELECT wi.id, wi.workspace_id, wi.item_type, wi.name, wi.path, wi.created_at, wi.updated_at FROM workspace_items wi ORDER BY wi.position DESC, wi.id ASC";

    var rows = try db.query(allocator, sql, &.{});
    defer rows.deinit();

    var items = std.ArrayList(WorkspaceItemInfo).empty;
    errdefer {
        for (items.items) |item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const item = WorkspaceItemInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_id = try allocator.dupe(u8, row.values[1]),
            .item_type = try allocator.dupe(u8, row.values[2]),
            .name = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .path = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .created_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .updated_at = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else null,
        };
        try items.append(allocator, item);
        row.deinit(allocator);
    }

    return try items.toOwnedSlice(allocator);
}

// =============================================================================
// Workspace Context (used by build_messages_for_agent_prompt.zig to render
// the `## Workspace Context` section of the system prompt — see
// docs/plans/2026-06-19-workspace-siblings-in-prompt.md, Chunk 1)
// =============================================================================

/// Maximum number of sibling items returned per session. When a
/// workspace has more items than this, the helper renders the
/// first 20 (sorted with `is_self` first) and reports
/// `truncated_items_count = total_item_count - MAX_SIBLING_ITEMS`.
/// Centralized here as a `pub const` so the Chunk 2 renderer
/// (`BuildWorkspaceContext` in `build_messages_for_agent_prompt.zig`)
/// can reuse the same value to format the cap footer.
pub const MAX_SIBLING_ITEMS: u32 = 20;

/// Maximum number of tasks listed under each sibling item.
pub const MAX_TASKS_PER_ITEM: u32 = 5;

/// Context for the "Workspace Context" dynamic prompt section.
/// Returned by `getWorkspaceContext`; the tui layer's
/// `BuildWorkspaceContext` consumes this struct and renders
/// the markdown block.
pub const WorkspaceContext = struct {
    workspace_id: []u8,
    self_item_id: []u8, // task's own item id
    self_task_id: []u8, // task's own id
    self_item_type: []u8, // parent's workspace_items.item_type ('kanban', 'chat', 'folder', ...)
    self_path: ?[]u8, // task's own item path (cwd hint)
    siblings: []SiblingItem, // all items in the same workspace, self first
    truncated_items_count: u32, // > 0 when 20-item cap hit
    total_item_count: u32, // for diagnostic footer

    pub const SiblingItem = struct {
        id: []u8,
        item_type: []u8,
        name: ?[]u8,
        path: ?[]u8,
        is_self: bool,
        tasks: []SiblingTask, // ≤ MAX_TASKS_PER_ITEM
        truncated_tasks_count: u32, // > 0 when 5-task cap hit

        pub const SiblingTask = struct {
            id: []u8,
            name: []u8,
            task_type: []u8,
        };

        /// Free the per-item allocations. Mirrors the parent's
        /// `WorkspaceContext.deinit` shape so callers that iterate
        /// `siblings` and free each entry don't have to inline
        /// the cleanup at every call site (see Pitfall 3 in the
        /// plan — Zig 0.16 requires struct methods to be declared
        /// inside the struct body).
        pub fn deinit(self: SiblingItem, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.item_type);
            if (self.name) |n| allocator.free(n);
            if (self.path) |p| allocator.free(p);
            for (self.tasks) |t| {
                allocator.free(t.id);
                allocator.free(t.name);
                allocator.free(t.task_type);
            }
            allocator.free(self.tasks);
        }
    };

    /// Free all heap-allocated fields of this `WorkspaceContext`.
    /// Callers MUST call `deinit` on a non-null value returned by
    /// `getWorkspaceContext` exactly once.
    pub fn deinit(self: WorkspaceContext, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.self_item_id);
        allocator.free(self.self_task_id);
        allocator.free(self.self_item_type);
        if (self.self_path) |p| allocator.free(p);
        for (self.siblings) |sib| sib.deinit(allocator);
        allocator.free(self.siblings);
    }
};

/// Look up the workspace context for a session. Returns `null`
/// when the session is not bound to any `workspace_item_task`
/// (the caller omits the section silently in that case — matches
/// `appendSkillsListing` behavior).
///
/// Anchor: `workspace_item_tasks.id = ?` → task → item → workspace.
/// (The `session_id` column was dropped in Migration 052; `id` IS
/// the session id for kanban / routine tasks per the
/// `task.id == session_id` convention.)
/// Then enumerate `workspace_items WHERE workspace_id = ?` (capped at
/// `MAX_SIBLING_ITEMS`, ordered with self first). For each item,
/// enumerate its tasks (capped at `MAX_TASKS_PER_ITEM`).
///
/// SQL convention: all tables are aliased (`wi` for workspace_items,
/// `t` for workspace_item_tasks) per the project's
/// `nalar-sql-alias-tables` memory rule.
pub fn getWorkspaceContext(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?WorkspaceContext {
    if (session_id.len == 0) return null;

    // 1. Anchor: find the task bound to this session.
    //
    // The `task.id == session_id` convention (see AppLayout.vue
    // `:chat-id="activeTask.id"` and
    // workspacesStore.subscribeToSessionEvents comment in
    // workspaces.ts:1412) means the session_id we receive from the
    // frontend IS the task's own id. We anchor on `t.id` directly.
    // (Historically this query used `WHERE t.session_id = ?`, but
    // that column was redundant with `t.id` and was being populated
    // inconsistently — the frontend's createTask does not set it, so
    // freshly-created kanban tasks had `session_id = NULL` and the
    // `## Workspace Context` section was silently omitted from the
    // system prompt. Migration 052 dropped the column.)
    const anchor_sql =
        \\SELECT t.id, t.workspace_item_id, wi.workspace_id, wi.path, wi.item_type
        \\FROM workspace_item_tasks t
        \\JOIN workspace_items wi ON wi.id = t.workspace_item_id
        \\WHERE t.id = ?
    ;
    var anchor_q = try db.query(allocator, anchor_sql, &.{session_id});
    defer anchor_q.deinit();
    const anchor_row = (try anchor_q.next()) orelse return null;
    const self_task_id = try allocator.dupe(u8, anchor_row.values[0]);
    const self_item_id = try allocator.dupe(u8, anchor_row.values[1]);
    const workspace_id = try allocator.dupe(u8, anchor_row.values[2]);
    const self_path: ?[]u8 = if (anchor_row.values[3].len > 0)
        try allocator.dupe(u8, anchor_row.values[3])
    else
        null;
    const self_item_type = try allocator.dupe(u8, anchor_row.values[4]);
    anchor_row.deinit(allocator); // Pitfall 1: pass allocator explicitly, NOT `anchor_row.allocator`

    // 2. Total item count for the "and N more" footer.
    var count_q = try db.query(
        allocator,
        "SELECT COUNT(*) FROM workspace_items wi WHERE wi.workspace_id = ?",
        &.{workspace_id},
    );
    defer count_q.deinit();
    const count_row = (try count_q.next()) orelse {
        // Defensive: COUNT(*) should always return a row. If not,
        // synthesize an empty siblings list so the caller still
        // gets a usable context.
        return WorkspaceContext{
            .workspace_id = workspace_id,
            .self_item_id = self_item_id,
            .self_task_id = self_task_id,
            .self_item_type = self_item_type,
            .self_path = self_path,
            .siblings = &.{},
            .truncated_items_count = 0,
            .total_item_count = 0,
        };
    };
    const total_item_count = try std.fmt.parseInt(u32, count_row.values[0], 10);
    count_row.deinit(allocator); // Pitfall 1 again

    // 3. Enumerate items (capped at MAX_SIBLING_ITEMS).
    //
    // Pitfall 2: SQLite's `LIMIT ?` doesn't bind an integer via the
    // SqliteBackend's text-binding path. Inline the limit into the
    // SQL string at build time. Mirrors the project's existing
    // convention in `routines/model.zig` where index hints are
    // also inlined (no parameterized LIMIT).
    const items_sql = try std.fmt.allocPrint(allocator,
        \\SELECT wi.id, wi.item_type, wi.name, wi.path,
        \\       (wi.id = ?) AS is_self
        \\FROM workspace_items wi
        \\WHERE wi.workspace_id = ?
        \\ORDER BY is_self DESC, wi.position DESC, wi.id ASC
        \\LIMIT {d}
    , .{MAX_SIBLING_ITEMS});
    defer allocator.free(items_sql);

    var items_q = try db.query(allocator, items_sql, &.{ self_item_id, workspace_id });
    defer items_q.deinit();

    var siblings: std.ArrayList(WorkspaceContext.SiblingItem) = .empty;
    errdefer {
        for (siblings.items) |s| s.deinit(allocator);
        siblings.deinit(allocator);
    }

    while (try items_q.next()) |row| {
        const item_id_owned = try allocator.dupe(u8, row.values[0]);
        errdefer allocator.free(item_id_owned);
        const item_type_owned = try allocator.dupe(u8, row.values[1]);
        const name_owned: ?[]u8 = if (row.values[2].len > 0) try allocator.dupe(u8, row.values[2]) else null;
        const path_owned: ?[]u8 = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null;
        const is_self_owned = std.mem.eql(u8, row.values[4], "1");
        row.deinit(allocator);

        // 4. Enumerate tasks under this item (capped at
        // MAX_TASKS_PER_ITEM). Same inlined-LIMIT pattern as above.
        const tasks_sql = try std.fmt.allocPrint(allocator,
            \\SELECT t.id, t.name, t.task_type
            \\FROM workspace_item_tasks t
            \\WHERE t.workspace_item_id = ?
            \\ORDER BY t.updated_at DESC, t.id ASC
            \\LIMIT {d}
        , .{MAX_TASKS_PER_ITEM});
        defer allocator.free(tasks_sql);

        var tasks_q = try db.query(allocator, tasks_sql, &.{item_id_owned});
        defer tasks_q.deinit();

        var tasks: std.ArrayList(WorkspaceContext.SiblingItem.SiblingTask) = .empty;
        errdefer {
            for (tasks.items) |t| {
                allocator.free(t.id);
                allocator.free(t.name);
                allocator.free(t.task_type);
            }
            tasks.deinit(allocator);
        }

        while (try tasks_q.next()) |trow| {
            const t_id = try allocator.dupe(u8, trow.values[0]);
            const t_name = try allocator.dupe(u8, trow.values[1]);
            const t_type = try allocator.dupe(u8, trow.values[2]);
            trow.deinit(allocator);
            try tasks.append(allocator, .{
                .id = t_id,
                .name = t_name,
                .task_type = t_type,
            });
        }

        // 4b. Truncation detection for tasks: see if there are
        // more tasks than we loaded.
        var task_count_q = try db.query(
            allocator,
            "SELECT COUNT(*) FROM workspace_item_tasks t WHERE t.workspace_item_id = ?",
            &.{item_id_owned},
        );
        defer task_count_q.deinit();
        const task_count_row = (try task_count_q.next()) orelse {
            // Defensive — COUNT(*) should always return a row.
            // Use the loaded count as the truth.
            try siblings.append(allocator, .{
                .id = item_id_owned,
                .item_type = item_type_owned,
                .name = name_owned,
                .path = path_owned,
                .is_self = is_self_owned,
                .tasks = try tasks.toOwnedSlice(allocator),
                .truncated_tasks_count = 0,
            });
            continue;
        };
        const total_tasks: u32 = try std.fmt.parseInt(u32, task_count_row.values[0], 10);
        task_count_row.deinit(allocator);
        const truncated_tasks_count: u32 = if (total_tasks > MAX_TASKS_PER_ITEM)
            total_tasks - MAX_TASKS_PER_ITEM
        else
            0;

        try siblings.append(allocator, .{
            .id = item_id_owned,
            .item_type = item_type_owned,
            .name = name_owned,
            .path = path_owned,
            .is_self = is_self_owned,
            .tasks = try tasks.toOwnedSlice(allocator),
            .truncated_tasks_count = truncated_tasks_count,
        });
    }

    const truncated_items_count: u32 = if (total_item_count > MAX_SIBLING_ITEMS)
        total_item_count - MAX_SIBLING_ITEMS
    else
        0;

    return WorkspaceContext{
        .workspace_id = workspace_id,
        .self_item_id = self_item_id,
        .self_task_id = self_task_id,
        .self_item_type = self_item_type,
        .self_path = self_path,
        .siblings = try siblings.toOwnedSlice(allocator),
        .truncated_items_count = truncated_items_count,
        .total_item_count = total_item_count,
    };
}

// =============================================================================
// Workspace Item Tasks Functions (migrated from workspace_item_tasks_table.zig)
// =============================================================================

/// Inline routine metadata embedded in `WorkspaceItemTaskInfo`.
/// Mirrors the API response shape. Populated by the LEFT JOIN in
/// the listers; null for standard tasks.
pub const RoutineMeta = struct {
    schedule: []const u8,
    initial_prompt: []const u8,
    enabled: bool,
    last_run_at: ?[]const u8 = null,
    next_run_at: []const u8,
    last_status: routines_model.RoutineRunStatus = .idle,
    last_error: ?[]const u8 = null,
};

/// WorkspaceItemTask info for CRUD operations
pub const WorkspaceItemTaskInfo = struct {
    id: []u8,
    name: []u8,
    workspace_item_id: []u8,
    /// Task type. 'standard' for legacy rows; 'routine' for routine tasks.
    /// Every constructor explicitly allocates this so deinit can free it.
    task_type: []u8 = &.{},
    /// Inline routine metadata. Populated for routine tasks only.
    routine: ?RoutineMeta = null,
    /// Free-form description (Migration 062). Empty string is the
    /// canonical "no description" sentinel — the column is NOT NULL
    /// DEFAULT ''. Owned by the lister; freed by `deinit`.
    description: []u8 = &.{},
    created_at: ?[]u8 = null,
    updated_at: ?[]u8 = null,
    /// Pin flag. `true` when the user has pinned this task; the lister
    /// surfaces pinned tasks first (in `pinned_position` order, DESC),
    /// then unpinned tasks in the existing sort order.
    is_pinned: bool = false,
    /// Position within the pinned subset of a single workspace item.
    /// Higher = higher in the pinned region. Only meaningful when
    /// `is_pinned == true`. Mirrors the `position` columns on
    /// `workspaces` and `workspace_items` (Migrations043/045).
    pinned_position: i64 = 0,
    /// Kanban column this task belongs to, when the parent workspace
    /// item is a kanban. `null` for standard tasks and for tasks whose
    /// parent is not a kanban. Mirrors `workspace_item_tasks.kanban_column_id`
    /// (Migration 048). Owned by the lister; freed by `deinit`.
    kanban_column_id: ?[]u8 = null,
    /// Position within the kanban column (lower = higher in the column).
    /// `0` for non-kanban tasks. Mirrors `workspace_item_tasks.kanban_position`
    /// (Migration 048).
    kanban_position: i64 = 0,
    /// Unattended-mode flag, joined from `sessions` for routine tasks
    /// (where `task.id == session.id` per the project convention).
    /// `'0'` for standard tasks that have no session row. The frontend's
    /// KanbanTaskDetailDialog toggle reads this on dialog open to show
    /// the current state. Owned by the lister; freed by `deinit`.
    is_auto_retry_until_stop: []u8 = &.{},

    /// Last `finish_reason` reported by the workflow (joined from
    /// `sessions`). Empty string when no session row exists for this
    /// task (LEFT JOIN NULL → COALESCE ''). The kanban card UI reads
    /// this to decide whether to show the "reviewed" green checkmark
    /// when `needs_human_review` is false. Owned by the lister;
    /// freed by `deinit`.
    ///
    /// Plan: docs/plans/2026-07-26-kanban-task-notification-icon.md
    /// (Chunk 2 — backend reader).
    last_finish_reason: []u8 = &.{},

    /// Computed boolean for the kanban card "AI finished — awaiting
    /// review" orange dot. SQL `CASE` produces 1 when:
    ///   - `sessions.last_finish_reason == 'stop'` AND
    ///   - either `tasks.last_human_touched_at IS NULL` or it's
    ///     strictly older than the session's `updated_at` (in
    ///     unix-ms — we multiply SQLite's seconds by 1000).
    /// Otherwise 0. Frontend renders orange dot when true, green
    /// checkmark when false (and finish_reason was 'stop'). Used by
    /// every kanban-card query path.
    needs_human_review: bool = false,

    /// JSON-encoded array of tag strings (Migration 067 —
    /// kanban task tags feature). Empty string is the canonical
    /// "no tags" sentinel, matching the `description` column
    /// (Migration 062) pattern. Owned by the lister; freed by
    /// `deinit`. Plan:
    /// docs/superpowers/plans/2026-07-28-kanban-task-tags.md
    tags: []u8 = &.{},

    pub fn deinit(self: WorkspaceItemTaskInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.workspace_item_id);
        if (self.task_type.len > 0) allocator.free(self.task_type);
        if (self.routine) |r| {
            allocator.free(r.schedule);
            allocator.free(r.initial_prompt);
            if (r.last_run_at) |lr| allocator.free(lr);
            allocator.free(r.next_run_at);
            if (r.last_error) |le| allocator.free(le);
        }
        if (self.description.len > 0) allocator.free(self.description);
        if (self.created_at) |ca| allocator.free(ca);
        if (self.updated_at) |ua| allocator.free(ua);
        if (self.kanban_column_id) |kc| allocator.free(kc);
        if (self.is_auto_retry_until_stop.len > 0) allocator.free(self.is_auto_retry_until_stop);
        if (self.last_finish_reason.len > 0) allocator.free(self.last_finish_reason);
        if (self.tags.len > 0) allocator.free(self.tags);
    }
};

/// Create a new workspace item task
pub fn createWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    task_type: []const u8,
    description: ?[]const u8,
    /// JSON-encoded array of tag strings (Migration 067 —
    /// kanban task tags feature). Null = no tags supplied;
    /// empty slice = SQL '' literal (NOT NULL DEFAULT '') which
    /// is stored as '' (the canonical "no tags" sentinel). The
    /// caller is responsible for passing a VALIDATED+ENCODED
    /// JSON array string — use `http_handlers.tags_validation
    /// .validateAndNormalizeTags` to produce one. Plan:
    /// docs/superpowers/plans/2026-07-28-kanban-task-tags.md
    tags: ?[]const u8,
) !WorkspaceItemTaskInfo {
    if (!std.mem.eql(u8, task_type, "standard") and !std.mem.eql(u8, task_type, "routine")) {
        return error.InvalidTaskType;
    }

    // Note: this used to take a separate `session_id` parameter. The
    // `task.id == session_id` convention made the column redundant
    // (Migration 052 dropped it). Callers that need the session_id
    // should use the task's own `id`.
    //
    // Migration 062 added `description TEXT NOT NULL DEFAULT ''` to
    // `workspace_item_tasks`. We use a dynamic SQL builder + parallel
    // `bind_values` list (single `db.exec` call) instead of three
    // hardcoded branches — see PR #101 review feedback. Three
    // cases for description:
    //
    //   - description == null  → omit the column entirely; DEFAULT ''
    //     applies.
    //   - description == ""   → SQL '' literal (NOT bound via `?`).
    //     `SqliteBackend.exec` binds empty `[]const u8` slices as
    //     SQL NULL, which would fail the NOT NULL constraint. The
    //     SQL literal binds as the empty string, NOT NULL. See
    //     memory `sqlite-backend-empty-slice-binds-as-null`.
    //   - description == "x…"  → bind via `?` like normal.
    //
    // Migration 067 follows the EXACT same shape for `tags`: null
    // omits the column, "" uses SQL '' literal, "x…" binds via `?`.
    // The same SQL-builder pattern is reused rather than chaining
    // another branch.
    //
    // The choice between "omit column" and "SQL '' literal" doesn't
    // change the stored value — both produce '' in the row. The
    // builder keeps the bind-safe path the only shape the call site
    // can ever reach, regardless of how the caller expressed "no
    // description" / "no tags" (null vs empty string).
    const returned_desc: []const u8 = description orelse "";
    const returned_tags: []const u8 = tags orelse "";
    {
        var cols_buf: std.ArrayList(u8) = .empty;
        defer cols_buf.deinit(allocator);
        var vals_buf: std.ArrayList(u8) = .empty;
        defer vals_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try cols_buf.appendSlice(allocator, "id, name, workspace_item_id, task_type");
        try vals_buf.appendSlice(allocator, "?, ?, ?, ?");
        try bind_values.appendSlice(allocator, &[_][]const u8{
            id, name, workspace_item_id, task_type,
        });

        if (description) |d| {
            if (d.len == 0) {
                try cols_buf.appendSlice(allocator, ", description");
                try vals_buf.appendSlice(allocator, ", ''");
            } else {
                try cols_buf.appendSlice(allocator, ", description");
                try vals_buf.appendSlice(allocator, ", ?");
                try bind_values.append(allocator, d);
            }
        }

        // Migration 067 — same dynamic-SQL builder pattern for tags.
        // Note: empty string MUST be a SQL '' literal — see the
        // SqliteBackend.exec empty-slice-binds-as-NULL rule cited
        // above. The validation helper (tags_validation.zig) only
        // returns `''` when the caller supplied no tags.
        if (tags) |t| {
            if (t.len == 0) {
                try cols_buf.appendSlice(allocator, ", tags");
                try vals_buf.appendSlice(allocator, ", ''");
            } else {
                try cols_buf.appendSlice(allocator, ", tags");
                try vals_buf.appendSlice(allocator, ", ?");
                try bind_values.append(allocator, t);
            }
        }

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        try sql_buf.print(
            allocator,
            "INSERT INTO workspace_item_tasks ({s}) VALUES ({s})",
            .{ cols_buf.items, vals_buf.items },
        );

        try db.exec(allocator, sql_buf.items, bind_values.items);
    }

    return WorkspaceItemTaskInfo{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .workspace_item_id = try allocator.dupe(u8, workspace_item_id),
        .task_type = try allocator.dupe(u8, task_type),
        .routine = null,
        // Persist the description we just INSERTed (so the caller's
        // view of the new task matches what's in the DB without a
        // round-trip SELECT).
        .description = try allocator.dupe(u8, returned_desc),
        // Persist the tags we just INSERTed (Migration 067). dupe
        // unconditionally so `deinit` can free consistently.
        .tags = try allocator.dupe(u8, returned_tags),
    };
}

/// Get a workspace item task by id
pub fn getWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !?WorkspaceItemTaskInfo {
    // Column index map for `row.values[N]`:
    //   0: id
    //   1: name
    //   2: workspace_item_id
    //   3: description      (Migration 062 — added right after workspace_item_id)
    //   4: created_at
    //   5: updated_at
    //   6: task_type        (Migration 044)
    //   7: tags             (Migration 067 — JSON-encode array string)
    //
    // All subsequent column indices shift by one when a column is added.
    // Update this comment block + the constructor below together.
    const sql = "SELECT id, name, workspace_item_id, description, created_at, updated_at, task_type, tags FROM workspace_item_tasks t WHERE t.id = ?";

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            // description is NOT NULL DEFAULT '' (Migration 062) so
            // the row value is always present. dupe unconditionally
            // (an empty slice still gets a fresh allocation so deinit
            // can free it consistently with the other []u8 fields).
            .description = try allocator.dupe(u8, row.values[3]),
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .task_type = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else try allocator.dupe(u8, "standard"),
            // tags is NOT NULL DEFAULT '' (Migration 067). The frontend
            // decodes via JSON.parse. Stored value is a JSON-encode
            // array string ('' when no tags).
            .tags = try allocator.dupe(u8, row.values[7]),
            .routine = null, // single-row fetch path; routine loaded on demand
        };
        row.deinit(allocator);
        return task;
    }

    return null;
}

/// Update workspace item task
pub fn updateWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    name: ?[]const u8,
) !void {
    if (name == null) {
        // Nothing to update
        return;
    }

    var set_clauses = std.ArrayList([]const u8).empty;
    var values = std.ArrayList([]const u8).empty;

    if (name) |n| {
        try set_clauses.append(allocator, "name = ?");
        try values.append(allocator, n);
    }

    try values.append(allocator, id);

    var sql = std.ArrayList(u8).empty;
    try sql.appendSlice(allocator, "UPDATE workspace_item_tasks SET ");
    for (set_clauses.items, 0..) |clause, i| {
        if (i > 0) try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, clause);
    }
    try sql.appendSlice(allocator, ", updated_at = datetime('now') WHERE id = ?");

    try db.exec(allocator, sql.items, values.items);
}

/// Delete a workspace item task by id
pub fn deleteWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !void {
    const sql = "DELETE FROM workspace_item_tasks WHERE id = ?";
    try db.exec(allocator, sql, &.{id});
}

/// Set or clear the `is_pinned` flag for a single task. When
/// `is_pinned` is true, the row's `pinned_position` is bumped to
/// (MAX(pinned_position WHERE is_pinned=1) + 1) so a newly-pinned
/// task appears at the bottom of the pinned region (the user can
/// drag it to a different position afterwards). When `is_pinned`
/// is false, the row's `pinned_position` is reset to 0 (the
/// default; the value is irrelevant for unpinned rows).
///
/// Returns the new `pinned_position` so the caller can echo it
/// back to the client.
pub fn setTaskPinned(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    is_pinned: bool,
) !i64 {
    if (is_pinned) {
        // Bump pinned_position to MAX+1 for the relevant
        // workspace_item. The MAX subquery is correlated on
        // workspace_item_id (derived from the row being pinned)
        // so the position is scoped per item, not globally.
        var max_q = try db.query(
            allocator,
            "SELECT COALESCE(MAX(t.pinned_position), -1) FROM workspace_item_tasks t WHERE t.is_pinned = 1 AND t.workspace_item_id = (SELECT workspace_item_id FROM workspace_item_tasks WHERE id = ?)",
            &.{id},
        );
        defer max_q.deinit();
        const max_row = (try max_q.next()) orelse {
            return error.TaskNotFound;
        };
        defer max_row.deinit(allocator);
        const max_pos = std.fmt.parseInt(i64, max_row.values[0], 10) catch 0;
        const new_pos = max_pos + 1;
        const new_pos_str = try std.fmt.allocPrint(allocator, "{d}", .{new_pos});
        defer allocator.free(new_pos_str);
        try db.exec(
            allocator,
            "UPDATE workspace_item_tasks SET is_pinned = 1, pinned_position = ?, updated_at = datetime('now') WHERE id = ?",
            &.{ new_pos_str, id },
        );
        return new_pos;
    } else {
        try db.exec(
            allocator,
            "UPDATE workspace_item_tasks SET is_pinned = 0, pinned_position = 0, updated_at = datetime('now') WHERE id = ?",
            &.{id},
        );
        return 0;
    }
}

/// Reorder the pinned subset of a single workspace item. The
/// `ordered_ids` array is the full ordered list of pinned task
/// IDs for that workspace item (top-to-bottom display order, the
/// same convention as `workspaces_reorder` and
/// `workspace_items_reorder`). Each row's `pinned_position` is
/// set to `count - 1 - i` so the first id gets the highest
/// position (sorted to the top with `ORDER BY pinned_position
/// DESC`).
///
/// Defense in depth: the use case scopes every UPDATE by
/// `workspace_item_id` (derived from the URL) AND `is_pinned = 1`,
/// so a stale or out-of-range id is a silent no-op. A row that
/// isn't currently pinned (e.g. accidentally included in the
/// payload) is silently skipped too — the WHERE clause filters it.
pub fn reorderPinnedTasks(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    ordered_ids: []const []const u8,
) !void {
    if (ordered_ids.len == 0) return;

    const count: i64 = @intCast(ordered_ids.len);
    var buf: [32]u8 = undefined;

    for (ordered_ids, 0..) |id_str, i| {
        const new_pos: i64 = count - 1 - @as(i64, @intCast(i));
        const pos_str = std.fmt.bufPrint(&buf, "{d}", .{new_pos}) catch {
            return error.IntegerTooLarge;
        };
        try db.exec(
            allocator,
            "UPDATE workspace_item_tasks SET pinned_position = ?, updated_at = datetime('now') " ++
                "WHERE id = ? AND workspace_item_id = ? AND is_pinned = 1",
            &.{ pos_str, id_str, workspace_item_id },
        );
    }
}

/// List all workspace item tasks by workspace_item_id
pub fn listWorkspaceItemTasks(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]WorkspaceItemTaskInfo {
    // Migration 062: added `t.description` to the SELECT column list,
    // positioned right after `t.workspace_item_id`. All subsequent
    // column indices shift by one.
    const sql =
        \\SELECT t.id, t.name, t.workspace_item_id, t.description, t.created_at, t.updated_at, t.task_type,
        \\       COALESCE(t.is_pinned, 0), COALESCE(t.pinned_position, 0),
        \\       t.kanban_column_id, COALESCE(t.kanban_position, 0),
        \\       r.schedule, r.initial_prompt, r.enabled, r.last_run_at, r.next_run_at, r.last_status, r.last_error
        \\FROM workspace_item_tasks t LEFT JOIN routines r ON r.task_id = t.id
        \\WHERE t.workspace_item_id = ?
        \\ORDER BY t.is_pinned DESC, t.pinned_position DESC, t.updated_at DESC, t.id DESC
    ;

    var rows = try db.query(allocator, sql, &.{workspace_item_id});
    defer rows.deinit();

    var tasks = std.ArrayList(WorkspaceItemTaskInfo).empty;
    errdefer {
        for (tasks.items) |task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    while (try rows.next()) |row| {
        // Row indices (post-Migration-061):
        //   0: id, 1: name, 2: workspace_item_id, 3: description,
        //   4: created_at, 5: updated_at, 6: task_type,
        //   7: is_pinned, 8: pinned_position, 9: kanban_column_id,
        //   10: kanban_position, 11-17: routine fields. routine.schedule
        //   is NOT NULL, so its presence discriminates joined routine
        //   rows from standard tasks.
        const task_type = if (row.values[6].len > 0)
            try allocator.dupe(u8, row.values[6])
        else
            try allocator.dupe(u8, "standard");
        const is_pinned_int = row.values[7];
        const pinned_position_str = row.values[8];
        const has_routine = row.values[11].len > 0;
        const routine_meta: ?RoutineMeta = if (has_routine) blk: {
            const v = row.values[16];
            const last_status: routines_model.RoutineRunStatus =
                if (v.len == 0) .idle else if (std.mem.eql(u8, v, "success")) .success else if (std.mem.eql(u8, v, "failed")) .failed else if (std.mem.eql(u8, v, "running")) .running else .idle;
            break :blk RoutineMeta{
                .schedule = try allocator.dupe(u8, row.values[11]),
                .initial_prompt = try allocator.dupe(u8, row.values[12]),
                .enabled = std.mem.eql(u8, row.values[13], "1"),
                .last_run_at = if (row.values[14].len > 0) try allocator.dupe(u8, row.values[14]) else null,
                .next_run_at = try allocator.dupe(u8, row.values[15]),
                .last_status = last_status,
                .last_error = if (row.values[17].len > 0) try allocator.dupe(u8, row.values[17]) else null,
            };
        } else null;

        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            .created_at = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .updated_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .task_type = task_type,
            .is_pinned = std.mem.eql(u8, is_pinned_int, "1"),
            .pinned_position = std.fmt.parseInt(i64, pinned_position_str, 10) catch 0,
            .kanban_column_id = if (row.values[8].len > 0) try allocator.dupe(u8, row.values[8]) else null,
            .kanban_position = std.fmt.parseInt(i64, row.values[9], 10) catch 0,
            .routine = routine_meta,
        };
        try tasks.append(allocator, task);
        row.deinit(allocator);
    }

    return try tasks.toOwnedSlice(allocator);
}

/// List workspace item tasks with cursor pagination. The `cursor` is
/// the value of the `sort_field` for the last task from the previous
/// page; pass null to fetch the first page. The `sort_field` /
/// `sort_direction` controls the ORDER BY direction. The `id` column
/// is used as a tiebreaker for stable pagination when many tasks share
/// the same `updated_at` (e.g. all batch-renamed in one second).
///
/// Ordered by `sort_field sort_direction, id sort_direction` (newest
/// first when sort_direction is `desc`). Returns at most `limit`
/// tasks plus a `has_more` flag indicating whether at least one more
/// task exists after this page.
///
/// Cursor filter: `(sort_field, id) < (cursor_value, last_id)` for DESC,
/// or `>` for ASC. The last_id is encoded in the cursor as
/// `"<sort_value>|<id>"` by the handler. Mirrors
/// `getSessionListWithCursor` (above) for SQL building style.
pub fn listWorkspaceItemTasksWithCursor(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    limit: u32,
    cursor: ?[]const u8,
    sort_field: TaskSortField,
    sort_direction: TaskSortDirection,
) !struct {
    tasks: []WorkspaceItemTaskInfo,
    has_more: bool,
} {
    // Fetch `limit + 1` rows so we can detect "there are more pages"
    // without a separate COUNT query.
    const query_limit = limit + 1;
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{query_limit});
    defer allocator.free(limit_str);

    // Build the ORDER BY column expression for the sort field. We
    // hardcode the column name (not the value) into the SQL string
    // — only the values are parameterized, so this is safe.
    //
    // Qualify with `t.` because the LEFT JOIN on `routines` exposes
    // `id`, `created_at`, and `updated_at` from BOTH tables (the
    // routines table also has all three per Migration 044), and
    // SQLite rejects unqualified references as "ambiguous column
    // name" — see the runtime error from `nalar --port 8081 ...`
    // after the JOIN was added.
    const sort_col = switch (sort_field) {
        .created_at => "t.created_at",
        .updated_at => "t.updated_at",
        .name => "t.name",
    };
    const sort_dir_str = switch (sort_direction) {
        .asc => "ASC",
        .desc => "DESC",
    };
    const order_by = try std.fmt.allocPrint(
        allocator,
        "ORDER BY t.is_pinned DESC, t.pinned_position DESC, {s} {s}, t.id {s}",
        .{ sort_col, sort_dir_str, sort_dir_str },
    );
    defer allocator.free(order_by);

    // Cursor: encoded as "<sort_value>|<id>" by the handler. Split it
    // into the sort-field value (compared first) and the id (tiebreaker).
    // When cursor is null, no WHERE clause is added.
    //
    // v1 limitation: the cursor applies only to the unpinned region.
    // Pinned rows are always returned on page 1 (when cursor is null).
    // Subsequent pages (cursor != null) restrict to is_pinned = 0 so
    // pinned rows don't re-appear after the cursor boundary.
    const cursor_clause: []u8 = blk: {
        const c = cursor orelse break :blk try allocator.dupe(u8, "");
        const pipe_idx = std.mem.indexOfScalar(u8, c, '|') orelse
            return error.MalformedCursor;
        const sort_value = c[0..pipe_idx];
        const id_value = c[pipe_idx + 1 ..];

        const cmp = switch (sort_direction) {
            .desc => "<",
            .asc => ">",
        };
        break :blk try std.fmt.allocPrint(
            allocator,
            " AND t.is_pinned = 0 AND ({s} {s} '{s}' OR ({s} = '{s}' AND t.id {s} '{s}'))",
            .{ sort_col, cmp, sort_value, sort_col, sort_value, cmp, id_value },
        );
    };
    defer allocator.free(cursor_clause);

    const sql = try std.fmt.allocPrint(
        allocator,
        // Auto-retry-until-stop: LEFT JOIN sessions on t.id =
        // sessions.id (per the project convention task.id ==
        // session.id for routine tasks; standard tasks that have
        // no matching session row get NULL → COALESCE to '0').
        // COALESCE(t.kanban_position, 0) ensures standard tasks
        // without a kanban_position still get '0' (the column is
        // nullable per Migration 048). s.is_auto_retry_until_stop
        // appends as column 18, shifting nothing because routines
        // fields are already past it (still 11-17).
        //
        // Kanban notification icon (Migration 065, plan:
        // docs/plans/2026-07-26-kanban-task-notification-icon.md
        // Chunk 2): appends 2 derived columns at indices 19 + 20:
        //   19: COALESCE(s.last_finish_reason, '') — the AI's
        //       most-recent finish_reason for this task's session,
        //       or '' if no session row exists (LEFT JOIN NULL).
        //   20: CASE … needs_human_review — 1 when the AI has
        //       finished (last_finish_reason = 'stop') and the
        //       human has not touched the task since
        //       (last_human_touched_at IS NULL OR older than
        //       sessions.updated_at, in unix-ms — we multiply
        //       SQLite's strftime('%s', updated_at) by 1000).
        //
        // Kanban task tags (Migration 067): appends a single
        // passthrough column at index 21:
        //   21: t.tags — JSON-encode array string ('' when no tags).
        //       NOT NULL DEFAULT '' so always present.
        "SELECT t.id, t.name, t.workspace_item_id, t.description, t.created_at, t.updated_at, t.task_type, COALESCE(t.is_pinned, 0), COALESCE(t.pinned_position, 0), t.kanban_column_id, COALESCE(t.kanban_position, 0), r.schedule, r.initial_prompt, r.enabled, r.last_run_at, r.next_run_at, r.last_status, r.last_error, COALESCE(s.is_auto_retry_until_stop, '0'), COALESCE(s.last_finish_reason, ''), CASE WHEN COALESCE(s.last_finish_reason, '') = 'stop' AND (t.last_human_touched_at IS NULL OR t.last_human_touched_at < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000) THEN 1 ELSE 0 END, t.tags FROM workspace_item_tasks t LEFT JOIN routines r ON r.task_id = t.id LEFT JOIN sessions s ON s.id = t.id WHERE t.workspace_item_id = ?{s} {s} LIMIT {s}",
        .{ cursor_clause, order_by, limit_str },
    );
    defer allocator.free(sql);

    var rows = try db.query(allocator, sql, &.{workspace_item_id});
    defer rows.deinit();

    var tasks = std.ArrayList(WorkspaceItemTaskInfo).empty;
    errdefer {
        for (tasks.items) |task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    while (try rows.next()) |row| {
        // Row indices (post-Migration-063-attended-toggle JOIN,
        // post-Migration-065-notification-icon JOIN,
        // post-Migration-067-tags):
        //   0: id, 1: name, 2: workspace_item_id, 3: description,
        //   4: created_at, 5: updated_at, 6: task_type,
        //   7: is_pinned, 8: pinned_position, 9: kanban_column_id,
        //   10: kanban_position, 11-17: routine fields,
        //   18: is_auto_retry_until_stop (joined from sessions),
        //   19: last_finish_reason (joined from sessions),
        //   20: needs_human_review (CASE derived),
        //   21: tags (Migration 067 — JSON-encode array string).
        const task_type = if (row.values[6].len > 0)
            try allocator.dupe(u8, row.values[6])
        else
            try allocator.dupe(u8, "standard");
        const is_pinned_int = row.values[7];
        const pinned_position_str = row.values[8];
        const has_routine = row.values[11].len > 0;
        const routine_meta: ?RoutineMeta = if (has_routine) blk: {
            const v = row.values[16];
            const last_status: routines_model.RoutineRunStatus =
                if (v.len == 0) .idle else if (std.mem.eql(u8, v, "success")) .success else if (std.mem.eql(u8, v, "failed")) .failed else if (std.mem.eql(u8, v, "running")) .running else .idle;
            break :blk RoutineMeta{
                .schedule = try allocator.dupe(u8, row.values[11]),
                .initial_prompt = try allocator.dupe(u8, row.values[12]),
                .enabled = std.mem.eql(u8, row.values[13], "1"),
                .last_run_at = if (row.values[14].len > 0) try allocator.dupe(u8, row.values[14]) else null,
                .next_run_at = try allocator.dupe(u8, row.values[15]),
                .last_status = last_status,
                .last_error = if (row.values[17].len > 0) try allocator.dupe(u8, row.values[17]) else null,
            };
        } else null;

        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            // Migration 062: description at index 3.
            .description = try allocator.dupe(u8, row.values[3]),
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .task_type = task_type,
            .is_pinned = std.mem.eql(u8, is_pinned_int, "1"),
            .pinned_position = std.fmt.parseInt(i64, pinned_position_str, 10) catch 0,
            .kanban_column_id = if (row.values[9].len > 0) try allocator.dupe(u8, row.values[9]) else null,
            .kanban_position = std.fmt.parseInt(i64, row.values[10], 10) catch 0,
            .routine = routine_meta,
            // Auto-retry-until-stop: index 18 (joined from sessions).
            // COALESCE'd to '0' in the SQL so this is always non-empty.
            .is_auto_retry_until_stop = try allocator.dupe(u8, row.values[18]),
            // Kanban notification icon (Migration 065): index 19.
            // COALESCE'd to '' in the SQL so this is always non-empty.
            .last_finish_reason = try allocator.dupe(u8, row.values[19]),
            // Kanban notification icon (Migration 065): index 20.
            // SQL CASE produces '1' or '0'; parse to bool.
            .needs_human_review = std.mem.eql(u8, row.values[20], "1"),
            // Kanban task tags (Migration 067): index 21. NOT NULL
            // DEFAULT '' so always present.
            .tags = try allocator.dupe(u8, row.values[21]),
        };
        try tasks.append(allocator, task);
        row.deinit(allocator);
    }

    const has_more = tasks.items.len > limit;
    if (has_more) {
        // Drop the extra row we fetched to detect has_more.
        const extra = tasks.pop().?;
        extra.deinit(allocator);
    }

    return .{
        .tasks = try tasks.toOwnedSlice(allocator),
        .has_more = has_more,
    };
}

/// Get all active sessions for SSE broadcast
pub fn getSessionsForBroadcast(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
) ![]SessionBroadcastInfo {
    const sql = "SELECT s.id, COALESCE(s.name, ''), COALESCE(s.status, 'active'), COALESCE(s.cwd, ''), COALESCE(s.created_at, ''), COALESCE(s.updated_at, ''), COALESCE(h.agent, 'Agent'), COALESCE(s.selected_profile_model, ''), COALESCE(s.git_worktree_cwd, '') FROM sessions s LEFT JOIN llm_history h ON s.id = h.session_id ORDER BY s.updated_at DESC";

    var rows = db.query(allocator, sql, &[_][]const u8{}) catch return &[_]SessionBroadcastInfo{};
    defer rows.deinit();

    var sessions = std.ArrayList(SessionBroadcastInfo).empty;
    errdefer sessions.deinit(allocator);

    while (rows.next() catch false) |row| {
        const session = SessionBroadcastInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
            .cwd = try allocator.dupe(u8, row.values[3]),
            .created_at = try allocator.dupe(u8, row.values[4]),
            .updated_at = try allocator.dupe(u8, row.values[5]),
            .agent = try allocator.dupe(u8, row.values[6]),
            .selected_profile_model = try allocator.dupe(u8, row.values[7]),
            .git_worktree_cwd = try allocator.dupe(u8, row.values[8]),
        };
        try sessions.append(allocator, session);
    }

    return try sessions.toOwnedSlice(allocator);
}

/// Free session broadcast info array
pub fn freeSessionsForBroadcast(allocator: std.mem.Allocator, sessions: []SessionBroadcastInfo) void {
    for (sessions) |*s| {
        allocator.free(s.session_id);
        allocator.free(s.session_name);
        allocator.free(s.status);
        allocator.free(s.cwd);
        allocator.free(s.created_at);
        allocator.free(s.updated_at);
        allocator.free(s.agent);
        allocator.free(s.git_worktree_cwd);
    }
    allocator.free(sessions);
}

pub fn updateSessionUpdatedAt(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) !void {
    const sql = "UPDATE sessions SET updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{session_id});
}

pub fn updateWorkspaceUpdatedAt(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) !void {
    const sql = "UPDATE workspace_item_tasks SET updated_at = datetime('now') WHERE id = ?";
    try db.exec(allocator, sql, &.{session_id});
}
