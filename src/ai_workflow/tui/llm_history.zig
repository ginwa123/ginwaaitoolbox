const std = @import("std");
const tree1 = @import("nalarcore");
const sqlite = tree1.sqlite;
const agent = tree1.agent;
const TUIHistory = @import("models.zig").TUIHistory;

pub fn mark_message_not_for_llm_run(
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
    session_dir: []const u8,
    created_at: []const u8,
    agent: []const u8,
    session_name: []const u8,

    pub fn deinit(self: *const SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.session_dir);
        allocator.free(self.created_at);
        allocator.free(self.agent);
        allocator.free(self.session_name);
    }
};

/// Detailed session info
pub const SessionDetail = struct {
    session_id: []const u8,
    session_dir: []const u8,
    created_at: []const u8,
    agent: []const u8,
    session_name: []const u8,
    model: []const u8,
    temperature: f32,

    pub fn deinit(self: *const SessionDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.session_dir);
        allocator.free(self.created_at);
        allocator.free(self.agent);
        allocator.free(self.session_name);
        allocator.free(self.model);
    }
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

    const sql = "SELECT h.session_id, COALESCE(h.session_dir, ''), MAX(h.created_at) as created_at, COALESCE(h.agent, 'Agent'), COALESCE(s.name, '') FROM llm_history h LEFT JOIN sessions s ON h.session_id = s.id WHERE 1=1 GROUP BY h.session_id ORDER BY MAX(h.created_at) DESC LIMIT ? OFFSET ?";

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
            .session_dir = try allocator.dupe(u8, row.values[1]),
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
/// Optionally filtered by session_dir
pub fn getSessionListWithCursor(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    status: ?[]const u8,
    agent_type: ?[]const u8,
    session_dir: ?[]const u8,
    limit: u32,
    cursor: ?[]const u8,
) !struct { sessions: []SessionInfo, total: u32 } {
    _ = status;
    _ = agent_type;

    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    defer allocator.free(limit_str);

    // Build query with session_dir filter and cursor condition
    const sql_final: []u8 = if (session_dir) |dir| blk: {
        if (cursor) |c| {
            break :blk try std.fmt.allocPrint(allocator,
                "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history WHERE 1=1 AND session_dir = '{s}' AND created_at < '{s}' GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT {d}",
                .{dir, c, limit});
        } else {
            break :blk try std.fmt.allocPrint(allocator,
                "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history WHERE 1=1 AND session_dir = '{s}' GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT {d}",
                .{dir, limit});
        }
    } else blk: {
        if (cursor) |c| {
            break :blk try std.fmt.allocPrint(allocator,
                "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history WHERE 1=1 AND created_at < '{s}' GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT {d}",
                .{c, limit});
        } else {
            break :blk try std.fmt.allocPrint(allocator,
                "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history WHERE 1=1 GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT {d}",
                .{limit});
        }
    };
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
            .session_dir = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
            .agent = try allocator.dupe(u8, row.values[3]),
            .session_name = try allocator.dupe(u8, row.values[4]),
        };
        try sessions.append(allocator, session);
        row.deinit(allocator);
    }

    // Build count query with session_dir filter
    const count_sql: []u8 = if (session_dir) |dir|
        try std.fmt.allocPrint(allocator,
            "SELECT COUNT(DISTINCT session_id) FROM llm_history WHERE session_dir = '{s}'",
            .{dir})
    else
        try allocator.dupe(u8, "SELECT COUNT(DISTINCT session_id) FROM llm_history");
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

