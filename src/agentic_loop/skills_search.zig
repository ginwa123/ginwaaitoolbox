//! Matching + rendering for the `search_skills` agent tool.
//!
//! This is the skills-side twin of `progressive_catalog.zig`: the same
//! shape (collect rows → match a query → page → render JSON), the same
//! `progressive_regex` engine, the same `pattern_mode` / `pattern_warning`
//! / `total` / `next_offset` / `hint` contract the model already reads from
//! `search_tool`. It lives HERE rather than in
//! `src/modules/agent/tools/skill_tools.zig` because a `modules → agentic_loop`
//! import would close a cycle through the `pabrikcore` root — the same reason
//! `progressive_tools.zig` keeps its AgentTool literals pure.
//!
//! The tool schema + `SearchSkillsInput` live in `skill_tools.zig`; the raw
//! per-tier listing (`skill_tools.listAllSkills`) is shared with the HTTP
//! `/skills` handler and is deliberately NOT renamed — that endpoint still
//! answers "everything installed", which is a different question from this
//! tool's "what matches my query".
//!
//! Tiers: `global` (`~/.config/pabrik/skills/`) and `local` (`<cwd>/.pabrik/skills/`).
//! `workspace` (SQLite) is deliberately NOT in `parseScope` yet — see the note
//! on `Scope`: an accepted-but-empty tier is worse than a rejected one.

const std = @import("std");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const progressive_regex = @import("progressive_regex.zig");
const skill_tools = pabrikcore.skill_tools;

/// Default page size and the hard ceiling. The result rides in the context
/// window, so a single call may never return the whole library.
pub const DEFAULT_SEARCH_LIMIT: usize = 40;
pub const MAX_SEARCH_LIMIT: usize = 200;

/// A skill's tier. Every result row carries one, because the model cannot
/// pass anything else back to `use_skill` (which loads by exact `path`) and
/// `add_skill` / `edit_skill` need to know which directory they write to.
///
/// `workspace` (the SQLite tier) has no rows yet — this module has no
/// database handle. It is listed in the error message `parseScope` produces
/// for an unknown value only once it is real; until then an unknown scope is
/// REJECTED rather than silently matching nothing, because a zero-result
/// answer to "search the workspace tier" reads as "no skills exist there"
/// instead of "that tier does not exist yet".
pub const Scope = enum {
    global,
    local,
};

pub fn scopeStr(scope: Scope) []const u8 {
    return switch (scope) {
        .global => "global",
        .local => "local",
    };
}

/// `"global"` / `"local"` → `Scope`. `null` for anything else (including
/// `""`), so callers can reject an unusable value instead of running a
/// query that can only return zero rows.
pub fn parseScope(raw: []const u8) ?Scope {
    if (std.mem.eql(u8, raw, "global")) return .global;
    if (std.mem.eql(u8, raw, "local")) return .local;
    return null;
}

/// The accepted `scope` values, for the error message on a bad one.
pub const ACCEPTED_SCOPES_MSG =
    "scope must be omitted (search every tier) or one of: 'global', 'local'";

/// One installed skill, flattened out of its tier.
pub const SkillRow = struct {
    name: []const u8,
    description: []const u8,
    scope: Scope,
    /// The EXACT path to hand to `use_skill` — case-sensitive, ends in `SKILL.MD`.
    path: []const u8,
};

/// Flatten the per-tier listing into scope-tagged rows.
///
/// Borrows every string from `data` — the caller must keep `data` (and free
/// it with `skill_tools.freeSkillsListData`) alive for as long as the rows.
pub fn collectRows(allocator: std.mem.Allocator, data: skill_tools.SkillsListData) ![]SkillRow {
    var out: std.ArrayList(SkillRow) = .empty;
    errdefer out.deinit(allocator);

    for (data.global_skills) |s| {
        try out.append(allocator, .{ .name = s.name, .description = s.description, .scope = .global, .path = s.path });
    }
    for (data.local_skills) |s| {
        try out.append(allocator, .{ .name = s.name, .description = s.description, .scope = .local, .path = s.path });
    }

    return out.toOwnedSlice(allocator);
}

