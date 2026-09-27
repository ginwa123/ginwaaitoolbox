//! Storage layer for the `skills` table — the source of truth for skills.
//!
//! Before this module a skill *was* a file: `<skills-root>/<name>/SKILL.MD`,
//! and listing them meant walking a directory tree, opening and stat-ing
//! every file, then reading each one a second time to parse its YAML
//! frontmatter. This module replaces that with indexed SQL.
//!
//! Public surface (thin CRUD + one importer, no JSON, no HTTP):
//!   - `listSkills`  — every row, optionally filtered by scope/cwd
//!   - `getSkill`    — one row by name, with local-first resolution
//!   - `upsertSkill` — insert-or-update by the `(is_global, cwd, name)` key
//!   - `updateSkill` — partial update of description/tags/content
//!   - `deleteSkill` — remove one row, returns false when nothing matched
//!   - `importFromDisk` — `INSERT OR IGNORE` sweep of both skills roots
//!
//! Why disk is still involved at all
//! ────────────────────────────────
//! Two reasons, both deliberate:
//!   1. `importFromDisk` runs once at boot so an existing user — or a fresh
//!      clone of a repo that tracks `.nalar/skills/` — keeps every skill they
//!      had. It is `INSERT OR IGNORE`, so it never clobbers a row the agent
//!      has since edited.
//!   2. `add_skill` / `edit_skill` / `remove_skill` mirror their writes back
//!      to `SKILL.MD` (see skill_tools.zig) so the files stay reviewable and
//!      committable. The mirror is best-effort and log-and-continue: the row
//!      is the truth, the file is a convenience.
//!
//! The one sharp edge every write here must respect
//! ──────────────────────────────────────────────────
//! `SqliteBackend.exec` binds an **empty slice as SQL NULL** (see
//! `executeStatement` in ruangsql's Sqlite.zig:177-186). A `NOT NULL` column
//! then fails at runtime, not compile time. Migration 079's `content` column
//! and Migration 092's `config_json` both shipped that bug. So every free-text
//! column below is written as `COALESCE(?, '')` — never a bare `?`.
//!
//! The asymmetry nobody writes down: `query` / `queryRow` do **not** have that
//! guard (Sqlite.zig:586-591, :226-231), so `""` is NULL in a SELECT's WHERE
//! args but `''` in an INSERT's VALUES. Every entry point here rejects an
//! empty name explicitly rather than letting a WHERE silently match nothing.
//!
//! Plan: docs/plans/2026-09-28-skills-sqlite-table.md (W2)

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const helpers = @import("helpers");
const skill_files = @import("../modules/agent/tools/skills.zig");

const SqliteBackend = sqlite.SqliteBackend;

/// Separator for the `tags` column, mirroring `agent_memories.tags`.
pub const TAG_SEPARATOR = "||";

/// One row in `skills`. Every string field is allocator-owned; free a single
/// row with `freeSkillRow` or a slice with `freeSkillRows`.
pub const SkillRow = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    tags: []const u8,
    content: []const u8,
    is_global: bool,
    /// Canonical abspath when `is_global == false`; empty when `is_global`.
    cwd: []const u8,
    /// Where this row was imported from. Provenance only — it is never an
    /// LLM-facing handle, and it is `""` for rows the agent created.
    source_path: []const u8,

    pub fn deinit(self: *const SkillRow, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.tags);
        allocator.free(self.content);
        allocator.free(self.cwd);
        allocator.free(self.source_path);
    }
};

/// Arguments for `upsertSkill`. `id` is ignored on insert (always generated)
/// but returned so the caller can address the row afterwards.
pub const UpsertSkillInput = struct {
    name: []const u8,
    description: []const u8 = "",
    tags: []const u8 = "",
    content: []const u8 = "",
    is_global: bool = false,
    /// Overwritten with `""` when `is_global` is true — the invariant that
    /// makes a row addressable by `(is_global, cwd, name)`.
    cwd: []const u8 = "",
    source_path: []const u8 = "",
};