/// Build JSON response for a list of sessions with cursor pagination
pub fn buildSessionListJson(
    allocator: std.mem.Allocator,
    sessions: []const SessionInfo,
    total: u32,
    has_more: bool,
    next_cursor: ?[]const u8,
) ![]u8 {
    var json_sessions = std.ArrayList(u8).empty;
    errdefer json_sessions.deinit(allocator);

    try json_sessions.appendSlice(allocator, "[");
    for (sessions, 0..) |sess, i| {
        if (i > 0) try json_sessions.append(allocator, ',');

        // Build each field with JSON escaping
        try json_sessions.append(allocator, '{');
        try json_sessions.appendSlice(allocator, "\"session_id\":");
        try jsonAppendEscaped(allocator, &json_sessions, sess.session_id);
        try json_sessions.append(allocator, ',');
        try json_sessions.appendSlice(allocator, "\"session_dir\":");
        try jsonAppendEscaped(allocator, &json_sessions, sess.session_dir);
        try json_sessions.append(allocator, ',');
        try json_sessions.appendSlice(allocator, "\"created_at\":");
        try jsonAppendEscaped(allocator, &json_sessions, sess.created_at);
        try json_sessions.append(allocator, ',');
        try json_sessions.appendSlice(allocator, "\"agent\":");
        try jsonAppendEscaped(allocator, &json_sessions, sess.agent);
        try json_sessions.append(allocator, ',');
        try json_sessions.appendSlice(allocator, "\"session_name\":");
        try jsonAppendEscaped(allocator, &json_sessions, sess.session_name);
        try json_sessions.append(allocator, '}');
    }
    try json_sessions.append(allocator, ']');

    // Build has_more and next_cursor JSON
    const has_more_str = if (has_more) "true" else "false";
    const next_cursor_json = if (next_cursor) |c|
        try std.fmt.allocPrint(allocator, ",\"next_cursor\":\"{s}\"", .{c})
    else
        "";
    defer if (next_cursor) |_| allocator.free(next_cursor_json);

    const result = try std.fmt.allocPrint(allocator,
        "{{\"sessions\":{s},\"total\":{d},\"has_more\":{s}{s}}}",
        .{ json_sessions.items, total, has_more_str, next_cursor_json });
    json_sessions.deinit(allocator);
    return result;
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
    const sql = "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, ''), COALESCE(model, 'gpt-4'), COALESCE(temperature, 0.2) FROM llm_history WHERE session_id = ? GROUP BY session_id";

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const session = SessionDetail{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_dir = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
            .agent = try allocator.dupe(u8, row.values[3]),
            .session_name = try allocator.dupe(u8, row.values[4]),
            .model = try allocator.dupe(u8, row.values[5]),
            .temperature = std.fmt.parseFloat(f32, row.values[6]) catch 0.2,
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
    }
};

