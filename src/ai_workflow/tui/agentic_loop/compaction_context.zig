//! Helpers for the "better compaction context" feature.
//!
//! When a session's history grows past the compactor's threshold, the
//! next iteration of the agent needs more than the compactor's summary —
//! it needs the full user chat history (so it can see the original ask
//! and every refinement) and every file the AI read via `read_file`
//! (so it can re-read context without re-fetching). This module queries
//! `llm_history` for both slices and produces an enriched compaction XML
//! envelope that wraps the compactor's output in
//! `<compaction_context>...</compaction_context>`.

const std = @import("std");
const nalarcore = @import("nalarcore");

const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const Logger = logger_mod.Logger;
const xml_escape = nalarcore.helpers.xml_escape;

/// One user-turn row from `llm_history`. Used to embed the full user
/// history into the compacted envelope so the next iteration of the
/// agent sees the original ask + every refinement, not just the
/// compactor's summary.
pub const UserTurn = struct {
    content: []const u8,
    created_at: []const u8,

    pub fn deinit(self: UserTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        allocator.free(self.created_at);
    }
};

/// One read_file tool-result row from `llm_history`. `path` is the
/// extracted value from the `<path>...</path>` tag in the XML envelope.
/// `raw_content` is kept for debugging and for tests that assert on the
/// full XML; production callers only consume `path`.
pub const ReadFileTurn = struct {
    path: []const u8,
    raw_content: []const u8,
    created_at: []const u8,

    pub fn deinit(self: ReadFileTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.raw_content);
        allocator.free(self.created_at);
    }
};

/// Extract the `<path>...</path>` value from the read_file XML envelope.
/// Returns `null` if the open or close tag is missing. The returned
/// slice borrows from `content` (no allocation) — the caller MUST keep
/// `content` alive for the lifetime of the returned slice.
///
/// The first `<path>` tag wins. Production envelopes have two `<path>`
/// occurrences — one in `<parameters>` (the agent's call args) and one
/// in `<data>` (the tool's response) — but they hold the same value, so
/// the first occurrence is always correct.
pub fn parseReadFilePath(content: []const u8) ?[]const u8 {
    const start_tag = "<path>";
    const end_tag = "</path>";
    const start = std.mem.indexOf(u8, content, start_tag) orelse return null;
    const path_start = start + start_tag.len;
    const end = std.mem.indexOf(u8, content[path_start..], end_tag) orelse return null;
    return content[path_start .. path_start + end];
}

/// Fetch all user chat history rows for a session, in chronological
/// order. Filters out assistant/tool rows, rows with NULL/empty content,
/// and rows from other sessions.
pub fn fetchUserChatHistory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !std.ArrayList(UserTurn) {
    var turns: std.ArrayList(UserTurn) = .empty;
    errdefer {
        for (turns.items) |t| t.deinit(allocator);
        turns.deinit(allocator);
    }

    var rows = try db.query(
        allocator,
        "SELECT response_content, created_at " ++
            "FROM llm_history " ++
            "WHERE session_id = ? " ++
            "  AND role = 'user' " ++
            "  AND response_content IS NOT NULL " ++
            "  AND response_content != '' " ++
            "ORDER BY created_at ASC, id ASC",
        &.{session_id},
    );
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        try turns.append(allocator, .{
            .content = try allocator.dupe(u8, row.values[0]),
            .created_at = try allocator.dupe(u8, row.values[1]),
        });
    }
    return turns;
}

/// Fetch all read_file tool-result rows for a session, with the
/// `<path>` already extracted from each row's XML envelope. Rows with
/// missing or malformed `<path>` tags are SKIPPED with a `logger.warn`
/// rather than failing the whole query — better to lose one row than
/// abort the compaction.
///
/// Caller is responsible for deduping `path` values if desired; this
/// helper returns one entry per row in insertion order.
pub fn fetchReadFilePaths(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    logger: *Logger,
) !std.ArrayList(ReadFileTurn) {
    var turns: std.ArrayList(ReadFileTurn) = .empty;
    errdefer {
        for (turns.items) |t| t.deinit(allocator);
        turns.deinit(allocator);
    }

    var rows = try db.query(
        allocator,
        "SELECT response_content, created_at " ++
            "FROM llm_history " ++
            "WHERE session_id = ? " ++
            "  AND tool_name = 'read_file' " ++
            "  AND is_output = 1 " ++
            "ORDER BY created_at ASC, id ASC",
        &.{session_id},
    );
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const raw = try allocator.dupe(u8, row.values[0]);
        const created_at = try allocator.dupe(u8, row.values[1]);
        const path_borrowed = parseReadFilePath(raw) orelse {
            logger.warnFmt(
                "[COMPACTION] read_file row missing <path> tag (session_id={s}); skipping",
                .{session_id},
            );
            allocator.free(raw);
            allocator.free(created_at);
            continue;
        };
        const path_owned = try allocator.dupe(u8, path_borrowed);
        try turns.append(allocator, .{
            .path = path_owned,
            .raw_content = raw,
            .created_at = created_at,
        });
    }
    return turns;
}