/// Arguments for `updateSkill`. A `null` field is left untouched.
pub const UpdateSkillInput = struct {
    name: []const u8,
    is_global: bool = false,
    cwd: []const u8 = "",
    description: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub const SkillDbError = error{
    /// The skill name was empty. Caught before any SQL: an empty bind becomes
    /// NULL in a WHERE clause and would silently match nothing.
    EmptyName,
    /// The UPDATE/DELETE matched no row.
    RowNotFound,
    InsertFailed,
    QueryFailed,
    OutOfMemory,
};

/// The column list every read shares, in the order `rowToSkill` expects.
const SELECT_COLUMNS = "id, name, description, tags, content, is_global, cwd, source_path";

/// SQLite's argv is `[]const []const u8` — there is no integer binding — so
/// every bool crosses the boundary as "0"/"1". Same idiom as design_model.zig.
fn boolToSql(allocator: std.mem.Allocator, v: bool) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{@intFromBool(v)});
}

fn rowToSkill(allocator: std.mem.Allocator, row: *const SqliteBackend.Row) !SkillRow {
    return .{
        .id = try allocator.dupe(u8, row.values[0]),
        .name = try allocator.dupe(u8, row.values[1]),
        .description = try allocator.dupe(u8, row.values[2]),
        .tags = try allocator.dupe(u8, row.values[3]),
        .content = try allocator.dupe(u8, row.values[4]),
        .is_global = std.mem.eql(u8, row.values[5], "1"),
        .cwd = try allocator.dupe(u8, row.values[6]),
        .source_path = try allocator.dupe(u8, row.values[7]),
    };
}

pub fn freeSkillRow(allocator: std.mem.Allocator, row: SkillRow) void {
    var mutable = row;
    mutable.deinit(allocator);
}

pub fn freeSkillRows(allocator: std.mem.Allocator, rows: []SkillRow) void {
    for (rows) |row| freeSkillRow(allocator, row);
    allocator.free(rows);
}

/// All skills, optionally narrowed.
///
/// `is_global == null` returns both branches (used by `GET /api/skills`, which
/// partitions the result itself). A concrete `is_global` returns only that
/// branch. When `is_global == false`, `cwd` selects the workspace; when it is
/// `null` every local row is returned, which is what the importer wants.
pub fn listSkills(
    allocator: std.mem.Allocator,
    db: *SqliteBackend,
    is_global: ?bool,
    cwd: ?[]const u8,
) SkillDbError![]SkillRow {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try sql.appendSlice(allocator, "SELECT ");
    try sql.appendSlice(allocator, SELECT_COLUMNS);
    try sql.appendSlice(allocator, " FROM skills");

    // Declared out here on purpose: a `defer` inside an if-block runs when the
    // BLOCK exits, which would free the string out from under the query below.
    const g_str = try boolToSql(allocator, is_global orelse false);
    defer allocator.free(g_str);

    if (is_global) |g| {
        if (!g) {
            try sql.appendSlice(allocator, " WHERE is_global = ? AND cwd = ?");
            try args.append(allocator, g_str);
            try args.append(allocator, cwd orelse "");
        } else {
            try sql.appendSlice(allocator, " WHERE is_global = ?");
            try args.append(allocator, g_str);
        }
    } else if (cwd) |c| {
        // Both branches for one workspace: the global root plus its local dir.
        try sql.appendSlice(allocator, " WHERE is_global = 1 OR (is_global = 0 AND cwd = ?)");
        try args.append(allocator, c);
    }

    try sql.appendSlice(allocator, " ORDER BY is_global DESC, name ASC");

    var rows = db.query(allocator, sql.items, args.items) catch return error.QueryFailed;
    defer rows.deinit();

    var out: std.ArrayList(SkillRow) = .empty;
    errdefer {
        for (out.items) |r| freeSkillRow(allocator, r);
        out.deinit(allocator);
    }

    while (rows.next() catch return error.QueryFailed) |row| {
        const skill = try rowToSkill(allocator, &row);
        row.deinit(allocator);
        try out.append(allocator, skill);
    }

    return out.toOwnedSlice(allocator);
}

