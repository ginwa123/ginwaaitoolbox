const std = @import("std");
const memories = @import("memories.zig");

// Helper: substring check
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// -------------------------------------------------------------------------
// get_local_memories_path_for_dir — pure function tests
// -------------------------------------------------------------------------

test "get_local_memories_path_for_dir returns <cwd>/.nalar/memories" {
    const alloc = std.testing.allocator;
    const path = memories.get_local_memories_path_for_dir(alloc, "/tmp/proj");
    defer if (path) |p| alloc.free(p);

    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/tmp/proj/.nalar/memories", path.?);
}

test "get_local_memories_path_for_dir returns null on empty cwd" {
    const alloc = std.testing.allocator;
    const path = memories.get_local_memories_path_for_dir(alloc, "");

    try std.testing.expect(path == null);
}

test "get_local_memories_path_for_dir does not resolve relative paths" {
    // Mirrors get_local_skills_path_for_dir semantics: no realpath
    // resolution. The caller (buildMessages) is responsible for passing
    // an absolute cwd, which it does via realPathFileAlloc.
    const alloc = std.testing.allocator;
    const path = memories.get_local_memories_path_for_dir(alloc, "relative/proj");
    defer if (path) |p| alloc.free(p);

    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("relative/proj/.nalar/memories", path.?);
}

test "get_local_memories_path_for_dir freed slice does not double-free" {
    // Sanity: returned slice is allocator-owned; freeing it does not crash.
    const alloc = std.testing.allocator;
    const path = memories.get_local_memories_path_for_dir(alloc, "/tmp/x");
    try std.testing.expect(path != null);
    alloc.free(path.?);
}

// -------------------------------------------------------------------------
// listMemoriesInDir — filesystem integration tests
// -------------------------------------------------------------------------

test "listMemoriesInDir returns empty slice when dir does not exist" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Point at a dir we know is absent.
    const missing_dir = "/tmp/nalar-list-memories-missing-dir";
    std.Io.Dir.cwd().deleteTree(io, missing_dir) catch {};

    const list = memories.listMemoriesInDir(alloc, io, missing_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "listMemoriesInDir returns empty slice when dir has no .md files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/nalar-list-memories-empty";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    // Drop a non-md file
    const txt_path = "/tmp/nalar-list-memories-empty/notes.txt";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "should be ignored");
    }

    const list = memories.listMemoriesInDir(alloc, io, tmp_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "listMemoriesInDir skips .txt, .json, and subdirectories" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/nalar-list-memories-filter";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    // Create a real .md file
    const md_path = "/tmp/nalar-list-memories-filter/keep.md";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, md_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "# Keep Me\n");
    }

    // A .txt file (must be filtered)
    const txt_path = "/tmp/nalar-list-memories-filter/skip.txt";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "ignore");
    }

    // A .json file (must be filtered)
    const json_path = "/tmp/nalar-list-memories-filter/skip.json";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, json_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "{}");
    }

    // A subdirectory that should be skipped (no SKILL.MD analogue for memories)
    try std.Io.Dir.cwd().createDirPath(io, "/tmp/nalar-list-memories-filter/subdir");

    const list = memories.listMemoriesInDir(alloc, io, tmp_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("keep.md", list[0].name);
    try std.testing.expectEqualStrings("Keep Me", list[0].title);
}

test "listMemoriesInDir lists multiple .md files with correct titles" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/nalar-list-memories-multi";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    const file1 = "/tmp/nalar-list-memories-multi/after-fix-test.md";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file1, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Write Regression Test First
            \\
            \\After fixing a tricky bug, write a regression test.
            \\
        );
    }

    const file2 = "/tmp/nalar-list-memories-multi/stderr-debug.md";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file2, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Use stderr for Debug Output
            \\
            \\Stderr can be redirected without affecting stdout.
            \\
        );
    }

    const list = memories.listMemoriesInDir(alloc, io, tmp_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 2), list.len);

    // We don't assert on order (dir.iterate order is OS-dependent),
    // just that both files appear with their expected titles.
    var found_after_fix = false;
    var found_stderr = false;
    for (list) |mem| {
        if (std.mem.eql(u8, mem.name, "after-fix-test.md")) {
            try std.testing.expectEqualStrings("Write Regression Test First", mem.title);
            try std.testing.expect(contains(mem.path, "after-fix-test.md"));
            found_after_fix = true;
        } else if (std.mem.eql(u8, mem.name, "stderr-debug.md")) {
            try std.testing.expectEqualStrings("Use stderr for Debug Output", mem.title);
            try std.testing.expect(contains(mem.path, "stderr-debug.md"));
            found_stderr = true;
        }
    }
    try std.testing.expect(found_after_fix);
    try std.testing.expect(found_stderr);
}

