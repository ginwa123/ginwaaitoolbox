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
const llm_history = @import("../llm_history.zig");

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

/// One row from the `session_activity` per-session log (Migration 073).
/// Embedded into the compacted envelope so the next iteration of the
/// agent sees what the previous agent was thinking/doing at the tail
/// of the now-compacted-away messages — without these rows, the next
/// iteration has no signal about the recent internal-state context.
pub const RecentActivity = struct {
    description: []const u8,
    created_at: []const u8,

    pub fn deinit(self: RecentActivity, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
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

/// Fetch the most recent `limit` rows from `session_activity` for
/// `session_id`, in chronological order (oldest first — same direction
/// the agent reads them as a timeline).
///
/// `session_activity` is an append-only log written by the
/// `update_activity` tool (Migration 073). It records what the agent
/// was thinking/doing at each user message boundary, and the next
/// iteration of the agent (after compaction) needs the tail of this
/// log to recover the recent internal-state context that the
/// compacted-away messages no longer carry.
pub fn fetchRecentActivities(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    limit: u32,
) !std.ArrayList(RecentActivity) {
    var turns: std.ArrayList(RecentActivity) = .empty;
    errdefer {
        for (turns.items) |t| t.deinit(allocator);
        turns.deinit(allocator);
    }

    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    defer allocator.free(limit_str);

    // Two-step approach (vs. a single DESC+reverse): the production
    // path is a small-N recent tail, so doing the LIMIT first then
    // reversing in Zig is both correct and lets us reuse the existing
    // `idx_session_activity_session_created` index.
    var rows = try db.query(
        allocator,
        "SELECT description, created_at FROM session_activity " ++
            "WHERE session_id = ? " ++
            "ORDER BY created_at DESC, id DESC LIMIT ?",
        &.{ session_id, limit_str },
    );
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const desc_dup = try allocator.dupe(u8, row.values[0]);
        const created_at_dup = try allocator.dupe(u8, row.values[1]);
        try turns.append(allocator, .{
            .description = desc_dup,
            .created_at = created_at_dup,
        });
    }

    // Reverse in-place to chronological (oldest first).
    std.mem.reverse(RecentActivity, turns.items);
    return turns;
}

/// Fetch all session skills loaded for `session_id` via the `session_skills`
/// table. Each row in that table is what the `add_skill` tool wrote during
/// the session; embedding them into the compacted envelope gives the
/// post-compaction agent continuity on guidance that may not appear in
/// the compactor's summary (skill files are large, free-form reference
/// material that the compactor is unlikely to summarize verbatim).
///
/// Returns an empty slice when `session_id` is empty OR the session has
/// no skills — both `getSessionSkills` callers see the same shape,
/// so the caller can elide the empty-session check.
///
/// Caller owns the returned slice AND each skill's `skill_name` /
/// `content` fields. Cleanup pattern:
///   defer {
///       for (skills) |s| s.deinit(allocator);
///       allocator.free(skills);
///   }
pub fn fetchSessionSkills(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]llm_history.SkillInfo {
    return llm_history.getSessionSkills(allocator, db, session_id);
}

/// Embed the user history, read_file paths, recent session activities,
/// and loaded session skills into the compacted XML. Returns a new
/// `[]u8` allocated from `allocator`; caller owns it. The original
/// `compacted_xml` is left untouched (the helper dups content during
/// the embed).
///
/// Hard caps:
///   - 100 user turns, 2000 chars per turn
///   - 50 session skills, 10_000 chars per skill content
///   - 20 recent activities (caller is expected to slice
///     `recent_activities` to the desired limit before calling)
///   - read_file paths are deduped (first occurrence wins, insertion order
///     preserved); no explicit count cap on read_files
pub fn enrichCompactionXml(
    allocator: std.mem.Allocator,
    compacted_xml: []const u8,
    user_turns: []const UserTurn,
    read_files: []const ReadFileTurn,
    recent_activities: []const RecentActivity,
    session_skills: []const llm_history.SkillInfo,
    cwd: []const u8,
) ![]u8 {
    const MAX_USER_TURNS: usize = 100;
    const MAX_USER_CONTENT_CHARS: usize = 2000;
    const MAX_SKILLS: usize = 50;
    const MAX_SKILL_CONTENT_CHARS: usize = 10_000;

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

    // ── recent_activities (omitted entirely when empty) ───────────
    // Mirrors the user_history / read_files pattern: the section is
    // useful for "what was the agent doing/thinking at the tail of the
    // compacted-away messages" (Migration 073 / PR #226 — the agent's
    // own activity log, NOT a metadata row for the compaction itself).
    if (recent_activities.len > 0) {
        try out.appendSlice(allocator, "  <recent_activities");
        try out.print(allocator, " count=\"{d}\"", .{recent_activities.len});
        try out.appendSlice(allocator, ">\n");
        for (recent_activities) |a| {
            const escaped = try xml_escape(allocator, a.description);
            defer allocator.free(escaped);
            try out.print(
                allocator,
                "    <activity created_at=\"{s}\">{s}</activity>\n",
                .{ a.created_at, escaped },
            );
        }
        try out.appendSlice(allocator, "  </recent_activities>\n");
    }

    // ── session_skills (loaded-once guidance material) ────────────
    // Skills are typically large, free-form reference material that the
    // compactor is unlikely to summarize verbatim. Embedding them here
    // keeps the post-compaction agent operating under the same guidance
    // the pre-compaction agent had. Content is wrapped in CDATA so the
    // raw `<`, `>`, `&` inside skill files can never break the envelope.
    try out.appendSlice(allocator, "  <session_skills");
    if (session_skills.len > MAX_SKILLS) {
        try out.print(allocator, " truncated_by=\"{d}\"", .{session_skills.len - MAX_SKILLS});
    }
    try out.appendSlice(allocator, ">\n");
    const show_skill_count = @min(session_skills.len, MAX_SKILLS);
    for (session_skills[0..show_skill_count]) |skill| {
        const name_escaped = try xml_escape(allocator, skill.skill_name);
        defer allocator.free(name_escaped);
        try out.print(allocator, "    <skill name=\"{s}\"", .{name_escaped});
        if (skill.loaded_at) |ts| {
            try out.print(allocator, " loaded_at=\"{d}\"", .{ts});
        }
        try out.appendSlice(allocator, ">\n");
        const truncated = if (skill.content.len > MAX_SKILL_CONTENT_CHARS)
            skill.content[0..MAX_SKILL_CONTENT_CHARS]
        else
            skill.content;
        // CDATA escape: XML CDATA sections cannot contain the literal
        // sequence `]]>`. To embed a skill body that contains `]]>`, split
        // it into adjacent CDATA sections: close the current section with
        // `]]>` (the two `]` already in the data), then re-open with
        // `<![CDATA[` and emit the literal `>` as content of the new
        // section. On the wire this looks like `...]]><![CDATA[>...`.
        try out.appendSlice(allocator, "      <content><![CDATA[\n");
        if (std.mem.indexOf(u8, truncated, "]]>") == null) {
            try out.appendSlice(allocator, truncated);
        } else {
            var rest = truncated;
            while (std.mem.indexOf(u8, rest, "]]>")) |idx| {
                try out.appendSlice(allocator, rest[0..idx]); // up to but NOT incl "]]"
                try out.appendSlice(allocator, "]]><![CDATA[>"); // close current, reopen, literal '>'
                rest = rest[idx + 3 ..];
            }
            try out.appendSlice(allocator, rest);
        }
        try out.appendSlice(allocator, "\n      ]]></content>\n");
        try out.appendSlice(allocator, "    </skill>\n");
    }
    try out.appendSlice(allocator, "  </session_skills>\n");

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
    try db.exec(alloc,
        "CREATE TABLE session_activity (" ++
            "  id TEXT PRIMARY KEY," ++
            "  session_id TEXT NOT NULL," ++
            "  description TEXT NOT NULL," ++
            "  created_at DATETIME DEFAULT CURRENT_TIMESTAMP" ++
            ")",
        &[_][]const u8{},
    );
    try db.exec(alloc,
        "CREATE TABLE session_skills (" ++
            "  session_id TEXT NOT NULL," ++
            "  skill_name TEXT NOT NULL," ++
            "  content TEXT NOT NULL," ++
            "  loaded_at INTEGER" ++
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

test "fetchRecentActivities returns the most recent N rows in chrono order" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const alloc = testing.allocator;

    // Seed 5 rows for sess_a in NON-chrono order; the helper must
    // return them sorted by created_at ASC (oldest first).
    const sess_a_rows = [_]struct {
        id: []const u8,
        description: []const u8,
        created_at: []const u8,
    }{
        .{ .id = "a3", .description = "wiring it in", .created_at = "2026-01-01 00:00:03" },
        .{ .id = "a1", .description = "planning the migration", .created_at = "2026-01-01 00:00:01" },
        .{ .id = "a5", .description = "shipping it", .created_at = "2026-01-01 00:00:05" },
        .{ .id = "a2", .description = "writing the test", .created_at = "2026-01-01 00:00:02" },
        .{ .id = "a4", .description = "reviewing", .created_at = "2026-01-01 00:00:04" },
    };
    for (sess_a_rows) |r| {
        try s.db.exec(alloc,
            "INSERT INTO session_activity (id, session_id, description, created_at) " ++
                "VALUES (?, ?, ?, ?)",
            &.{ r.id, "sess_a", r.description, r.created_at });
    }
    // Other-session row — must be filtered out by the WHERE clause.
    try s.db.exec(alloc,
        "INSERT INTO session_activity (id, session_id, description, created_at) " ++
            "VALUES (?, ?, ?, ?)",
        &.{ "a_x", "sess_b", "wrong session", "2026-01-01 00:00:01" });

    var turns = try fetchRecentActivities(alloc, &s.db, "sess_a", 3);
    defer {
        for (turns.items) |t| t.deinit(alloc);
        turns.deinit(alloc);
    }

    // limit=3 → the SQL fetches the 3 newest (DESC) then the helper
    // reverses in-place to chronological (oldest first). The 3 newest
    // rows by created_at are a5, a4, a3; after reverse that's
    // a3, a4, a5 → wiring it in, reviewing, shipping it.
    try testing.expectEqual(@as(usize, 3), turns.items.len);
    try testing.expectEqualStrings("wiring it in", turns.items[0].description);
    try testing.expectEqualStrings("reviewing", turns.items[1].description);
    try testing.expectEqualStrings("shipping it", turns.items[2].description);

    // limit larger than the row count returns all sess_a rows
    // (sess_b's row is filtered out by WHERE) in chrono order.
    var all = try fetchRecentActivities(alloc, &s.db, "sess_a", 100);
    defer {
        for (all.items) |t| t.deinit(alloc);
        all.deinit(alloc);
    }
    try testing.expectEqual(@as(usize, 5), all.items.len);
    try testing.expectEqualStrings("planning the migration", all.items[0].description);
    try testing.expectEqualStrings("shipping it", all.items[4].description);
}

test "fetchRecentActivities returns an empty list when the session has no activity" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const alloc = testing.allocator;

    var turns = try fetchRecentActivities(alloc, &s.db, "sess_no_activity", 20);
    defer turns.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), turns.items.len);
}

