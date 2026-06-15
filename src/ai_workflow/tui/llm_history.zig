const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const agent = nalarcore.agent;
const logger_mod = nalarcore.logger;
const TUIHistory = @import("models.zig").TUIHistory;
const llm_models = @import("nalarcore").llm_models;
const ai_mod = @import("mod.zig");
const on_event_sent = ai_mod.on_event_sent;
const routines_model = @import("routines/model.zig");

pub fn markMessageNotForLlmRun(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !void {
    const sql = "UPDATE llm_history SET is_feed_to_llm = 0 WHERE session_id = ?";
    try db.exec(allocator, sql, &.{session_id});
}

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

    pub fn deinit(self: *const SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.session_name);
        allocator.free(self.status);
        allocator.free(self.cwd);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        allocator.free(self.agent);
        allocator.free(self.selected_profile_model);
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

    const sql = "SELECT h.session_id, COALESCE(s.cwd, ''), MAX(h.created_at) as created_at, COALESCE(h.agent, 'Agent'), COALESCE(s.name, '') FROM llm_history h LEFT JOIN sessions s ON h.session_id = s.id GROUP BY h.session_id ORDER BY MAX(h.created_at) DESC LIMIT ? OFFSET ?";

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
        \\COALESCE(s.selected_profile_model, '')
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
    // New columns
    is_input: []const u8,
    is_output: []const u8,
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
        allocator.free(self.is_input);
        allocator.free(self.is_output);
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
            \\       COALESCE(h.finish_reason, ''), COALESCE(s.cwd, ''), COALESCE(h.reasoning_content, ''),
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
            \\       COALESCE(h.finish_reason, ''), COALESCE(s.cwd, ''), COALESCE(h.reasoning_content, ''),
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

    while (try rows.next()) |row| {
        // Extract cwd from last column of first row (index 9, reasoning_content is at 10)
        if (cwd == null) {
            const cwd_val = row.values[9];
            if (cwd_val.len > 0) {
                cwd = try allocator.dupe(u8, cwd_val);
            }
        }

        const msg = SessionMessage{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .role = try allocator.dupe(u8, row.values[2]),
            .content = try allocator.dupe(u8, row.values[3]),
            .timestamp = try allocator.dupe(u8, row.values[4]),
            .is_input = try allocator.dupe(u8, row.values[5]),
            .is_output = try allocator.dupe(u8, row.values[6]),
            .tool_name = try allocator.dupe(u8, row.values[7]),
            .finish_reason = try allocator.dupe(u8, row.values[8]),
            .reasoning_content = try allocator.dupe(u8, row.values[10]),
            .diffview_before = if (row.values[11].len > 0) try allocator.dupe(u8, row.values[11]) else null,
            .diffview_after = if (row.values[12].len > 0) try allocator.dupe(u8, row.values[12]) else null,
            .image_urls = if (row.values[13].len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, row.values[13], '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .tool_call_id = if (row.values[14].len > 0) try allocator.dupe(u8, row.values[14]) else null,
            .tool_calls_json = if (row.values[15].len > 0) try allocator.dupe(u8, row.values[15]) else null,
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
        .max_total_tokens = getMaxTotalTokensForSession(allocator, db, session_id) catch 0,
        .max_capacity_total_tokens = if (nalarcore.getSingleton() catch null) |di|
            llm_models.getModelTokenCount(nalarcore.getLlmConfig(di).model)
        else
            llm_models.getModelTokenCount(""),
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

        const msg_json = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","session_id":"{s}","role":"{s}","content":"{s}","timestamp":"{s}",
            \\"is_input":"{s}","is_output":"{s}","tool_name":"{s}","finish_reason":"{s}","reasoning_content":"{s}"}}
        , .{ escaped_id, escaped_session_id, escaped_role, escaped_content, escaped_timestamp, msg.is_input, msg.is_output, escaped_tool_name, escaped_finish_reason, escaped_reasoning_content });
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
        , .{ escaped_id, escaped_session_id, escaped_role, escaped_content, escaped_timestamp, msg.is_input, msg.is_output, escaped_tool_name, escaped_finish_reason, escaped_reasoning_content });
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
    const session_id = try std.fmt.bufPrint(&session_id_buf, "kerjabot_{}", .{std.time.timestamp()});

    // Insert into sessions table first (for JOIN queries)
    const session_sql = "INSERT INTO sessions (id, name, status) VALUES (?, ?, 'active')";
    const copy_session_name = try std.heap.c_allocator.dupe(u8, session_name);
    defer std.heap.c_allocator.free(copy_session_name);
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
};

