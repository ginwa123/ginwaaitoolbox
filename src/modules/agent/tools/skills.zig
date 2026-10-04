//! Skill BODY helpers: frontmatter parsing and bundle materialisation.
//!
//! What used to live here — and what no longer does
//! ─────────────────────────────────────────────────
//! This file used to be the skills STORAGE layer: it resolved
//! `~/.config/pabrik/skills/` vs `<cwd>/.pabrik/skills/`, walked those
//! directories looking for `<skill>/SKILL.MD`, and returned `SkillInfo`
//! rows carrying a `path`. All of that is gone. Skills are rows in the
//! `skills` table now (Migration 101), read through
//! `pabrikcore.skills_store`, and a skill's identity is `(workspace_id,
//! name)` rather than a pathname. "Which directory did this come from?"
//! no longer has an answer to give, so every function that existed only to
//! produce one is deleted rather than left behind as dead glue.
//!
//! What remains is the part that has nothing to do with storage:
//!
//!   * `parseYamlFrontmatter` — still called by the three HTTP handlers
//!     and by the importer, so its signature and its
//!     `ParsedFrontmatter` struct are unchanged.
//!   * `materializeAssetDir` — writes a bundle's `skill_assets` rows back
//!     out as real files so the relative paths a skill body refers to
//!     (`scripts/convert_pdf_to_images.py`) actually resolve when the
//!     model follows them.
//!
//! The materialised directory is a MATERIALISATION, not a location of
//! record: it is created per `use_skill` call and may be reaped. The row
//! is the truth.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const skills_store = pabrikcore.skills_store;

/// Root for materialised asset directories. `/tmp` is hardcoded for the
/// same reason `run_skill_eval.zig`'s `makeTmpRoot` hardcodes it: these
/// are short-lived scratch trees that must survive no reboot and must not
/// sit inside a workspace (where an agent's `present_files` sweep would
/// find them and a `deleteTree` would take user data with them).
const TMP_ROOT = "/tmp";

/// Parsed YAML frontmatter from a skill file
pub const ParsedFrontmatter = struct {
    name: []const u8,
    description: []const u8,
};

/// Parse YAML frontmatter from skill file content
/// Expected format:
/// ---
/// name: skill-name
/// description: "Skill description text"
/// ---
/// # Skill content follows...
///
/// Returns allocated ParsedFrontmatter with owned name and description strings
/// Caller owns the returned memory and must free name and description.
pub fn parseYamlFrontmatter(allocator: std.mem.Allocator, content: []const u8) ?ParsedFrontmatter {
    // Find the first --- marker
    const first_newline = std.mem.indexOf(u8, content, "\n") orelse return null;
    const after_first_line = content[first_newline + 1 ..];

    // Find the closing --- marker
    const closing_marker = std.mem.indexOf(u8, after_first_line, "\n---") orelse return null;
    const frontmatter_content = after_first_line[0..closing_marker];

    // Parse name and description from frontmatter
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;

    var line_start: usize = 0;
    while (line_start < frontmatter_content.len) {
        const line_end = std.mem.indexOf(u8, frontmatter_content[line_start..], "\n") orelse frontmatter_content.len - line_start;
        const line = std.mem.trim(u8, frontmatter_content[line_start .. line_start + line_end], " \t\r");

        if (line.len == 0) {
            line_start += line_end + 1;
            continue;
        }

        // Parse "name:" or "description:" lines
        if (std.mem.startsWith(u8, line, "name:")) {
            const value = std.mem.trim(u8, line[5..], " \t");
            // Remove quotes if present, then allocate
            if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
                name = allocator.dupe(u8, value[1 .. value.len - 1]) catch return null;
            } else {
                name = allocator.dupe(u8, value) catch return null;
            }
        } else if (std.mem.startsWith(u8, line, "description:")) {
            const value = std.mem.trim(u8, line[12..], " \t");
            // Remove quotes if present, then allocate
            if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
                description = allocator.dupe(u8, value[1 .. value.len - 1]) catch return null;
            } else {
                description = allocator.dupe(u8, value) catch return null;
            }
        }

        line_start += line_end + 1;
    }
    const parsed_name = name orelse return null;
    const parsed_desc = description orelse "";

    return .{
        .name = parsed_name,
        .description = parsed_desc,
    };
}

