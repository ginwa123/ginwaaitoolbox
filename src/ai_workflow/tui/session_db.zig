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

/// Build JSON response for a list of sessions
pub fn buildSessionListJson(
    allocator: std.mem.Allocator,
    sessions: []const SessionInfo,
    total: u32,
) ![]u8 {
    var json_sessions = std.ArrayList(u8).empty;
    errdefer json_sessions.deinit(allocator);

    try json_sessions.appendSlice(allocator, "[");
    for (sessions, 0..) |sess, i| {
        if (i > 0) try json_sessions.append(allocator, ',');

        // Escape JSON strings
        const sess_json = try std.fmt.allocPrint(allocator,
            "{{\"sessionId\":{s},\"sessionDir\":{s},\"createdAt\":{s},\"agent\":{s},\"sessionName\":{s}}}",
            .{
                try jsonEscape(allocator, sess.session_id),
                try jsonEscape(allocator, sess.session_dir),
                try jsonEscape(allocator, sess.created_at),
                try jsonEscape(allocator, sess.agent),
                try jsonEscape(allocator, sess.session_name),
            });
        defer allocator.free(sess_json);
        try json_sessions.appendSlice(allocator, sess_json);
    }
    try json_sessions.append(allocator, ']');

    const result = try std.fmt.allocPrint(allocator,
        "{{\"sessions\":{s},\"total\":{d}}}",
        .{ json_sessions.items, total });
    json_sessions.deinit(allocator);
    return result;
}

/// Escape a string for JSON - wraps in quotes and escapes special characters
fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var escaped = std.ArrayList(u8).init(allocator);
    errdefer escaped.deinit(allocator);

    try escaped.append(allocator, '"');
    for (input) |c| {
        switch (c) {
            '"' => try escaped.appendSlice(allocator, "\\\""),
            '\\' => try escaped.appendSlice(allocator, "\\\\"),
            '\n' => try escaped.appendSlice(allocator, "\\n"),
            '\r' => try escaped.appendSlice(allocator, "\\r"),
            '\t' => try escaped.appendSlice(allocator, "\\t"),
            else => try escaped.append(allocator, c),
        }
    }
    try escaped.append(allocator, '"');

    return try escaped.toOwnedSlice(allocator);
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

    pub fn deinit(self: *const SessionMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.role);
        allocator.free(self.content);
        allocator.free(self.timestamp);
    }
};

/// Get messages for a session
pub fn getSessionMessages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    limit: u32,
    offset: u32,
) ![]SessionMessage {
    const sql = "SELECT id, session_id, role, content, created_at FROM llm_history WHERE session_id = ? ORDER BY created_at ASC, id ASC LIMIT ? OFFSET ?";

    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    const offset_str = try std.fmt.allocPrint(allocator, "{d}", .{offset});
    defer {
        allocator.free(limit_str);
        allocator.free(offset_str);
    }

    var rows = try db.query(allocator, sql, &.{ session_id, limit_str, offset_str });
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
            "{{\"id\":\"{s}\",\"sessionId\":\"{s}\",\"role\":\"{s}\",\"content\":\"{s}\",\"timestamp\":\"{s}\"}}",
            .{ msg.id, msg.session_id, msg.role, escaped_content.items, msg.timestamp });
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
