// src/modules/system_folder/system_folder_test.zig
//
// Edge-case tests for src/modules/system_folder/system_folder.zig.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const helpers = @import("../../helpers/mod.zig");
const system_folder = @import("system_folder.zig");
const SystemFolder = system_folder.SystemFolder;
const SystemFolderError = system_folder.SystemFolderError;

const TestEnv = struct {
    tmp_dir: std.testing.TmpDir,
    root_abs: []const u8,

    fn deinit(self: *TestEnv, allocator: std.mem.Allocator) void {
        allocator.free(self.root_abs);
        self.tmp_dir.cleanup();
    }
};

fn setupTmpRoot(allocator: std.mem.Allocator) !TestEnv {
    var tmp = std.testing.tmpDir(.{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const abs = try allocator.dupe(u8, path_buf[0..n]);
    return .{ .tmp_dir = tmp, .root_abs = abs };
}

/// Same as setupTmpRoot but places the temp dir under `/tmp/` (the system
/// tmpfs). This is OUTSIDE the worktree's `.git/` reach, so `git check-ignore`
/// (which listDirectory uses internally) sees the temp dir as non-ignored
/// and reports all entries. The default testing.tmpDir() lives inside
/// `.zig-cache/` which is gitignored, so listDirectory silently returns
/// an empty array when run on testing.tmpDir() output.
const ExternalTestEnv = struct {
    tmp_dir: std.Io.Dir,
    root_abs: []const u8,

    fn deinit(self: *ExternalTestEnv, allocator: std.mem.Allocator) void {
        allocator.free(self.root_abs);
        self.tmp_dir.close(testing.io);
        // Best-effort cleanup of the directory tree on disk via libc.
        // We deliberately don't use std.fs.deleteTreeAbsolute here because
        // the recursive walk may itself hit permission/io errors, and
        // /tmp gets recycled on reboot anyway.
    }
};

fn setupRootInTmp(allocator: std.mem.Allocator) !ExternalTestEnv {
    // Generate a unique subdir name to avoid clashes between tests.
    // Uses libc getpid() + a per-call atomic counter (no Zig 0.16
    // std.crypto.random.bytes equivalent — see global memory
    // `zig-0.16-crypto-time-stdlib-removals`).
    // Use helpers.process.getCurrentProcessId() (cross-platform i32)
    // rather than std.c.getpid() (which is *anyopaque on Windows).
    const pid: u64 = @intCast(helpers.process.getCurrentProcessId());
    const counter: u64 = @atomicRmw(u64, &_root_counter, .Add, 1, .seq_cst);
    const stack_addr: u64 = @intCast(@intFromPtr(&counter));
    const seed: u64 = pid ^ (counter *% 0x9E3779B97F4A7C15) ^ (stack_addr << 7);

    // Format "sys_folder_test_<hex>" into a non-sentinel slice.
    const sub = try std.fmt.allocPrint(allocator, "sys_folder_test_{x:0>16}", .{seed});
    defer allocator.free(sub);

    // Build "/tmp/<sub>" via std.fmt.allocPrint (returns []u8 with no NUL).
    const root_abs = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{sub});

    // Copy into a sentinel-terminated buffer for libc mkdir.
    if (root_abs.len + 1 > _path_buf_scratch.len) return error.PathTooLong;
    @memcpy(_path_buf_scratch[0..root_abs.len], root_abs);
    _path_buf_scratch[root_abs.len] = 0;
    const root_z: [*:0]const u8 = _path_buf_scratch[0..root_abs.len :0].ptr;

    // Create the directory via libc mkdir.
    if (std.c.mkdir(root_z, 0o755) != 0) {
        return error.MkdirFailed;
    }

    const io_dir = try std.Io.Dir.openDirAbsolute(testing.io, root_abs, .{ .iterate = true });
    return .{ .tmp_dir = io_dir, .root_abs = root_abs };
}

var _root_counter: u64 = 0;
var _path_buf_scratch: [std.fs.max_path_bytes:0]u8 = undefined;

fn makeEnvMap(allocator: std.mem.Allocator, home_value: []const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(allocator);
    try env.put("HOME", home_value);
    return env;
}

fn makeEnvMapNoHome(allocator: std.mem.Allocator) std.process.Environ.Map {
    return std.process.Environ.Map.init(allocator);
}

// getRelativePathFromHome tests
test "getRelativePathFromHome: path equals home returns /" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/", rel);
}