/// Embed the user history and read_file paths into the compacted XML.
/// Returns a new `[]u8` allocated from `allocator`; caller owns it.
/// The original `compacted_xml` is left untouched (the helper dups
/// content during the embed).
///
/// Hard caps: 100 user turns, 2000 chars per turn. Read paths are
/// deduplicated (first occurrence wins, insertion order preserved).
pub fn enrichCompactionXml(
    allocator: std.mem.Allocator,
    compacted_xml: []const u8,
    user_turns: []const UserTurn,
    read_files: []const ReadFileTurn,
    cwd: []const u8,
) ![]u8 {
    const MAX_USER_TURNS: usize = 100;
    const MAX_USER_CONTENT_CHARS: usize = 2000;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<compaction_context>\n");

    // ── user_history ──────────────────────────────────────────────
    try out.appendSlice(allocator, "  <user_history");
    if (user_turns.len > MAX_USER_TURNS) {
        try out.print(allocator, " truncated_by=\"{d}\"", .{user_turns.len - MAX_USER_TURNS});
    }
    try out.appendSlice(allocator, ">\n");
    const show_user_count = @min(user_turns.len, MAX_USER_TURNS);
    for (user_turns[0..show_user_count]) |t| {
        const truncated = if (t.content.len > MAX_USER_CONTENT_CHARS)
            t.content[0..MAX_USER_CONTENT_CHARS]
        else
            t.content;
        const escaped = try xml_escape(allocator, truncated);
        defer allocator.free(escaped);
        try out.print(
            allocator,
            "    <turn created_at=\"{s}\">{s}</turn>\n",
            .{ t.created_at, escaped },
        );
    }
    try out.appendSlice(allocator, "  </user_history>\n");

    // ── read_files (deduped; first-occurrence wins) ───────────────
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    try out.appendSlice(allocator, "  <read_files>\n");
    for (read_files) |rf| {
        if (seen.contains(rf.path)) continue;
        try seen.put(allocator, rf.path, {});
        const abs = try resolvePath(allocator, rf.path, cwd);
        defer allocator.free(abs);
        const escaped = try xml_escape(allocator, rf.path);
        defer allocator.free(escaped);
        try out.print(
            allocator,
            "    <path abs=\"{s}\">{s}</path>\n",
            .{ abs, escaped },
        );
    }
    try out.appendSlice(allocator, "  </read_files>\n");

    // ── summary (the original compactor output, wrapped in CDATA) ─
    try out.appendSlice(allocator, "  <summary><![CDATA[\n");
    try out.appendSlice(allocator, compacted_xml);
    try out.appendSlice(allocator, "\n]]></summary>\n");

    try out.appendSlice(allocator, "</compaction_context>\n");

    return out.toOwnedSlice(allocator);
}

fn resolvePath(allocator: std.mem.Allocator, path: []const u8, cwd: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        "CREATE TABLE llm_history (" ++
            "  id TEXT PRIMARY KEY," ++
            "  session_id TEXT NOT NULL," ++
            "  model TEXT," ++
            "  response_content TEXT," ++
            "  role TEXT," ++
            "  tool_name TEXT," ++
            "  is_input INTEGER DEFAULT 0," ++
            "  is_output INTEGER DEFAULT 0," ++
            "  is_feed_to_llm INTEGER DEFAULT 1," ++
            "  created_at TEXT DEFAULT (datetime('now'))" ++
            ")",
        &[_][]const u8{},
    );
    return .{ .db = db, .threaded = threaded };
}

