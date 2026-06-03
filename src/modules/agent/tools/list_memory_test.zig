const std = @import("std");
const list_memory = @import("list_memory.zig");
const memories = list_memory.memories;

// Helper: substring check
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// -------------------------------------------------------------------------
// Pure serialization tests (no filesystem)
// -------------------------------------------------------------------------

test "toXml on empty list produces <memories></memories>" {
    const alloc = std.testing.allocator;
    const list = &[_]memories.MemoryInfo{};

    const xml = try list_memory.toXml(alloc, list);
    defer alloc.free(xml);

    try std.testing.expect(std.mem.startsWith(u8, xml, "<memories>"));
    try std.testing.expect(std.mem.endsWith(u8, xml, "</memories>"));
    // No <memory> elements in an empty list
    try std.testing.expect(!contains(xml, "<memory>"));
}

test "toXml escapes special characters in memory fields" {
    const alloc = std.testing.allocator;
    const list = &[_]memories.MemoryInfo{
        .{
            .name = "weird <name>.md",
            .title = "Title & more",
            .path = "/path/with \"quotes\"",
            .size = 42,
        },
    };

    const xml = try list_memory.toXml(alloc, list);
    defer alloc.free(xml);

    // The wrapper tags are present
    try std.testing.expect(contains(xml, "<memories>"));
    try std.testing.expect(contains(xml, "<memory>"));
    // Special chars are escaped
    try std.testing.expect(contains(xml, "&lt;name&gt;"));
    try std.testing.expect(contains(xml, "&amp; more"));
    try std.testing.expect(contains(xml, "&quot;"));
    // Size is rendered as digits
    try std.testing.expect(contains(xml, "<size>42</size>"));
}

test "toJson on empty list produces {\"memories\":[]}" {
    const alloc = std.testing.allocator;
    const list = &[_]memories.MemoryInfo{};

    const json = try list_memory.toJson(alloc, list);
    defer alloc.free(json);

    try std.testing.expect(std.mem.startsWith(u8, json, "{"));
    try std.testing.expect(std.mem.endsWith(u8, json, "}"));
    try std.testing.expect(contains(json, "\"memories\":[]"));
}

test "toJson includes all four fields per memory" {
    const alloc = std.testing.allocator;
    const list = &[_]memories.MemoryInfo{
        .{
            .name = "user-prefs.md",
            .title = "User Preferences",
            .path = "/home/u/.config/nalar/memories/user-prefs.md",
            .size = 1024,
        },
    };

    const json = try list_memory.toJson(alloc, list);
    defer alloc.free(json);

    try std.testing.expect(contains(json, "\"name\":\"user-prefs.md\""));
    try std.testing.expect(contains(json, "\"title\":\"User Preferences\""));
    try std.testing.expect(contains(json, "\"path\":\"/home/u/.config/nalar/memories/user-prefs.md\""));
    try std.testing.expect(contains(json, "\"size\":1024"));
}

// -------------------------------------------------------------------------
// freeMemoriesList — no panic on empty
// -------------------------------------------------------------------------

test "freeMemoriesList handles empty list without panicking" {
    const alloc = std.testing.allocator;
    const list = &[_]memories.MemoryInfo{};
    // Should not panic
    memories.freeMemoriesList(alloc, list);
}

// -------------------------------------------------------------------------
// execute_list_memory — filesystem integration tests
// -------------------------------------------------------------------------

test "execute_list_memory returns missing-dir empty XML, no crash" {
    // Point HOME at a path that does NOT contain a memories/ subdir.
    // The tool should return <memories></memories>, not throw.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-list-memory-missing-home";
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);
    // Make sure XDG_CONFIG_HOME does not shadow HOME either
    try env.put("XDG_CONFIG_HOME", tmp_home);

    const output = try list_memory.execute_list_memory(alloc, io, &env);
    defer alloc.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "<memories>"));
    try std.testing.expect(std.mem.endsWith(u8, output, "</memories>"));
    try std.testing.expect(!contains(output, "<memory>"));
}

test "execute_list_memory lists .md files in HOME/.config/nalar/memories" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-list-memory-with-files";
    const memories_dir = "/tmp/nalar-list-memory-with-files/.config/nalar/memories";
    const file1_path = "/tmp/nalar-list-memory-with-files/.config/nalar/memories/user-prefs.md";
    const file2_path = "/tmp/nalar-list-memory-with-files/.config/nalar/memories/project-notes.md";

    // Clean up any leftovers from prior runs
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    // Create the memories directory and two .md files
    try std.Io.Dir.cwd().createDirPath(io, memories_dir);

    const file1_content = "# User Preferences\n\nLikes tabs not spaces.\n";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file1_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, file1_content);
    }

    const file2_content =
        \\# Project Notes
        \\
        \\Some long-running project context.
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file2_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, file2_content);
    }

    // Also create a .txt file that should be SKIPPED
    const txt_path = "/tmp/nalar-list-memory-with-files/.config/nalar/memories/notes.txt";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "should be ignored");
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    // Set HOME only so get_global_memories_path falls back to HOME/.config/nalar/memories,
    // which matches where the test created the files. Setting XDG_CONFIG_HOME would
    // make the tool look at ${XDG_CONFIG_HOME}/nalar/memories (XDG spec) instead.
    try env.put("HOME", tmp_home);

    const output = try list_memory.execute_list_memory(alloc, io, &env);
    defer alloc.free(output);

    // Both .md files should appear
    try std.testing.expect(contains(output, "user-prefs.md"));
    try std.testing.expect(contains(output, "User Preferences"));
    try std.testing.expect(contains(output, "project-notes.md"));
    try std.testing.expect(contains(output, "Project Notes"));

    // The .txt file should be filtered out
    try std.testing.expect(!contains(output, "notes.txt"));
    try std.testing.expect(!contains(output, "should be ignored"));

    // Each file becomes a <memory> element
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, output, idx, "<memory>")) |pos| {
        count += 1;
        idx = pos + "<memory>".len;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "execute_list_memory falls back to filename stem when no H1 present" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-list-memory-no-h1";
    const memories_dir = "/tmp/nalar-list-memory-no-h1/.config/nalar/memories";
    const file_path = "/tmp/nalar-list-memory-no-h1/.config/nalar/memories/random-name.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        // No H1 in this content — title should fall back to "random-name"
        try std.Io.File.writeStreamingAll(f, io, "Just some prose, no header.\n");
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    // HOME-only: see note in the previous test about XDG_CONFIG_HOME precedence.
    try env.put("HOME", tmp_home);

    const output = try list_memory.execute_list_memory(alloc, io, &env);
    defer alloc.free(output);

    try std.testing.expect(contains(output, "random-name.md"));
    // Filename stem is used as the title when no H1 exists
    try std.testing.expect(contains(output, "<title>random-name</title>"));
}

test "execute_list_memory with null environment returns error XML" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const output = try list_memory.execute_list_memory(alloc, io, null);
    defer alloc.free(output);

    try std.testing.expect(contains(output, "<error>MissingEnvironment</error>"));
}