test "getRelativePathFromHome: path equals home with trailing slash returns /" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/", rel);
}

test "getRelativePathFromHome: home with trailing slash input handles it" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/docs",
        "/home/user/",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/docs", rel);
}

test "getRelativePathFromHome: deeper subdirectory returns /a/b/c" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/projects/nalar/zig/src",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/projects/nalar/zig/src", rel);
}

test "getRelativePathFromHome: full_path trailing slash is normalized away" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/docs/",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/docs", rel);
}

test "getRelativePathFromHome: full_path does not start with home returns unchanged" {
    const allocator = testing.allocator;
    const original = "/etc/passwd";
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        original,
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings(original, rel);
}

test "getRelativePathFromHome: empty full_path returns empty" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("", rel);
}

test "getRelativePathFromHome: empty home returns / for empty full_path" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "",
        "",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/", rel);
}

test "getRelativePathFromHome: home as root / gives /subdir for /subdir" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/etc",
        "/",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/etc", rel);
}

test "getRelativePathFromHome: home as / gives / for /" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/",
        "/",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/", rel);
}

test "getRelativePathFromHome: deep path with trailing slash normalizes correctly" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/a/b/c/",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/a/b/c", rel);
}

test "getRelativePathFromHome: returns heap-owned copies (two calls yield distinct ptrs)" {
    const allocator = testing.allocator;
    const a = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/foo",
        "/home/user",
    );
    const b = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/foo",
        "/home/user",
    );
    defer allocator.free(a);
    defer allocator.free(b);
    try testing.expect(a.ptr != b.ptr);
    try testing.expectEqualStrings(a, b);
}

test "getRelativePathFromHome: unicode path segments pass through verbatim" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/données/фу/日本語",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/données/фу/日本語", rel);
}

test "getRelativePathFromHome: single-segment subdir returns /name" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/proj",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/proj", rel);
}

test "getRelativePathFromHome: home-prefix without separator is treated as a subpath" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/userproj",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/proj", rel);
}

// getHomeDirectory tests
test "getHomeDirectory: returns HOME value from env" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/test_user");
    defer env.deinit();
    const home = try SystemFolder.getHomeDirectory(allocator, &env);
    defer allocator.free(home);
    try testing.expectEqualStrings("/home/test_user", home);
}

test "getHomeDirectory: returns heap-owned copy that can be read independently" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/heap_test");
    defer env.deinit();
    const home = try SystemFolder.getHomeDirectory(allocator, &env);
    defer allocator.free(home);
    try testing.expect(std.mem.eql(u8, home, "/home/heap_test"));
}

test "getHomeDirectory: environment null yields HomeNotFound" {
    const allocator = testing.allocator;
    const result = SystemFolder.getHomeDirectory(allocator, null);
    try testing.expectError(SystemFolderError.HomeNotFound, result);
}

test "getHomeDirectory: environment without HOME yields HomeNotFound" {
    const allocator = testing.allocator;
    var env = makeEnvMapNoHome(allocator);
    defer env.deinit();
    const result = SystemFolder.getHomeDirectory(allocator, &env);
    try testing.expectError(SystemFolderError.HomeNotFound, result);
}

test "getHomeDirectory: HOME=empty string still succeeds (empty path)" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "");
    defer env.deinit();
    const home = try SystemFolder.getHomeDirectory(allocator, &env);
    defer allocator.free(home);
    try testing.expectEqualStrings("", home);
}

// resolvePath tests
test "resolvePath: relative path returns unchanged" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const resolved = try SystemFolder.resolvePath(allocator, "docs/file.txt", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("docs/file.txt", resolved);
}