pub fn saveMessage(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    input: SaveMessageInput,
) !void {
    const id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(id);
    const created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(created_at);

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

    const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, tool_call_id, reasoning_content, is_feed_to_llm, agent, loop_index, temperature, is_thinking, created_at, parent_session_id, parent_id, prompt_tokens, completion_tokens, total_tokens, is_input, is_output, tool_name, diffview_before, diffview_after, image_url) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";

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

    const sqlArgs = &.{ id, copy_session_id, copy_model, copy_content, copy_finish_reason, copy_role, copy_tool_calls, copy_tool_call_id, copy_reasoning, copy_agent, loop_index_str, temperature_str, is_thinking_str, created_at, copy_parent_session_id, copy_parent_id, prompt_tokens_str, completion_tokens_str, total_tokens_str, if (input.is_input) "1" else "0", if (input.is_output) "1" else "0", copy_tool_name, copy_diffview_before, copy_diffview_after, image_urls_str };

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
            .is_input = std.mem.eql(u8, row.values[19], "1"),
            .is_output = std.mem.eql(u8, row.values[20], "1"),
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
            .is_input = std.mem.eql(u8, row.values[19], "1"),
            .is_output = std.mem.eql(u8, row.values[20], "1"),
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

    pub fn deinit(self: *const WorkerInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.working_directory);
        allocator.free(self.last_activity_description);
    }

    /// Determine if this worker is a sub-agent by checking if session_id contains "subagent"
    pub fn isSubAgent(self: *const WorkerInfo) bool {
        return std.mem.indexOf(u8, self.session_id, "subagent") != null;
    }
};

/// Get all active workers with their info
pub fn getActiveWorker(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
) ![]WorkerInfo {
    const sql = "SELECT session_id, COALESCE(working_directory, ''), last_activity, COALESCE(last_activity_description, '') FROM worker ORDER BY last_activity DESC";

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
        };
        try workers.append(allocator, worker);
        row.deinit(allocator);
    }

    return try workers.toOwnedSlice(allocator);
}

/// Register or update a worker
pub fn upsertWorker(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    worker_id: []const u8,
    session_id: []const u8,
    working_directory: []const u8,
) !void {
    // Check if worker exists to determine action
    const check_sql = "SELECT id FROM worker WHERE id = ?";
    var rows = try db.query(allocator, check_sql, &.{worker_id});
    defer rows.deinit();
    const exists = (try rows.next()) != null;

    const sql = "INSERT OR REPLACE INTO worker (id, session_id, working_directory, last_activity, last_activity_description) VALUES (?, ?, ?, strftime('%s', 'now'), '')";
    try db.exec(allocator, sql, &.{ worker_id, session_id, working_directory });

    // Also ensure session exists in sessions table (for JOIN queries)
    // Use INSERT OR IGNORE to handle cases where session might already exist
    const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status, created_at, updated_at) VALUES (?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)";
    try db.exec(allocator, session_sql, &.{ session_id, session_id });

    // Emit worker event
    const action = if (exists) "updated" else "created";
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now_timestamp: i64 = ts.sec;
    on_event_sent.onEventSendWorkers(allocator, .{
        .action = action,
        .id = worker_id,
        .session_id = session_id,
        .working_directory = working_directory,
        .last_activity = now_timestamp,
        .last_activity_description = "",
        .created_at = "",
    }) catch {};
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
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now_timestamp: i64 = ts.sec;
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

/// Update worker's last activity timestamp
pub fn updateWorkerActivity(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    worker_id: []const u8,
) !void {
    const sql = "UPDATE worker SET last_activity = strftime('%s', 'now') WHERE id = ?";
    try db.exec(allocator, sql, &.{worker_id});
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
pub fn getWorkerBySessionId(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?WorkerInfo {
    const sql = "SELECT session_id, COALESCE(working_directory, ''), last_activity, COALESCE(last_activity_description, '') FROM worker WHERE session_id = ?";

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const last_activity = std.fmt.parseInt(i64, row.values[2], 10) catch 0;
        const worker = WorkerInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .working_directory = try allocator.dupe(u8, row.values[1]),
            .last_activity = last_activity,
            .last_activity_description = try allocator.dupe(u8, row.values[3]),
        };
        row.deinit(allocator);
        return worker;
    }
    return null;
}

