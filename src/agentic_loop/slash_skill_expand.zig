//! Send-time expansion of slash-command skill tokens in chat messages.
//!
//! The frontend renders `/skill-<name>` (and bare `/<name>`) chips in the
//! composer, but the wire body that reaches `POST /api/llm/session` is
//! plain text — the token is just characters in `queue_message`. This
//! module resolves those tokens server-side, in `session_create.useCase`,
//! before the run starts: each known token loads its workspace skill
//! through the canonical `use_skill` loader and the bodies ride along as
//! a trailing `<slash_skills>` block, so the model sees the instructions
//! without spending a `use_skill` round trip. A loaded skill is also
//! recorded in `session_skills`, the same persistence the agent-tool path
//! gets from `handle_tool`, so later turns keep the context.
//!
//! Unknown tokens stay literal in the text. There is no 404 and no toast
//! in v1 — a follow-up may surface them — so a typo degrades to the model
//! reading the raw `/name` characters, never to a dropped send.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const skills_store = pabrikcore.skills_store;
const skill_tools = pabrikcore.skill_tools;
const testing = std.testing;
const migration = @import("../migrations/migration.zig");

/// A token character is exactly the skill-name alphabet minus the dot
/// rules: `isValidSkillName` owns the final verdict (leading/trailing
/// dots, length), the scanner just finds candidate extents.
fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
}

/// Map one raw `/`-token to the skill name it means, or null when the
/// token is not a skill reference. `/skill-<rest>` strips the prefix;
/// a bare `/<tok>` keeps it. A lone `/skill` is the prefix with nothing
/// after it, not a skill called `skill`, so it maps to null.
fn nameFromToken(tok: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, tok, "skill")) return null;
    const name = if (std.mem.startsWith(u8, tok, "skill-")) tok["skill-".len..] else tok;
    if (name.len == 0) return null;
    if (!skills_store.isValidSkillName(name)) return null;
    return name;
}