test "listMemoriesInDir falls back to filename stem when no H1" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/nalar-list-memories-no-h1";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    const file_path = "/tmp/nalar-list-memories-no-h1/random-name.md";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "Just some prose, no header.\n");
    }

    const list = memories.listMemoriesInDir(alloc, io, tmp_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("random-name.md", list[0].name);
    try std.testing.expectEqualStrings("random-name", list[0].title);
}

test "listMemoriesInDir finds H1 in second line (after blank line)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/nalar-list-memories-h1-second-line";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    const file_path = "/tmp/nalar-list-memories-h1-second-line/delayed-h1.md";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        // First line is prose, second line is the H1
        try std.Io.File.writeStreamingAll(f, io,
            \\Some intro prose that is NOT a heading.
            \\
            \\# The Real Title
            \\
            \\Body content.
            \\
        );
    }

    const list = memories.listMemoriesInDir(alloc, io, tmp_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("The Real Title", list[0].title);
}

test "listMemoriesInDir record path is absolute" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/nalar-list-memories-path-check";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    const file_path = "/tmp/nalar-list-memories-path-check/test.md";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "# Test\n");
    }

    const list = memories.listMemoriesInDir(alloc, io, tmp_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expect(std.fs.path.isAbsolute(list[0].path));
    try std.testing.expectEqualStrings(file_path, list[0].path);
}

test "listMemoriesInDir free contract: empty list is safe to free" {
    const alloc = std.testing.allocator;
    const list = &[_]memories.MemoryInfo{};
    memories.freeMemoriesList(alloc, list);
    // No panic — success criterion.
}

// -------------------------------------------------------------------------
// CRUD helpers — Chunk 1 of the memories-settings-menu plan.
//
// The CRUD functions (readMemoryFile / writeMemoryFile / deleteMemoryFile /
// memoryExists / editMemoryFile) all take a `*const std.process.Environ.Map`
// and resolve the global memories dir from `HOME` (or `XDG_CONFIG_HOME`).
// The tests below build a real `Environ.Map` with just `HOME` set to a
// temp directory under `/tmp/`. The temp dir is created with a unique
// name per test and torn down in a `defer` to keep the suite hermetic.
// -------------------------------------------------------------------------

/// Build a fresh `Environ.Map` with `HOME` set to `home_path`, plus a
/// per-test scratch dir under `/tmp/`. The returned path is freshly
/// created and must be removed with `deleteTree` by the caller. The
/// returned env map must be `deinit`'d by the caller.
fn setupMemoryHomeEnv(alloc: std.mem.Allocator, io: std.Io, scratch_name: []const u8) !struct {
    env: std.process.Environ.Map,
    home_path: []u8,
} {
    const home_path = try std.fs.path.join(alloc, &.{ "/tmp", scratch_name });
    errdefer alloc.free(home_path);

    // Clean any leftover state from a previous run, then create the dir.
    std.Io.Dir.cwd().deleteTree(io, home_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home_path);

    var env = std.process.Environ.Map.init(alloc);
    errdefer env.deinit();
    try env.put("HOME", home_path);
    return .{ .env = env, .home_path = home_path };
}

// -------------------------------------------------------------------------
// isValidMemoryName — pure validator tests
// -------------------------------------------------------------------------

test "isValidMemoryName rejects empty, whitespace, no .md, slashes, parent ref" {
    // Reject cases
    const reject = &[_][]const u8{
        "",                  // empty
        "   ",               // whitespace only
        "\t\r\n",            // other whitespace
        "foo",               // no .md
        "foo.txt",           // wrong extension
        "foo.MD",            // case-sensitive — only lowercase .md is OK
        "path/to.md",        // forward slash
        "path\\to.md",       // backslash
        "..",                // bare parent ref
        "../escape.md",      // starts with parent ref
        "subdir/../foo.md",  // contains parent ref anywhere
    };
    for (reject) |name| {
        try std.testing.expect(!memories.isValidMemoryName(name));
    }
}

test "isValidMemoryName accepts simple, hyphenated, and dotted .md names" {
    // Accept cases
    const accept = &[_][]const u8{
        "foo.md",
        "user-preferences.md",
        "user_preferences.md",
        "with.dots.in.name.md", // dots are OK; only ".." is rejected
        "a.md",
        "x-y-z.md",
        "  trimmed.md  ",      // leading/trailing whitespace is trimmed
    };
    for (accept) |name| {
        try std.testing.expect(memories.isValidMemoryName(name));
    }
}