/// One row by name.
///
/// `is_global == null` resolves **local-first, then global** — the historical
/// `use_skill` rule, and the reason the same name may legitimately exist in
/// both branches. The caller can tell which one it got from the row's own
/// `is_global`.
pub fn getSkill(
    allocator: std.mem.Allocator,
    db: *SqliteBackend,
    name: []const u8,
    is_global: ?bool,
    cwd: []const u8,
) SkillDbError!?SkillRow {
    if (name.len == 0) return error.EmptyName;

    if (is_global == null) {
        if (cwd.len > 0) {
            if (try getSkillInBranch(allocator, db, name, false, cwd)) |local| return local;
        }
        return try getSkillInBranch(allocator, db, name, true, "");
    }
    return try getSkillInBranch(allocator, db, name, is_global.?, cwd);
}

fn getSkillInBranch(
    allocator: std.mem.Allocator,
    db: *SqliteBackend,
    name: []const u8,
    is_global: bool,
    cwd: []const u8,
) SkillDbError!?SkillRow {
    const g_str = try boolToSql(allocator, is_global);
    defer allocator.free(g_str);

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "SELECT ");
    try sql.appendSlice(allocator, SELECT_COLUMNS);
    try sql.appendSlice(allocator, " FROM skills WHERE name = ? AND is_global = ?");
    if (!is_global) try sql.appendSlice(allocator, " AND cwd = ?");

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, name);
    try args.append(allocator, g_str);
    if (!is_global) try args.append(allocator, cwd);

    var rows = db.query(allocator, sql.items, args.items) catch return error.QueryFailed;
    defer rows.deinit();

    const row = (rows.next() catch return error.QueryFailed) orelse return null;
    defer row.deinit(allocator);
    return try rowToSkill(allocator, &row);
}

/// Insert or update by the `(is_global, cwd, name)` key, mirroring
/// `design_model.setDesignPage`: look the key up first, UPDATE when it is
/// already there so `created_at` survives, INSERT otherwise.
///
/// Returns the row id, newly generated or pre-existing.
pub fn upsertSkill(
    allocator: std.mem.Allocator,
    db: *SqliteBackend,
    input: UpsertSkillInput,
) SkillDbError![]u8 {
    if (input.name.len == 0) return error.EmptyName;

    const g_str = try boolToSql(allocator, input.is_global);
    defer allocator.free(g_str);
    const cwd = if (input.is_global) "" else input.cwd;

    if (try getSkill(allocator, db, input.name, input.is_global, cwd)) |existing| {
        defer freeSkillRow(allocator, existing);
        const updated = try updateSkill(allocator, db, .{
            .name = input.name,
            .is_global = input.is_global,
            .cwd = cwd,
            .description = input.description,
            .tags = input.tags,
            .content = input.content,
        });
        defer freeSkillRow(allocator, updated);
        return try allocator.dupe(u8, existing.id);
    }

    const id = try newSkillId(allocator);

    db.exec(allocator,
        \\INSERT INTO skills
        \\  (id, name, description, tags, content, is_global, cwd, source_path, created_at, updated_at)
        \\  VALUES (?, ?, COALESCE(?, ''), COALESCE(?, ''), COALESCE(?, ''), ?, COALESCE(?, ''), COALESCE(?, ''), datetime('now'), datetime('now'))
    , &.{ id, input.name, input.description, input.tags, input.content, g_str, cwd, input.source_path }) catch return error.InsertFailed;

    return id;
}

