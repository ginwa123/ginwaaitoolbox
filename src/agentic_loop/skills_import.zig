//! One-shot migration of the two on-disk skill directories into
//! Migration 101's `skills` and `skill_assets` tables.
//!
//! 39 skills are installed today: 22 under `~/.config/pabrik/skills/` and 17
//! under `<cwd>/.pabrik/skills/`. When the database stops being a cache of
//! the filesystem and becomes the source of truth, anything this importer
//! does not write is gone from the product. So the design goal here is not
//! "import cleanly", it is "never lose a skill silently": every directory
//! entry either becomes a row or becomes a named entry in
//! `ImportReport.skipped` with the reason why.
//!
//! Three properties the rest of the codebase depends on:
//!
//! - **Byte-exact bodies.** The `content` column is written with the
//!   bytes read from `SKILL.MD`, including the `---` frontmatter and
//!   including whatever trailing whitespace the author left. `skill_eval`
//!   identities are `sha256(body)`, so one normalised newline invalidates
//!   every cached verdict for that skill — silently, and with no way to
//!   tell a fresh run from a re-grade. Nothing in this file trims,
//!   re-encodes or reformats a body.
//! - **Idempotent.** Writes go through `skills_store.upsertSkill`, never a
//!   bare INSERT, so re-running updates the row in place and keeps its id
//!   (the id every `skill_assets` row points at). A second import of an
//!   unchanged directory writes the same rows with the same ids.
//! - **Non-destructive.** Nothing is deleted from disk. A revert of the
//!   migration is a revert of that migration, not a restore from a backup
//!   nobody made. The flip side — also deliberate — is that a skill
//!   deleted through the HTTP API reappears on the next import of that
//!   directory; see `skill_delete.zig`.
//!
//! Where each directory LANDS is a policy question this file refuses to
//! answer. "Global skills go to every workspace, local skills go to the
//! one whose project they live in" is a decision for the caller, so the
//! entry points take a `DirTarget` list and this file only knows how to
//! read a directory and write rows.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
/// `parseYamlFrontmatter` is used HERE and nowhere else in the read path:
/// this is the one moment the description moves out of the body and into
/// the `description` column. Every later read takes the column.
const skill_mod = pabrikcore.skill_mod;
const skills_store = @import("skills_store.zig");

/// The file that makes a directory a skill.
pub const SKILL_FILE_NAME = "SKILL.MD";

/// How deep to walk inside one skill directory looking for companions.
/// The deepest installed bundle is two levels (`skill-creator` has
/// `scripts/`, `references/`, `agents/`); the cap exists so a symlink
/// cycle or a pathological tree cannot turn a start-up import into an
/// unbounded walk.
pub const MAX_SKILL_DEPTH: usize = 8;

// =====================================================================
// Report
// =====================================================================

/// Why one directory entry did not become a row.
///
/// `not_a_directory` is not necessarily a problem: a README.md sitting in
/// the skills directory shows up here. The other variants mean a real
/// skill was left behind.
pub const SkipReason = enum {
    /// The directory name fails `isValidSkillName` (`.hidden`, `..`,
    /// `has space`, a name longer than 128 bytes). Checked BEFORE any file
    /// is opened, because the name becomes a path component.
    invalid_name,
    /// An entry in the skills directory that is not a skill folder.
    not_a_directory,
    /// A symlink inside a bundle. Not followed: it is either a cycle or a
    /// pointer outside the bundle, and materialising the target under a
    /// `rel_path` the body never mentions would be a surprise.
    symlinked_entry,
    /// No readable `SKILL.MD` in the directory.
    missing_skill_file,
    /// `SKILL.MD` is zero bytes.
    empty_skill_file,
    /// `SKILL.MD` is over `skills_store.MAX_CONTENT_BYTES`.
    body_too_large,
    /// `SKILL.MD` is not valid UTF-8, so it is binary, not a skill.
    body_not_utf8,
    /// A companion could not be read.
    companion_unreadable,
    /// A companion is over `skills_store.MAX_ASSET_BYTES`.
    companion_too_large,
    /// A companion is not valid UTF-8.
    companion_not_utf8,
    /// A `rel_path` that could escape the materialisation directory.
    unsafe_rel_path,
    /// The bundle nests deeper than `MAX_SKILL_DEPTH`.
    max_depth_exceeded,
    /// The skills directory itself could not be opened for a reason that
    /// is not "it is not there".
    skills_dir_unreadable,
};

/// One entry that did not become a row. All strings are allocator-owned.
pub const SkippedEntry = struct {
    /// The DIRECTORY name, which is always known — even when the
    /// frontmatter was unusable and there is no better identifier. An
    /// operator can always find this folder on disk with it.
    dir_name: []const u8,
    reason: SkipReason,
    /// The offending relative path, the I/O error name, or "" when the
    /// reason speaks for itself.
    detail: []const u8,
};

pub const ImportReport = struct {
    /// Rows CREATED, counted per (skill, destination workspace). A skill
    /// fanned out to three workspaces contributes three.
    skills_written: usize = 0,
    /// Rows that already held that name and were updated in place, same
    /// counting rule. On a second run of an unchanged import every skill
    /// lands here and `skills_written` is zero — which is the signal that
    /// a start-up import changed nothing.
    skills_updated: usize = 0,
    /// Companion rows written, across every skill written above.
    assets_written: usize = 0,
    /// Everything that did NOT make it in, with the reason. Empty is the
    /// only acceptable steady state; a caller that logs
    /// `skipped.len` at start-up turns a silent loss into a visible one.
    skipped: []const SkippedEntry = &.{},
};