// -------------------------------------------------------------------------
// readMemoryFile — invalid name + missing file
// -------------------------------------------------------------------------

test "readMemoryFile returns null on invalid name" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "nalar-crud-invalid-name");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // Invalid names should return null even if the file would otherwise
    // be readable — validation is the first guard.
    try std.testing.expect(memories.readMemoryFile(alloc, io, &env, "") == null);
    try std.testing.expect(memories.readMemoryFile(alloc, io, &env, "no-extension") == null);
    try std.testing.expect(memories.readMemoryFile(alloc, io, &env, "../escape.md") == null);
    try std.testing.expect(memories.readMemoryFile(alloc, io, &env, "sub/dir.md") == null);
}

test "readMemoryFile returns null on missing file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "nalar-crud-missing-read");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // No file written yet → null (not a panic / error throw).
    const result = memories.readMemoryFile(alloc, io, &env, "never-written.md");
    try std.testing.expect(result == null);
}

// -------------------------------------------------------------------------
// writeMemoryFile — creates parent dir, overwrites
// -------------------------------------------------------------------------

test "writeMemoryFile creates parent dir if missing" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "nalar-crud-create-parent");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // The memories/ subdir does not exist yet. writeMemoryFile must
    // create it (via createDirPath) before writing the file.
    try std.testing.expect(memories.writeMemoryFile(alloc, io, &env, "new.md", "# Hello\n"));

    // Read it back to confirm the write actually landed.
    const read_back = memories.readMemoryFile(alloc, io, &env, "new.md");
    try std.testing.expect(read_back != null);
    defer if (read_back) |r| alloc.free(r);
    try std.testing.expectEqualStrings("# Hello\n", read_back.?);
}

test "writeMemoryFile overwrites existing file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "nalar-crud-overwrite");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // First write
    try std.testing.expect(memories.writeMemoryFile(alloc, io, &env, "mem.md", "v1 content"));
    {
        const r1 = memories.readMemoryFile(alloc, io, &env, "mem.md");
        try std.testing.expect(r1 != null);
        defer if (r1) |r| alloc.free(r);
        try std.testing.expectEqualStrings("v1 content", r1.?);
    }
    // Overwrite with new content
    try std.testing.expect(memories.writeMemoryFile(alloc, io, &env, "mem.md", "v2 content (longer)"));
    {
        const r2 = memories.readMemoryFile(alloc, io, &env, "mem.md");
        try std.testing.expect(r2 != null);
        defer if (r2) |r| alloc.free(r);
        try std.testing.expectEqualStrings("v2 content (longer)", r2.?);
    }
}

// -------------------------------------------------------------------------
// memoryExists — stat-based check
// -------------------------------------------------------------------------

test "memoryExists: false on missing, true after write, false after delete" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "nalar-crud-exists");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // Missing → false
    try std.testing.expect(!memories.memoryExists(alloc, io, &env, "absent.md"));

    // Write → true
    try std.testing.expect(memories.writeMemoryFile(alloc, io, &env, "present.md", "hello"));
    try std.testing.expect(memories.memoryExists(alloc, io, &env, "present.md"));

    // Delete → false
    try std.testing.expect(memories.deleteMemoryFile(alloc, io, &env, "present.md"));
    try std.testing.expect(!memories.memoryExists(alloc, io, &env, "present.md"));
}

// -------------------------------------------------------------------------
// deleteMemoryFile — idempotent
// -------------------------------------------------------------------------

test "deleteMemoryFile is idempotent (returns true on missing)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "nalar-crud-idem-delete");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // Delete a file that was never written — must return true (idempotent).
    try std.testing.expect(memories.deleteMemoryFile(alloc, io, &env, "never.md"));

    // And on an invalid name — must return false (validation is the
    // first guard, so an invalid name short-circuits to false before
    // we even check the FS).
    try std.testing.expect(!memories.deleteMemoryFile(alloc, io, &env, "no-ext"));
    try std.testing.expect(!memories.deleteMemoryFile(alloc, io, &env, "../escape.md"));
}

// -------------------------------------------------------------------------
// editMemoryFile — fails on missing
// -------------------------------------------------------------------------

test "editMemoryFile returns false when target does not exist" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "nalar-crud-edit-missing");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // Edit on a file that was never written → false.
    const result = try memories.editMemoryFile(alloc, io, &env, "ghost.md", "replacement");
    try std.testing.expect(!result);

    // And the file must NOT have been created as a side-effect — the
    // whole point of edit (vs write) is to require pre-existence.
    try std.testing.expect(!memories.memoryExists(alloc, io, &env, "ghost.md"));
}