// ============================================================================
// Asset materialisation
// ============================================================================

/// Why a bundle could not be written out. Every arm is a REFUSAL: nothing
/// here degrades to "skip that file and load the rest", because a skill
/// body that says "run scripts/convert.py" and then silently has no
/// scripts/convert.py is worse than a failed load — the model reports a
/// script it never saw.
pub const MaterializeError = error{
    /// The skill has no companion files. A skill with no assets must
    /// return `asset_dir: null`, not an empty directory.
    NoAssets,
    /// `skill_name` is not a legal single-token name. It becomes a path
    /// segment of the materialisation directory, so `..` here would place
    /// the bundle somewhere else entirely.
    InvalidSkillName,
    /// A `rel_path` escapes the materialisation directory, or is absolute,
    /// or uses a backslash. See `isSafeRelPath`.
    UnsafeAssetPath,
    /// No free directory could be created under the temp root.
    CannotCreateTempDir,
};

/// True when `rel_path` is safe to join onto a directory we just created.
///
/// Three shapes are refused outright, and refused as an ERROR rather than
/// skipped:
///
///   * `..` anywhere — `../../etc/cron.d/x` and `scripts/../../escape`
///     both leave the directory. The substring test is deliberately
///     blunter than a path-component walk: it also rejects the legal-but-
///     pointless `a..b`, which is the right trade for a guard that runs on
///     untrusted input.
///   * an absolute prefix — a leading `/`, or an NT drive prefix like
///     `C:payload`, which `std.fs.path.join` would happily accept and
///     resolve against the drive root.
///   * a backslash — on Windows a backslash IS the separator, so a path
///     that is a safe single-component string on Linux is a traversal on
///     Windows. The materialised tree is written on whichever host the
///     server runs, and a guard that only holds on one of them is not a
///     guard.
pub fn isSafeRelPath(rel_path: []const u8) bool {
    if (rel_path.len == 0) return false;
    if (std.mem.indexOf(u8, rel_path, "..") != null) return false;
    if (rel_path[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, rel_path, '\\') != null) return false;
    // `C:foo` / `Z:bar` — a drive-relative path, absolute for our purposes.
    if (rel_path.len >= 2 and std.ascii.isAlphabetic(rel_path[0]) and rel_path[1] == ':') return false;
    return true;
}

/// Create a fresh, uniquely-named directory under `TMP_ROOT`. Returns an
/// owned path the caller frees with `allocator.free`.
///
/// Uniqueness comes from a nanosecond stamp plus an attempt counter,
/// mirroring `run_skill_eval.zig`'s `makeTmpRoot` — the two materialise
/// short-lived trees per agent turn and must never collide, or one
/// bundle's files would show up inside another's.
fn createUniqueAssetDir(
    io: std.Io,
    alloc: std.mem.Allocator,
    skill_name: []const u8,
) ![]u8 {
    const stamp = std.Io.Timestamp.now(io, .real).nanoseconds;
    var attempt: u32 = 0;
    while (attempt < 16) : (attempt += 1) {
        var buf: [160]u8 = undefined;
        const leaf = std.fmt.bufPrint(&buf, "pabrik-skill-assets-{s}-{d}-{d}", .{
            skill_name,
            stamp,
            attempt,
        }) catch return error.CannotCreateTempDir;
        const dir = try std.fs.path.join(alloc, &.{ TMP_ROOT, leaf });
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            alloc.free(dir);
            // A name collision is the only expected failure: everything
            // else (permissions, ENOSPC, a missing temp root) is a real
            // filesystem problem the caller has to hear about.
            if (err == error.PathAlreadyExists) continue;
            return err;
        };
        return dir;
    }
    return error.CannotCreateTempDir;
}