pub fn freeImportReport(allocator: std.mem.Allocator, report: ImportReport) void {
    for (report.skipped) |s| {
        allocator.free(s.dir_name);
        allocator.free(s.detail);
    }
    if (report.skipped.len > 0) allocator.free(report.skipped);
}

/// A skills directory and the workspaces that should receive it.
///
/// The fan-out lives here rather than inside the importer because it is
/// policy: global skills to every workspace, local skills to the one whose
/// `workspace_items.path` matches the project, and a brand-new workspace
/// gets the global set at provision time. A skill wanted in ten workspaces
/// is ten rows, and the caller is the only thing that knows which ten.
pub const DirTarget = struct {
    /// `~/.config/pabrik/skills` or `<project>/.pabrik/skills`, resolved
    /// against the process cwd. Ignored when `open_dir` is set.
    dir: []const u8 = "",
    /// An ALREADY-OPEN handle to that directory, for a caller that has
    /// one. Preferred whenever it exists: resolving a relative path
    /// through `std.Io.Dir.cwd()` is the cross-platform trap
    /// `skills.zig` documents (it fails outright on Linux), and
    /// `std.testing.tmpDir` hands out a handle plus a leaf name rather
    /// than a path that can be re-opened.
    open_dir: ?std.Io.Dir = null,
    /// Every workspace that should end up holding these skills. Empty
    /// means "nowhere", and the directory is then not read at all —
    /// reporting its skills as skipped would blame them for a decision
    /// this importer was handed.
    workspace_ids: []const []const u8,
};

/// The importer's error surface is exactly the store's, plus "you handed
/// me no directory". A malformed SKILL.MD is NOT an error here — it is a
/// skip, recorded by name. A database failure IS an error, because
/// failing loudly is the whole point of not losing skills quietly.
pub const ImportError = skills_store.ListSkillsError ||
    skills_store.GetSkillError ||
    skills_store.UpsertSkillError ||
    skills_store.ReplaceAssetsError ||
    error{SkillsDirRequired};

// =====================================================================
// Entry points
// =====================================================================

/// Read one skills directory into one workspace.
///
/// The shape most callers want: `~/.config/pabrik/skills` or one project's
/// `.pabrik/skills`, one destination. For the two-directory case with a
/// fan-out policy, use `importFromTargets`.
pub fn importFromDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    skills_dir: []const u8,
) ImportError!ImportReport {
    return importFromTargets(io, allocator, db, &.{
        .{ .dir = skills_dir, .workspace_ids = &.{workspace_id} },
    });
}

/// Read every directory in `targets`, writing each one's skills into each
/// of that target's workspaces.
///
/// Pass two targets — one global, one project-local — and this is the
/// "both directories" import. Each directory is read from disk ONCE even
/// when it fans out to several workspaces.
pub fn importFromTargets(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    targets: []const DirTarget,
) ImportError!ImportReport {
    var report: ImportReport = .{};
    var skipped: std.ArrayList(SkippedEntry) = .empty;
    errdefer {
        freeSkipped(allocator, skipped.items);
        skipped.deinit(allocator);
    }

    for (targets) |target| {
        if (target.workspace_ids.len == 0) {
            std.log.warn(
                "skills_import: {s} has no destination workspace; not reading it",
                .{target.dir},
            );
            continue;
        }

        var loaded: std.ArrayList(LoadedSkill) = .empty;
        defer {
            freeLoaded(allocator, loaded.items);
            loaded.deinit(allocator);
        }
        if (target.open_dir) |handle| {
            try loadDir(io, allocator, target.dir, handle, &loaded, &skipped);
        } else {
            if (target.dir.len == 0) return error.SkillsDirRequired;
            try openAndLoadDir(io, allocator, target.dir, &loaded, &skipped);
        }

        for (target.workspace_ids) |workspace_id| {
            try writeSkills(allocator, db, workspace_id, loaded.items, &report);
        }
    }

    report.skipped = try skipped.toOwnedSlice(allocator);
    return report;
}

// =====================================================================
// Read phase
// =====================================================================

/// A skill as it exists on disk, fully loaded, ready to be written to any
/// number of workspaces. Read once per directory, written N times.
const LoadedSkill = struct {
    /// Row name. The frontmatter's `name:` when it parses AND passes
    /// `isValidSkillName`, else the directory name. The frontmatter wins
    /// because that is the identity the old handlers resolved by and the
    /// one `use_skill({name})` is called with; the fallback exists so a
    /// skill with broken frontmatter is renamed rather than dropped.
    name: []const u8,
    description: []const u8,
    /// Byte-exact SKILL.MD, frontmatter included.
    body: []const u8,
    /// Companion files, `rel_path` relative to the SKILL DIRECTORY (so
    /// `scripts/convert.py`, never `pdf/scripts/convert.py`) — the path
    /// the body refers to, and the path `use_skill` materialises.
    assets: []skills_store.SkillAssetInput,
};

fn freeLoaded(allocator: std.mem.Allocator, items: []const LoadedSkill) void {
    for (items) |s| {
        allocator.free(s.name);
        allocator.free(s.description);
        allocator.free(s.body);
        for (s.assets) |a| {
            allocator.free(a.rel_path);
            allocator.free(a.content);
        }
        if (s.assets.len > 0) allocator.free(s.assets);
    }
}

