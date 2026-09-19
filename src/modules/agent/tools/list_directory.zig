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

/// JSON payload mirrors the old `<directory_listing>` envelope 1:1:
/// `path`, `count`, and `entries` (one object per former `<file>` /
/// `<directory>` tag with `name`, `path`, `is_directory`, `is_symlink`).
/// `std.json` handles all escaping.
pub const ListDirectoryEntryJSON = struct {
    name: []const u8,
    path: []const u8,
    is_directory: bool,
    is_symlink: bool,
};

pub const ListDirectoryJSON = struct {
    path: []const u8,
    count: usize,
    entries: []ListDirectoryEntryJSON,
};

pub fn toJSON(allocator: std.mem.Allocator, entries: []const Entry, dir_path: []const u8) ![]u8 {
    const items = try allocator.alloc(ListDirectoryEntryJSON, entries.len);
    defer allocator.free(items);
    for (entries, 0..) |e, i| {
        items[i] = .{
            .name = e.name,
            .path = e.path,
            .is_directory = e.is_directory,
            .is_symlink = e.is_symlink,
        };
    }
    return try std.json.Stringify.valueAlloc(allocator, ListDirectoryJSON{
        .path = dir_path,
        .count = entries.len,
        .entries = items,
    }, .{});
}

/// Tool definition for the LLM-facing API.
pub const list_directory_tool_system_prompt =
    \\## List Directory Tool — Behavior
    \\Use `list_directory` to list first-level entries in a directory (like `ls`).
    \\- Respects `.gitignore`. Set `hidden=true` to include dotfiles.
    \\- Use to explore project structure before diving into files.
    \\
;

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
        \\Each entry is an object {name, path, is_directory, is_symlink}
        \\inside `entries`, with `path` and `count` alongside.
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
        .system_prompt = list_directory_tool_system_prompt,
    },
};

// src/modules/agent/tools/list_directory_test.zig
//
// Tests for the list_directory agent tool: first-level directory
// listing (ls-like). Companion to glob_test.zig (recursive pattern
// matching).
//
// These tests are RUN IN-ISOLATION against `testing.tmpDir(.{})`
// (Zig 0.16 stdlib helper). They do NOT touch ctx.cwd — they call
// `execute_list_directory` directly with an absolute path resolved by
// the test. The exec wrapper is tested in
// src/agentic_loop/tools_exec_list_directory_test.zig.

const builtin = @import("builtin");
const testing = std.testing;
const list_directory = @import("list_directory.zig");

const TestEnv = struct {
    tmp_dir: std.testing.TmpDir,
    root_abs: []const u8,

    fn deinit(self: *TestEnv, allocator: std.mem.Allocator) void {
        allocator.free(self.root_abs);
        self.tmp_dir.cleanup();
    }
};