test "enrichCompactionXml with empty user history and empty read files returns the original compacted_xml wrapped in <summary>" {
    const alloc = testing.allocator;
    const result = try enrichCompactionXml(
        alloc,
        "GOAL: ship X\nNEXT: test",
        &.{},
        &.{},
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
        &.{},
        &.{},
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
        &.{},
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
        &.{},
        &.{},
        "/home/user",
    );
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 3), countSubstring(result, "<path "));
    try testing.expect(std.mem.indexOf(u8, result, "<path abs=\"/home/user/foo.zig\">/home/user/foo.zig</path>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<path abs=\"/home/user/bar.zig\">/home/user/bar.zig</path>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<path abs=\"/home/user/baz.zig\">/home/user/baz.zig</path>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "truncated_by") == null);
}

test "enrichCompactionXml embeds recent_activities inside <compaction_context>" {
    // Regression: when recent_activities are non-empty, the enrich
    // helper MUST emit a `<recent_activities>` section alongside
    // <user_history> + <read_files>, with one <activity> per row,
    // each row's description XML-escaped.
    const alloc = testing.allocator;
    const recent_activities = [_]RecentActivity{
        .{ .description = "[2026-08-13 10:00] planning the migration", .created_at = "2026-08-13 10:00:00" },
        .{ .description = "[2026-08-13 10:01] <bold>writing</bold> the test", .created_at = "2026-08-13 10:01:00" },
    };
    const result = try enrichCompactionXml(
        alloc,
        "GOAL: ship X",
        &.{},
        &.{},
        &recent_activities,
        &.{},
        "/tmp",
    );
    defer alloc.free(result);

    // Section header is present, and the section lives INSIDE
    // <compaction_context> (not at top level).
    try testing.expect(std.mem.indexOf(u8, result, "<recent_activities") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</recent_activities>") != null);
    // Activities live BETWEEN <recent_activities> and </recent_activities>.
    const header_pos = std.mem.indexOf(u8, result, "<recent_activities").?;
    // Both descriptions are embedded.
    try testing.expect(std.mem.indexOfPos(u8, result, header_pos, "planning the migration") != null);
    try testing.expect(std.mem.indexOfPos(u8, result, header_pos, "<bold>writing</bold> the test") == null); // XML-escaped
    try testing.expect(std.mem.indexOfPos(u8, result, header_pos, "&lt;bold&gt;writing&lt;/bold&gt; the test") != null);
    // Activities appear in chrono order (oldest first) — the same order
    // they were passed in (caller is responsible for sorting, matching
    // the existing user_history/read_files ordering rule).
    const planning_pos = std.mem.indexOfPos(u8, result, header_pos, "planning the migration").?;
    const writing_pos = std.mem.indexOfPos(u8, result, header_pos, "writing").?;
    try testing.expect(planning_pos < writing_pos);
    // The section is INSIDE <compaction_context>, not at top level.
    const ctx_open = std.mem.indexOf(u8, result, "<compaction_context>").?;
    try testing.expect(ctx_open < header_pos);
}

test "enrichCompactionXml omits <recent_activities> when the slice is empty" {
    // Mirrors the existing "omit when empty" pattern for user_history
    // and read_files sections: emitting an empty <recent_activities/>
    // would add no information and pollute the envelope.
    const alloc = testing.allocator;
    const result = try enrichCompactionXml(
        alloc,
        "GOAL: ship X",
        &.{},
        &.{},
        &.{},
        &.{},
        "/tmp",
    );
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<recent_activities") == null);
}

// ─── session_skills tests ───────────────────────────────────────────────────

fn seedSkill(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    skill_name: []const u8,
    content: []const u8,
    loaded_at: ?i64,
) !void {
    if (loaded_at) |ts| {
        const ts_str = try std.fmt.allocPrint(alloc, "{d}", .{ts});
        defer alloc.free(ts_str);
        try db.exec(
            alloc,
            "INSERT INTO session_skills (session_id, skill_name, content, loaded_at) " ++
                "VALUES (?, ?, ?, ?)",
            &.{ session_id, skill_name, content, ts_str },
        );
    } else {
        try db.exec(
            alloc,
            "INSERT INTO session_skills (session_id, skill_name, content, loaded_at) " ++
                "VALUES (?, ?, ?, NULL)",
            &.{ session_id, skill_name, content },
        );
    }
}

test "fetchSessionSkills returns only matching session's skills in insertion order" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try seedSkill(alloc, &s.db, "sess_a", "alpha", "first skill body", 100);
    try seedSkill(alloc, &s.db, "sess_a", "beta", "second skill body", 200);
    try seedSkill(alloc, &s.db, "sess_a", "gamma", "third skill body", null);
    try seedSkill(alloc, &s.db, "sess_b", "delta", "different session", 300);

    const skills = try fetchSessionSkills(alloc, &s.db, "sess_a");
    defer {
        for (skills) |s2| s2.deinit(alloc);
        alloc.free(skills);
    }

    try testing.expectEqual(@as(usize, 3), skills.len);
    try testing.expectEqualStrings("alpha", skills[0].skill_name);
    try testing.expectEqualStrings("first skill body", skills[0].content);
    try testing.expectEqual(@as(i64, 100), skills[0].loaded_at.?);
    try testing.expectEqualStrings("beta", skills[1].skill_name);
    try testing.expectEqualStrings("gamma", skills[2].skill_name);
    try testing.expect(skills[2].loaded_at == null);
}

test "fetchSessionSkills returns empty slice when session has no skills" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    const skills = try fetchSessionSkills(alloc, &s.db, "sess_empty");
    defer {
        for (skills) |sk| sk.deinit(alloc);
        alloc.free(skills);
    }
    try testing.expectEqual(@as(usize, 0), skills.len);
}

