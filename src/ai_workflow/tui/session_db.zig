const std = @import("std");
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;

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

    // Query to get distinct sessions with their latest message info
    const sql = "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history WHERE 1=1 GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT ? OFFSET ?";

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
pub fn getSessionListWithCursor(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    status: ?[]const u8,
    agent_type: ?[]const u8,
    limit: u32,
    cursor: ?[]const u8,
) !struct { sessions: []SessionInfo, total: u32 } {
    _ = status;
    _ = agent_type;

    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    defer allocator.free(limit_str);

    // Build query with cursor condition if provided
    const sql_final: []u8 = if (cursor) |c| blk: {
        break :blk try std.fmt.allocPrint(allocator,
            "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history WHERE 1=1 AND created_at < '{s}' GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT {d}",
            .{c, limit});
    } else blk: {
        break :blk try std.fmt.allocPrint(allocator,
            "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history WHERE 1=1 GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT {d}",
            .{limit});
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
) ![]SessionMessage {
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    defer allocator.free(limit_str);

    var sql: []u8 = undefined;
    var argv: []const []const u8 = undefined;

    if (cursor) |c| {
        // With cursor
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
            \\FROM llm_history WHERE session_id = ? AND id > ?{s} LIMIT ?
            , .{order_part});
        argv = &.{ session_id, c, limit_str };
    } else {
        // Without cursor
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

    return try messages.toOwnedSlice(allocator);
}

/// Build JSON response for session messages
pub fn buildSessionMessagesJson(
    allocator: std.mem.Allocator,
    messages: []const SessionMessage,
) ![]u8 {
    var json_messages = std.ArrayList(u8).empty;
    errdefer json_messages.deinit(allocator);

    try json_messages.appendSlice(allocator, "[");
    for (messages, 0..) |msg, i| {
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

    const result = try std.fmt.allocPrint(allocator,
        "{{\"messages\":{s}}}",
        .{json_messages.items});
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

/// Build XML response for session messages
pub fn buildSessionMessagesXml(
    allocator: std.mem.Allocator,
    messages: []const SessionMessage,
) ![]u8 {
    var xml_messages = std.ArrayList(u8).empty;
    errdefer xml_messages.deinit(allocator);

    try xml_messages.appendSlice(allocator, "<messages>");
    for (messages) |msg| {
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
    try xml_messages.appendSlice(allocator, "</messages>");

    return try xml_messages.toOwnedSlice(allocator);
}