/// How a query was interpreted. Rendered into the result so the model can
/// tell a real regex hit from a literal fallback without guessing.
pub const QueryMode = enum {
    /// No query given: every row (scope filter only).
    all,
    /// Compiled and matched as a regex.
    regex,
    /// `literal: true` was passed: case-insensitive substring.
    literal,
    /// The query did not compile as a regex and was matched as a literal
    /// substring instead. `QueryResult.warning` says why.
    regex_fallback,
};

pub const MatchOptions = struct {
    /// `literal: true`: case-insensitive substring, no metacharacters.
    literal: bool = false,
    /// `null` = every tier.
    scope: ?Scope = null,
};

pub const QueryResult = struct {
    rows: []const SkillRow,
    mode: QueryMode,
    /// Non-empty only when the query was reinterpreted or the match ran out
    /// of budget. Rendered as `pattern_warning`. Always a STATIC string, so
    /// no result owns an allocation the caller can leak.
    warning: []const u8 = "",
};

const WARNING_SUFFIX =
    " Supported: literals, '.', '[...]', '\\d \\w \\s \\b', '*', '+', '?', '{m,n}' ranges," ++
    " '( )' groups, '|', '^', '$'. Pass literal:true when the query is literal text.";

/// Why a pattern was reinterpreted as a literal substring. One STATIC string
/// per failure so the caller never has to free a warning; the `@errorName` is
/// spelled out per arm so a compile failure tells the model which limit it hit
/// (`PatternTooLong` means "shorten it", `InvalidPattern` means "fix or quote
/// it") rather than lumping them under one message.
fn invalidPatternWarningFor(err: progressive_regex.Error) []const u8 {
    return switch (err) {
        error.InvalidPattern =>
        "query is not a valid regex (InvalidPattern) — matched as a case-insensitive literal substring instead." ++ WARNING_SUFFIX,
        error.PatternTooLong =>
        "query is too long for the pattern compiler (PatternTooLong) — matched as a case-insensitive literal substring instead." ++ WARNING_SUFFIX,
        error.OutOfMemory =>
        "the pattern could not be compiled (OutOfMemory) — matched as a case-insensitive literal substring instead." ++ WARNING_SUFFIX,
    };
}

fn exhaustedWarning() []const u8 {
    return "the pattern was too expensive to finish matching, so some skills were skipped — anchor it with '^' or pass literal:true";
}