test "fetchSessionSkills returns empty slice when session_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    const skills = try fetchSessionSkills(alloc, &s.db, "");
    defer {
        for (skills) |sk| sk.deinit(alloc);
        alloc.free(skills);
    }
    try testing.expectEqual(@as(usize, 0), skills.len);
}

test "enrichCompactionXml embeds session_skills with name, loaded_at, and CDATA-wrapped content" {
    const alloc = testing.allocator;
    const skills = [_]llm_history.SkillInfo{
        .{
            .skill_name = try alloc.dupe(u8, "code-review"),
            .content = try alloc.dupe(u8, "always check the test before merging"),
            .loaded_at = 1700000000,
        },
        .{
            .skill_name = try alloc.dupe(u8, "no-yolo"),
            .content = try alloc.dupe(u8, "never skip writing tests"),
            .loaded_at = null,
        },
    };
    defer for (skills) |s2| s2.deinit(alloc);

    const result = try enrichCompactionXml(
        alloc,
        "summary",
        &.{},
        &.{},
        &.{},
        &skills,
        "/tmp",
    );
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<session_skills>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<skill name=\"code-review\" loaded_at=\"1700000000\">") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<content><![CDATA[\nalways check the test before merging\n      ]]></content>") != null);
    // Skill without loaded_at omits the attribute entirely.
    try testing.expect(std.mem.indexOf(u8, result, "<skill name=\"no-yolo\">") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<content><![CDATA[\nnever skip writing tests\n      ]]></content>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</session_skills>") != null);
}

