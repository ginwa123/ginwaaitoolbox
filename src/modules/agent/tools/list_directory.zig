//! src/modules/agent/tools/list_directory.zig
//!
//! Agent tool: list first-level entries in a directory (like `ls <path>`).
//! Companion to `glob` (which finds files by pattern, recursive) —
//! `list_directory` answers "what's in this folder?" with one level.
//!
//! SECURITY: the input `path` MUST be relative (resolved against the
//! session's cwd by the exec wrapper before reaching here). Absolute
//! paths are rejected upstream — see path_security.zig. The
//! `dir_path_abs` parameter to `execute_list_directory` is expected to
//! be an absolute path (it's the result of the upstream resolver), and
//! is what we pass to `openDirAbsolute`.
//!
//! Spec: docs/superpowers/specs/2026-08-14-ban-absolute-paths-design.md
//! Plan: docs/superpowers/plans/2026-08-14-ban-absolute-paths.md (Task 5)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;

/// Per-entry result returned by the iterator. Owned by the caller (use
/// `freeEntries`).
pub const Entry = struct {
    name: []const u8,
    /// Absolute path, e.g. `/home/user/project/src/main.zig`.
    path: []const u8,
    is_directory: bool,
    is_symlink: bool,
};

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.path);
    }
    allocator.free(entries);
}

/// `dir_path_abs` MUST be an absolute path (validated by the upstream
/// exec wrapper). The function will NOT re-validate — that's the
/// wrapper's job.
///
/// Behaviour:
/// - Non-existent / non-directory path → returns `error.PathNotFound`
/// - Hidden entries (`.foo`) are skipped unless `hidden == true`
/// - `respect_ignore_files == true` (default) → entries ignored by
///   `git check-ignore` (when run from inside a git repo) are filtered
/// - Results sorted: directories first, then files, alphabetically
pub fn execute_list_directory(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path_abs: []const u8,
    hidden: bool,
    respect_ignore_files: bool,
) ![]Entry {
    var entries = std.ArrayList(Entry).empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.path);
        }
        entries.deinit(allocator);
    }

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path_abs, .{ .iterate = true }) catch {
        return error.PathNotFound;
    };
    defer std.Io.Dir.close(dir, io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const name = entry.name;
        if (name.len == 0) break;

        // Skip hidden files/folders unless caller asked for them.
        if (!hidden and name.len > 0 and name[0] == '.') continue;

        const is_dir = entry.kind == .directory;
        const is_link = entry.kind == .sym_link;
        const is_file = entry.kind == .file;

        if (!is_dir and !is_file) continue;

        // Gitignore check (when enabled). Spawn failures (no `git`
        // on PATH) are FALL-THROUGH-OK — treat as "not gitignored"
        // so the entry is shown rather than silently dropped.
        if (respect_ignore_files) {
            const git_result = std.process.run(allocator, io, .{
                .argv = &.{ "git", "-C", dir_path_abs, "check-ignore", name },
            }) catch blk: {
                break :blk std.process.RunResult{
                    .term = .{ .exited = 128 },
                    .stdout = &[_]u8{},
                    .stderr = &[_]u8{},
                };
            };
            defer allocator.free(git_result.stdout);
            defer allocator.free(git_result.stderr);
            if (git_result.term.exited == 0) continue; // gitignored → skip
        }

        const entry_name = allocator.dupe(u8, name) catch continue;
        const full_path = std.fs.path.join(allocator, &.{ dir_path_abs, name }) catch {
            allocator.free(entry_name);
            continue;
        };

        entries.append(allocator, Entry{
            .name = entry_name,
            .path = full_path,
            .is_directory = is_dir,
            .is_symlink = is_link,
        }) catch {
            allocator.free(entry_name);
            allocator.free(full_path);
            continue;
        };
    }

    // Sort: directories first, then files, alphabetically.
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            if (a.is_directory != b.is_directory) return a.is_directory;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.less);

    return entries.toOwnedSlice(allocator);
}

/// XML-serialise entries into the LLM-facing envelope.
pub fn toXml(allocator: std.mem.Allocator, entries: []const Entry, dir_path: []const u8) ![]u8 {
    var xml = std.ArrayList(u8).empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<directory_listing");
    try xml.print(allocator, " path=\"{s}\" count=\"{d}\"", .{ dir_path, entries.len });
    try xml.appendSlice(allocator, ">");
    for (entries) |e| {
        const tag: []const u8 = if (e.is_directory) "directory" else "file";
        try xml.print(allocator, "<{s} name=\"{s}\" path=\"{s}\" is_symlink=\"{s}\"/>", .{
            tag,
            e.name,
            e.path,
            if (e.is_symlink) "true" else "false",
        });
    }
    try xml.appendSlice(allocator, "</directory_listing>");

    return xml.toOwnedSlice(allocator);
}

/// Tool definition for the LLM-facing API.
pub const list_directory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_directory",
        .description =
        \\List first-level entries in a directory (like `ls <path>`).
        \\Companion to `glob` (which finds files by pattern, recursive).
        \\
        \\Respects `.gitignore` by default — entries ignored by git
        \\are filtered out. Hidden files (starting with `.`) are
        \\skipped unless `hidden=true`.
        \\
        \\Results are sorted: directories first, then files, alphabetically.
        \\Each entry is wrapped as `<directory name=... path=.../>` or
        \\`<file name=... path=.../>` inside a single `<directory_listing>`.
        \\
        \\Path is RELATIVE to the session's cwd by default. Absolute
        \\paths are accepted (passed through to openDirAbsolute).
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Directory to list. Absolute paths are accepted. Default: \".\" (the cwd itself).",
                },
                .{
                    .name = "hidden",
                    .type = "boolean",
                    .description = "Include hidden files/folders (starting with .). Default: false.",
                },
                .{
                    .name = "respect_ignore_files",
                    .type = "boolean",
                    .description = "Respect .gitignore (entries ignored by git are filtered out). Default: true. Set false to list gitignored paths (build/, .zig-cache/, .git/, etc.).",
                },
            },
            .required = &.{},
        },
    },
};
