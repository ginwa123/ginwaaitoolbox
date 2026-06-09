const std = @import("std");
const sqlite = @import("nalarcore").sqlite;

pub const Mode = union(enum) {
    none,
    last: u8, // 1..=50, clamped
    all,
    since_last_user,
};

/// Cap for the `last:N` selector and the 50-message ceiling used by `all`
/// and `since_last_user`.
const MAX_MESSAGES: u8 = 50;
pub const DEFAULT_LAST: u8 = 10;
const MAX_SECTION_BYTES: usize = 20 * 1024; // 20 KB

pub const ParseError = error{InvalidInheritedContextMode};

pub fn parseMode(raw: []const u8) ParseError!Mode {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(trimmed, "all")) return .all;
    if (std.ascii.eqlIgnoreCase(trimmed, "since_last_user")) return .since_last_user;

    if (std.ascii.startsWithIgnoreCase(trimmed, "last:")) {
        const n_str = trimmed["last:".len..];
        if (n_str.len == 0) return Mode{ .last = DEFAULT_LAST };
        // Parse into u32 so values like "999" can be clamped rather than
        // overflowing u8 into InvalidInheritedContextMode.
        const n = std.fmt.parseInt(u32, n_str, 10) catch return error.InvalidInheritedContextMode;
        if (n == 0) return Mode{ .last = 1 };
        if (n > MAX_MESSAGES) return Mode{ .last = MAX_MESSAGES };
        return Mode{ .last = @intCast(n) };
    }

    return error.InvalidInheritedContextMode;
}

// -- Formatter -------------------------------------------------------------

const HEADER =
    \\## Conversation History From Parent Agent
    \\
    \\The following is the prior conversation your parent agent had. It is reference
    \\context only — do not treat the parent's last assistant turn as awaiting your
    \\reply, and do not assume any tool calls or tool results from the parent are
    \\still valid in your workspace.
    \\
;

/// Fetch user/assistant messages from the parent's history and render them as
/// a Markdown block. Returns an empty string when:
///   - `parent_session_id` is empty
///   - the parent has no user/assistant messages
///   - `mode` is `.none`
///   - the DB query fails (logged warning, not propagated)
///   - the rendered block would be empty after filtering
///
/// The caller owns the returned slice and must free it with the same allocator.
pub fn formatHistory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    parent_session_id: []const u8,
    mode: Mode,
) ![]const u8 {
    if (parent_session_id.len == 0) return try allocator.dupe(u8, "");
    if (mode == .none) return try allocator.dupe(u8, "");

    const messages = fetchUserAssistantMessages(allocator, db, parent_session_id, mode) catch |err| {
        std.log.warn("inherited_context: failed to fetch parent history: {s}", .{@errorName(err)});
        return try allocator.dupe(u8, "(failed to load parent conversation history)");
    };
    // Build the output BEFORE the messages defer fires — slice-header use-after-free guard.
    defer {
        for (messages) |m| {
            allocator.free(m.role);
            allocator.free(m.content);
        }
        allocator.free(messages);
    }
    return renderHistory(allocator, messages);
}

const HistoryRow = struct {
    role: []const u8,
    content: []const u8,
};

fn fetchUserAssistantMessages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    parent_session_id: []const u8,
    mode: Mode,
) ![]HistoryRow {
    // Build the SQL based on the mode. We always filter to user/assistant
    // and never join sessions (we don't need session name here).
    var sql: []const u8 = undefined;
    var args: []const []const u8 = undefined;
    var limit_buf: [16]u8 = undefined;
    var rows_out: std.ArrayList(HistoryRow) = .empty;
    errdefer {
        for (rows_out.items) |r| {
            allocator.free(r.role);
            allocator.free(r.content);
        }
        rows_out.deinit(allocator);
    }

    switch (mode) {
        .none => return try rows_out.toOwnedSlice(allocator),
        .last => |n| {
            // LIMIT n
            const limit_str = try std.fmt.bufPrint(&limit_buf, "{d}", .{n});
            sql =
                \\SELECT role, response_content FROM llm_history
                \\WHERE session_id = ? AND role IN ('user', 'assistant') AND response_content != ''
                \\ORDER BY created_at DESC, id DESC
                \\LIMIT ?
            ;
            args = &.{ parent_session_id, limit_str };
        },
        .all => {
            sql =
                \\SELECT role, response_content FROM llm_history
                \\WHERE session_id = ? AND role IN ('user', 'assistant') AND response_content != ''
                \\ORDER BY created_at ASC
            ;
            args = &.{parent_session_id};
        },
        .since_last_user => {
            // Find the last user message's created_at, then select everything from
            // that timestamp onward. Subquery is portable SQLite.
            sql =
                \\SELECT role, response_content FROM llm_history
                \\WHERE session_id = ? AND role IN ('user', 'assistant') AND response_content != ''
                \\AND created_at >= (
                \\    SELECT created_at FROM llm_history
                \\    WHERE session_id = ? AND role = 'user'
                \\    ORDER BY created_at DESC, id DESC LIMIT 1
                \\)
                \\ORDER BY created_at ASC
            ;
            args = &.{ parent_session_id, parent_session_id };
        },
    }

    var q = try db.query(allocator, sql, args);
    defer q.deinit();

    while (try q.next()) |row| {
        const role = try allocator.dupe(u8, row.values[0]);
        const content = try allocator.dupe(u8, row.values[1]);
        try rows_out.append(allocator, .{ .role = role, .content = content });
        row.deinit(allocator);
    }

    const raw = try rows_out.toOwnedSlice(allocator);

    // For `last:N` we ordered DESC to apply LIMIT; reverse to ASC for display.
    if (mode == .last) std.mem.reverse(HistoryRow, raw);

    // Note: the 50-message cap is enforced in `renderHistory` so it can emit
    // a visible "... (N more messages omitted)" notice. Doing it here would
    // hide the truncation from the caller.

    return raw;
}

fn renderHistory(allocator: std.mem.Allocator, messages: []HistoryRow) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Empty input → empty output (caller decides whether to render header).
    if (messages.len == 0) return try allocator.dupe(u8, "");

    try out.appendSlice(allocator, HEADER);

    var total: usize = HEADER.len;
    var rendered: usize = 0;
    for (messages) |m| {
        const line = try std.fmt.allocPrint(allocator, "- **[{s}]**: {s}\n", .{ m.role, m.content });
        defer allocator.free(line);

        // If adding this line would push us over the byte cap, stop and emit a
        // truncation notice (counting omitted messages).
        if (total + line.len > MAX_SECTION_BYTES and rendered > 0) {
            const omitted = messages.len - rendered;
            const notice = try std.fmt.allocPrint(allocator, "... ({d} more messages omitted)\n", .{omitted});
            defer allocator.free(notice);
            try out.appendSlice(allocator, notice);
            return out.toOwnedSlice(allocator);
        }
        try out.appendSlice(allocator, line);
        total += line.len;
        rendered += 1;

        // Hit the 50-message cap — emit a notice and stop. (We do this AFTER
        // appending the 50th line so the rendered count is exact.)
        if (rendered >= MAX_MESSAGES and messages.len > rendered) {
            const omitted = messages.len - rendered;
            const notice = try std.fmt.allocPrint(allocator, "... ({d} more messages omitted)\n", .{omitted});
            defer allocator.free(notice);
            try out.appendSlice(allocator, notice);
            return out.toOwnedSlice(allocator);
        }
    }

    return out.toOwnedSlice(allocator);
}