test "enrichCompactionXml escapes XML special chars in skill name" {
    const alloc = testing.allocator;
    const skills = [_]llm_history.SkillInfo{
        .{
            .skill_name = try alloc.dupe(u8, "fix<this> & \"that\""),
            .content = try alloc.dupe(u8, "body"),
            .loaded_at = null,
        },
    };
    defer for (skills) |s2| s2.deinit(alloc);

    const result = try enrichCompactionXml(
        alloc,
        "summary",
        &.{},
        &.{},
        &.{},
        &skills,
        "/tmp",
    );
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<skill name=\"fix&lt;this&gt; &amp; &quot;that&quot;\">") != null);
}

test "enrichCompactionXml splits skill content CDATA on ']]>' boundary" {
    const alloc = testing.allocator;
    const skills = [_]llm_history.SkillInfo{
        .{
            .skill_name = try alloc.dupe(u8, "weird-content"),
            .content = try alloc.dupe(u8, "before ]]> middle ]]> after"),
            .loaded_at = null,
        },
    };
    defer for (skills) |s2| s2.deinit(alloc);

    const result = try enrichCompactionXml(
        alloc,
        "summary",
        &.{},
        &.{},
        &.{},
        &skills,
        "/tmp",
    );
    defer alloc.free(result);

    // The two ]]> sequences must be split into adjacent CDATA sections
    // so the envelope is still well-formed XML, with the literal '>'
    // reappearing between them.
    try testing.expect(std.mem.indexOf(u8, result, "before ]]><![CDATA[> middle ]]><![CDATA[> after") != null);
}