fn freeSkipped(allocator: std.mem.Allocator, items: []const SkippedEntry) void {
    for (items) |s| {
        allocator.free(s.dir_name);
        allocator.free(s.detail);
    }
}

fn recordSkip(
    allocator: std.mem.Allocator,
    skipped: *std.ArrayList(SkippedEntry),
    dir_name: []const u8,
    reason: SkipReason,
    detail: []const u8,
) !void {
    // Logged AND recorded: the record is what an operator reads after the
    // fact, and the log is what reaches them the one time they are looking
    // at the console. Neither alone is enough — a report nobody reads and a
    // line nobody scrolls back to are the same silence.
    std.log.warn(
        "skills_import: skipped '{s}': {s}{s}{s}",
        .{
            dir_name,
            @tagName(reason),
            if (detail.len > 0) ": " else "",
            detail,
        },
    );
    try skipped.append(allocator, .{
        .dir_name = try allocator.dupe(u8, dir_name),
        .reason = reason,
        .detail = try allocator.dupe(u8, detail),
    });
}

/// Open `skills_dir` and read every skill in it.
fn openAndLoadDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    skills_dir: []const u8,
    loaded: *std.ArrayList(LoadedSkill),
    skipped: *std.ArrayList(SkippedEntry),
) !void {
    // follow_symlinks = true here (the default) so a symlinked skills
    // directory still opens; the recursion into a skill's own
    // subdirectories uses false.
    const dir = std.Io.Dir.cwd().openDir(io, skills_dir, .{ .iterate = true }) catch |err| switch (err) {
        // A machine with no `~/.config/pabrik/skills` has nothing to
        // import, and that is not a skip worth reporting — reporting it
        // would put a permanent entry in every fresh install's report.
        error.FileNotFound, error.NotDir, error.BadPathName => return,
        else => |e| {
            try recordSkip(allocator, skipped, skills_dir, .skills_dir_unreadable, @errorName(e));
            return;
        },
    };
    defer std.Io.Dir.close(dir, io);

    try loadDir(io, allocator, skills_dir, dir, loaded, skipped);
}

/// Every skill in one already-open directory, plus everything in it that
/// did not qualify. `label` names the directory in a skip record and is
/// only used for a whole-directory failure, so it may be empty when the
/// caller passed a handle instead of a path.
fn loadDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    label: []const u8,
    dir: std.Io.Dir,
    loaded: *std.ArrayList(LoadedSkill),
    skipped: *std.ArrayList(SkippedEntry),
) !void {
    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(io) catch |err| {
            try recordSkip(allocator, skipped, label, .skills_dir_unreadable, @errorName(err));
            break;
        } orelse break;

        if (entry.kind != .directory) {
            try recordSkip(allocator, skipped, entry.name, .not_a_directory, "");
            continue;
        }
        try loadSkill(io, allocator, dir, entry.name, loaded, skipped);
    }
}

