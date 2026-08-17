//! Helpers for building the compaction-message payload sent to the
//! CompactionAgent and enriching the compactor's output into the
//! `<compaction_context>...</compaction_context>` envelope.
//!
//! This file is the consolidation of two former modules:
//!   - `compaction.zig::buildCompactMessagePrompt` (originally extracted
//!     into `compaction.zig` by the 2026-08-06-encapsulate-compaction-prompt
//!     refactor, then moved here by 2026-08-14-consolidate-compaction-message)
//!     — the pure-data prompt builder that walks the conversation history
//!     and emits the handoff-package text the CompactionAgent receives as
//!     its user message.
//!   - `compaction_context.zig` (deleted 2026-08-14) — the DB-backed helpers
//!     that fetch user chat history, read_file paths, recent session
//!     activity, and loaded session skills, plus the `enrichCompactionXml`
//!     helper that wraps the bare compactor output in the
//!     `<compaction_context>` envelope.
//!
//! Both halves share the same conceptual job ("what does the
//! compaction-message payload look like?") and used to share an import
//! chain in `workflow_commpact_message.zig` (the orchestrator), so
//! consolidating them keeps the file layout aligned with the call
//! graph. The LLM-call orchestration (`callCompactAgent` + its
//! `CallCompactAgentInput`) now lives in `workflow_commpact_message.zig`
//! alongside `maybeCompactMessagesNew` — that file owns the
//! `agent.Agent` lifecycle and the streaming response, which are
//! unrelated to message shape but live with the orchestrator that
//! wires them.
//!
//! Public surface (re-exported by `workflow.zig` and therefore reachable
//! as `nalarcore.ai_mod.ai_workflow.agentic_loop.<name>`):
//!   - `buildCompactMessagePrompt` (prompt builder)
//!   - `parseReadFilePath`, `fetchUserChatHistory`, `fetchReadFilePaths`,
//!     `fetchRecentActivities`, `fetchSessionSkills`, `enrichCompactionXml`
//!     (envelope helpers)
//!   - `UserTurn`, `ReadFileTurn`, `RecentActivity` (row types)

const std = @import("std");
const nalarcore = @import("nalarcore");

const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const Logger = logger_mod.Logger;
const xml_escape = nalarcore.helpers.xml_escape;
const agent = nalarcore.agent;
const llm_history = @import("llm_history.zig");
const migration = @import("../../../migrations/migration.zig");

// ─── Compaction-context types ────────────────────────────────────────────────
//
// One user-turn row from `llm_history`. Used to embed the full user
// history into the compacted envelope so the next iteration of the
// agent sees the original ask + every refinement, not just the
// compactor's summary.
pub const UserTurn = struct {
    content: []const u8,
    created_at: []const u8,

    pub fn deinit(self: UserTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        allocator.free(self.created_at);
    }
};

// One row from the `session_activity` per-session log (Migration 073).
// Embedded into the compacted envelope so the next iteration of the
// agent sees what the previous agent was thinking/doing at the tail
// of the now-compacted-away messages — without these rows, the next
// iteration has no signal about the recent internal-state context.
pub const RecentActivity = struct {
    description: []const u8,
    created_at: []const u8,

    pub fn deinit(self: RecentActivity, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        allocator.free(self.created_at);
    }
};

// One read_file tool-result row from `llm_history`. `path` is the
// extracted value from the `<path>...</path>` tag in the XML envelope.
// `raw_content` is kept for debugging and for tests that assert on the
// full XML; production callers only consume `path`.
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

// ─── Compaction-context helpers ──────────────────────────────────────────────

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
        "SELECT response_content, created_at_nano AS created_at " ++
            "FROM llm_history " ++
            "WHERE session_id = ? " ++
            "  AND role = 'user' " ++
            "  AND response_content IS NOT NULL " ++
            "  AND response_content != '' " ++
            "ORDER BY created_at_nano ASC, id ASC",
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
        "SELECT response_content, created_at_nano AS created_at " ++
            "FROM llm_history " ++
            "WHERE session_id = ? " ++
            "  AND tool_name = 'read_file' " ++
            "  AND is_output = 1 " ++
            "ORDER BY created_at_nano ASC, id ASC",
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