/// Response for session messages with cursor pagination
pub const SessionMessageResponse = struct {
    messages: []SessionMessage,
    has_more: bool,
    next_cursor: ?[]const u8,
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
pub fn get_session_messages_sorted(
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
        const cursor_cmp = if (is_asc) " AND created_at > ?" else " AND created_at < ?";

        const order_part = switch (sort_spec) {
            .created_at_asc => " ORDER BY created_at ASC, id ASC",
            .created_at_desc => " ORDER BY created_at DESC, id DESC",
            .id_asc => " ORDER BY created_at ASC, id ASC",
            .id_desc => " ORDER BY created_at DESC, id DESC",
            .role_asc => " ORDER BY role ASC, created_at ASC, id ASC",
            .role_desc => " ORDER BY role DESC, created_at DESC, id DESC",
        };
        sql = try std.fmt.allocPrint(allocator,
            \\SELECT id, session_id, role, response_content, created_at,
            \\       COALESCE(is_input, 0), COALESCE(is_output, 0), COALESCE(tool_name, ''),
            \\       COALESCE(finish_reason, '')
            \\FROM llm_history WHERE session_id = ?{s}{s} LIMIT ?
            , .{ cursor_cmp, order_part });
        argv = &.{ session_id, c, limit_str };
    } else {
        const order_part = switch (sort_spec) {
            .created_at_asc => " ORDER BY created_at ASC, id ASC",
            .created_at_desc => " ORDER BY created_at DESC, id DESC",
            .id_asc => " ORDER BY id ASC",
            .id_desc => " ORDER BY id DESC",
            .role_asc => " ORDER BY role ASC, created_at ASC, id ASC",
            .role_desc => " ORDER BY role DESC, created_at DESC, id DESC",
        };
        sql = try std.fmt.allocPrint(allocator,
            \\SELECT id, session_id, role, response_content, created_at,
            \\       COALESCE(is_input, 0), COALESCE(is_output, 0), COALESCE(tool_name, ''),
            \\       COALESCE(finish_reason, '')
            \\FROM llm_history WHERE session_id = ?{s} LIMIT ?
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

    while (try rows.next()) |row| {
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
        };
        try messages.append(allocator, msg);
        row.deinit(allocator);
    }

    // Check if there are more results
    const has_more = messages.items.len > @as(usize, limit);

    // Get next cursor from last message if has_more
    const next_cursor: ?[]const u8 = if (has_more and messages.items.len > 0)
        messages.items[@as(usize, limit) - 1].id
    else
        null;

    // Return only limit messages if has_more
    const result_messages = if (has_more) messages.items[0..limit] else messages.items;

    return SessionMessageResponse{
        .messages = result_messages,
        .has_more = has_more,
        .next_cursor = next_cursor,
    };
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
        // Escape content for JSON
        var escaped_content = std.ArrayList(u8).empty;
        errdefer escaped_content.deinit(allocator);
        for (msg.content) |c| {
            switch (c) {
                '"' => try escaped_content.appendSlice(allocator, "\\\""),
                '\\' => try escaped_content.appendSlice(allocator, "\\\\"),
                '\n' => try escaped_content.appendSlice(allocator, "\\n"),
                '\r' => try escaped_content.appendSlice(allocator, "\\r"),
                '\t' => try escaped_content.appendSlice(allocator, "\\t"),
                else => try escaped_content.append(allocator, c),
            }
        }
        const msg_json = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","session_id":"{s}","role":"{s}","content":"{s}","timestamp":"{s}",
            \\"is_input":"{s}","is_output":"{s}","tool_name":"{s}","finish_reason":"{s}"}}
            ,
            .{ msg.id, msg.session_id, msg.role, escaped_content.items, msg.timestamp, msg.is_input, msg.is_output, msg.tool_name, msg.finish_reason });
        defer allocator.free(msg_json);
        try json_messages.appendSlice(allocator, msg_json);
        escaped_content.deinit(allocator);
    }
    try json_messages.append(allocator, ']');

    // Build pagination fields
    const has_more_str = if (response.has_more) "true" else "false";
    const next_cursor_str = if (response.next_cursor) |c|
        try std.fmt.allocPrint(allocator, "\"{s}\"", .{c})
    else
        try std.fmt.allocPrint(allocator, "null", .{});
    defer allocator.free(next_cursor_str);

    const result = try std.fmt.allocPrint(allocator,
        "{{\"messages\":{s},\"has_more\":{s},\"next_cursor\":{s}}}",
        .{json_messages.items, has_more_str, next_cursor_str});
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
            \\</message>
            ,
            .{ escaped_id, escaped_session_id, escaped_role, escaped_content,
               escaped_timestamp, msg.is_input, msg.is_output, escaped_tool_name, escaped_finish_reason });
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
    var aw: std.io.Writer.Allocating = .init(allocator);
    try aw.writer.print("{f}", .{std.json.fmt(tool_calls, .{})});
    return try aw.toOwnedSlice();
}

pub const save_messageInput = struct {
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
};

/// Helper function to safely duplicate a string
/// Uses c_allocator to avoid arena aliasing issues
fn safeDupe(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const copy = try std.heap.c_allocator.dupe(u8, s);
    _ = allocator; // Mark as intentionally unused - we use c_allocator to avoid aliasing
    return copy;
}