fn loadSkill(
    io: std.Io,
    allocator: std.mem.Allocator,
    skills_dir_handle: std.Io.Dir,
    dir_name: []const u8,
    loaded: *std.ArrayList(LoadedSkill),
    skipped: *std.ArrayList(SkippedEntry),
) !void {
    // Before any path is built from the name. `isValidSkillName` is the
    // same guard `use_skill` relies on when it joins the name onto a
    // materialisation directory, so a name that fails here would fail
    // there too — the row would be unusable the moment it was written.
    if (!skills_store.isValidSkillName(dir_name)) {
        try recordSkip(allocator, skipped, dir_name, .invalid_name, "");
        return;
    }

    var dir = skills_dir_handle.openDir(io, dir_name, .{ .iterate = true }) catch |err| {
        try recordSkip(allocator, skipped, dir_name, .missing_skill_file, @errorName(err));
        return;
    };
    defer std.Io.Dir.close(dir, io);

    // Limit one byte over the cap so an oversized file is DETECTED rather
    // than surfacing as `error.StreamTooLong`, which would be
    // indistinguishable from a read failure.
    const body = dir.readFileAlloc(
        io,
        SKILL_FILE_NAME,
        allocator,
        .limited(skills_store.MAX_CONTENT_BYTES + 1),
    ) catch |err| {
        try recordSkip(allocator, skipped, dir_name, .missing_skill_file, @errorName(err));
        return;
    };
    if (body.len > skills_store.MAX_CONTENT_BYTES) {
        allocator.free(body);
        try recordSkip(allocator, skipped, dir_name, .body_too_large, "");
        return;
    }
    if (body.len == 0) {
        allocator.free(body);
        try recordSkip(allocator, skipped, dir_name, .empty_skill_file, "");
        return;
    }
    if (!std.unicode.utf8ValidateSlice(body)) {
        allocator.free(body);
        try recordSkip(allocator, skipped, dir_name, .body_not_utf8, "");
        return;
    }
    errdefer allocator.free(body);

    // Name and description. `parseYamlFrontmatter` returns null when the
    // file has no usable `--- … ---` block; that is not a reason to drop
    // the skill, because the directory name is a perfectly good identity
    // and a model can still call `use_skill` with it.
    //
    // The two copies happen INSIDE the `if` block, while `parsed` is still
    // alive: its `defer` frees the parser's own strings at the end of that
    // block, so a copy taken after it would dupe a dangling slice. Every
    // branch therefore ends up owning exactly one `name` and one
    // `description`, and `LoadedSkill` never holds a borrowed string that
    // `freeLoaded` would then try to free.
    var row_name: ?[]const u8 = null;
    var row_description: ?[]const u8 = null;
    errdefer {
        if (row_name) |n| allocator.free(n);
        if (row_description) |d| allocator.free(d);
    }

    if (skill_mod.parseYamlFrontmatter(allocator, body)) |parsed| {
        defer {
            allocator.free(parsed.name);
            allocator.free(parsed.description);
        }
        if (skills_store.isValidSkillName(parsed.name)) {
            if (!std.mem.eql(u8, parsed.name, dir_name)) {
                std.log.debug(
                    "skills_import: '{s}' declares name '{s}'; the declared name wins",
                    .{ dir_name, parsed.name },
                );
            }
            row_name = try allocator.dupe(u8, parsed.name);
        } else {
            std.log.warn(
                "skills_import: '{s}' declares unusable name '{s}'; using the directory name",
                .{ dir_name, parsed.name },
            );
            row_name = try allocator.dupe(u8, dir_name);
        }
        row_description = try allocator.dupe(u8, parsed.description);
    } else {
        std.log.warn(
            "skills_import: '{s}' has no parseable frontmatter; importing with an empty description",
            .{dir_name},
        );
        row_name = try allocator.dupe(u8, dir_name);
        row_description = try allocator.dupe(u8, "");
    }
    const name = row_name.?;
    const description = row_description.?;

    var assets: std.ArrayList(skills_store.SkillAssetInput) = .empty;
    errdefer {
        for (assets.items) |a| {
            allocator.free(a.rel_path);
            allocator.free(a.content);
        }
        assets.deinit(allocator);
    }
    try collectAssets(io, allocator, dir, dir_name, "", 0, skipped, &assets);

    const owned_assets = try assets.toOwnedSlice(allocator);
    errdefer {
        for (owned_assets) |a| {
            allocator.free(a.rel_path);
            allocator.free(a.content);
        }
        if (owned_assets.len > 0) allocator.free(owned_assets);
    }

    try loaded.append(allocator, .{
        .name = name,
        .description = description,
        .body = body,
        .assets = owned_assets,
    });
    std.log.debug("skills_import: read '{s}' ({d} companion file(s))", .{ dir_name, owned_assets.len });
}

/// Walk one skill directory collecting every companion file.
///
/// `rel_prefix` is the path of the directory being walked relative to the
/// SKILL DIRECTORY — "" at the top, "scripts/" one level in — which is what
/// lands in `SkillAssetInput.rel_path`. The body refers to those paths and
/// `use_skill` recreates them, so the stored path has to be exactly the
/// one the author wrote.
fn collectAssets(
    io: std.Io,
    allocator: std.mem.Allocator,
    skill_dir: std.Io.Dir,
    skill_dir_name: []const u8,
    rel_prefix: []const u8,
    depth: usize,
    skipped: *std.ArrayList(SkippedEntry),
    out: *std.ArrayList(skills_store.SkillAssetInput),
) !void {
    if (depth > MAX_SKILL_DEPTH) {
        // `detail` is duped by recordSkip, so the borrowed prefix is fine
        // here — an allocPrint would be a second copy nobody frees.
        try recordSkip(allocator, skipped, skill_dir_name, .max_depth_exceeded, rel_prefix);
        return;
    }

    var iter = skill_dir.iterate();
    while (true) {
        const entry = iter.next(io) catch |err| {
            try recordSkip(allocator, skipped, skill_dir_name, .symlinked_entry, @errorName(err));
            break;
        } orelse break;

        // The body's own file is not a companion of itself.
        if (depth == 0 and std.mem.eql(u8, entry.name, SKILL_FILE_NAME)) continue;

        // `defer`, not `errdefer`: the block ends every iteration, and the
        // success path copies the path into the asset row rather than
        // handing over this buffer. An `errdefer` here leaks one allocation
        // per companion file, on every import, forever.
        const rel_path = try std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ rel_prefix, entry.name },
        );
        defer allocator.free(rel_path);

        // A name assembled from directory entries cannot contain `..`
        // today, but this is the guard the store's own contract promises,
        // and it is cheaper here than discovering the hole after some
        // future caller starts building rel_paths from file contents.
        if (!isSafeRelPath(rel_path)) {
            try recordSkip(allocator, skipped, skill_dir_name, .unsafe_rel_path, rel_path);
            continue;
        }

        switch (entry.kind) {
            .directory => {
                // follow_symlinks = false: a link loop would otherwise walk
                // until MAX_SKILL_DEPTH, and a link out of the bundle would
                // materialise a file the body never mentions.
                const sub = skill_dir.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch |err| {
                    try recordSkip(allocator, skipped, skill_dir_name, .symlinked_entry, @errorName(err));
                    continue;
                };
                defer std.Io.Dir.close(sub, io);

                const nested_prefix = try std.fmt.allocPrint(allocator, "{s}/", .{rel_path});
                defer allocator.free(nested_prefix);
                try collectAssets(io, allocator, sub, skill_dir_name, nested_prefix, depth + 1, skipped, out);
            },
            .sym_link => {
                try recordSkip(allocator, skipped, skill_dir_name, .symlinked_entry, rel_path);
            },
            else => try readCompanion(io, allocator, skill_dir, skill_dir_name, entry.name, rel_path, skipped, out),
        }
    }
}

