//! Tier 0 of a skill eval: the deterministic half. No LLM, no tokens.
//!
//! A skill names things — file paths, commands, `file:line` references. Those
//! are claims about the code as it is TODAY, and they can be checked
//! mechanically. Doing that here rather than asking a model to remember a
//! codebase is the difference between adjudicating a fact and recalling one,
//! and it means the cheapest and most common failure (a skill pointing at a
//! file that has since moved) costs nothing to detect.
//!
//! ## Tier 0 deliberately never reports severity `high`
//!
//! `skill_evals_db.decideVerdict` promotes any high-severity finding to
//! `delete`, and that is correct: some findings really do mean the skill must
//! go. A renamed path is not one of them. It means the skill needs UPDATING.
//! So this module caps severity at `medium`, which makes "Tier 0 can never
//! delete a skill" a structural property rather than a promise — deletion is
//! reserved for the LLM tier, which can judge that a skill's subject matter is
//! gone rather than merely moved.
//!
//! ## Why `statFile`, not `statFileAbsolute`
//!
//! The paths checked here come from LLM-authored prose, so they can be
//! relative, empty, or nonsense. Zig's `*Absolute` family ASSERTS on a
//! non-absolute path and aborts the whole process — a `catch` cannot save you,
//! because the panic fires inside the callee (PR #639's crash class).
//! `std.Io.Dir.cwd().statFile` is the path-based, assertion-free form, and an
//! error from it is exactly the signal wanted.

const std = @import("std");
const testing = std.testing;
const skill_evals_db = @import("skill_evals_db.zig");
const Verdict = skill_evals_db.Verdict;

/// Cap on the paths checked per skill. A skill that names more than this is
/// either enormous or listing examples; either way, checking the first 50 is
/// enough to reach a verdict and keeps a pathological body from turning one
/// eval into thousands of stats.
pub const MAX_REFERENCED_PATHS = 50;

/// A skill larger than this is a smell (`MAX_SKILLS_SIZE` in `skills.zig`).
pub const MAX_BODY_BYTES = 100 * 1024;

pub const Finding = struct {
    dimension: []const u8,
    severity: []const u8,
    claim: []const u8,
    evidence: []const u8,
};

pub const Analysis = struct {
    verdict: Verdict = .keep,
    /// Always false — see the module doc. Present so the caller does not have
    /// to know that.
    has_high: bool = false,
    findings_json: []u8 = &.{},
    referenced_paths_json: []u8 = &.{},
    missing_paths_json: []u8 = &.{},
    finding_count: u32 = 0,
    missing_count: u32 = 0,

    pub fn deinit(self: Analysis, allocator: std.mem.Allocator) void {
        if (self.findings_json.len > 0) allocator.free(self.findings_json);
        if (self.referenced_paths_json.len > 0) allocator.free(self.referenced_paths_json);
        if (self.missing_paths_json.len > 0) allocator.free(self.missing_paths_json);
    }
};

fn jsonQuoted(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, s, .{});
}