/// Partial update. `null` fields are left as they are; a 0-row UPDATE is
/// `error.RowNotFound` so the caller can 404 instead of pretending.
pub fn updateSkill(
    allocator: std.mem.Allocator,
    db: *SqliteBackend,
    input: UpdateSkillInput,
) SkillDbError!SkillRow {
    if (input.name.len == 0) return error.EmptyName;

    const before = (try getSkill(allocator, db, input.name, input.is_global, input.cwd)) orelse return error.RowNotFound;
    defer freeSkillRow(allocator, before);

    // Keep the value the caller did not supply, so every column is written
    // explicitly — a partially built SET list is where the COALESCE coverage
    // tends to get holes.
    const description = input.description orelse before.description;
    const tags = input.tags orelse before.tags;
    const content = input.content orelse before.content;

    const g_str = try boolToSql(allocator, input.is_global);
    defer allocator.free(g_str);

    db.exec(allocator,
        \\UPDATE skills
        \\   SET description = COALESCE(?, ''),
        \\       tags        = COALESCE(?, ''),
        \\       content     = COALESCE(?, ''),
        \\       updated_at  = datetime('now')
        \\ WHERE name = ? AND is_global = ?
    , &.{ description, tags, content, input.name, g_str }) catch return error.QueryFailed;

    if (!input.is_global) {
        db.exec(allocator,
            \\UPDATE skills SET cwd = COALESCE(?, '') WHERE name = ? AND is_global = 0
        , &.{ input.cwd, input.name }) catch return error.QueryFailed;
    }

    return (try getSkill(allocator, db, input.name, input.is_global, input.cwd)).?;
}

/// Delete one row. Returns false when the key matched nothing, which the HTTP
/// layer turns into a 404.
pub fn deleteSkill(
    allocator: std.mem.Allocator,
    db: *SqliteBackend,
    name: []const u8,
    is_global: bool,
    cwd: []const u8,
) SkillDbError!bool {
    if (name.len == 0) return error.EmptyName;

    const g_str = try boolToSql(allocator, is_global);
    defer allocator.free(g_str);

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "DELETE FROM skills WHERE name = ? AND is_global = ?");
    if (!is_global) try sql.appendSlice(allocator, " AND cwd = ?");

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, name);
    try args.append(allocator, g_str);
    if (!is_global) try args.append(allocator, cwd);

    // db.exec gives us no affected-row count, so read the row back first to
    // learn whether anything matched. The probe row owns its strings, so it
    // has to be freed either way.
    const probe = try getSkill(allocator, db, name, is_global, cwd);
    if (probe) |row| freeSkillRow(allocator, row);
    if (probe == null) return false;

    db.exec(allocator, sql.items, args.items) catch return error.QueryFailed;
    return true;
}

/// Sweep both skills roots into the table with `INSERT OR IGNORE`.
///
/// Called once at boot, after migrations run. `INSERT OR IGNORE` (not
/// `INSERT OR REPLACE`) is the whole point: a row the agent has since edited
/// must NOT be reverted by a restart. Re-importing a skill is therefore a
/// deliberate act — `remove_skill`, then let the next boot pick it up.
///
/// `cwd` may be null, in which case only the global root is swept.
pub fn importFromDisk(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *SqliteBackend,
    environment: ?*const std.process.Environ.Map,
    cwd: ?[]const u8,
) SkillDbError!void {
    // Global root.
    if (skill_files.get_global_skills_path_from_env(allocator, environment orelse return)) |global_path| {
        defer allocator.free(global_path);
        try importFromDir(allocator, io, db, global_path, true, "");
    }

    // Local root for this session's workspace.
    if (cwd) |dir| {
        const canonical = try canonicalCwd(allocator, io, dir);
        defer allocator.free(canonical);
        if (skill_files.get_local_skills_path_for_dir(allocator, canonical)) |local_path| {
            defer allocator.free(local_path);
            try importFromDir(allocator, io, db, local_path, false, canonical);
        }
    }
}