fn readCompanion(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    skill_dir_name: []const u8,
    file_name: []const u8,
    rel_path: []const u8,
    skipped: *std.ArrayList(SkippedEntry),
    out: *std.ArrayList(skills_store.SkillAssetInput),
) !void {
    const content = dir.readFileAlloc(
        io,
        file_name,
        allocator,
        .limited(skills_store.MAX_ASSET_BYTES + 1),
    ) catch |err| {
        try recordSkip(
            allocator,
            skipped,
            skill_dir_name,
            .companion_unreadable,
            try std.fmt.allocPrint(allocator, "{s}: {s}", .{ rel_path, @errorName(err) }),
        );
        return;
    };
    if (content.len > skills_store.MAX_ASSET_BYTES) {
        allocator.free(content);
        try recordSkip(allocator, skipped, skill_dir_name, .companion_too_large, rel_path);
        return;
    }
    // The store's columns are TEXT. A binary companion would be written as
    // a byte blob and come back out of SQLite mangled, so it is refused
    // here and NAMED here rather than becoming a corrupt row nobody
    // notices until `use_skill` fails to materialise it.
    if (!std.unicode.utf8ValidateSlice(content)) {
        allocator.free(content);
        try recordSkip(allocator, skipped, skill_dir_name, .companion_not_utf8, rel_path);
        return;
    }
    errdefer allocator.free(content);

    const owned_rel_path = try allocator.dupe(u8, rel_path);
    errdefer allocator.free(owned_rel_path);

    try out.append(allocator, .{
        .rel_path = owned_rel_path,
        // Byte-exact. Not trimmed, not re-encoded: a companion is a script
        // the model may RUN, and normalising it would change behaviour.
        .content = content,
    });
}