/// Write every companion file of one skill into a fresh directory and
/// return it.
///
/// `rel_path` is honoured verbatim because a skill BODY refers to its
/// companions by that exact string — `scripts/run_eval.py` in
/// `skill-creator`, `scripts/convert_pdf_to_images.py` in `pdf` — so
/// re-rooting, flattening or renames would all silently break the skill.
/// Parent directories are created on demand; the store hands them back
/// sorted by `rel_path`, so the write order is stable.
///
/// The returned `dir` is absolute and owned by the caller, who frees it
/// with `allocator.free` (and owns the tree: `deleteTree` it when done).
/// `file_count` is the number of files actually written, which equals
/// `assets.len` — there is no partial-success path.
///
/// Refuses, never skips: `error.NoAssets` for an empty bundle,
/// `error.InvalidSkillName` for a name that is not a single path-safe
/// token, `error.UnsafeAssetPath` for any `rel_path` that would escape the
/// directory. Validate BEFORE creating the directory so a hostile bundle
/// cannot make the tool litter `/tmp` before it is rejected.
pub fn materializeAssetDir(
    io: std.Io,
    alloc: std.mem.Allocator,
    skill_name: []const u8,
    assets: []const skills_store.SkillAssetRow,
) !struct { dir: []const u8, file_count: usize } {
    if (assets.len == 0) return error.NoAssets;
    if (!skills_store.isValidSkillName(skill_name)) return error.InvalidSkillName;
    for (assets) |a| {
        if (!isSafeRelPath(a.rel_path)) return error.UnsafeAssetPath;
    }

    const dir = try createUniqueAssetDir(io, alloc, skill_name);
    // Everything below is a partial-materialisation failure from here on,
    // so unwind the tree rather than leaving an orphan directory holding
    // half a bundle.
    errdefer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    for (assets) |a| {
        const full = try std.fs.path.join(alloc, &.{ dir, a.rel_path });
        defer alloc.free(full);

        // `dirname` yields `dir` itself for a top-level file, and
        // `createDirPath` on an existing directory is a no-op.
        const parent = std.fs.path.dirname(full) orelse dir;
        std.Io.Dir.cwd().createDirPath(io, parent) catch |err| return err;

        const file = std.Io.Dir.createFileAbsolute(io, full, .{}) catch |err| return err;
        defer std.Io.File.close(file, io);
        std.Io.File.writeStreamingAll(file, io, a.content) catch |err| return err;
    }

    return .{ .dir = dir, .file_count = assets.len };
}

// ============================================================================
// skills.zig — inline tests
// ============================================================================
//
// The three tests this file used to carry were all about DIRECTORY
// RESOLUTION (`parse_skill` picking the session repo over the process
// cwd, the process-cwd resolvers agreeing with each other). There is no
// directory resolution any more, so there was nothing to convert — they
// are replaced by tests for the one thing here that has a contract:
// materialising a bundle, and refusing to materialise one that would
// escape the directory it was given.

const testing = std.testing;

/// A `SkillAssetRow` without a database behind it. Every field is a plain
/// slice, so the materialiser's only real input is `(rel_path, content)`
/// and no store fixture is needed to exercise the traversal guard.
fn fakeAsset(rel_path: []const u8, content: []const u8) skills_store.SkillAssetRow {
    return .{
        .id = "sa_1",
        .skill_id = "sk_1",
        .rel_path = rel_path,
        .content = content,
        .created_at = "",
    };
}