pub fn save_message(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: save_messageInput,
) !void {
    const id = try std.fmt.allocPrint(allocator, "{}", .{std.time.nanoTimestamp()});
    defer allocator.free(id);
    const created_at = try std.fmt.allocPrint(allocator, "{}", .{std.time.milliTimestamp()});
    defer allocator.free(created_at);

    const contentStr = input.content orelse "";
    const finishReasonStr = input.finish_reason orelse "null";
    const roleStr = input.role orelse "assistant";
    const reasoningStr = input.reasoning_content orelse "";
    const agentStr = input.agent_name orelse "Agent";

    // Determine tool_calls_json: prefer serialized tool_calls, fall back to tool_call_id, then empty string
    var toolCallsJson: []const u8 = "";
    var toolCallsOwned: ?[]u8 = null;
    if (input.tool_calls) |tc| {
        toolCallsOwned = try serializeToolCalls(allocator, tc);
        toolCallsJson = toolCallsOwned.?;
    } else if (input.tool_call_id) |tcid| {
        toolCallsJson = tcid;
    }
    defer if (toolCallsOwned) |tcj| allocator.free(tcj);

    const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, reasoning_content, session_dir, is_feed_to_llm, agent, loop_index, temperature, is_thinking, created_at, parent_session_id, parent_id, prompt_tokens, completion_tokens, total_tokens, is_input, is_output, tool_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";

    // Use safeDupe to avoid arena aliasing issues
    const copy_session_id = try safeDupe(allocator, input.session_id);
    defer std.heap.c_allocator.free(copy_session_id);
    const copy_model = try safeDupe(allocator, input.model);
    defer std.heap.c_allocator.free(copy_model);
    const copy_content = try safeDupe(allocator, contentStr);
    defer std.heap.c_allocator.free(copy_content);
    const copy_finish_reason = try safeDupe(allocator, finishReasonStr);
    defer std.heap.c_allocator.free(copy_finish_reason);
    const copy_role = try safeDupe(allocator, roleStr);
    defer std.heap.c_allocator.free(copy_role);
    const copy_tool_calls = try safeDupe(allocator, toolCallsJson);
    defer std.heap.c_allocator.free(copy_tool_calls);
    const copy_reasoning = try safeDupe(allocator, reasoningStr);
    defer std.heap.c_allocator.free(copy_reasoning);
    const copy_cwd = try safeDupe(allocator, input.cwd);
    defer std.heap.c_allocator.free(copy_cwd);
    const copy_agent = try safeDupe(allocator, agentStr);
    defer std.heap.c_allocator.free(copy_agent);
    const loop_index_str = try std.fmt.allocPrint(allocator, "{}", .{input.loop_index});
    defer allocator.free(loop_index_str);
    const temperature_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{input.temperature});
    defer allocator.free(temperature_str);
    const is_thinking_str = if (input.is_thinking) "1" else "0";
    const copy_parent_session_id = try safeDupe(allocator, input.parent_session_id orelse "");
    defer std.heap.c_allocator.free(copy_parent_session_id);
    const copy_parent_id = try safeDupe(allocator, input.parent_id orelse "");
    defer std.heap.c_allocator.free(copy_parent_id);
    const copy_tool_name = try safeDupe(allocator, input.tool_name orelse "");
    defer std.heap.c_allocator.free(copy_tool_name);
    const prompt_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.prompt_tokens});
    defer allocator.free(prompt_tokens_str);
    const completion_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.completion_tokens});
    defer allocator.free(completion_tokens_str);
    const total_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.total_tokens});
    defer allocator.free(total_tokens_str);

    const sqlArgs = &.{ id, copy_session_id, copy_model, copy_content, copy_finish_reason, copy_role, copy_tool_calls, copy_reasoning, copy_cwd, copy_agent, loop_index_str, temperature_str, is_thinking_str, created_at, copy_parent_session_id, copy_parent_id, prompt_tokens_str, completion_tokens_str, total_tokens_str, if (input.is_input) "1" else "0", if (input.is_output) "1" else "0", copy_tool_name };

    try db.exec(allocator, sql, sqlArgs);

    // Update worker description with latest messages
    try update_worker_description(allocator, db, input.session_id);
}

/// Check if a session exists in the database
/// Returns true if session exists, false otherwise or on error
pub fn check_session_exists(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) bool {
    const sql = "SELECT COUNT(*) as cnt FROM llm_history WHERE session_id = ?";

    const result = db.queryRow(allocator, sql, &.{session_id}) catch return false;
    defer result.deinit(allocator);

    if (result.values.len > 0) {
        const count_str = std.mem.sliceTo(result.values[0], 0);
        if (std.fmt.parseInt(i32, count_str, 10)) |count| {
            return count > 0;
        } else |_| {}
    }

    return false;
}

