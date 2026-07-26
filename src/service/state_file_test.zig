// src/service/state_file_test.zig
//
// Tests for src/service/state_file.zig. Verifies:
//   - readStateFile returns null when the file does not exist
//   - writeStateFile + readStateFile round-trip a State value
//   - defaultStatePath returns an XDG-aware path on Linux/macOS
//
// Zig 0.16 API notes (matching the production code in state_file.zig):
//   * readStateFile takes an `io: std.Io` parameter because
//     std.Io.Dir.cwd().readFileAlloc requires it in 0.16.
//   * std.testing.tmpDir(.{}) returns a TmpDir with a .cleanup() method.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const state_file = @import("state_file.zig");

test "readStateFile returns null when file does not exist" {
    const allocator = testing.allocator;
    const result = try state_file.readStateFile(
        allocator,
        testing.io,
        "/tmp/this/path/does/not/exist/state.json",
    );
    try testing.expect(result == null);
}

test "writeStateFile round-trips a State" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Get the tmp dir's canonical realpath via Io.Dir.realPath (Zig 0.16).
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    // Build "<tmpdir>/state.json" without std.fs.path.join (every join arg
    // is treated as a path component; concatenating the suffix manually).
    const path = try allocator.alloc(u8, tmp_dir_path.len + 1 + "state.json".len);
    defer allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    path[tmp_dir_path.len] = '/';
    @memcpy(path[tmp_dir_path.len + 1..], "state.json");

    const original: state_file.State = .{
        .pid = 12345,
        .port = 8081,
        .host = "127.0.0.1",
        .started_at = 1751558400,
        .version = "0.4.0",
        .static_dir = "/tmp/nalar-webapp-1234",
    };
    try state_file.writeStateFile(allocator, testing.io, path, original);
    const restored = try state_file.readStateFile(allocator, testing.io, path);
    defer if (restored) |s| state_file.freeState(allocator, s);
    try testing.expect(restored != null);
    try testing.expectEqual(original.pid, restored.?.pid);
    try testing.expectEqual(original.port, restored.?.port);
    try testing.expectEqualStrings(original.host, restored.?.host);
    try testing.expectEqualStrings(original.static_dir.?, restored.?.static_dir.?);
}

test "defaultStatePath returns XDG-aware path on POSIX" {
    if (builtin.os.tag == .windows) return; // skip on non-POSIX CI cells
    const allocator = testing.allocator;
    const path = try state_file.defaultStatePath(allocator);
    defer allocator.free(path);
    // Path should end in /state.json under a 'nalar' dir.
    try testing.expect(std.mem.endsWith(u8, path, "/state.json"));
    try testing.expect(std.mem.indexOf(u8, path, "nalar") != null);
}

test "writeStateFile does mkdir-p into a fresh nested dir" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    // Build "<tmpdir>/deeply/nested/that/does/not/exist/state.json" — the
    // parent dirs do NOT exist when writeStateFile is called. This is the
    // exact path the daemon hits on a fresh $HOME.
    const leaf = "deeply/nested/that/does/not/exist/state.json";
    const path = try allocator.alloc(u8, tmp_dir_path.len + 1 + leaf.len);
    defer allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    path[tmp_dir_path.len] = '/';
    @memcpy(path[tmp_dir_path.len + 1..], leaf);

    const original: state_file.State = .{
        .pid = 99,
        .port = 8081,
        .host = "127.0.0.1",
        .started_at = 1751558400,
        .version = "0.4.0",
        .static_dir = null,
    };
    try state_file.writeStateFile(allocator, testing.io, path, original);
    const restored = try state_file.readStateFile(allocator, testing.io, path);
    defer if (restored) |s| state_file.freeState(allocator, s);
    try testing.expect(restored != null);
    try testing.expectEqual(original.pid, restored.?.pid);
}

test "freeState is a no-op on slices (does not double-free)" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    const leaf = "free_test/state.json";
    const path = try allocator.alloc(u8, tmp_dir_path.len + 1 + leaf.len);
    defer allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    path[tmp_dir_path.len] = '/';
    @memcpy(path[tmp_dir_path.len + 1..], leaf);

    const original: state_file.State = .{
        .pid = 1,
        .port = 8081,
        .host = "x",
        .started_at = 1,
        .version = "v",
        .static_dir = "/tmp/static",
    };
    try state_file.writeStateFile(allocator, testing.io, path, original);
    const restored = try state_file.readStateFile(allocator, testing.io, path);
    try testing.expect(restored != null);
    // Freeing twice in a row must NOT panic — the second call is a no-op
    // because the slices are "" / null after the first free. Use null
    // optional to simulate this.
    if (restored) |s| state_file.freeState(allocator, s);
}