/// Distinct skill names referenced by `/`-tokens in `message`, in first-
/// appearance order. A token starts at a `/` at offset 0 or after
/// whitespace; anything else (`http://x`, `a/b`) is a path or URL, not a
/// command. Pure string scan — no DB, safe to unit-test in isolation.
///
/// All returned strings are allocator-owned; free each element, then the
/// slice itself.
pub fn extractSkillTokens(allocator: std.mem.Allocator, message: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |t| allocator.free(t);
        out.deinit(allocator);
    }
    var i: usize = 0;
    while (i < message.len) {
        if (message[i] == '/' and (i == 0 or std.ascii.isWhitespace(message[i - 1]))) {
            var j = i + 1;
            while (j < message.len and isTokenChar(message[j])) : (j += 1) {}
            if (j > i + 1) {
                if (nameFromToken(message[i + 1 .. j])) |name| {
                    var seen = false;
                    for (out.items) |e| {
                        if (std.mem.eql(u8, e, name)) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) try out.append(allocator, try allocator.dupe(u8, name));
                }
                i = j;
                continue;
            }
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// The outcome of `expandSlashSkills`. `message` is the send text: the
/// original verbatim when nothing loaded, otherwise the original plus a
/// trailing `<slash_skills>` block. `unknown` names the tokens that
/// resolved to no skill, left literal in the text. Both are
/// allocator-owned; call `deinit`.
pub const ExpandResult = struct {
    message: []const u8,
    unknown: [][]const u8,
    loaded_count: usize,

    pub fn deinit(self: *ExpandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.unknown.len > 0) {
            for (self.unknown) |u| allocator.free(u);
            allocator.free(self.unknown);
        }
        self.* = undefined;
    }
};

/// Resolve every `/`-token in `message` against the calling session's
/// workspace and rewrite the text with the loaded bodies appended.
/// Best-effort by construction: a token that loads to nothing lands in
/// `unknown` (left literal), a token whose load errors is skipped with a
/// warning, and only hard allocation failures propagate.
pub fn expandSlashSkills(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    message: []const u8,
) !ExpandResult {
    const tokens = try extractSkillTokens(allocator, message);
    defer {
        for (tokens) |t| allocator.free(t);
        allocator.free(tokens);
    }
    if (tokens.len == 0) {
        return .{
            .message = try allocator.dupe(u8, message),
            .unknown = &.{},
            .loaded_count = 0,
        };
    }

    // `names` borrows from `tokens`; `contents` is duped out of each
    // loader response before that response is freed.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var contents: std.ArrayList([]const u8) = .empty;
    defer {
        for (contents.items) |c| allocator.free(c);
        contents.deinit(allocator);
    }
    var unknown: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (unknown.items) |u| allocator.free(u);
        unknown.deinit(allocator);
    }

    for (tokens) |name| {
        const maybe_body = loadOne(allocator, io, db, session_id, name) catch |err| {
            std.log.warn("slash_skill_expand: load '{s}' failed, leaving token literal: {s}", .{ name, @errorName(err) });
            continue;
        };
        const body = maybe_body orelse {
            try unknown.append(allocator, try allocator.dupe(u8, name));
            continue;
        };
        // Loop-body scope: runs at the end of each iteration, after the
        // dupe below has taken its own copy for the block.
        defer allocator.free(body);
        try names.append(allocator, name);
        try contents.append(allocator, try allocator.dupe(u8, body));
        persistSkill(allocator, db, session_id, name, body);
    }

    if (names.items.len == 0) {
        return .{
            .message = try allocator.dupe(u8, message),
            .unknown = try unknown.toOwnedSlice(allocator),
            .loaded_count = 0,
        };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, message);
    try out.appendSlice(allocator, "\n\n<slash_skills>\n");
    for (names.items, contents.items) |name, body| {
        try out.appendSlice(allocator, "<skill name=\"");
        try out.appendSlice(allocator, name);
        try out.appendSlice(allocator, "\">");
        try out.appendSlice(allocator, body);
        try out.appendSlice(allocator, "</skill>\n");
    }
    try out.appendSlice(allocator, "</slash_skills>");

    return .{
        .message = try out.toOwnedSlice(allocator),
        .unknown = try unknown.toOwnedSlice(allocator),
        .loaded_count = names.items.len,
    };
}

/// Load one skill through the canonical `use_skill` loader. Returns the
/// owned body when the skill exists and carries instructions, null when
/// the token names nothing loadable (not-found, scope refusal, or an
/// empty body — `SqliteBackend.exec` binds zero-length slices as NULL,
/// so an empty body could never persist anyway).
///
/// A body containing `</skill` is refused: it would break out of the
/// `<skill>` envelope the rewritten message wraps it in, and the safe
/// move is to leave the token literal rather than ship a malformed
/// block the model would misparse.
fn loadOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    name: []const u8,
) !?[]const u8 {
    const inner = try skill_tools.execute_use_skill_to_string(allocator, io, db, session_id, .{ .name = name });
    defer allocator.free(inner);
    const parsed = std.json.parseFromSlice(
        skill_tools.UseSkillOutput,
        allocator,
        inner,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        std.log.warn("slash_skill_expand: unparseable loader output for '{s}': {s}", .{ name, @errorName(err) });
        return null;
    };
    defer parsed.deinit();
    if (!parsed.value.loaded or parsed.value.content.len == 0) return null;
    if (std.mem.indexOf(u8, parsed.value.content, "</skill") != null) {
        std.log.warn("slash_skill_expand: skill '{s}' body contains a closing tag, leaving token literal", .{name});
        return null;
    }
    return try allocator.dupe(u8, parsed.value.content);
}