/// True when `rel_path` is safe to hand to `use_skill`'s materialisation
/// directory: relative, no `..`, no `.`, no backslash, no empty or
/// trailing component.
///
/// Exported so the guard has a test of its own and so a future caller that
/// builds a `rel_path` from anything other than directory entries can be
/// checked against the same rule instead of re-deriving it.
pub fn isSafeRelPath(rel_path: []const u8) bool {
    if (rel_path.len == 0) return false;
    // A backslash is a separator on Windows and a legal filename byte
    // everywhere else; a rel_path containing one means the caller built it
    // on the wrong platform, and writing it out would resolve differently
    // than it was validated.
    if (std.mem.indexOfScalar(u8, rel_path, '\\') != null) return false;
    // Covers `/etc/passwd`, `\\server\share` and the Windows drive form
    // `C:\\x`, which `std.fs.path.isAbsolute` refuses to recognise when the
    // build target is POSIX. A rel_path is validated on whatever platform
    // imported it and may be materialised on another.
    if (std.fs.path.isAbsolute(rel_path)) return false;
    const first = rel_path[0];
    if (first == '/' or first == '\\') return false;
    if (std.ascii.isAlphabetic(first) and rel_path.len > 1 and rel_path[1] == ':') return false;

    var it = std.mem.splitScalar(u8, rel_path, '/');
    while (it.next()) |segment| {
        // Covers a leading "/" ("/etc/passwd" splits to "" then "etc"),
        // a doubled "//", and a trailing "/".
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

// =====================================================================
// Write phase
// =====================================================================

fn writeSkills(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    loaded: []const LoadedSkill,
    report: *ImportReport,
) ImportError!void {
    for (loaded) |skill| {
        // Read before writing so the report can separate "new row" from
        // "row already there, updated". That difference is the one signal
        // that tells an operator whether an import actually changed
        // anything — on a steady-state start-up every skill lands here.
        const existing = skills_store.getSkillByName(allocator, db, workspace_id, skill.name) catch |err| switch (err) {
            error.NotFound, error.WorkspaceIdNameRequired => null,
            error.QueryFailed => return error.QueryFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (existing) |row| {
            skills_store.freeSkillRow(allocator, row);
            report.skills_updated += 1;
        } else {
            report.skills_written += 1;
        }

        const written = try skills_store.upsertSkill(allocator, db, .{
            .workspace_id = workspace_id,
            .name = skill.name,
            .description = skill.description,
            .content = skill.body,
        });
        skills_store.freeSkillRow(allocator, written);

        // Called even for a single-file skill, i.e. with an EMPTY asset
        // list. `replaceAssets` replaces rather than merges, so this is
        // what makes the database match the directory exactly: a companion
        // deleted from disk disappears from the database, and a bundle that
        // lost a file stops pointing at one.
        try skills_store.replaceAssets(allocator, db, workspace_id, skill.name, skill.assets);
        report.assets_written += skill.assets.len;
    }
}

// ============================================================================
// skills_import — inline tests
// ============================================================================
//
// The fixture is a REAL temporary directory holding two skills: one a
// single `SKILL.MD`, one a bundle with a `scripts/` subdirectory. The
// in-memory database is the same Migration 101 schema `skills_store`
// tests against, so a store/importer mismatch fails here.
//
// Each case answers one question:
//
//   1. Does a skill land with the name and description its frontmatter
//      declares?
//   2. Does a companion land at the path the BODY refers to, rather than
//      at a path rooted at the skill directory?
//   3. Is the body byte-exact, frontmatter included?
//   4. Is a second import a no-op that keeps every id?
//   5. Is nothing deleted from disk?
//   6. Does a skipped skill get a NAME and a REASON?
//   7. Can a `rel_path` escape the materialisation directory?

const testing = std.testing;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// The `skills_store` fixture, unchanged: in-memory database plus the real
/// Migration 101 DDL imported from the migration file rather than re-typed.
fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try migration.Migration102CreateSkills.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

/// Write a file under `dir`, creating every parent directory. Bytes are
/// written verbatim — one fixture companion is deliberately invalid UTF-8
/// to exercise the binary-companion skip.
fn writeFixture(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    data: []const u8,
) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        var parent_dir = try dir.createDirPathOpen(io, parent, .{});
        defer std.Io.Dir.close(parent_dir, io);
        try parent_dir.writeFile(io, .{
            .sub_path = std.fs.path.basename(sub_path),
            .data = data,
        });
    } else {
        try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    }
}

const SIMPLE_BODY =
    \\---
    \\name: zig-trap
    \\description: The `std.mem.trimRight` trap.
    \\---
    \\
    \\# Zig trap
    \\
    \\Body line, then a tab-indented line and a trailing-space line:
    \\  \tindented with a tab
    \\trailing spaces here. 
;

/// Byte-exact, including the trailing space on this line — a normalising
/// importer would silently drop it and change the sha256.
const BUNDLE_BODY =
    \\---
    \\name: pdf
    \\description: Work with PDFs.
    \\---
    \\
    \\Run `scripts/convert.py` to convert.
;

const SCRIPT = "print('hi')  \n";

/// One single-file skill and one bundle, in a real directory.
fn seedSkillsDir(io: std.Io, dir: std.Io.Dir) !void {
    try writeFixture(io, dir, "zig-trap/SKILL.MD", SIMPLE_BODY);
    try writeFixture(io, dir, "pdf/SKILL.MD", BUNDLE_BODY);
    try writeFixture(io, dir, "pdf/scripts/convert.py", SCRIPT);
    try writeFixture(io, dir, "pdf/scripts/nested/helper.py", "HELPER = 1\n");
    try writeFixture(io, dir, "pdf/references/schemas.md", "# schemas\n");
}

/// `@import` the store for the assertion helpers rather than re-writing
/// `getSkillByName` at the call site.
const store = skills_store;

fn expectAssetContent(
    ctx: *TestCtx,
    workspace_id: []const u8,
    skill_name: []const u8,
    rel_path: []const u8,
    expected: []const u8,
) !void {
    const assets = try store.listAssets(testing.allocator, &ctx.db, workspace_id, skill_name);
    defer store.freeSkillAssetRows(testing.allocator, assets);
    for (assets) |a| {
        if (std.mem.eql(u8, a.rel_path, rel_path)) {
            try testing.expectEqualStrings(expected, a.content);
            return;
        }
    }
    std.debug.print(
        "no companion at '{s}'; found:",
        .{rel_path},
    );
    for (assets) |a| std.debug.print(" {s}", .{a.rel_path});
    std.debug.print("\n", .{});
    return error.AssetMissing;
}

fn countRows(ctx: *TestCtx, sql: []const u8) !usize {
    var q = try ctx.db.query(testing.allocator, sql, &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    return std.fmt.parseInt(usize, row.values[0], 10) catch 0;
}

fn findSkip(report: ImportReport, dir_name: []const u8) ?SkippedEntry {
    for (report.skipped) |s| {
        if (std.mem.eql(u8, s.dir_name, dir_name)) return s;
    }
    return null;
}

test "skills_import writes one row per skill with its declared name and description" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try seedSkillsDir(io, tmp.dir);

    const report = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = tmp.dir, .workspace_ids = &.{"ws_a"} },
    });
    defer freeImportReport(alloc, report);

    try testing.expectEqual(@as(usize, 2), report.skills_written);
    try testing.expectEqual(@as(usize, 0), report.skills_updated);
    try testing.expectEqual(@as(usize, 3), report.assets_written);
    try testing.expectEqual(@as(usize, 0), report.skipped.len);

    const trap = try store.getSkillByName(alloc, &ctx.db, "ws_a", "zig-trap");
    defer store.freeSkillRow(alloc, trap);
    try testing.expectEqualStrings("The `std.mem.trimRight` trap.", trap.description);

    const pdf = try store.getSkillByName(alloc, &ctx.db, "ws_a", "pdf");
    defer store.freeSkillRow(alloc, pdf);
    try testing.expectEqualStrings("Work with PDFs.", pdf.description);
}

test "skills_import stores a bundle companion at the path the body refers to" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try seedSkillsDir(io, tmp.dir);

    const report = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = tmp.dir, .workspace_ids = &.{"ws_a"} },
    });
    defer freeImportReport(alloc, report);

    // `scripts/convert.py`, NOT `pdf/scripts/convert.py`: the body says
    // "run `scripts/convert.py`" and `use_skill` materialises the row's
    // rel_path verbatim under the bundle's temp directory. Rooting it at
    // the skill directory would put the file where the body does not look.
    try expectAssetContent(&ctx, "ws_a", "pdf", "scripts/convert.py", SCRIPT);
    try expectAssetContent(&ctx, "ws_a", "pdf", "references/schemas.md", "# schemas\n");
    // Nested subdirectories keep their depth.
    try expectAssetContent(&ctx, "ws_a", "pdf", "scripts/nested/helper.py", "HELPER = 1\n");

    // The body itself is not a companion of itself.
    const assets = try store.listAssets(alloc, &ctx.db, "ws_a", "zig-trap");
    defer store.freeSkillAssetRows(alloc, assets);
    try testing.expectEqual(@as(usize, 0), assets.len);
}