// ─── buildCompactMessagePrompt ──────────────────────────────────────────────
//
// Build the compaction handoff prompt that gets sent to the CompactionAgent.
//
// Walks `messages[1..last_idx]` (excluding the system prompt at index 0 AND
// the current/pending message at the last index) and renders each message
// into a labeled row:
// - `content` becomes `[<role>]: <content>`
// - each `tool_calls[i]` becomes `[tool_call]: <name>(<arguments>)`
//
// The rows are joined with `\n` and embedded into a fixed handoff-package
// template alongside `original_system_prompt`. The resulting string is what
// the CompactionAgent sees as its user message.
//
// **Caller owns the returned string** and must free it with `allocator.free`.
// Returns `null` on allocation failure (after logging via `logger`); the
// caller is then expected to short-circuit the compaction flow.
//
// **Precondition:** `messages.items.len >= 2` (the caller — `callCompactAgent`
// — enforces this). With only one message, `last_idx = 0` and the history
// slice `messages.items[1..0]` is empty; the prompt is still produced but
// has no conversation rows.
pub fn buildCompactMessagePrompt(
    allocator: std.mem.Allocator,
    logger: ?*logger_mod.Logger,
    messages: std.ArrayList(agent.AgentMessage),
    original_system_prompt: []const u8,
) ?[]const u8 {
    const last_idx = messages.items.len - 1;

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    for (messages.items[1..last_idx]) |msg| {
        if (msg.content) |c| {
            const role_str = msg.role.to_str();
            const labeled = std.fmt.allocPrint(allocator, "[{s}]: {s}", .{ role_str, c }) catch |err| {
                logger.?.errFmt("[COMPACTION] Failed to label message content: {s}", .{@errorName(err)});
                return null;
            };
            // If append fails, free our just-allocated `labeled` before
            // returning null — otherwise it's a one-byte-equivalent leak
            // that the leak detector will catch under `testing.allocator`.
            parts.append(allocator, labeled) catch |err| {
                logger.?.errFmt("[COMPACTION] Failed to collect message content: {s}", .{@errorName(err)});
                allocator.free(labeled);
                return null;
            };
        }
        if (msg.tool_calls) |tool_calls| {
            for (tool_calls) |tc| {
                const tc_str = std.fmt.allocPrint(allocator, "[tool_call]: {s}({s})", .{
                    tc.function.name,
                    tc.function.arguments,
                }) catch continue;
                // Same leak guard as the content branch above.
                parts.append(allocator, tc_str) catch {
                    allocator.free(tc_str);
                    continue;
                };
            }
        }
    }

    const history_str = std.mem.join(allocator, "\n", parts.items) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to join history: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(history_str);

    // `std.mem.join` copies each segment into a fresh allocation, so the
    // originals (`parts.items`) are now orphan references and must be freed
    // — caught by `testing.allocator.detectLeaks()` otherwise.
    defer for (parts.items) |part| allocator.free(part);

    const compact_message = std.fmt.allocPrint(allocator,
        \\You are preparing a handoff package for a fresh AI coding agent.
        \\The next agent has ZERO context. It cannot ask questions. It must act immediately.
        \\
        \\Rules:
        \\- Be surgical. No narrative, no filler, no summaries of conversation.
        \\- Every line must help the next agent take action or avoid a mistake.
        \\- If something was tried and failed, say exactly why — not just "it failed".
        \\- If a file was modified, say what changed and why, not just the filename.
        \\- The NEXT ACTION must be a single concrete step, not a vague goal.
        \\- If there are blockers, say what they are and what was tried to unblock them.
        \\
        \\Output exactly this structure, no extra sections:
        \\
        \\GOAL:
        \\(The original user objective, one or two sentences max)
        \\
        \\CURRENT STATE:
        \\- cwd:
        \\- repo:
        \\- branch:
        \\- worktree:
        \\- build status: (passing / failing / unknown)
        \\- test status: (passing / failing / unknown)
        \\
        \\TECH STACK:
        \\(Languages, frameworks, build tools — only what is relevant to the task)
        \\
        \\FILES MODIFIED:
        \\(path — what changed and why, one line per file)
        \\
        \\KEY DISCOVERIES:
        \\(Non-obvious things learned about the codebase, APIs, or constraints)
        \\
        \\FAILED ATTEMPTS:
        \\(What was tried, what happened, root cause if known)
        \\
        \\OPEN ISSUES:
        \\(Unresolved problems blocking or threatening progress)
        \\
        \\ASSUMPTIONS MADE:
        \\(Decisions taken without explicit user confirmation)
        \\
        \\NEXT ACTION:
        \\(Exactly one concrete step. File to edit, command to run, function to write.)
        \\
        \\AFTER THAT:
        \\(The 2-3 steps that follow NEXT ACTION, in order)
        \\
        \\DO NOT:
        \\(Pitfalls, wrong paths, things that look right but aren't)
        \\
        \\---
        \\ORIGINAL SYSTEM PROMPT (context only — constraints, tools, scope the
        \\original agent operated under. Do NOT summarize this section itself;
        \\use it only to inform DO NOT / ASSUMPTIONS MADE / FAILED ATTEMPTS above):
        \\{s}
        \\
        \\---
        \\CONVERSATION HISTORY:
        \\{s}
    , .{ original_system_prompt, history_str }) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to format compact message: {s}", .{@errorName(err)});
        return null;
    };

    return compact_message;
}