// =============================================================================
// Get Messages Functions
// =============================================================================

pub fn get_messages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]TUIHistory {
    var results: std.ArrayList(TUIHistory) = .empty;

    const sql = "SELECT h.id, h.session_id, h.model, h.created_at, h.response_content, h.finish_reason, COALESCE(h.role, 'assistant'), COALESCE(h.tool_calls_json, ''), COALESCE(h.reasoning_content, ''), COALESCE(h.agent, 'Agent'), COALESCE(s.name, ''), COALESCE(h.loop_index, 0), COALESCE(h.tool_name, ''), COALESCE(h.parent_session_id, ''), COALESCE(h.temperature, 0.2), COALESCE(h.is_thinking, 0), COALESCE(h.prompt_tokens, 0), COALESCE(h.completion_tokens, 0), COALESCE(h.total_tokens, 0), COALESCE(h.is_input, 0), COALESCE(h.is_output, 0) FROM llm_history h LEFT JOIN sessions s ON h.session_id = s.id WHERE h.session_id = ? AND (h.is_feed_to_llm = 1 OR h.is_feed_to_llm IS NULL) ORDER BY h.created_at ASC";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    while (try rows.next()) |row| {
        const parent_session_id_str = row.values[13];
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
        };
        try results.append(allocator, history);
        row.deinit(allocator);
    }

    return results.toOwnedSlice(allocator);
}