/// Check if a session is currently running (exists in worker table)
pub fn isSessionRunning(
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) bool {
    const sql = "SELECT 1 FROM worker WHERE id = ? LIMIT 1";
    var rows = db.query(std.heap.c_allocator, sql, &.{session_id}) catch return false;
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

/// Check if a session is cancelled
pub fn isSessionCancelled(
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) bool {
    const sql = "SELECT cancelled FROM worker WHERE id = ?";
    var rows = db.query(std.heap.c_allocator, sql, &.{session_id}) catch return false;
    defer rows.deinit();
    if (rows.next() catch return false) |row| {
        const cancelled = std.fmt.parseInt(i32, row.values[0], 10) catch 0;
        return cancelled == 1;
    }
    return false;
}

/// Mark session as idle (remove from worker table) and emit SSE "deleted" event
pub fn markSessionIdle(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !void {
    const sql = "DELETE FROM worker WHERE id = ?";
    try db.exec(allocator, sql, &.{session_id});

    // Emit worker deleted event so connected SSE clients can drop the entry
    on_event_sent.onEventSendWorkers(allocator, .{
        .action = "deleted",
        .id = session_id,
        .session_id = "",
        .working_directory = "",
        .last_activity = 0,
        .last_activity_description = "",
        .created_at = "",
    }) catch {};
}

/// Queue a message for a session and emit SSE event to notify connected clients
pub fn queueMessage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    message: []const u8,
    image_url: []const u8,
) !void {
    const id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(std.Options.debug_io, .real).nanoseconds});
    defer allocator.free(id);

    const sql = "INSERT INTO session_queue_messages (id, session_id, message, image_url) VALUES (?, ?, ?, ?)";
    const copy_image_url = try allocator.dupe(u8, image_url);
    defer allocator.free(copy_image_url);

    try db.exec(allocator, sql, &.{ id, session_id, message, copy_image_url });

    // Emit SSE event to notify connected clients
    const di = nalarcore.getSingleton() catch return;
    const event_bus = di.event_bus;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const payload = .{
        .action = "queued",
        .id = id,
        .message = message,
        .session_id = session_id,
        .image_url = image_url,
    };
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_4,
    })});

    const data_copy = try allocator.dupe(u8, buf.items);
    const event = ai_mod.on_event_sent.SseEvent{
        .session_id = session_id,
        .data = data_copy,
        .event_type = "queue_message",
    };

    const key = try std.fmt.allocPrint(allocator, "queue_messages_{s}", .{session_id});
    defer allocator.free(key);

    event_bus.emit(ai_mod.on_event_sent.SseEvent, key, event);
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

/// Delete a specific queued message and emit SSE event
pub fn deleteQueuedMessage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    message: []const u8,
) !void {
    const sql = "DELETE FROM session_queue_messages WHERE session_id = ? AND message = ? ";
    try db.exec(allocator, sql, &.{ session_id, message });

    // Emit SSE event to notify connected clients
    const di = nalarcore.getSingleton() catch return;
    const event_bus = di.event_bus;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const payload = .{
        .action = "deleted",
        .message = message,
        .session_id = session_id,
    };
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_4,
    })});

    const data_copy = try allocator.dupe(u8, buf.items);
    const event = ai_mod.on_event_sent.SseEvent{
        .session_id = session_id,
        .data = data_copy,
        .event_type = "queue_message",
    };

    const key = try std.fmt.allocPrint(allocator, "queue_messages_{s}", .{session_id});
    defer allocator.free(key);

    event_bus.emit(ai_mod.on_event_sent.SseEvent, key, event);
}

/// Check if session has queued messages
pub fn hasQueuedMessages(
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) bool {
    const sql = "SELECT 1 FROM session_queue_messages WHERE session_id = ? LIMIT 1";
    var rows = db.query(std.heap.c_allocator, sql, &.{session_id}) catch return false;
    defer rows.deinit();

    if (rows.next() catch return false) |row| {
        const queued = std.fmt.parseInt(i32, row.values[0], 10) catch 0;
        return queued == 1;
    }

    return false;
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

    pub fn deinit(self: SessionTableInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.status);
        allocator.free(self.cwd);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        allocator.free(self.selected_profile_model);
    }
};