test "skills_import writes the body byte-exact, frontmatter included" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try seedSkillsDir(io, tmp.dir);

    const report = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = tmp.dir, .workspace_ids = &.{"ws_a"} },
    });
    defer freeImportReport(alloc, report);

    // `skill_eval` identities are sha256(body). Trimming, re-encoding or
    // dropping the `---` block would change every hash, which invalidates
    // every cached verdict for the skill with no other visible symptom.
    const trap = try store.getSkillByName(alloc, &ctx.db, "ws_a", "zig-trap");
    defer store.freeSkillRow(alloc, trap);
    try testing.expectEqualStrings(SIMPLE_BODY, trap.content);
    try testing.expect(std.mem.startsWith(u8, trap.content, "---"));

    try expectAssetContent(&ctx, "ws_a", "pdf", "scripts/convert.py", SCRIPT);
    try testing.expect(std.mem.endsWith(u8, SCRIPT, " \n"));
}

test "skills_import is idempotent: a second run updates in place and keeps every id" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try seedSkillsDir(io, tmp.dir);

    const first = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = tmp.dir, .workspace_ids = &.{"ws_a"} },
    });
    defer freeImportReport(alloc, first);
    const second = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = tmp.dir, .workspace_ids = &.{"ws_a"} },
    });
    defer freeImportReport(alloc, second);

    // Nothing new, everything recognised as already present. This is the
    // steady state on every start-up after the first.
    try testing.expectEqual(@as(usize, 0), second.skills_written);
    try testing.expectEqual(@as(usize, 2), second.skills_updated);
    try testing.expectEqual(@as(usize, 0), second.skipped.len);

    // One row per skill and one row per companion — no UNIQUE collision, no
    // duplicate ids, no orphaned assets.
    try testing.expectEqual(@as(usize, 2), try countRows(&ctx, "SELECT COUNT(*) FROM skills"));
    try testing.expectEqual(@as(usize, 3), try countRows(&ctx, "SELECT COUNT(*) FROM skill_assets"));
}

test "skills_import deletes nothing from disk" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try seedSkillsDir(io, tmp.dir);

    const report = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = tmp.dir, .workspace_ids = &.{"ws_a"} },
    });
    defer freeImportReport(alloc, report);

    // Non-destructive by contract: a revert of the migration is a revert of
    // the migration, not a restore from a backup nobody made.
    try tmp.dir.access(io, "zig-trap/SKILL.MD", .{});
    try tmp.dir.access(io, "pdf/SKILL.MD", .{});
    try tmp.dir.access(io, "pdf/scripts/convert.py", .{});
}

test "skills_import reports a directory with no SKILL.MD instead of dropping it" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try seedSkillsDir(io, tmp.dir);
    try writeFixture(io, tmp.dir, "empty-skill/notes.md", "no SKILL.MD here\n");

    const report = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = tmp.dir, .workspace_ids = &.{"ws_a"} },
    });
    defer freeImportReport(alloc, report);

    // The two real skills still import: one bad directory does not abort
    // the import and take the rest with it.
    try testing.expectEqual(@as(usize, 2), report.skills_written);

    const skip = findSkip(report, "empty-skill") orelse {
        std.debug.print("unreported skips:", .{});
        for (report.skipped) |s| std.debug.print(" {s} ({s})", .{ s.dir_name, @tagName(s.reason) });
        std.debug.print("\n", .{});
        return error.SilentSkip;
    };
    try testing.expectEqual(SkipReason.missing_skill_file, skip.reason);
    // The reason says what went wrong; `detail` says WHICH FILE.
    try testing.expect(skip.detail.len > 0);
}

test "skills_import reports an unusable directory name rather than writing it" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(io, tmp.dir, "has space/SKILL.MD", "---\nname: has space\ndescription: d\n---\nbody\n");

    const report = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = tmp.dir, .workspace_ids = &.{"ws_a"} },
    });
    defer freeImportReport(alloc, report);

    try testing.expectEqual(@as(usize, 0), report.skills_written);
    const skip = findSkip(report, "has space") orelse return error.SilentSkip;
    try testing.expectEqual(SkipReason.invalid_name, skip.reason);
}

test "skills_import imports the skill but names a non-UTF-8 companion" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(io, tmp.dir, "pdf/SKILL.MD", BUNDLE_BODY);
    try writeFixture(io, tmp.dir, "pdf/scripts/convert.py", SCRIPT);
    // 0xFF 0xFE is not valid UTF-8 in any position.
    try writeFixture(io, tmp.dir, "pdf/assets/logo.bin", &[_]u8{ 0xFF, 0xFE, 0x00, 0x01 });

    const report = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = tmp.dir, .workspace_ids = &.{"ws_a"} },
    });
    defer freeImportReport(alloc, report);

    // The skill and its good companion survive; only the binary file is
    // refused, and it is refused BY NAME with a reason — the alternative
    // is a row that comes back out of SQLite mangled and fails at
    // materialisation time, where nothing says why.
    try testing.expectEqual(@as(usize, 1), report.skills_written);
    try testing.expectEqual(@as(usize, 1), report.assets_written);
    try expectAssetContent(&ctx, "ws_a", "pdf", "scripts/convert.py", SCRIPT);

    const skip = findSkip(report, "pdf") orelse return error.SilentSkip;
    try testing.expectEqual(SkipReason.companion_not_utf8, skip.reason);
    try testing.expectEqualStrings("assets/logo.bin", skip.detail);
}

