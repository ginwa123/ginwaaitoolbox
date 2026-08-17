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
// src/ai_workflow/tui/agentic_loop/tools_exec_list_directory_test.zig.

const std = @import("std");
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
        alloc, testing.io, env.root_abs, true, false,
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
        alloc, testing.io, "/tmp/this_path_definitely_does_not_exist_xyz_123", false, false,
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
        alloc, testing.io, env.root_abs, false, true,
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
        alloc, testing.io, env.root_abs, false, false,
    );
    defer list_directory.freeEntries(alloc, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("foo.log", entries[0].name);
}

// -------------------------------------------------------------------------
// toXml — XML envelope
// -------------------------------------------------------------------------

test "toXml: emits <directory_listing path=... count=...>" {
    const alloc = testing.allocator;

    const entries = &[_]list_directory.Entry{
        .{ .name = "src", .path = "/proj/src", .is_directory = true, .is_symlink = false },
        .{ .name = "main.zig", .path = "/proj/main.zig", .is_directory = false, .is_symlink = false },
    };

    const xml = try list_directory.toXml(alloc, entries, "/proj");
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<directory_listing") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "path=\"/proj\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "count=\"2\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<directory name=\"src\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<file name=\"main.zig\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "</directory_listing>") != null);
}

test "toXml: empty list produces empty <directory_listing>" {
    const alloc = testing.allocator;
    const entries = &[_]list_directory.Entry{};

    const xml = try list_directory.toXml(alloc, entries, "/empty");
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "count=\"0\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<directory ") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<file ") == null);
}

// -------------------------------------------------------------------------
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

test "list_directory_tool description mentions absolute-paths-rejected policy" {
    const desc = list_directory.list_directory_tool.function.description;
    // Static-contract grep — guards against accidental removal of
    // the security note when the description is edited. The
    // description wraps "absolute paths are rejected — security
    // policy" across multiple lines, so we look for the substring
    // "rejected" which only appears in that phrase.
    if (std.mem.indexOf(u8, desc, "rejected") == null) {
        std.debug.print("!! list_directory description does not mention 'rejected' (security policy) !!\n", .{});
        try testing.expect(false);
    }
}
