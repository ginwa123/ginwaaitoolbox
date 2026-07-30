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
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
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