/// Create a new session with status set to 'active'
pub fn create_session(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    name: []const u8,
) !SessionTableInfo {
    const sql = "INSERT INTO sessions (id, name, status, created_at, updated_at) VALUES (?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)";
    try db.exec(allocator, sql, &.{ id, name });

    // Broadcast session created event
    ai_mod.on_event_sent.onEventSendSessions(allocator, .{
        .action = "created",
        .id = id,
        .name = name,
        .status = "active",
        .cwd = "",
        .created_at = "",
        .updated_at = "",
        .selected_profile_model = "",
    }) catch {};

    return SessionTableInfo{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .status = try allocator.dupe(u8, "active"),
        .created_at = try allocator.dupe(u8, ""),
        .updated_at = try allocator.dupe(u8, ""),
        .selected_profile_model = try allocator.dupe(u8, ""),
    };
}

/// Get a session by id
pub fn getSession(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !?SessionTableInfo {
    const sql = "SELECT id, name, status, COALESCE(cwd, ''), COALESCE(created_at, ''), COALESCE(updated_at, ''), COALESCE(selected_profile_model, '') FROM sessions WHERE id = ?";

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
        }) catch {};
    }
}

/// Rename a workspace item task. If the task has a `session_id`,
/// the rename cascades to the linked session via `updateSessionName`,
/// which itself emits a `session.updated` SSE event so subscribers
/// (e.g. the ChatsList sidebar) see the new name in real time. Tasks
/// without a `session_id` (e.g. freshly created, not yet bound) are
/// renamed in the task table only — there is no session to cascade to,
/// and no SSE event is emitted.
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

    // 2) Look up the task to find its session_id. If the task doesn't
    // exist (rare — e.g. the caller's id is wrong) there's nothing to
    // cascade. Return early; the UPDATE above is a no-op in that case.
    const task = (getWorkspaceItemTask(allocator, db, id) catch null) orelse return;
    defer task.deinit(allocator);

    // 3) If the task is not bound to a session yet, we are done.
    // The task row already has the new name. Nothing to broadcast.
    const session_id = task.session_id orelse return;

    // 4) Cascade the rename to the linked session. `updateSessionName`
    // also re-reads the session row and broadcasts a `session.updated`
    // SSE event with the new name, which is the ChatsList hook.
    // A failure here is non-fatal — the task row is the source of
    // truth for the sidebar, and the next rename will reconcile.
    updateSessionName(allocator, db, session_id, new_name) catch {};
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
/// Sorted by `position DESC, id ASC`. The `position` column is the
/// drag-and-drop sort key (added by Migration 045). The `id ASC`
/// tiebreaker makes the order deterministic when two items share a
/// position (shouldn't happen post-reorder, but defense-in-depth).
pub fn listWorkspaceItems(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
) ![]WorkspaceItemInfo {
    const sql = "SELECT id, workspace_id, item_type, name, path, created_at, updated_at FROM workspace_items WHERE workspace_id = ? ORDER BY position DESC, id ASC";

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
/// per-workspace list: `position DESC, id ASC`. New items get
/// position = MAX(position) + 1 (scoped by workspace_id) at insert
/// time, so the per-workspace "newest at top" visual order is
/// preserved here too.
pub fn listAllWorkspaceItems(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
) ![]WorkspaceItemInfo {
    const sql = "SELECT id, workspace_id, item_type, name, path, created_at, updated_at FROM workspace_items ORDER BY position DESC, id ASC";

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
    session_id: ?[]u8 = null,
    /// Task type. 'standard' for legacy rows; 'routine' for routine tasks.
    /// Every constructor explicitly allocates this so deinit can free it.
    task_type: []u8 = &.{},
    /// Inline routine metadata. Populated for routine tasks only.
    routine: ?RoutineMeta = null,
    created_at: ?[]u8 = null,
    updated_at: ?[]u8 = null,

    pub fn deinit(self: WorkspaceItemTaskInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.workspace_item_id);
        if (self.session_id) |s| allocator.free(s);
        if (self.task_type.len > 0) allocator.free(self.task_type);
        if (self.routine) |r| {
            allocator.free(r.schedule);
            allocator.free(r.initial_prompt);
            if (r.last_run_at) |lr| allocator.free(lr);
            allocator.free(r.next_run_at);
            if (r.last_error) |le| allocator.free(le);
        }
        if (self.created_at) |ca| allocator.free(ca);
        if (self.updated_at) |ua| allocator.free(ua);
    }
};