test "materializeAssetDir writes each asset at its rel_path, creating parents" {
    const alloc = testing.allocator;
    const io = testing.io;

    const out = try materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("scripts/convert.py", "print('hi')"),
        fakeAsset("references/schemas.md", "# ref"),
        fakeAsset("README.md", "top level"),
    });
    defer alloc.free(out.dir);
    defer std.Io.Dir.cwd().deleteTree(io, out.dir) catch {};

    try testing.expectEqual(@as(usize, 3), out.file_count);
    // Absolute, so the model can pass it to bash/read_file directly.
    try testing.expect(std.fs.path.isAbsolute(out.dir));
    try testing.expect(std.mem.indexOf(u8, out.dir, "pabrik-skill-assets-pdf-") != null);

    // Two levels of nesting created, relative paths preserved verbatim —
    // the body refers to these strings and nothing renames them.
    const nested = try std.fs.path.join(alloc, &.{ out.dir, "scripts", "convert.py" });
    defer alloc.free(nested);
    const script_body = try std.Io.Dir.cwd().readFileAlloc(io, nested, alloc, std.Io.Limit.limited(1024));
    defer alloc.free(script_body);
    try testing.expectEqualStrings("print('hi')", script_body);

    const deep = try std.fs.path.join(alloc, &.{ out.dir, "references", "schemas.md" });
    defer alloc.free(deep);
    const deep_body = try std.Io.Dir.cwd().readFileAlloc(io, deep, alloc, std.Io.Limit.limited(1024));
    defer alloc.free(deep_body);
    try testing.expectEqualStrings("# ref", deep_body);

    const top = try std.fs.path.join(alloc, &.{ out.dir, "README.md" });
    defer alloc.free(top);
    const top_body = try std.Io.Dir.cwd().readFileAlloc(io, top, alloc, std.Io.Limit.limited(1024));
    defer alloc.free(top_body);
    try testing.expectEqualStrings("top level", top_body);
}

test "materializeAssetDir refuses a traversing / absolute / backslash rel_path" {
    const alloc = testing.allocator;
    const io = testing.io;

    // Each of these would land outside the directory we just created.
    // Silently skipping one would hand the model a body that points at a
    // file that does not exist, so every arm must be an error.
    try testing.expectError(error.UnsafeAssetPath, materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("../../etc/passwd", "pwned"),
    }));
    try testing.expectError(error.UnsafeAssetPath, materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("scripts/../../escape.py", "pwned"),
    }));
    try testing.expectError(error.UnsafeAssetPath, materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("/etc/passwd", "pwned"),
    }));
    // Backslash is a separator on Windows, so a path that is inert on
    // Linux is a traversal there.
    try testing.expectError(error.UnsafeAssetPath, materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("scripts\\..\\..\\escape.py", "pwned"),
    }));
    // NT drive prefix.
    try testing.expectError(error.UnsafeAssetPath, materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("C:payload", "pwned"),
    }));
    // Empty rel_path has no parent to write into.
    try testing.expectError(error.UnsafeAssetPath, materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("", "pwned"),
    }));

    // A legal name is not caught by the same substring rule: the guard is
    // about escaping, not about punctuation.
    try testing.expect(isSafeRelPath("scripts/run_eval.py"));
    try testing.expect(isSafeRelPath("agents/grader.md"));
    try testing.expect(!isSafeRelPath("a..b"));
}

test "materializeAssetDir refuses a name that is not a single path-safe token" {
    const alloc = testing.allocator;
    const io = testing.io;

    // `skill_name` is a path SEGMENT of the materialisation directory, so
    // the same guard the store's `isValidSkillName` applies to the row key
    // has to apply here. This is the traversal the old `remove_skill`
    // `deleteTree` guard used to exist for.
    try testing.expectError(error.InvalidSkillName, materializeAssetDir(io, alloc, "..", &.{
        fakeAsset("a.py", "x"),
    }));
    try testing.expectError(error.InvalidSkillName, materializeAssetDir(io, alloc, "a/b", &.{
        fakeAsset("a.py", "x"),
    }));
}

test "materializeAssetDir refuses an empty bundle instead of making an empty dir" {
    const alloc = testing.allocator;
    const io = testing.io;

    // `use_skill` returns `asset_dir: null` for a skill with no
    // companions; there is no directory at all in that case, so this must
    // not quietly create one.
    try testing.expectError(error.NoAssets, materializeAssetDir(io, alloc, "single-file", &.{}));
}