fn buildStringArray(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (items, 0..) |s, i| {
        if (i > 0) try out.append(allocator, ',');
        const q = try jsonQuoted(allocator, s);
        defer allocator.free(q);
        try out.appendSlice(allocator, q);
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn buildFindings(allocator: std.mem.Allocator, findings: []const Finding) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (findings, 0..) |f, i| {
        if (i > 0) try out.append(allocator, ',');
        const d = try jsonQuoted(allocator, f.dimension);
        defer allocator.free(d);
        const sv = try jsonQuoted(allocator, f.severity);
        defer allocator.free(sv);
        const c = try jsonQuoted(allocator, f.claim);
        defer allocator.free(c);
        const e = try jsonQuoted(allocator, f.evidence);
        defer allocator.free(e);
        const one = try std.fmt.allocPrint(allocator,
            "{{\"dimension\":{s},\"severity\":{s},\"claim\":{s},\"evidence\":{s}}}",
            .{ d, sv, c, e });
        defer allocator.free(one);
        try out.appendSlice(allocator, one);
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

/// Delimiters that end a candidate path token. `/`, `.`, `-`, `_`, `:` and
/// digits are deliberately NOT delimiters — they are what makes a token look
/// like a path, and `:` is needed for the `file:line` form.
const token_delims = " \t\r\n`\"'()[]{}<>,;|*!?=";

/// Strip a trailing `:LINE` (or `:LINE:COL`) from a `file:line` reference.
fn stripLineSuffix(token: []const u8) []const u8 {
    // Loops rather than stripping once, so `file:line:col` collapses to `file`
    // as well as `file:line` does.
    var t = token;
    while (true) {
        const colon = std.mem.lastIndexOfScalar(u8, t, ':') orelse return t;
        if (colon == 0 or colon + 1 >= t.len) return t;
        var all_digits = true;
        for (t[colon + 1 ..]) |ch| {
            if (!std.ascii.isDigit(ch)) {
                all_digits = false;
                break;
            }
        }
        if (!all_digits) return t;
        t = t[0..colon];
    }
}

fn looksLikePath(token: []const u8) bool {
    if (token.len < 3 or token.len > 200) return false;
    if (std.mem.indexOfScalar(u8, token, '/') != null) return true;
    const known = [_][]const u8{
        ".zig", ".md",   ".ts",  ".vue", ".json", ".toml", ".sh",
        ".py",  ".yml",  ".yaml", ".sql", ".txt",  ".rs",
    };
    for (known) |ext| {
        if (std.mem.endsWith(u8, token, ext)) return true;
    }
    return false;
}

fn shouldSkip(token: []const u8) bool {
    // URLs and protocol-relative refs are not repo paths.
    if (std.mem.startsWith(u8, token, "http")) return true;
    if (std.mem.startsWith(u8, token, "//")) return true;
    // A bare leading slash with one segment (`/api/skills`) is a route, not a
    // file, and stats against it would be a false "missing".
    if (token.len > 0 and token[0] == '/') return true;
    // Glob-ish or template-ish tokens: not a single concrete path.
    if (std.mem.indexOfAny(u8, token, "*?<>$") != null) return true;
    return false;
}

/// Extract the de-duplicated path-ish tokens from a skill body, in order.
/// Caller owns the returned slice and each entry.
pub fn extractPaths(allocator: std.mem.Allocator, body: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    var it = std.mem.tokenizeAny(u8, body, token_delims);
    while (it.next()) |raw| {
        if (out.items.len >= MAX_REFERENCED_PATHS) break;
        const token = std.mem.trim(u8, raw, ".,;:");
        if (!looksLikePath(token)) continue;
        if (shouldSkip(token)) continue;
        const base = stripLineSuffix(token);
        if (!looksLikePath(base)) continue;
        if (shouldSkip(base)) continue;

        var seen = false;
        for (out.items) |p| {
            if (std.mem.eql(u8, p, base)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        try out.append(allocator, try allocator.dupe(u8, base));
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freePaths(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

/// Structural checks that need no filesystem at all.
fn structuralFindings(allocator: std.mem.Allocator, body: []const u8, out: *std.ArrayList(Finding)) !void {
    if (body.len == 0) {
        try out.append(allocator, .{
            .dimension = "structural",
            .severity = "medium",
            .claim = "the skill body is empty",
            .evidence = "read 0 bytes",
        });
        return;
    }
    if (body.len > MAX_BODY_BYTES) {
        try out.append(allocator, .{
            .dimension = "structural",
            .severity = "medium",
            .claim = "the skill body is larger than the 100 KB listing cap, so its discovery cost is high",
            .evidence = "body exceeds MAX_SKILLS_SIZE (skills.zig)",
        });
    }
    // The frontmatter the prompt mandates. A missing `name:` means the skill
    // cannot be listed correctly, which is a real defect worth surfacing.
    if (std.mem.indexOf(u8, body, "name:") == null) {
        try out.append(allocator, .{
            .dimension = "structural",
            .severity = "low",
            .claim = "no `name:` in the frontmatter",
            .evidence = "no 'name:' token found in the body",
        });
    }
    if (std.mem.indexOf(u8, body, "description:") == null) {
        try out.append(allocator, .{
            .dimension = "structural",
            .severity = "low",
            .claim = "no `description:`, so the skill cannot be discovered by scanning list_skills",
            .evidence = "no 'description:' token found in the body",
        });
    }
}

/// Analyse one skill body against the code as it is now.
///
/// `cwd` is used to resolve relative paths; when it is empty, relative
/// references are reported as uncheckable rather than as missing — a false
/// "missing" would be worse than an honest "unknown".
pub fn analyse(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    body: []const u8,
) !Analysis {
    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(allocator);
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(allocator);
    var referenced: std.ArrayList([]const u8) = .empty;
    defer referenced.deinit(allocator);

    try structuralFindings(allocator, body, &findings);

    const paths = try extractPaths(allocator, body);
    defer freePaths(allocator, paths);

    for (paths) |p| {
        try referenced.append(allocator, p);
        if (p.len == 0) continue;

        // Resolve. Absolute stays as-is; relative joins onto cwd, which
        // `std.fs.path.join` keeps absolute when the root is absolute.
        const resolved: ?[]u8 = if (std.fs.path.isAbsolute(p))
            try allocator.dupe(u8, p)
        else if (cwd.len > 0)
            try std.fs.path.join(allocator, &.{ cwd, p })
        else
            null;
        if (resolved == null) continue;
        defer allocator.free(resolved.?);

        _ = std.Io.Dir.cwd().statFile(io, resolved.?, .{}) catch {
            try missing.append(allocator, p);
            try findings.append(allocator, .{
                .dimension = "stale_path",
                .severity = "medium",
                .claim = "this path does not exist any more",
                .evidence = p,
            });
            continue;
        };
    }

    const findings_json = try buildFindings(allocator, findings.items);
    errdefer allocator.free(findings_json);
    const referenced_json = try buildStringArray(allocator, referenced.items);
    errdefer allocator.free(referenced_json);
    const missing_json = try buildStringArray(allocator, missing.items);

    return .{
        .verdict = if (findings.items.len > 0) .update else .keep,
        .has_high = false,
        .findings_json = findings_json,
        .referenced_paths_json = referenced_json,
        .missing_paths_json = missing_json,
        .finding_count = @intCast(findings.items.len),
        .missing_count = @intCast(missing.items.len),
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

test "extractPaths finds path-shaped tokens and rejects the rest" {
    const alloc = testing.allocator;
    const body =
        \\## Procedure
        \\Run `rg foo src/agentic_loop/workflow.zig:1598` then read src/modules/config/Config.zig
        \\See docs/plans/2026-09-27-skill-evals.md for context.
        \\Call `zig build test --summary all`. Visit https://example.com/src/fake.zig
        \\The route is /api/skills/:name and the glob is src/**/*.zig
        \\The word workflow.zig is a bare filename too.
    ;
    const paths = try extractPaths(alloc, body);
    defer freePaths(alloc, paths);

    var found_workflow = false;
    var found_config = false;
    var found_plan = false;
    for (paths) |p| {
        // The `:1598` suffix must be stripped: the file is what exists.
        if (std.mem.eql(u8, p, "src/agentic_loop/workflow.zig")) found_workflow = true;
        if (std.mem.eql(u8, p, "src/modules/config/Config.zig")) found_config = true;
        if (std.mem.eql(u8, p, "docs/plans/2026-09-27-skill-evals.md")) found_plan = true;
        // Never the URL, never the route, never the glob.
        try testing.expect(std.mem.indexOf(u8, p, "example.com") == null);
        try testing.expect(std.mem.indexOf(u8, p, "api/skills") == null);
        try testing.expect(std.mem.indexOf(u8, p, "*") == null);
        // No duplicates.
    }
    try testing.expect(found_workflow);
    try testing.expect(found_config);
    try testing.expect(found_plan);

    // De-duplication: the same path twice yields one entry.
    var count: usize = 0;
    for (paths) |p| {
        if (std.mem.eql(u8, p, "src/modules/config/Config.zig")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "stripLineSuffix removes a :line and a :line:col but not a plain path" {
    try testing.expectEqualStrings("a/b.zig", stripLineSuffix("a/b.zig:12"));
    try testing.expectEqualStrings("a/b.zig", stripLineSuffix("a/b.zig:12:5"));
    try testing.expectEqualStrings("a/b.zig", stripLineSuffix("a/b.zig"));
    // A colon that is not a line number is left alone.
    try testing.expectEqualStrings("a/b:c.zig", stripLineSuffix("a/b:c.zig"));
}

test "a missing referenced path is reported as needing an UPDATE, never a delete" {
    const alloc = testing.allocator;
    const body =
        \\---
        \\name: probe
        \\description: probe
        \\---
        \\## Procedure
        \\Read src/this/path/does/not/exist.zig then continue.
    ;
    const a = try analyse(alloc, testing.io, "/tmp", body);
    defer a.deinit(alloc);

    try testing.expectEqual(@as(u32, 1), a.missing_count);
    try testing.expectEqual(@as(u32, 1), a.finding_count);
    // The invariant this module exists to keep.
    try testing.expect(!a.has_high);
    try testing.expectEqual(Verdict.update, a.verdict);
    try testing.expectEqual(Verdict.update, skill_evals_db.decideVerdict(a.verdict, a.has_high));
    try testing.expectEqualStrings("[\"src/this/path/does/not/exist.zig\"]", a.missing_paths_json);
}

test "a healthy skill is a keep with no findings" {
    const alloc = testing.allocator;
    const body =
        \\---
        \\name: healthy
        \\description: a skill whose references all resolve
        \\---
        \\## Procedure
        \\Read src/agentic_loop/skill_evals_drift.zig for the details.
    ;
    // cwd "." rather than an absolute path to the developer's checkout: the
    // file referenced below is in THIS tree, and the test binary runs from it.
    const a = try analyse(alloc, testing.io, ".", body);
    defer a.deinit(alloc);

    try testing.expectEqual(@as(u32, 0), a.missing_count);
    try testing.expectEqual(@as(u32, 0), a.finding_count);
    try testing.expectEqual(Verdict.keep, a.verdict);
    try testing.expectEqualStrings("[]", a.findings_json);
    try testing.expectEqualStrings("[]", a.missing_paths_json);
}

test "structural problems are found without touching the filesystem" {
    const alloc = testing.allocator;
    const body = "no frontmatter at all, and no description either\n";
    const a = try analyse(alloc, testing.io, ".", body);
    defer a.deinit(alloc);

    try testing.expectEqual(@as(u32, 2), a.finding_count); // name + description
    try testing.expectEqual(Verdict.update, a.verdict);
    try testing.expect(!a.has_high);
}

test "an empty body is a finding, not a crash" {
    const alloc = testing.allocator;
    const a = try analyse(alloc, testing.io, ".", "");
    defer a.deinit(alloc);

    try testing.expectEqual(@as(u32, 1), a.finding_count);
    try testing.expectEqual(Verdict.update, a.verdict);
    try testing.expect(!a.has_high);
}

test "a relative path is only checked when there is a cwd to resolve it against" {
    const alloc = testing.allocator;
    const body =
        \\---
        \\name: rel
        \\description: rel
        \\---
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    // With a cwd, the path resolves and is found.
    const with_cwd = try analyse(alloc, testing.io, ".", body);
    defer with_cwd.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), with_cwd.missing_count);
    try testing.expectEqual(Verdict.keep, with_cwd.verdict);

    // Without one we say NOTHING rather than reporting a false "missing" — an
    // honest unknown beats a wrong verdict.
    const without_cwd = try analyse(alloc, testing.io, "", body);
    defer without_cwd.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), without_cwd.missing_count);
}

test "analyse tolerates a body full of hostile tokens without aborting" {
    const alloc = testing.allocator;
    // Empty-ish, relative-only, absolute, glob, URL, and a bare slash: this is
    // the shape that used to be able to kill the process via the *Absolute
    // assert family. It must return a verdict instead.
    const body =
        \\.zig :12 / // ../..  ../../etc/passwd http://x/y.zig **/*.md ``
        \\C:\Users\fake\file.zig
    ;
    const a = try analyse(alloc, testing.io, "/tmp", body);
    defer a.deinit(alloc);
    // It RETURNED, which is the point — the *Absolute family would have aborted
    // the process here. Some of these tokens legitimately resolve to nothing
    // (`../../etc/passwd` under /tmp), so the verdict may be `update`; what must
    // hold is that a mechanical check can never authorise a deletion.
    try testing.expect(!a.has_high);
    try testing.expect(skill_evals_db.decideVerdict(a.verdict, a.has_high) != .delete);
}