fn importFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *SqliteBackend,
    dir_path: []const u8,
    is_global: bool,
    cwd: []const u8,
) SkillDbError!void {
    const listed = skill_files.list_skills_from_dir_path(allocator, io, dir_path);
    defer skill_files.free_skills_list(allocator, listed);

    for (listed) |info| {
        // `path` is the SKILL.MD file. A skill whose frontmatter has no name
        // was never listed in the first place (parseYamlFrontmatter returns
        // null), so every entry here has one.
        const content = skill_files.load_skills_from_path(allocator, io, info.path);
        defer allocator.free(content);
        if (content.len == 0) continue;

        const tags = blk: {
            const fm = skill_files.parseYamlFrontmatter(allocator, content) orelse break :blk try allocator.dupe(u8, "");
            defer skill_files.freeParsedFrontmatter(allocator, fm);
            break :blk try allocator.dupe(u8, fm.tags);
        };
        defer allocator.free(tags);

        const id = try newSkillId(allocator);
        const g_str = try boolToSql(allocator, is_global);
        defer allocator.free(g_str);

        // INSERT OR IGNORE: never overwrite. That is what keeps an agent edit
        // from being silently reverted at the next boot.
        db.exec(allocator,
            \\INSERT OR IGNORE INTO skills
            \\  (id, name, description, tags, content, is_global, cwd, source_path, created_at, updated_at)
            \\  VALUES (?, ?, COALESCE(?, ''), COALESCE(?, ''), COALESCE(?, ''), ?, COALESCE(?, ''), COALESCE(?, ''), datetime('now'), datetime('now'))
        , &.{ id, info.name, info.description, tags, content, g_str, cwd, info.path }) catch continue;
        allocator.free(id);
    }
}

/// Resolve a workspace path to one canonical spelling.
///
/// The importer and the lookup must agree on this string or the same workspace
/// addresses two different rows and local skills become invisible — the exact
/// failure `tools_exec_skills.zig` warns about when it passes `ctx.cwd`
/// deliberately. Caller owns the returned slice.
///
/// `realPathFile` fails when the directory does not exist (a brand-new session
/// cwd, or a workspace item that was never materialised), so the fallback is
/// the path as given with a trailing separator removed: "/ws/" and "/ws" must
/// not produce two rows.
pub fn canonicalCwd(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator)) |resolved| {
        defer allocator.free(resolved);
        return allocator.dupe(u8, resolved);
    } else |_| {}
    const trimmed = std.mem.trimEnd(u8, path, "/");
    return allocator.dupe(u8, if (trimmed.len == 0) path else trimmed);
}

fn newSkillId(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "skill_{d}", .{helpers.unixTimestampNanos()});
}

/// Normalise a caller-supplied tag list to the stored `'||'` form.
///
/// Accepts `"a, b"`, `"[a, b]"`, and already-joined `"a||b"`, and returns a
/// freshly allocated canonical string. Empty in, empty out — the empty-slice
/// → SQL NULL trap is handled at the write site by `COALESCE(?, '')`.
pub fn normalizeTags(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        trimmed = trimmed[1 .. trimmed.len - 1];
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |part| {
        // Accept the already-joined form as an alias for a separator so
        // round-tripping through the tool does not accumulate "a||b" junk.
        var inner = std.mem.tokenizeScalar(u8, part, '|');
        while (inner.next()) |piece| {
            const t = std.mem.trim(u8, piece, " \t");
            if (t.len == 0) continue;
            if (out.items.len > 0) try out.appendSlice(allocator, TAG_SEPARATOR);
            try out.appendSlice(allocator, t);
        }
    }

    return out.toOwnedSlice(allocator);
}

// ─── tests ──────────────────────────────────────────────────────────────
//
// The importer gets its own coverage here rather than in a functional test
// because it is a DB-layer function over a real directory: it needs a real
// `SKILL.MD` on disk and a real environment map, both of which are trivial
// to set up in-process and impossible to arrange around the python harness
// (which boots the server before the test body runs, so a "write the file,
// then boot" ordering test cannot exist there).