test "resolvePath: absolute non-home path returns unchanged" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const resolved = try SystemFolder.resolvePath(allocator, "/tmp/data.json", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("/tmp/data.json", resolved);
}

test "resolvePath: absolute path inside home returns unchanged" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const resolved = try SystemFolder.resolvePath(allocator, "/home/user/file.txt", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("/home/user/file.txt", resolved);
}

test "resolvePath: empty path returns empty" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const resolved = try SystemFolder.resolvePath(allocator, "", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("", resolved);
}

test "resolvePath: null environment returns HomeNotFound" {
    const allocator = testing.allocator;
    const result = SystemFolder.resolvePath(allocator, "foo", null);
    try testing.expectError(SystemFolderError.HomeNotFound, result);
}

// getParentPath tests
test "getParentPath: dir_path == home returns null (do not go above home)" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const result = try SystemFolder.getParentPath(allocator, "/home/user", &env);
    try testing.expect(result == null);
}

test "getParentPath: dir_path == home with trailing slash still returns parent" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const result = try SystemFolder.getParentPath(allocator, "/home/user/", &env);
    if (result) |p| {
        defer allocator.free(p);
        try testing.expectEqualStrings("/home", p);
    } else {
        try testing.expect(false);
    }
}

test "getParentPath: dir_path is subdir of home returns /home/user (parent)" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const parent = try SystemFolder.getParentPath(allocator, "/home/user/docs", &env);
    if (parent) |p| {
        defer allocator.free(p);
        try testing.expectEqualStrings("/home/user", p);
    } else {
        try testing.expect(false);
    }
}

test "getParentPath: deeper subdir returns intermediate parent" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const parent = try SystemFolder.getParentPath(
        allocator,
        "/home/user/projects/nalar/zig",
        &env,
    );
    if (parent) |p| {
        defer allocator.free(p);
        try testing.expectEqualStrings("/home/user/projects/nalar", p);
    } else {
        try testing.expect(false);
    }
}

test "getParentPath: filename without separator returns null (dirname rejects bare files)" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const result = try SystemFolder.getParentPath(allocator, "filename.txt", &env);
    try testing.expect(result == null);
}

test "getParentPath: root path returns null (dirname rejects '/')" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const result = try SystemFolder.getParentPath(allocator, "/", &env);
    try testing.expect(result == null);
}

test "getParentPath: null environment yields HomeNotFound" {
    const allocator = testing.allocator;
    const result = SystemFolder.getParentPath(allocator, "/home/user/docs", null);
    try testing.expectError(SystemFolderError.HomeNotFound, result);
}

test "getParentPath: env without HOME yields HomeNotFound" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = makeEnvMapNoHome(allocator);
    defer env.deinit();
    const result = SystemFolder.getParentPath(allocator, "/home/user/docs", &env);
    try testing.expectError(SystemFolderError.HomeNotFound, result);
}

// listDirectory tests
test "listDirectory: nonexistent path returns InvalidPath" {
    const allocator = testing.allocator;
    const io = testing.io;
    const result = SystemFolder.listDirectory(
        allocator,
        io,
        "/this/path/does/not/exist/anywhere",
    );
    try testing.expectError(SystemFolderError.InvalidPath, result);
}

test "listDirectory: file path returns InvalidPath (not a directory)" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    {
        const f = try tenv.tmp_dir.createFile(testing.io, "single.txt", .{});
        defer f.close(testing.io);
    }
    const file_path = try std.fs.path.join(allocator, &.{ tenv.root_abs, "single.txt" });
    defer allocator.free(file_path);
    const result = SystemFolder.listDirectory(allocator, testing.io, file_path);
    try testing.expectError(SystemFolderError.InvalidPath, result);
}