fn seedRow(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    row: struct {
        id: []const u8,
        session_id: []const u8,
        role: []const u8,
        tool_name: []const u8,
        content: []const u8,
        is_input: []const u8,
        is_output: []const u8,
        created_at: []const u8,
    },
) !void {
    try db.exec(
        alloc,
        "INSERT INTO llm_history " ++
            "(id, session_id, model, response_content, role, tool_name, is_input, is_output, is_feed_to_llm, created_at) " ++
            "VALUES (?, ?, 'test-model', ?, ?, ?, ?, ?, 1, ?)",
        &.{ row.id, row.session_id, row.content, row.role, row.tool_name, row.is_input, row.is_output, row.created_at },
    );
}

test "parseReadFilePath extracts the path from a valid envelope" {
    const content = "<path>/home/user/foo.zig</path>\n<content>body</content>";
    try testing.expectEqualStrings("/home/user/foo.zig", parseReadFilePath(content).?);
}

test "parseReadFilePath returns null when the tag is missing" {
    const content = "<content>body without a path</content>";
    try testing.expect(parseReadFilePath(content) == null);
}

test "parseReadFilePath returns null when the close tag is missing" {
    const content = "<path>/home/user/foo.zig\n<content>body</content>";
    try testing.expect(parseReadFilePath(content) == null);
}

test "parseReadFilePath handles paths with spaces and unicode" {
    const content = "<path>/home/user/My Files/日本語.txt</path><content>x</content>";
    try testing.expectEqualStrings("/home/user/My Files/日本語.txt", parseReadFilePath(content).?);
}

test "fetchUserChatHistory returns only matching session's user rows with non-null content, in chrono order" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const alloc = testing.allocator;

    try seedRow(alloc, &s.db, .{
        .id = "u1",
        .session_id = "sess_a",
        .role = "user",
        .tool_name = "",
        .content = "first ask",
        .is_input = "1",
        .is_output = "0",
        .created_at = "2026-01-01 00:00:01",
    });
    try seedRow(alloc, &s.db, .{
        .id = "a1",
        .session_id = "sess_a",
        .role = "assistant",
        .tool_name = "",
        .content = "first reply",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:02",
    });
    try seedRow(alloc, &s.db, .{
        .id = "u2",
        .session_id = "sess_a",
        .role = "user",
        .tool_name = "",
        .content = "second ask",
        .is_input = "1",
        .is_output = "0",
        .created_at = "2026-01-01 00:00:03",
    });
    try seedRow(alloc, &s.db, .{
        .id = "u3",
        .session_id = "sess_a",
        .role = "user",
        .tool_name = "",
        .content = "",
        .is_input = "1",
        .is_output = "0",
        .created_at = "2026-01-01 00:00:04",
    });
    try seedRow(alloc, &s.db, .{
        .id = "u_x",
        .session_id = "sess_b",
        .role = "user",
        .tool_name = "",
        .content = "wrong session",
        .is_input = "1",
        .is_output = "0",
        .created_at = "2026-01-01 00:00:01",
    });

    var turns = try fetchUserChatHistory(alloc, &s.db, "sess_a");
    defer {
        for (turns.items) |t| t.deinit(alloc);
        turns.deinit(alloc);
    }

    try testing.expectEqual(@as(usize, 2), turns.items.len);
    try testing.expectEqualStrings("first ask", turns.items[0].content);
    try testing.expectEqualStrings("second ask", turns.items[1].content);
    try testing.expectEqualStrings("2026-01-01 00:00:01", turns.items[0].created_at);
    try testing.expectEqualStrings("2026-01-01 00:00:03", turns.items[1].created_at);
}

test "fetchReadFilePaths returns only matching session's read_file outputs, with parsed paths" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const alloc = testing.allocator;

    try seedRow(alloc, &s.db, .{
        .id = "rf1",
        .session_id = "sess_a",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<path>/home/user/foo.zig</path>\n<content>foo body</content>",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:01",
    });
    try seedRow(alloc, &s.db, .{
        .id = "rf2",
        .session_id = "sess_a",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<path>/home/user/bar.zig</path>\n<content>bar body</content>",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:02",
    });
    try seedRow(alloc, &s.db, .{
        .id = "rf3",
        .session_id = "sess_a",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<path>/home/user/ignored.zig</path>",
        .is_input = "1", // is_input not is_output -> filtered
        .is_output = "0",
        .created_at = "2026-01-01 00:00:03",
    });
    try seedRow(alloc, &s.db, .{
        .id = "rf_x",
        .session_id = "sess_b",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<path>/home/user/wrong.zig</path>",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:01",
    });
    try seedRow(alloc, &s.db, .{
        .id = "rf_malformed",
        .session_id = "sess_a",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<content>no path tag here</content>",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:04",
    });

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();
    var turns = try fetchReadFilePaths(alloc, &s.db, "sess_a", &lg);
    defer {
        for (turns.items) |t| t.deinit(alloc);
        turns.deinit(alloc);
    }

    // rf3 is filtered by is_output=0; rf_malformed is dropped with a warning
    // (not failed). 2 valid rows remain.
    try testing.expectEqual(@as(usize, 2), turns.items.len);
    try testing.expectEqualStrings("/home/user/foo.zig", turns.items[0].path);
    try testing.expectEqualStrings("/home/user/bar.zig", turns.items[1].path);
    try testing.expect(std.mem.indexOf(u8, turns.items[0].raw_content, "foo body") != null);
}