/// Match rows by `query`, a case-insensitive unanchored REGEX over the skill's
/// NAME and DESCRIPTION — the same contract `search_tool` uses, so the model
/// needs only one mental model for "search a catalog".
///
/// A query that does not compile is never a hard error: it degrades to a
/// case-insensitive substring match and the result carries the reason, so a
/// stray `(` in a legitimate search costs nothing and teaches the syntax in
/// the same turn.
pub fn matchQuery(
    allocator: std.mem.Allocator,
    rows: []const SkillRow,
    query: []const u8,
    opts: MatchOptions,
) !QueryResult {
    var matched: std.ArrayList(SkillRow) = .empty;
    errdefer matched.deinit(allocator);

    const inScope = struct {
        fn f(row: SkillRow, scope: ?Scope) bool {
            const want = scope orelse return true;
            return row.scope == want;
        }
    }.f;

    if (query.len == 0) {
        for (rows) |row| {
            if (!inScope(row, opts.scope)) continue;
            try matched.append(allocator, row);
        }
        return .{ .rows = try matched.toOwnedSlice(allocator), .mode = .all };
    }

    var regex: ?progressive_regex.Regex = null;
    defer if (regex) |*re| re.deinit();

    var mode: QueryMode = .literal;
    var warning: []const u8 = "";

    if (!opts.literal) {
        if (progressive_regex.compile(allocator, query, .{})) |re| {
            regex = re;
            mode = .regex;
        } else |err| {
            mode = .regex_fallback;
            warning = invalidPatternWarningFor(err);
        }
    }

    for (rows) |row| {
        if (!inScope(row, opts.scope)) continue;
        const hit = if (regex) |*re|
            (re.isMatch(row.name) or re.isMatch(row.description))
        else
            (containsIgnoreCase(row.name, query) or containsIgnoreCase(row.description, query));
        if (hit) try matched.append(allocator, row);
    }

    if (regex) |*re| {
        if (re.exhausted()) warning = exhaustedWarning();
    }

    return .{
        .rows = try matched.toOwnedSlice(allocator),
        .mode = mode,
        .warning = warning,
    };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Everything `renderSearchResult` needs beyond the page rows themselves.
pub const PageParams = struct {
    /// Matches before paging, so the model can tell how much it is not seeing.
    total: usize,
    /// How many matches were skipped to produce `page`.
    offset: usize,
    /// The requested page size. The renderer still caps `page` at this.
    limit: usize,
    query: []const u8,
    scope: ?Scope,
    mode: QueryMode,
    warning: []const u8,
};

/// The `offset`/`limit` window of `rows`. Paging is applied HERE rather than
/// in `matchQuery` so the pre-page `total` stays available to the renderer.
pub fn pageSlice(rows: []const SkillRow, offset: usize, limit: usize) []const SkillRow {
    if (offset >= rows.len or limit == 0) return &.{};
    const end = if (limit > rows.len - offset) rows.len else offset + limit;
    return rows[offset..end];
}

const SkillRowJson = struct {
    name: []const u8,
    description: []const u8,
    scope: []const u8,
    path: []const u8,
};

fn modeStr(mode: QueryMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .regex => "regex",
        .literal => "literal",
        .regex_fallback => "literal_fallback",
    };
}

/// `search_skills` result: `{"query","pattern_mode","pattern_warning",
/// "scope","count","total","offset","limit","skills","truncated",
/// "next_offset","hint"}`. Mirrors `search_tool`'s envelope field-for-field
/// so one paging convention serves both catalogs.
pub fn renderSearchResult(
    allocator: std.mem.Allocator,
    page: []const SkillRow,
    params: PageParams,
) ![]const u8 {
    const shown = @min(page.len, params.limit);
    const rows = try allocator.alloc(SkillRowJson, shown);
    defer allocator.free(rows);
    for (page[0..shown], 0..) |row, i| {
        rows[i] = .{
            .name = row.name,
            .description = row.description,
            .scope = scopeStr(row.scope),
            .path = row.path,
        };
    }

    const truncated = params.offset + shown < params.total;
    const next_offset: ?usize = if (truncated) params.offset + shown else null;
    const hint = if (truncated)
        try std.fmt.allocPrint(
            allocator,
            "Showing {d}-{d} of {d} matches — call again with offset={d} (same query) for the next page, or narrow the query.",
            .{ params.offset, params.offset + shown, params.total, params.offset + shown },
        )
    else
        try allocator.dupe(u8, "Call use_skill with a row's exact `path` to load it. Widen `query` or pass `scope` if you expected more.");
    defer allocator.free(hint);

    const warning: ?[]const u8 = if (params.warning.len > 0) params.warning else null;
    const scope: ?[]const u8 = if (params.scope) |s| scopeStr(s) else null;

    return try std.json.Stringify.valueAlloc(allocator, .{
        .query = params.query,
        .pattern_mode = modeStr(params.mode),
        .pattern_warning = warning,
        .scope = scope,
        .count = shown,
        .total = params.total,
        .offset = params.offset,
        .limit = params.limit,
        .skills = rows,
        .truncated = truncated,
        .next_offset = next_offset,
        .hint = hint,
    }, .{});
}

// ───────────────────────── tests ─────────────────────────

const testing_skill_tools = pabrikcore.skill_tools;

/// Parsed shape of `renderSearchResult` output.
const RenderedSearch = struct {
    query: []const u8 = "",
    pattern_mode: []const u8 = "",
    pattern_warning: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    count: usize = 0,
    total: usize = 0,
    offset: usize = 0,
    limit: usize = 0,
    skills: []const RenderedRow = &.{},
    truncated: bool = false,
    next_offset: ?usize = null,
    hint: []const u8 = "",
};