test "enrichCompactionXml adds truncated_by when session_skills exceeds the 50-cap" {
    const alloc = testing.allocator;
    var skills: [51]llm_history.SkillInfo = undefined;
    var owned_names: [51][]u8 = undefined;
    var owned_contents: [51][]u8 = undefined;
    for (&skills, &owned_names, &owned_contents, 0..) |*s2, *owned_name, *owned_content, i| {
        owned_name.* = try std.fmt.allocPrint(alloc, "skill-{d}", .{i});
        owned_content.* = try alloc.dupe(u8, "body");
        s2.* = .{
            .skill_name = owned_name.*,
            .content = owned_content.*,
            .loaded_at = null,
        };
    }
    // Only free the underlying slices (owned_names/owned_contents) — the
    // SkillInfo structs themselves are stack-allocated and SkillInfo.deinit
    // would free the same memory again. skills[i].skill_name and
    // skills[i].content are aliases for owned_names[i] / owned_contents[i].
    defer for (owned_names) |n| alloc.free(n);
    defer for (owned_contents) |c| alloc.free(c);

    const result = try enrichCompactionXml(
        alloc,
        "summary",
        &.{},
        &.{},
        &.{},
        &skills,
        "/tmp",
    );
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<session_skills truncated_by=\"1\">") != null);
    // Only the first 50 are embedded.
    try testing.expect(std.mem.indexOf(u8, result, "<skill name=\"skill-0\">") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<skill name=\"skill-49\">") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<skill name=\"skill-50\">") == null);
}