test "enrichCompactionXml with empty user history and empty read files returns the original compacted_xml wrapped in <summary>" {
    const alloc = testing.allocator;
    const result = try enrichCompactionXml(
        alloc,
        "GOAL: ship X\nNEXT: test",
        &.{},
        &.{},
        "/tmp",
    );
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<compaction_context>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<user_history>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<read_files>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<summary>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "GOAL: ship X") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<turn ") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<path ") == null);
}

test "enrichCompactionXml embeds user history and read files with the right content" {
    const alloc = testing.allocator;
    const user_turns = [_]UserTurn{
        .{ .content = "fix the bug", .created_at = "2026-01-01 00:00:01" },
        .{ .content = "now also write tests", .created_at = "2026-01-01 00:00:05" },
    };
    const read_files = [_]ReadFileTurn{
        .{
            .path = "/home/user/foo.zig",
            .raw_content = "<path>/home/user/foo.zig</path>",
            .created_at = "2026-01-01 00:00:02",
        },
    };
    const result = try enrichCompactionXml(
        alloc,
        "GOAL: ship X",
        &user_turns,
        &read_files,
        "/home/user",
    );
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<turn created_at=\"2026-01-01 00:00:01\">fix the bug</turn>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<turn created_at=\"2026-01-01 00:00:05\">now also write tests</turn>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<path abs=\"/home/user/foo.zig\">/home/user/foo.zig</path>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<summary>") != null);
}

test "enrichCompactionXml emits all 50 user turns when the cap is hit" {
    const alloc = testing.allocator;
    var turns: [50]UserTurn = undefined;
    var owned_strings: [50][]u8 = undefined;
    for (&turns, &owned_strings, 0..) |*t, *owned, i| {
        owned.* = try std.fmt.allocPrint(alloc, "turn {d}", .{i});
        t.* = .{
            .content = owned.*,
            .created_at = "2026-01-01 00:00:00",
        };
    }
    defer for (owned_strings) |s| alloc.free(s);

    const result = try enrichCompactionXml(
        alloc,
        "summary",
        &turns,
        &.{},
        "/tmp",
    );
    defer alloc.free(result);

    for (turns, 0..) |_, i| {
        const needle = try std.fmt.allocPrint(alloc, ">turn {d}</turn>", .{i});
        defer alloc.free(needle);
        try testing.expect(std.mem.indexOf(u8, result, needle) != null);
    }
}

test "enrichCompactionXml deduplicates read_file on the same path" {
    const alloc = testing.allocator;
    const read_files = [_]ReadFileTurn{
        .{ .path = "/home/user/foo.zig", .raw_content = "", .created_at = "t1" },
        .{ .path = "/home/user/bar.zig", .raw_content = "", .created_at = "t2" },
        .{ .path = "/home/user/foo.zig", .raw_content = "", .created_at = "t3" },
        .{ .path = "/home/user/baz.zig", .raw_content = "", .created_at = "t4" },
        .{ .path = "/home/user/bar.zig", .raw_content = "", .created_at = "t5" },
    };
    const result = try enrichCompactionXml(
        alloc,
        "summary",
        &.{},
        &read_files,
        "/home/user",
    );
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 3), countSubstring(result, "<path "));
    try testing.expect(std.mem.indexOf(u8, result, "<path abs=\"/home/user/foo.zig\">/home/user/foo.zig</path>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<path abs=\"/home/user/bar.zig\">/home/user/bar.zig</path>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<path abs=\"/home/user/baz.zig\">/home/user/baz.zig</path>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "truncated_by") == null);
}

fn countSubstring(hay: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, needle)) |pos| {
        count += 1;
        i = pos + needle.len;
    }
    return count;
}