// ─── Tests ─────────────────────────────────────────────────────────────────
//
// Convention: walk ALL migrations from scratch so the schema under test is
// GUARANTEED to match production. No hand-rolled CREATE TABLE.
// (Project memory `llm-history-test-use-migrations-module.md` — reviewer's
// recurring "use migrations module" feedback pattern.)
//
// Plan: docs/superpowers/plans/2026-08-14-consolidate-compaction-message-helpers.md
// Task: task_1786912658593_0

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

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

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
            "(id, session_id, model, response_content, role, tool_name, is_input, is_output, is_feed_to_llm, created_at_nano) " ++
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
            "INSERT INTO session_skills (session_id, skill_name, content, loaded_at_nano) " ++
                "VALUES (?, ?, ?, ?)",
            &.{ session_id, skill_name, content, ts_str },
        );
    } else {
        try db.exec(
            alloc,
            "INSERT INTO session_skills (session_id, skill_name, content, loaded_at_nano) " ++
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

// ─── buildCompactMessagePrompt tests ────────────────────────────────────────

const AgentMessage = agent.AgentMessage;
const ToolCall = agent.ToolCall;

/// Build a 5-message list mimicking the production workflow shape:
///   [0] system prompt, [1] user, [2] assistant, [3] user, [4] assistant (current/pending).
/// Index 0 is treated as the "original system prompt"; index 4 is the "current"
/// message excluded from history (per `messages.items[1..last_idx]` semantics in
/// `buildCompactMessagePrompt`). Caller owns and must free via `freeMessages`.
fn buildSampleMessages(allocator: std.mem.Allocator) !std.ArrayList(AgentMessage) {
    var list: std.ArrayList(AgentMessage) = .empty;
    try list.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, "ORIG_SYS") });
    try list.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "Hi") });
    try list.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "Hello") });
    try list.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "Help me") });
    try list.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "Sure") });
    return list;
}

fn freeMessages(allocator: std.mem.Allocator, messages: *std.ArrayList(AgentMessage)) void {
    for (messages.items) |*m| m.deinit(allocator);
    var owned = messages.*;
    owned.deinit(allocator);
}

test "buildCompactMessagePrompt: happy path embeds system prompt and labeled history" {
    const alloc = testing.allocator;
    var messages = try buildSampleMessages(alloc);
    defer freeMessages(alloc, &messages);

    const result = buildCompactMessagePrompt(alloc, null, messages, "ORIG_SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    try testing.expect(std.mem.indexOf(u8, s, "ORIGINAL SYSTEM PROMPT") != null);
    try testing.expect(std.mem.indexOf(u8, s, "ORIG_SYS") != null);
    try testing.expect(std.mem.indexOf(u8, s, "CONVERSATION HISTORY") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: Hi") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: Hello") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: Help me") != null);
}

test "buildCompactMessagePrompt: first AND last messages are excluded from history" {
    const alloc = testing.allocator;
    var messages = try buildSampleMessages(alloc);
    defer freeMessages(alloc, &messages);

    const result = buildCompactMessagePrompt(alloc, null, messages, "ORIG_SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    // Index 0 content ("ORIG_SYS") is passed in as `original_system_prompt`,
    // so it should NOT appear as a labeled `[system]: ...` row in history.
    try testing.expect(std.mem.indexOf(u8, s, "[system]: ORIG_SYS") == null);
    // Index 4 ("Sure") is the LAST message — excluded by `messages.items[1..last_idx]`.
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: Sure") == null);
    // Middle messages 1..3 SHOULD appear.
    try testing.expect(std.mem.indexOf(u8, s, "Help me") != null);
}

test "buildCompactMessagePrompt: tool_calls formatted as [tool_call]: name(args)" {
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);

    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "SYS") });
    // messages[1] has BOTH content and tool_calls — both should land in history
    try messages.append(alloc, .{
        .role = .assistant,
        .content = try alloc.dupe(u8, "calling search"),
    });
    const tc1 = try alloc.alloc(ToolCall, 2);
    tc1[0] = .{
        .id = "",
        .type = "function",
        .function = .{
            .name = try alloc.dupe(u8, "search_web"),
            .arguments = try alloc.dupe(u8, "{\"q\":\"zig\"}"),
        },
    };
    tc1[1] = .{
        .id = "",
        .type = "function",
        .function = .{
            .name = try alloc.dupe(u8, "read_file"),
            .arguments = try alloc.dupe(u8, "{\"path\":\"/tmp/x.zig\"}"),
        },
    };
    messages.items[1].tool_calls = tc1;
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "go") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "last") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: calling search") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[tool_call]: search_web({\"q\":\"zig\"})") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[tool_call]: read_file({\"path\":\"/tmp/x.zig\"})") != null);
    // The last message's content must not appear.
    try testing.expect(std.mem.indexOf(u8, s, "calling read") == null);
}