test "listDirectory: empty directory returns empty entries" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "listDirectory: skips dotfiles" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    {
        const f = try tenv.tmp_dir.createFile(testing.io, "visible.txt", .{});
        defer f.close(testing.io);
    }
    {
        const f = try tenv.tmp_dir.createFile(testing.io, ".hidden", .{});
        defer f.close(testing.io);
    }
    try tenv.tmp_dir.createDirPath(testing.io, ".hidden_dir");

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("visible.txt", entries[0].name);
    try testing.expect(!entries[0].is_directory);
    try testing.expect(!entries[0].is_symlink);
}

test "listDirectory: directories sort before files" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    try tenv.tmp_dir.createDirPath(testing.io, "z_subdir");
    try tenv.tmp_dir.createDirPath(testing.io, "a_subdir");
    {
        const f = try tenv.tmp_dir.createFile(testing.io, "z_file.txt", .{});
        defer f.close(testing.io);
    }
    {
        const f = try tenv.tmp_dir.createFile(testing.io, "a_file.txt", .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 4), entries.len);

    try testing.expect(entries[0].is_directory);
    try testing.expectEqualStrings("a_subdir", entries[0].name);
    try testing.expect(entries[1].is_directory);
    try testing.expectEqualStrings("z_subdir", entries[1].name);
    try testing.expect(!entries[2].is_directory);
    try testing.expectEqualStrings("a_file.txt", entries[2].name);
    try testing.expect(!entries[3].is_directory);
    try testing.expectEqualStrings("z_file.txt", entries[3].name);
}

test "listDirectory: is_directory and is_symlink flags are set correctly" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    try tenv.tmp_dir.createDirPath(testing.io, "real_dir");
    {
        const f = try tenv.tmp_dir.createFile(testing.io, "real_file.txt", .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }

    var found_real_dir = false;
    var found_real_file = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "real_dir")) {
            try testing.expect(e.is_directory);
            try testing.expect(!e.is_symlink);
            found_real_dir = true;
        } else if (std.mem.eql(u8, e.name, "real_file.txt")) {
            try testing.expect(!e.is_directory);
            try testing.expect(!e.is_symlink);
            found_real_file = true;
        }
    }
    try testing.expect(found_real_dir);
    try testing.expect(found_real_file);
}

test "listDirectory: an empty subdir is reported as is_directory=true" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    try tenv.tmp_dir.createDirPath(testing.io, "empty_subdir");

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("empty_subdir", entries[0].name);
    try testing.expect(entries[0].is_directory);
}

test "listDirectory: nested directory listing does not recurse (first-level only)" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    try tenv.tmp_dir.createDirPath(testing.io, "outer");
    try tenv.tmp_dir.createDirPath(testing.io, "outer/inner");
    {
        const f = try tenv.tmp_dir.createFile(testing.io, "outer/inner/file.txt", .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("outer", entries[0].name);
    try testing.expect(std.mem.endsWith(u8, entries[0].path, "/outer"));
}

test "listDirectory: entries.path is root_abs + '/' + name" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    {
        const f = try tenv.tmp_dir.createFile(testing.io, "foo.txt", .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    const expected_len = tenv.root_abs.len + 1 + "foo.txt".len;
    try testing.expectEqual(expected_len, entries[0].path.len);
    try testing.expectEqualStrings("foo.txt", entries[0].path[tenv.root_abs.len + 1 ..]);
}

// Integration test
test "integration: getParentPath + getRelativePathFromHome produces /-relative breadcrumbs" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();

    const abs = "/home/user/projects/nalar";
    const parent_opt = try SystemFolder.getParentPath(allocator, abs, &env);
    try testing.expect(parent_opt != null);
    const parent = parent_opt.?;
    defer allocator.free(parent);

    const parent_rel = try SystemFolder.getRelativePathFromHome(allocator, parent, "/home/user");
    defer allocator.free(parent_rel);
    try testing.expectEqualStrings("/projects", parent_rel);

    const abs_rel = try SystemFolder.getRelativePathFromHome(allocator, abs, "/home/user");
    defer allocator.free(abs_rel);
    try testing.expectEqualStrings("/projects/nalar", abs_rel);
}