/// Create a new workspace item task
pub fn createWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    session_id: ?[]const u8,
    task_type: []const u8,
) !WorkspaceItemTaskInfo {
    if (!std.mem.eql(u8, task_type, "standard") and !std.mem.eql(u8, task_type, "routine")) {
        return error.InvalidTaskType;
    }

    if (session_id) |sid| {
        const sql = "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id, task_type) VALUES (?, ?, ?, ?, ?)";
        try db.exec(allocator, sql, &.{ id, name, workspace_item_id, sid, task_type });
    } else {
        const sql = "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) VALUES (?, ?, ?, ?)";
        try db.exec(allocator, sql, &.{ id, name, workspace_item_id, task_type });
    }

    return WorkspaceItemTaskInfo{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .workspace_item_id = try allocator.dupe(u8, workspace_item_id),
        .session_id = if (session_id) |s| try allocator.dupe(u8, s) else null,
        .task_type = try allocator.dupe(u8, task_type),
        .routine = null,
    };
}

/// Get a workspace item task by id
pub fn getWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !?WorkspaceItemTaskInfo {
    const sql = "SELECT id, name, workspace_item_id, session_id, created_at, updated_at, task_type FROM workspace_item_tasks t WHERE t.id = ?";

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            .session_id = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .task_type = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else try allocator.dupe(u8, "standard"),
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
    session_id: ?[]const u8,
) !void {
    if (name == null and session_id == null) {
        // Nothing to update
        return;
    }

    var set_clauses = std.ArrayList([]const u8).empty;
    var values = std.ArrayList([]const u8).empty;

    if (name) |n| {
        try set_clauses.append(allocator, "name = ?");
        try values.append(allocator, n);
    }

    if (session_id) |s| {
        try set_clauses.append(allocator, "session_id = ?");
        try values.append(allocator, s);
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

/// List all workspace item tasks by workspace_item_id
pub fn listWorkspaceItemTasks(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]WorkspaceItemTaskInfo {
    const sql =
        \\SELECT t.id, t.name, t.workspace_item_id, t.session_id, t.created_at, t.updated_at, t.task_type,
        \\       r.schedule, r.initial_prompt, r.enabled, r.last_run_at, r.next_run_at, r.last_status, r.last_error
        \\FROM workspace_item_tasks t LEFT JOIN routines r ON r.task_id = t.id
        \\WHERE t.workspace_item_id = ? ORDER BY t.created_at DESC
    ;

    var rows = try db.query(allocator, sql, &.{workspace_item_id});
    defer rows.deinit();

    var tasks = std.ArrayList(WorkspaceItemTaskInfo).empty;
    errdefer {
        for (tasks.items) |task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    while (try rows.next()) |row| {
        // Row indices 0-5: task core; 6: task_type; 7-13: routine fields.
        // routine.schedule is NOT NULL, so its presence discriminates
        // joined routine rows from standard tasks.
        const task_type = if (row.values[6].len > 0)
            try allocator.dupe(u8, row.values[6])
        else
            try allocator.dupe(u8, "standard");
        const has_routine = row.values[7].len > 0;
        const routine_meta: ?RoutineMeta = if (has_routine) blk: {
            const v = row.values[12];
            const last_status: routines_model.RoutineRunStatus =
                if (v.len == 0) .idle
                else if (std.mem.eql(u8, v, "success")) .success
                else if (std.mem.eql(u8, v, "failed")) .failed
                else if (std.mem.eql(u8, v, "running")) .running
                else .idle;
            break :blk RoutineMeta{
                .schedule = try allocator.dupe(u8, row.values[7]),
                .initial_prompt = try allocator.dupe(u8, row.values[8]),
                .enabled = std.mem.eql(u8, row.values[9], "1"),
                .last_run_at = if (row.values[10].len > 0) try allocator.dupe(u8, row.values[10]) else null,
                .next_run_at = try allocator.dupe(u8, row.values[11]),
                .last_status = last_status,
                .last_error = if (row.values[13].len > 0) try allocator.dupe(u8, row.values[13]) else null,
            };
        } else null;

        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            .session_id = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .task_type = task_type,
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
        "ORDER BY {s} {s}, t.id {s}",
        .{ sort_col, sort_dir_str, sort_dir_str },
    );
    defer allocator.free(order_by);

    // Cursor: encoded as "<sort_value>|<id>" by the handler. Split it
    // into the sort-field value (compared first) and the id (tiebreaker).
    // When cursor is null, no WHERE clause is added.
    const cursor_clause: []u8 = blk: {
        const c = cursor orelse break :blk try allocator.dupe(u8, "");
        // The cursor format is "<sort_value>|<id>". For DATETIME columns
        // (created_at, updated_at) the value contains no '|' so the
        // split is unambiguous. For `name` a '|' in the name would
        // corrupt the split, but task names are user-typed and
        // unlikely to contain '|' — add a sanitizer in the handler if
        // that becomes a real problem.
        const pipe_idx = std.mem.indexOfScalar(u8, c, '|') orelse
            return error.MalformedCursor;
        const sort_value = c[0..pipe_idx];
        const id_value = c[pipe_idx + 1 ..];

        // For DESC: row should come AFTER the cursor pair in sort order,
        // which means sort_value < cursor.sort_value, OR sort_value
        // equals and id < cursor.id. For ASC: >. Build the clause.
        const cmp = switch (sort_direction) {
            .desc => "<",
            .asc => ">",
        };
        break :blk try std.fmt.allocPrint(
            allocator,
            " AND ({s} {s} '{s}' OR ({s} = '{s}' AND t.id {s} '{s}'))",
            .{ sort_col, cmp, sort_value, sort_col, sort_value, cmp, id_value },
        );
    };
    defer allocator.free(cursor_clause);

    const sql = try std.fmt.allocPrint(
        allocator,
        "SELECT t.id, t.name, t.workspace_item_id, t.session_id, t.created_at, t.updated_at, t.task_type, r.schedule, r.initial_prompt, r.enabled, r.last_run_at, r.next_run_at, r.last_status, r.last_error FROM workspace_item_tasks t LEFT JOIN routines r ON r.task_id = t.id WHERE t.workspace_item_id = ?{s} {s} LIMIT {s}",
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
        // Row indices 0-5: task core; 6: task_type; 7-13: routine fields.
        // routine.schedule is NOT NULL, so its presence discriminates
        // joined routine rows from standard tasks.
        const task_type = if (row.values[6].len > 0)
            try allocator.dupe(u8, row.values[6])
        else
            try allocator.dupe(u8, "standard");
        const has_routine = row.values[7].len > 0;
        const routine_meta: ?RoutineMeta = if (has_routine) blk: {
            const v = row.values[12];
            const last_status: routines_model.RoutineRunStatus =
                if (v.len == 0) .idle
                else if (std.mem.eql(u8, v, "success")) .success
                else if (std.mem.eql(u8, v, "failed")) .failed
                else if (std.mem.eql(u8, v, "running")) .running
                else .idle;
            break :blk RoutineMeta{
                .schedule = try allocator.dupe(u8, row.values[7]),
                .initial_prompt = try allocator.dupe(u8, row.values[8]),
                .enabled = std.mem.eql(u8, row.values[9], "1"),
                .last_run_at = if (row.values[10].len > 0) try allocator.dupe(u8, row.values[10]) else null,
                .next_run_at = try allocator.dupe(u8, row.values[11]),
                .last_status = last_status,
                .last_error = if (row.values[13].len > 0) try allocator.dupe(u8, row.values[13]) else null,
            };
        } else null;

        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            .session_id = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .task_type = task_type,
            .routine = routine_meta,
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
    const sql = "SELECT s.id, COALESCE(s.name, ''), COALESCE(s.status, 'active'), COALESCE(s.cwd, ''), COALESCE(s.created_at, ''), COALESCE(s.updated_at, ''), COALESCE(h.agent, 'Agent'), COALESCE(s.selected_profile_model, '') FROM sessions s LEFT JOIN llm_history h ON s.id = h.session_id ORDER BY s.updated_at DESC";

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