fn setupRoot(allocator: std.mem.Allocator) !TestEnv {
    var tmp = std.testing.tmpDir(.{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    return .{ .tmp_dir = tmp, .root_abs = try allocator.dupe(u8, path_buf[0..n]) };
}

// -------------------------------------------------------------------------
// execute_list_directory — basic happy paths
// -------------------------------------------------------------------------

test "execute_list_directory: lists files and subdirs at the cwd" {
    const alloc = testing.allocator;
    var env = try setupRoot(alloc);
    defer env.deinit(alloc);

    // Create: 2 files + 1 subdir + 1 hidden file
    {
        const f1 = try env.tmp_dir.dir.createFile(testing.io, "foo.txt", .{});
        defer f1.close(testing.io);
        const f2 = try env.tmp_dir.dir.createFile(testing.io, "bar.md", .{});
        defer f2.close(testing.io);
        try env.tmp_dir.dir.createDirPath(testing.io, "subdir");
        const f3 = try env.tmp_dir.dir.createFile(testing.io, ".hidden", .{});
        defer f3.close(testing.io);
    }

    const entries = try list_directory.execute_list_directory(
        alloc,
        testing.io,
        env.root_abs,
        false, // hidden
        false, // respect_ignore_files (gitignore lookup skipped — speed)
    );
    defer list_directory.freeEntries(alloc, entries);

    try testing.expectEqual(@as(usize, 3), entries.len); // foo, bar, subdir — NOT .hidden

    // Dirs-first sort: subdir first.
    try testing.expectEqualStrings("subdir", entries[0].name);
    try testing.expect(entries[0].is_directory);
    try testing.expectEqualStrings("bar.md", entries[1].name);
    try testing.expect(!entries[1].is_directory);
    try testing.expectEqualStrings("foo.txt", entries[2].name);
    try testing.expect(!entries[2].is_directory);
}

test "execute_list_directory: hidden=true includes dotfiles" {
    const alloc = testing.allocator;
    var env = try setupRoot(alloc);
    defer env.deinit(alloc);

    {
        const f1 = try env.tmp_dir.dir.createFile(testing.io, "visible.txt", .{});
        defer f1.close(testing.io);
        const f2 = try env.tmp_dir.dir.createFile(testing.io, ".hidden", .{});
        defer f2.close(testing.io);
    }

    const entries = try list_directory.execute_list_directory(
        alloc,
        testing.io,
        env.root_abs,
        true,
        false,
    );
    defer list_directory.freeEntries(alloc, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    // alphabetical: .hidden < visible.txt
    try testing.expectEqualStrings(".hidden", entries[0].name);
    try testing.expectEqualStrings("visible.txt", entries[1].name);
}

test "execute_list_directory: returns PathNotFound for missing dir" {
    const alloc = testing.allocator;

    // Path that almost certainly does not exist.
    const result = list_directory.execute_list_directory(
        alloc,
        testing.io,
        "/tmp/this_path_definitely_does_not_exist_xyz_123",
        false,
        false,
    );
    try testing.expectError(error.PathNotFound, result);
}

test "execute_list_directory: respects .gitignore (gitignored entries filtered)" {
    const alloc = testing.allocator;
    var env = try setupRoot(alloc);
    defer env.deinit(alloc);

    // Git init + write a .gitignore that ignores *.log
    const git_init = std.process.run(alloc, testing.io, .{
        .argv = &.{ "git", "-C", env.root_abs, "init", "--initial-branch=main", "--quiet" },
    }) catch null;
    if (git_init) |gr| {
        alloc.free(gr.stdout);
        alloc.free(gr.stderr);
    }
    {
        try env.tmp_dir.dir.writeFile(testing.io, .{
            .sub_path = ".gitignore",
            .data = "*.log\n",
        });
    }

    {
        const f1 = try env.tmp_dir.dir.createFile(testing.io, "foo.log", .{});
        defer f1.close(testing.io);
        const f2 = try env.tmp_dir.dir.createFile(testing.io, "bar.txt", .{});
        defer f2.close(testing.io);
    }
    const entries = try list_directory.execute_list_directory(
        alloc,
        testing.io,
        env.root_abs,
        false,
        true,
    );
    defer list_directory.freeEntries(alloc, entries);

    // bar.txt should be present, foo.log should be filtered.
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("bar.txt", entries[0].name);
}

test "execute_list_directory: respect_ignore_files=false lists gitignored paths" {
    const alloc = testing.allocator;
    var env = try setupRoot(alloc);
    defer env.deinit(alloc);

    // Set up a gitignore like the previous test.
    const git_init = std.process.run(alloc, testing.io, .{
        .argv = &.{ "git", "-C", env.root_abs, "init", "--initial-branch=main", "--quiet" },
    }) catch null;
    if (git_init) |gr| {
        alloc.free(gr.stdout);
        alloc.free(gr.stderr);
    }
    {
        try env.tmp_dir.dir.writeFile(testing.io, .{
            .sub_path = ".gitignore",
            .data = "*.log\n",
        });
    }

    {
        const f1 = try env.tmp_dir.dir.createFile(testing.io, "foo.log", .{});
        defer f1.close(testing.io);
    }

    // respect_ignore_files=false → foo.log is listed despite .gitignore.
    const entries = try list_directory.execute_list_directory(
        alloc,
        testing.io,
        env.root_abs,
        false,
        false,
    );
    defer list_directory.freeEntries(alloc, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("foo.log", entries[0].name);
}

// -------------------------------------------------------------------------
// toJSON — JSON envelope
// -------------------------------------------------------------------------

test "toJSON: emits path, count and entries" {
    const alloc = testing.allocator;

    const entries = &[_]list_directory.Entry{
        .{ .name = "src", .path = "/proj/src", .is_directory = true, .is_symlink = false },
        .{ .name = "main.zig", .path = "/proj/main.zig", .is_directory = false, .is_symlink = false },
    };

    const payload = try list_directory.toJSON(alloc, entries, "/proj");
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("/proj", obj.get("path").?.string);
    try testing.expectEqual(@as(i64, 2), obj.get("count").?.integer);
    const items = obj.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("src", items[0].object.get("name").?.string);
    try testing.expectEqualStrings("/proj/src", items[0].object.get("path").?.string);
    try testing.expect(items[0].object.get("is_directory").?.bool);
    try testing.expect(!items[0].object.get("is_symlink").?.bool);
    try testing.expectEqualStrings("main.zig", items[1].object.get("name").?.string);
    try testing.expect(!items[1].object.get("is_directory").?.bool);
}

test "toJSON: empty list produces empty entries array" {
    const alloc = testing.allocator;
    const entries = &[_]list_directory.Entry{};

    const payload = try list_directory.toJSON(alloc, entries, "/empty");
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 0), obj.get("count").?.integer);
    try testing.expectEqual(@as(usize, 0), obj.get("entries").?.array.items.len);
}

// Schema contract — mirrors the static-contract tests in glob_test.zig
// -------------------------------------------------------------------------

test "list_directory_tool schema: name is list_directory, parameters object with 3 properties" {
    const params = list_directory.list_directory_tool.function.parameters;
    try testing.expectEqualStrings("object", params.type);
    try testing.expectEqual(@as(usize, 3), params.properties.len);

    var found_path = false;
    var found_hidden = false;
    var found_ignore = false;
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "path")) found_path = true;
        if (std.mem.eql(u8, prop.name, "hidden")) found_hidden = true;
        if (std.mem.eql(u8, prop.name, "respect_ignore_files")) found_ignore = true;
    }
    try testing.expect(found_path);
    try testing.expect(found_hidden);
    try testing.expect(found_ignore);

    // All properties are optional (path defaults to ".").
    try testing.expectEqual(@as(usize, 0), params.required.len);
}

test "list_directory_tool description mentions absolute paths policy" {
    const desc = list_directory.list_directory_tool.function.description;
    // Static-contract grep — guards against accidental removal of
    // the path-handling note when the description is edited. The
    // description wraps "Absolute paths are accepted" across one or
    // more lines, so we look for the substring "accepted" which
    // appears only in that policy phrase.
    if (std.mem.indexOf(u8, desc, "accepted") == null) {
        std.debug.print("!! list_directory description does not mention 'accepted' (path policy) !!\n", .{});
        try testing.expect(false);
    }
}
