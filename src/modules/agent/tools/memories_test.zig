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