const RenderedRow = struct {
    name: []const u8,
    description: []const u8,
    scope: []const u8,
    path: []const u8,
};

fn parseRendered(alloc: std.mem.Allocator, out: []const u8) !std.json.Parsed(RenderedSearch) {
    return try std.json.parseFromSlice(RenderedSearch, alloc, out, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

const test_rows = [_]SkillRow{
    .{ .name = "zig-cross-platform", .description = "Prove Zig code compiles for Linux, macOS and Windows", .scope = .global, .path = "/g/zig/SKILL.MD" },
    .{ .name = "vitest-alias-stub", .description = "Resolve a bare specifier in a Vue component test", .scope = .global, .path = "/g/vitest/SKILL.MD" },
    .{ .name = "brainstorming", .description = "Explore user intent before creative work", .scope = .local, .path = "/l/brainstorming/SKILL.MD" },
};

test "parseScope accepts exactly global and local" {
    try testing.expectEqual(Scope.global, parseScope("global").?);
    try testing.expectEqual(Scope.local, parseScope("local").?);
    try testing.expect(parseScope("workspace") == null);
    try testing.expect(parseScope("") == null);
    try testing.expect(parseScope("GLOBAL") == null);
}

test "matchQuery with no query returns every row in mode=all" {
    const alloc = testing.allocator;
    const res = try matchQuery(alloc, &test_rows, "", .{});
    defer alloc.free(res.rows);

    try testing.expectEqual(QueryMode.all, res.mode);
    try testing.expectEqual(@as(usize, 3), res.rows.len);
    try testing.expectEqualStrings("", res.warning);
}

test "matchQuery regex matches name OR description, case-insensitively" {
    const alloc = testing.allocator;

    // name hit
    const by_name = try matchQuery(alloc, &test_rows, "zig-cross", .{});
    defer alloc.free(by_name.rows);
    try testing.expectEqual(QueryMode.regex, by_name.mode);
    try testing.expectEqual(@as(usize, 1), by_name.rows.len);
    try testing.expectEqualStrings("zig-cross-platform", by_name.rows[0].name);

    // description hit, different case on both sides
    const by_desc = try matchQuery(alloc, &test_rows, "VITEST", .{});
    defer alloc.free(by_desc.rows);
    try testing.expectEqual(@as(usize, 1), by_desc.rows.len);
    try testing.expectEqualStrings("vitest-alias-stub", by_desc.rows[0].name);

    // alternation reaches both in one call
    const alt = try matchQuery(alloc, &test_rows, "brainstorming|zig-cross", .{});
    defer alloc.free(alt.rows);
    try testing.expectEqual(@as(usize, 2), alt.rows.len);
}

test "matchQuery scope filter narrows to one tier; omitted means both" {
    const alloc = testing.allocator;

    const global_only = try matchQuery(alloc, &test_rows, "", .{ .scope = .global });
    defer alloc.free(global_only.rows);
    try testing.expectEqual(@as(usize, 2), global_only.rows.len);
    for (global_only.rows) |r| try testing.expectEqual(Scope.global, r.scope);

    const local_only = try matchQuery(alloc, &test_rows, "", .{ .scope = .local });
    defer alloc.free(local_only.rows);
    try testing.expectEqual(@as(usize, 1), local_only.rows.len);
    try testing.expectEqualStrings("brainstorming", local_only.rows[0].name);

    const both = try matchQuery(alloc, &test_rows, "", .{});
    defer alloc.free(both.rows);
    try testing.expectEqual(@as(usize, 3), both.rows.len);
}

test "matchQuery literal:true treats metacharacters verbatim" {
    const alloc = testing.allocator;

    // As a REGEX, "zig." is "zig" followed by any character, and matches the
    // skill named `zig-cross-platform`.
    const as_regex = try matchQuery(alloc, &test_rows, "zig.", .{});
    defer alloc.free(as_regex.rows);
    try testing.expectEqual(QueryMode.regex, as_regex.mode);
    try testing.expectEqual(@as(usize, 1), as_regex.rows.len);
    try testing.expectEqualStrings("zig-cross-platform", as_regex.rows[0].name);

    // As a LITERAL it is the 4-character text "zig.", which no row carries —
    // the flag is the only thing making those two answers differ.
    const as_literal = try matchQuery(alloc, &test_rows, "zig.", .{ .literal = true });
    defer alloc.free(as_literal.rows);
    try testing.expectEqual(QueryMode.literal, as_literal.mode);
    try testing.expectEqual(@as(usize, 0), as_literal.rows.len);

    // And a literal that IS present is still found.
    const desc_literal_hit = try matchQuery(alloc, &test_rows, "user intent", .{ .literal = true });
    defer alloc.free(desc_literal_hit.rows);
    try testing.expectEqual(@as(usize, 1), desc_literal_hit.rows.len);
    try testing.expectEqualStrings("brainstorming", desc_literal_hit.rows[0].name);
}

test "an invalid pattern degrades to a literal substring and says so" {
    const alloc = testing.allocator;

    // Unbalanced group — never a hard error.
    const res = try matchQuery(alloc, &test_rows, "zig(", .{});
    defer alloc.free(res.rows);

    try testing.expectEqual(QueryMode.regex_fallback, res.mode);
    try testing.expect(res.warning.len > 0);
    try testing.expect(std.mem.indexOf(u8, res.warning, "literal:true") != null);
    // Nothing matched: "zig(" is not a substring of any row.
    try testing.expectEqual(@as(usize, 0), res.rows.len);
}

test "pageSlice returns the requested window and clamps at the end" {
    try testing.expectEqual(@as(usize, 2), pageSlice(&test_rows, 0, 2).len);
    try testing.expectEqualStrings("brainstorming", pageSlice(&test_rows, 2, 2)[0].name);
    try testing.expectEqual(@as(usize, 0), pageSlice(&test_rows, 99, 2).len);
    try testing.expectEqual(@as(usize, 0), pageSlice(&test_rows, 0, 0).len);
    try testing.expectEqual(@as(usize, 1), pageSlice(&test_rows, 2, 99).len);
}

test "renderSearchResult carries scope + path on every row and reports the pre-page total" {
    const alloc = testing.allocator;

    const out = try renderSearchResult(alloc, &test_rows, .{
        .total = 3,
        .offset = 0,
        .limit = 2,
        .query = "skill",
        .scope = null,
        .mode = .regex,
        .warning = "",
    });
    defer alloc.free(out);

    const parsed = try parseRendered(alloc, out);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.value.count);
    try testing.expectEqual(@as(usize, 3), parsed.value.total);
    try testing.expect(parsed.value.truncated);
    try testing.expectEqual(@as(usize, 2), parsed.value.next_offset.?);
    try testing.expectEqualStrings("regex", parsed.value.pattern_mode);
    try testing.expect(parsed.value.pattern_warning == null);
    try testing.expect(parsed.value.scope == null);
    try testing.expectEqual(@as(usize, 2), parsed.value.skills.len);
    try testing.expectEqualStrings("global", parsed.value.skills[0].scope);
    try testing.expectEqualStrings("/g/zig/SKILL.MD", parsed.value.skills[0].path);
    // The hint names the exact continuing offset.
    try testing.expect(std.mem.indexOf(u8, parsed.value.hint, "offset=2") != null);
}

test "renderSearchResult on the last page is not truncated and points at use_skill" {
    const alloc = testing.allocator;

    const out = try renderSearchResult(alloc, &test_rows, .{
        .total = 3,
        .offset = 1,
        .limit = 40,
        .query = "",
        .scope = .local,
        .mode = .all,
        .warning = "",
    });
    defer alloc.free(out);

    const parsed = try parseRendered(alloc, out);
    defer parsed.deinit();

    try testing.expect(!parsed.value.truncated);
    try testing.expect(parsed.value.next_offset == null);
    try testing.expectEqualStrings("local", parsed.value.scope.?);
    try testing.expect(std.mem.indexOf(u8, parsed.value.hint, "use_skill") != null);
}

test "renderSearchResult surfaces a pattern_warning verbatim" {
    const alloc = testing.allocator;

    const res = try matchQuery(alloc, &test_rows, "zig(", .{});
    defer alloc.free(res.rows);

    const out = try renderSearchResult(alloc, res.rows, .{
        .total = res.rows.len,
        .offset = 0,
        .limit = 40,
        .query = "zig(",
        .scope = null,
        .mode = res.mode,
        .warning = res.warning,
    });
    defer alloc.free(out);

    const parsed = try parseRendered(alloc, out);
    defer parsed.deinit();
    try testing.expectEqualStrings("literal_fallback", parsed.value.pattern_mode);
    try testing.expect(parsed.value.pattern_warning != null);
}

// ---------------------------------------------------------------------------
// End-to-end against the real filesystem: the tier flattening must read the
// local tier from the PASSED cwd, not the process cwd (the regression the
// old `execute_list_skills` test pinned — the exec wiring once passed null).
// ---------------------------------------------------------------------------

const fsio = testing.io;

fn writeSkill(alloc: std.mem.Allocator, dir: []const u8, name: []const u8, desc: []const u8) !void {
    const skill_dir = try std.fs.path.join(alloc, &[_][]const u8{ dir, ".pabrik", "skills", name });
    defer alloc.free(skill_dir);
    try std.Io.Dir.cwd().createDirPath(fsio, skill_dir);

    const file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir, "SKILL.MD" });
    defer alloc.free(file_path);

    const body = try std.fmt.allocPrint(
        alloc,
        "---\nname: {s}\ndescription: \"{s}\"\n---\n\n# {s}\n\nbody\n",
        .{ name, desc, name },
    );
    defer alloc.free(body);

    const f = try std.Io.Dir.createFileAbsolute(fsio, file_path, .{});
    defer std.Io.File.close(f, fsio);
    try std.Io.File.writeStreamingAll(f, fsio, body);
}