const testing = std.testing;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: SqliteBackend,
    threaded: std.Io.Threaded,

    fn deinit(self: *TestCtx) void {
        // `threaded` owns the Io the backend needs, so it must outlive `db`.
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try migration.Migration094CreateSkills.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Write `<home>/.config/nalar/skills/<name>/SKILL.MD` with the given
/// frontmatter, and return the tmp home. Caller frees the returned slice.
fn writeGlobalSkill(alloc: std.mem.Allocator, io: std.Io, home: []const u8, name: []const u8, frontmatter: []const u8) !void {
    const dir = try std.fs.path.join(alloc, &.{ home, ".config", "nalar", "skills", name });
    defer alloc.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const file_path = try std.fs.path.join(alloc, &.{ dir, "SKILL.MD" });
    defer alloc.free(file_path);
    const f = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    defer std.Io.File.close(f, io);
    try std.Io.File.writeStreamingAll(f, io, frontmatter);
}

fn tmpHome(alloc: std.mem.Allocator, io: std.Io, tag: []const u8) ![]u8 {
    const home = try std.fmt.allocPrint(alloc, "/tmp/nalar-skills-db-{s}", .{tag});
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    return home;
}

test "importFromDisk pulls global skills in, with their tags" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const home = try tmpHome(alloc, io, "import-basic");
    defer alloc.free(home);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    try writeGlobalSkill(alloc, io, home, "imported", "---\nname: imported\ndescription: \"From disk\"\ntags: [workflow, api]\n---\n\n# Body\n");

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", home);

    try importFromDisk(alloc, io, &ctx.db, &env, null);

    const row = (try getSkill(alloc, &ctx.db, "imported", true, "")).?;
    defer freeSkillRow(alloc, row);
    try testing.expectEqualStrings("imported", row.name);
    try testing.expectEqualStrings("From disk", row.description);
    // The frontmatter `tags:` line reaches the column — the reason tags was
    // worth adding at all.
    try testing.expectEqualStrings("workflow||api", row.tags);
    try testing.expect(row.is_global);
    try testing.expectEqualStrings("", row.cwd);
    // source_path records where it came from, which is what the mirror and
    // the UI's Path: line read.
    try testing.expect(row.source_path.len > 0);
}

test "importFromDisk is INSERT OR IGNORE — an edited row is never reverted" {
    // The whole point of INSERT OR IGNORE over INSERT OR REPLACE: an agent
    // edit must survive a restart.
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const home = try tmpHome(alloc, io, "import-no-clobber");
    defer alloc.free(home);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    try writeGlobalSkill(alloc, io, home, "keep-mine", "---\nname: keep-mine\ndescription: \"stale disk copy\"\n---\n\nOLD BODY\n");

    // The agent edits the row first.
    const edited_id = try upsertSkill(alloc, &ctx.db, .{
        .name = "keep-mine",
        .description = "agent's newer version",
        .content = "NEW BODY",
        .is_global = true,
    });
    defer alloc.free(edited_id);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", home);

    // "Restart" — the importer runs again.
    try importFromDisk(alloc, io, &ctx.db, &env, null);

    const row = (try getSkill(alloc, &ctx.db, "keep-mine", true, "")).?;
    defer freeSkillRow(alloc, row);
    try testing.expectEqualStrings("agent's newer version", row.description);
    try testing.expectEqualStrings("NEW BODY", row.content);
}