/// Record a loaded skill in `session_skills` so later turns keep the
/// context without re-expanding. This is the single `INSERT OR REPLACE`
/// from `llm_history.saveSkill`, inlined because no `Logger` threads
/// through this send-time path — keep the SQL identical to that function
/// if either changes. Failures are warn-and-continue: the body still
/// rides in the rewritten message, so persistence is a bonus, not the
/// delivery mechanism.
fn persistSkill(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    name: []const u8,
    content: []const u8,
) void {
    if (session_id.len == 0 or content.len == 0) return;
    db.exec(
        allocator,
        "INSERT OR REPLACE INTO session_skills (session_id, skill_name, content, loaded_at_nano) VALUES (?, ?, ?, strftime('%s', 'now'))",
        &[_][]const u8{ session_id, name, content },
    ) catch |err| {
        std.log.warn("slash_skill_expand: persist '{s}' failed (non-fatal): {s}", .{ name, @errorName(err) });
    };
}

// =====================================================================
// Tests — behaviour only: tokenize the string, expand against a real
// in-memory workspace, read back real rows. No source greps.
// =====================================================================

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Real skills tables (Migration 102) plus the three tables
/// `workspace_scope.resolveWorkspaceId` reads and the `session_skills`
/// table the expansion persists into, so a test hands over a
/// `caller_session_id` and gets a real workspace back.
fn setupSlashDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT DEFAULT 'active', cwd TEXT)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES
        \\  ('i1', 'ws_1', 'kanban', 'A', '/proj/a', 1)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('s1', 'T1', 'i1')
    , &.{});
    try migration.Migration102CreateSkills.up(&db, alloc);
    try db.exec(alloc,
        \\CREATE TABLE IF NOT EXISTS session_skills (session_id TEXT NOT NULL, skill_name TEXT NOT NULL, content TEXT NOT NULL, loaded_at_nano INTEGER DEFAULT (strftime('%s', 'now')), PRIMARY KEY (session_id, skill_name))
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn seedSlashSkill(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    name: []const u8,
    content: []const u8,
) !void {
    const row = try skills_store.upsertSkill(alloc, db, .{
        .workspace_id = "ws_1",
        .name = name,
        .description = "test skill",
        .content = content,
    });
    skills_store.freeSkillRow(alloc, row);
}

fn freeTokenList(alloc: std.mem.Allocator, tokens: [][]const u8) void {
    for (tokens) |t| alloc.free(t);
    alloc.free(tokens);
}

fn sessionSkillBody(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8, name: []const u8) !?[]u8 {
    var q = try db.query(alloc, "SELECT content FROM session_skills WHERE session_id = ? AND skill_name = ?", &.{ session_id, name });
    defer q.deinit();
    const row = try q.next() orelse return null;
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "slash_skill_expand tokenizes both the skill- prefix and the bare shape" {
    const alloc = testing.allocator;
    const tokens = try extractSkillTokens(alloc, "help with /skill-pdf and /notes please");
    defer freeTokenList(alloc, tokens);
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqualStrings("pdf", tokens[0]);
    try testing.expectEqualStrings("notes", tokens[1]);
}

test "slash_skill_expand gates: urls, paths and a lone /skill yield zero tokens" {
    const alloc = testing.allocator;
    const from_url = try extractSkillTokens(alloc, "see http://x/y for details");
    defer freeTokenList(alloc, from_url);
    try testing.expectEqual(@as(usize, 0), from_url.len);

    const from_path = try extractSkillTokens(alloc, "open a/b tomorrow");
    defer freeTokenList(alloc, from_path);
    try testing.expectEqual(@as(usize, 0), from_path.len);

    const lone = try extractSkillTokens(alloc, "run /skill now");
    defer freeTokenList(alloc, lone);
    try testing.expectEqual(@as(usize, 0), lone.len);

    const dash_only = try extractSkillTokens(alloc, "run /skill- now");
    defer freeTokenList(alloc, dash_only);
    try testing.expectEqual(@as(usize, 0), dash_only.len);
}

test "slash_skill_expand dash handling: /skill-co strips, /code-review keeps" {
    const alloc = testing.allocator;
    const stripped = try extractSkillTokens(alloc, "use /skill-co here");
    defer freeTokenList(alloc, stripped);
    try testing.expectEqual(@as(usize, 1), stripped.len);
    try testing.expectEqualStrings("co", stripped[0]);

    const kept = try extractSkillTokens(alloc, "use /code-review here");
    defer freeTokenList(alloc, kept);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("code-review", kept[0]);
}

test "slash_skill_expand dedupes repeats across both shapes" {
    const alloc = testing.allocator;
    const tokens = try extractSkillTokens(alloc, "/pdf then /skill-pdf then /pdf again");
    defer freeTokenList(alloc, tokens);
    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expectEqualStrings("pdf", tokens[0]);
}

test "slash_skill_expand expansion loads seeded skills, persists rows, appends the block" {
    const alloc = testing.allocator;
    var ctx = try setupSlashDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSlashSkill(alloc, &ctx.db, "pdf", "## When to Use\n\nConvert PDFs.");
    try seedSlashSkill(alloc, &ctx.db, "notes", "## When to Use\n\nKeep notes.");

    const message = "help with /skill-pdf and /notes";
    var result = try expandSlashSkills(alloc, testing.io, &ctx.db, "s1", message);
    defer result.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), result.loaded_count);
    try testing.expectEqual(@as(usize, 0), result.unknown.len);
    // Original text survives verbatim at the head of the rewrite.
    try testing.expect(std.mem.startsWith(u8, result.message, message));
    try testing.expect(std.mem.indexOf(u8, result.message, "<slash_skills>") != null);
    try testing.expect(std.mem.indexOf(u8, result.message, "<skill name=\"pdf\">## When to Use\n\nConvert PDFs.</skill>") != null);
    try testing.expect(std.mem.indexOf(u8, result.message, "<skill name=\"notes\">## When to Use\n\nKeep notes.</skill>") != null);
    try testing.expect(std.mem.indexOf(u8, result.message, "</slash_skills>") != null);

    const pdf_body = try sessionSkillBody(alloc, &ctx.db, "s1", "pdf");
    defer if (pdf_body) |b| alloc.free(b);
    try testing.expect(pdf_body != null);
    try testing.expect(std.mem.indexOf(u8, pdf_body.?, "Convert PDFs.") != null);

    const notes_body = try sessionSkillBody(alloc, &ctx.db, "s1", "notes");
    defer if (notes_body) |b| alloc.free(b);
    try testing.expect(notes_body != null);
}