test "skills_import reads both directories and fans one of them out" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var global = testing.tmpDir(.{ .iterate = true });
    defer global.cleanup();
    try writeFixture(io, global.dir, "pdf/SKILL.MD", BUNDLE_BODY);
    try writeFixture(io, global.dir, "pdf/scripts/convert.py", SCRIPT);

    var local = testing.tmpDir(.{ .iterate = true });
    defer local.cleanup();
    try writeFixture(io, local.dir, "zig-trap/SKILL.MD", SIMPLE_BODY);

    // The policy is the caller's, not the importer's: the global directory
    // goes to BOTH workspaces, the project-local one to the workspace whose
    // project it belongs to.
    const report = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = global.dir, .workspace_ids = &.{ "ws_a", "ws_b" } },
        .{ .open_dir = local.dir, .workspace_ids = &.{"ws_a"} },
    });
    defer freeImportReport(alloc, report);

    // One global skill x 2 workspaces + one local skill x 1 workspace.
    // `skills_written` counts ROWS created, not directories read: a skill
    // fanned out to N workspaces is N rows, which is the whole point of
    // the fan-out.
    try testing.expectEqual(@as(usize, 3), report.skills_written);
    try testing.expectEqual(@as(usize, 3), try countRows(&ctx, "SELECT COUNT(*) FROM skills"));

    // ws_b has the global skill and NOT the project-local one.
    const b = try store.getSkillByName(alloc, &ctx.db, "ws_b", "pdf");
    defer store.freeSkillRow(alloc, b);
    try testing.expectError(
        error.NotFound,
        store.getSkillByName(alloc, &ctx.db, "ws_b", "zig-trap"),
    );
}

test "skills_import does not read a directory with no destination workspace" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try seedSkillsDir(io, tmp.dir);

    const report = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = tmp.dir, .workspace_ids = &.{} },
    });
    defer freeImportReport(alloc, report);

    // Reading it and then reporting every skill as skipped would blame the
    // skills for a routing decision the caller made.
    try testing.expectEqual(@as(usize, 0), report.skills_written);
    try testing.expectEqual(@as(usize, 0), report.skipped.len);
}

test "skills_import ignores a skills directory that is not there" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A machine that never installed a global skills directory is the
    // normal case, not a skip worth a permanent line in every report.
    const report = try importFromDir(
        io,
        alloc,
        &ctx.db,
        "ws_a",
        ".zig-cache/tmp/definitely-not-here-9f3a",
    );
    defer freeImportReport(alloc, report);

    try testing.expectEqual(@as(usize, 0), report.skills_written);
    try testing.expectEqual(@as(usize, 0), report.skipped.len);
}

test "isSafeRelPath refuses every shape that could escape the bundle" {
    try testing.expect(isSafeRelPath("convert.py"));
    try testing.expect(isSafeRelPath("scripts/convert.py"));
    try testing.expect(isSafeRelPath("a/b/c/d.md"));

    // `use_skill` materialises assets under a temp directory and returns
    // it. A `rel_path` that escapes that directory writes outside it.
    try testing.expect(!isSafeRelPath(""));
    try testing.expect(!isSafeRelPath("/etc/passwd"));
    try testing.expect(!isSafeRelPath("../outside.py"));
    try testing.expect(!isSafeRelPath("scripts/../../outside.py"));
    try testing.expect(!isSafeRelPath("scripts/./convert.py"));
    try testing.expect(!isSafeRelPath("scripts\\convert.py"));
    try testing.expect(!isSafeRelPath("C:\\windows\\system32"));
    try testing.expect(!isSafeRelPath("scripts/"));
    try testing.expect(!isSafeRelPath("scripts//convert.py"));
    try testing.expect(!isSafeRelPath(".."));
}

test "skills_import replaces a companion set rather than merging it" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(io, tmp.dir, "pdf/SKILL.MD", BUNDLE_BODY);
    try writeFixture(io, tmp.dir, "pdf/scripts/convert.py", SCRIPT);

    const first = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = tmp.dir, .workspace_ids = &.{"ws_a"} },
    });
    defer freeImportReport(alloc, first);

    // The script is deleted from the bundle. A merge would leave the row
    // alive and the body would still tell the model to run a file that can
    // no longer be materialised.
    try tmp.dir.deleteFile(io, "pdf/scripts/convert.py");

    const second = try importFromTargets(io, alloc, &ctx.db, &.{
        .{ .open_dir = tmp.dir, .workspace_ids = &.{"ws_a"} },
    });
    defer freeImportReport(alloc, second);

    try testing.expectEqual(@as(usize, 0), second.assets_written);
    try testing.expectEqual(@as(usize, 0), try countRows(&ctx, "SELECT COUNT(*) FROM skill_assets"));
}