test "importFromDisk scopes local skills to the workspace they came from" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const ws = try tmpHome(alloc, io, "import-local");
    defer alloc.free(ws);
    defer std.Io.Dir.cwd().deleteTree(io, ws) catch {};

    const local_dir = try std.fs.path.join(alloc, &.{ ws, ".nalar", "skills", "ws-local" });
    defer alloc.free(local_dir);
    try std.Io.Dir.cwd().createDirPath(io, local_dir);
    const lf = try std.fs.path.join(alloc, &.{ local_dir, "SKILL.MD" });
    defer alloc.free(lf);
    {
        const f = try std.Io.Dir.cwd().createFile(io, lf, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(
            f,
            io,
            "---\nname: ws-local\ndescription: \"Local only\"\n---\n\n# Body\n",
        );
    }

    // No HOME set, so nothing global can be imported — the only row should be
    // the local one, keyed to this workspace.
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();

    try importFromDisk(alloc, io, &ctx.db, &env, ws);

    const canonical = try canonicalCwd(alloc, io, ws);
    defer alloc.free(canonical);

    const row = (try getSkill(alloc, &ctx.db, "ws-local", false, canonical)).?;
    defer freeSkillRow(alloc, row);
    try testing.expect(!row.is_global);
    try testing.expectEqualStrings(canonical, row.cwd);

    // The same name is not visible from an unrelated workspace.
    const other = try canonicalCwd(alloc, io, "/tmp");
    defer alloc.free(other);
    try testing.expect((try getSkill(alloc, &ctx.db, "ws-local", false, other)) == null);
}

test "getSkill resolves local-first, then global" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const ws = try canonicalCwd(alloc, io, "/tmp");
    defer alloc.free(ws);

    const global_id = try upsertSkill(alloc, &ctx.db, .{
        .name = "twin",
        .description = "the global one",
        .is_global = true,
    });
    defer alloc.free(global_id);

    const local_id = try upsertSkill(alloc, &ctx.db, .{
        .name = "twin",
        .description = "the local one",
        .is_global = false,
        .cwd = ws,
    });
    defer alloc.free(local_id);

    // is_global = null → local wins.
    const resolved = (try getSkill(alloc, &ctx.db, "twin", null, ws)).?;
    defer freeSkillRow(alloc, resolved);
    try testing.expect(!resolved.is_global);
    try testing.expectEqualStrings("the local one", resolved.description);

    // Pinning the branch is honoured.
    const global = (try getSkill(alloc, &ctx.db, "twin", true, ws)).?;
    defer freeSkillRow(alloc, global);
    try testing.expect(global.is_global);
    try testing.expectEqualStrings("the global one", global.description);
}

test "getSkill with an empty name is EmptyName, not a silent NULL miss" {
    // query/queryRow do NOT collapse "" to NULL the way exec does, so an empty
    // bind here would simply match nothing and look like "not found".
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    try testing.expectError(error.EmptyName, getSkill(alloc, &ctx.db, "", true, ""));
    try testing.expectError(error.EmptyName, upsertSkill(alloc, &ctx.db, .{ .name = "" }));
    try testing.expectError(error.EmptyName, deleteSkill(alloc, &ctx.db, "", true, ""));
}

test "canonicalCwd agrees with itself across path spellings" {
    // The bug this prevents: importer and lookup computing different strings
    // for one workspace, which makes local skills invisible.
    const alloc = testing.allocator;
    const io = testing.io;

    const a = try canonicalCwd(alloc, io, "/tmp");
    defer alloc.free(a);
    const b = try canonicalCwd(alloc, io, "/tmp/");
    defer alloc.free(b);
    const c = try canonicalCwd(alloc, io, "/tmp/./");
    defer alloc.free(c);

    try testing.expectEqualStrings(a, b);
    try testing.expectEqualStrings(a, c);
}

test "upsertSkill forces cwd = '' for a global row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    // A caller that passes a cwd with is_global = true must not be able to
    // create a global row that is also workspace-scoped.
    const id = try upsertSkill(alloc, &ctx.db, .{
        .name = "inv",
        .description = "d",
        .is_global = true,
        .cwd = "/some/workspace",
    });
    defer alloc.free(id);

    const row = (try getSkill(alloc, &ctx.db, "inv", true, "")).?;
    defer freeSkillRow(alloc, row);
    try testing.expectEqualStrings("", row.cwd);
}

test "updateSkill on a missing row is RowNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    try testing.expectError(
        error.RowNotFound,
        updateSkill(alloc, &ctx.db, .{ .name = "ghost", .description = "d" }),
    );
}