test "enrichCompactionXml positions session_skills between read_files and summary" {
    const alloc = testing.allocator;
    const read_files = [_]ReadFileTurn{
        .{ .path = "/home/user/foo.zig", .raw_content = "", .created_at = "t1" },
    };
    const skills = [_]llm_history.SkillInfo{
        .{
            .skill_name = try alloc.dupe(u8, "guide"),
            .content = try alloc.dupe(u8, "how to behave"),
            .loaded_at = null,
        },
    };
    defer for (skills) |s2| s2.deinit(alloc);

    const result = try enrichCompactionXml(
        alloc,
        "summary",
        &.{},
        &read_files,
        &.{},
        &skills,
        "/tmp",
    );
    defer alloc.free(result);

    // Order: <compaction_context> <user_history> </user_history>
    // <read_files> </read_files> <session_skills> </session_skills>
    // <summary> </summary> </compaction_context>
    const idx_user_history = std.mem.indexOf(u8, result, "<user_history>").?;
    const idx_read_files = std.mem.indexOf(u8, result, "<read_files>").?;
    const idx_session_skills = std.mem.indexOf(u8, result, "<session_skills>").?;
    const idx_summary = std.mem.indexOf(u8, result, "<summary>").?;
    try testing.expect(idx_user_history < idx_read_files);
    try testing.expect(idx_read_files < idx_session_skills);
    try testing.expect(idx_session_skills < idx_summary);
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