test "slash_skill_expand unknown name stays literal and is reported" {
    const alloc = testing.allocator;
    var ctx = try setupSlashDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSlashSkill(alloc, &ctx.db, "pdf", "body");

    const message = "use /ghost now";
    var result = try expandSlashSkills(alloc, testing.io, &ctx.db, "s1", message);
    defer result.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), result.loaded_count);
    try testing.expectEqualStrings(message, result.message);
    try testing.expectEqual(@as(usize, 1), result.unknown.len);
    try testing.expectEqualStrings("ghost", result.unknown[0]);
}

test "slash_skill_expand message with no tokens comes back byte-identical" {
    const alloc = testing.allocator;
    var ctx = try setupSlashDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const message = "plain hello, no commands here";
    var result = try expandSlashSkills(alloc, testing.io, &ctx.db, "s1", message);
    defer result.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), result.loaded_count);
    try testing.expectEqualStrings(message, result.message);
}

test "slash_skill_expand body containing a closing tag is left out of the block" {
    const alloc = testing.allocator;
    var ctx = try setupSlashDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSlashSkill(alloc, &ctx.db, "evil", "open </skill> close");

    const message = "use /evil now";
    var result = try expandSlashSkills(alloc, testing.io, &ctx.db, "s1", message);
    defer result.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), result.loaded_count);
    try testing.expectEqualStrings(message, result.message);
    try testing.expect(std.mem.indexOf(u8, result.message, "<slash_skills>") == null);
}