pub fn get_message_latest(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?TUIHistory {
    const sql = "SELECT h.id, h.session_id, h.model, h.created_at, h.response_content, h.finish_reason, COALESCE(h.role, 'assistant'), COALESCE(h.tool_calls_json, ''), COALESCE(h.reasoning_content, ''), COALESCE(h.agent, 'Agent'), COALESCE(s.name, ''), COALESCE(h.loop_index, 0), COALESCE(h.tool_name, ''), COALESCE(h.parent_session_id, ''), COALESCE(h.temperature, 0.2), COALESCE(h.is_thinking, 0), COALESCE(h.prompt_tokens, 0), COALESCE(h.completion_tokens, 0), COALESCE(h.total_tokens, 0), COALESCE(h.is_input, 0), COALESCE(h.is_output, 0) FROM llm_history h LEFT JOIN sessions s ON h.session_id = s.id WHERE h.session_id = ? AND (h.is_feed_to_llm = 1 OR h.is_feed_to_llm IS NULL) ORDER BY h.created_at DESC LIMIT 1";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const parent_session_id_str = row.values[13];
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
    session_dir: []const u8,
) ![]SessionInfo {
    var results: std.ArrayList(SessionInfo) = .empty;

    const sql = "SELECT session_id, COALESCE(session_dir, '') as session_dir, MAX(created_at) as created_at FROM llm_history WHERE session_dir = ? GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT 10";
    var rows = try db.query(allocator, sql, &[_][]const u8{session_dir});
    defer rows.deinit();

    while (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_dir = try allocator.dupe(u8, row.values[1]),
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
    session_dir: []const u8,
) !?SessionInfo {
    const sql = "SELECT session_id, COALESCE(session_dir, '') as session_dir, MAX(created_at) as created_at FROM llm_history WHERE session_dir = ? GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT 1";
    var rows = try db.query(allocator, sql, &[_][]const u8{session_dir});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_dir = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
            .agent = try allocator.dupe(u8, ""),
            .session_name = try allocator.dupe(u8, ""),
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
};

/// Get all active workers with their info
pub fn get_active_workers(
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
pub fn upsert_worker(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    worker_id: []const u8,
    session_id: []const u8,
    working_directory: []const u8,
) !void {
    const sql = "INSERT OR REPLACE INTO worker (id, session_id, working_directory, last_activity, last_activity_description) VALUES (?, ?, ?, strftime('%s', 'now'), '')";
    try db.exec(allocator, sql, &.{ worker_id, session_id, working_directory });

    // Also ensure session exists in sessions table (for JOIN queries)
    // Use INSERT OR IGNORE to handle cases where session might already exist
    const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status) VALUES (?, ?, 'active')";
    try db.exec(allocator, session_sql, &.{ session_id, session_id });
}

/// Update worker's last activity timestamp with description
pub fn update_worker_activity_with_description(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    worker_id: []const u8,
    description: []const u8,
) !void {
    const sql = "UPDATE worker SET last_activity = strftime('%s', 'now'), last_activity_description = ? WHERE id = ?";
    try db.exec(allocator, sql, &.{ description, worker_id });
}

/// Update worker's last activity timestamp
pub fn update_worker_activity(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    worker_id: []const u8,
) !void {
    const sql = "UPDATE worker SET last_activity = strftime('%s', 'now') WHERE id = ?";
    try db.exec(allocator, sql, &.{worker_id});
}

/// Update worker's activity description (for display in agent prompts)
/// Gets the 5 latest messages from llm_history for the given session_id
/// and updates the worker's last_activity_description field.
pub fn update_worker_description(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !void {
    // Get the 5 latest messages from llm_history for this session
    // Note: tool_results_json is never populated, so we only use response_content and tool_calls_json
    const sql = "SELECT COALESCE(response_content, ''), COALESCE(tool_calls_json, ''), role FROM llm_history WHERE session_id = ? ORDER BY created_at DESC LIMIT 5";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    // Build description from messages in reverse order (oldest first)
    var description = std.ArrayList(u8).empty;
    errdefer description.deinit(allocator);
    try description.appendSlice(allocator, "Recent activity:\n");

    // Collect messages (we iterate newest first, so store them first)
    var messages = std.ArrayList([]const u8).empty;
    errdefer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const content = row.values[0];
        const tool_calls = row.values[1];
        const role = row.values[2];

        var msg = std.ArrayList(u8).empty;
        errdefer msg.deinit(allocator);

        // Format: [role] content
        if (content.len > 0) {
            try msg.appendSlice(allocator, "[");
            try msg.appendSlice(allocator, role);
            try msg.appendSlice(allocator, "] ");
            // Truncate long content
            if (content.len > 200) {
                try msg.appendSlice(allocator, content[0..200]);
                try msg.appendSlice(allocator, "...");
            } else {
                try msg.appendSlice(allocator, content);
            }
        } else if (tool_calls.len > 0) {
            // Tool call without content
            try msg.appendSlice(allocator, "[");
            try msg.appendSlice(allocator, role);
            try msg.appendSlice(allocator, "] (tool call)");
        } else {
            continue;
        }

        try messages.append(allocator, try msg.toOwnedSlice(allocator));
        row.deinit(allocator);
    }

    // Reverse order (oldest first for readability)
    var i: usize = 0;
    var j: usize = if (messages.items.len > 0) messages.items.len - 1 else 0;
    while (i < j) : ({ i += 1; j -= 1; }) {
        const tmp = messages.items[i];
        messages.items[i] = messages.items[j];
        messages.items[j] = tmp;
    }

    // Build final description
    for (messages.items, 0..) |msg, idx| {
        if (idx > 0) try description.append(allocator, '\n');
        try description.appendSlice(allocator, "- ");
        try description.appendSlice(allocator, msg);
        allocator.free(msg);
    }
    messages.deinit(allocator);

    const final_description = try description.toOwnedSlice(allocator);
    defer allocator.free(final_description);

    // Update worker with this description (find worker by session_id)
    const update_sql = "UPDATE worker SET last_activity = strftime('%s', 'now'), last_activity_description = ? WHERE session_id = ?";
    try db.exec(allocator, update_sql, &.{ final_description, session_id });
}


/// Remove a worker
pub fn remove_worker(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    worker_id: []const u8,
) !void {
    const sql = "DELETE FROM worker WHERE id = ?";
    try db.exec(allocator, sql, &.{worker_id});
}