test "collectRows + matchQuery: local tier resolves from the passed cwd and is scope-tagged" {
    const alloc = testing.allocator;

    const tmp = "/tmp/pabrik-search-skills-test";
    const other = "/tmp/pabrik-search-skills-other-cwd";
    std.Io.Dir.cwd().deleteTree(fsio, tmp) catch {};
    std.Io.Dir.cwd().deleteTree(fsio, other) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(fsio, tmp) catch {};
        std.Io.Dir.cwd().deleteTree(fsio, other) catch {};
    }

    try writeSkill(alloc, tmp, "search-fixture", "Fixture for the local tier");
    try writeSkill(alloc, other, "other-cwd-fixture", "Must never leak in");

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", "/tmp/pabrik-nonexistent-home-for-search-test");

    const data = try testing_skill_tools.listAllSkills(alloc, fsio, tmp, &env);
    defer testing_skill_tools.freeSkillsListData(alloc, data);

    const rows = try collectRows(alloc, data);
    defer alloc.free(rows);

    // Exactly one skill, and it is the LOCAL one from `tmp`.
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("search-fixture", rows[0].name);
    try testing.expectEqual(Scope.local, rows[0].scope);
    try testing.expectEqualStrings("Fixture for the local tier", rows[0].description);
    try testing.expect(std.mem.indexOf(u8, rows[0].path, "search-fixture/SKILL.MD") != null);

    // The same query with scope=global finds nothing — proves the filter runs.
    const global_res = try matchQuery(alloc, rows, "search-fixture", .{ .scope = .global });
    defer alloc.free(global_res.rows);
    try testing.expectEqual(@as(usize, 0), global_res.rows.len);

    const local_res = try matchQuery(alloc, rows, "search-fixture", .{ .scope = .local });
    defer alloc.free(local_res.rows);
    try testing.expectEqual(@as(usize, 1), local_res.rows.len);
}