test "buildCompactMessagePrompt: message with content=null and no tool_calls is skipped silently" {
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "SYS") });
    // messages[1] has BOTH fields null — must not produce a labeled row.
    try messages.append(alloc, .{ .role = .user, .content = null });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "ok") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "done") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    // No labeled row for the null-content message — neither `[user]: ` alone
    // nor `[user]: \n` should appear.
    try testing.expect(std.mem.indexOf(u8, s, "[user]:\n") == null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: \n") == null);
    // The assistant message and the "ok" text must appear.
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: ok") != null);
    // The last message ("done") is excluded.
    try testing.expect(std.mem.indexOf(u8, s, "[user]: done") == null);
}

test "buildCompactMessagePrompt: empty middle history (only system + last) returns valid prompt" {
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "SYS") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "last") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    // The prompt header still renders; CONVERSATION HISTORY section exists
    // but has no labeled rows (empty `history_str` from `join`).
    try testing.expect(std.mem.indexOf(u8, s, "ORIGINAL SYSTEM PROMPT") != null);
    try testing.expect(std.mem.indexOf(u8, s, "CONVERSATION HISTORY:") != null);
    // The last message's content must NOT appear in the history.
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: last") == null);
}

test "buildCompactMessagePrompt: history rows are joined with newline separator (order preserved)" {
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    // 6 messages → last_idx=5, history slice = messages[1..5] = 4 rows.
    // The 6th message ("D") is the LAST (current/pending) and must be excluded.
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "SYS") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "A") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "B") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "C") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "D") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "E_LAST") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    // Adjacent rows must be separated by a single `\n` (the `join` separator).
    try testing.expect(std.mem.indexOf(u8, s, "[user]: A\n[assistant]: B") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: B\n[user]: C") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: C\n[assistant]: D") != null);
    // The last message ("E_LAST") must NOT appear (it's the excluded tail).
    try testing.expect(std.mem.indexOf(u8, s, "[user]: E_LAST") == null);
}

test "buildCompactMessagePrompt: returns a heap-allocated, caller-owned string" {
    const alloc = testing.allocator;
    var messages = try buildSampleMessages(alloc);
    defer freeMessages(alloc, &messages);

    const result = buildCompactMessagePrompt(alloc, null, messages, "ORIG_SYS");
    try testing.expect(result != null);
    // Allocate, mutate, then free — leak detector (testing.allocator) enforces
    // ownership. If the impl ever returns a non-heap pointer, this `free`
    // would either crash (free on const slice) or trigger a leak report.
    const ptr = result.?;
    _ = ptr.len;
    alloc.free(ptr);
}

test "buildCompactMessagePrompt: empty-messages list (only system + 1 user) excludes last" {
    // Confirms `messages.items[1..last_idx]` semantics: with two messages
    // (system + last), the slice is empty, no labeled rows produced, but
    // the rest of the prompt renders fine.
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "ONLY_SYS") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "ONLY_USER") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "ONLY_SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    try testing.expect(std.mem.indexOf(u8, s, "ONLY_SYS") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: ONLY_USER") == null);
}
