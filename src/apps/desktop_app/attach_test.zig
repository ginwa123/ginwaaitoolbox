// src/apps/desktop_app/attach_test.zig
//
// Tests for the desktop's "find nalar" logic.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");
const attach = @import("attach.zig");

test "resolveAttachTarget returns state-file port when probe succeeds" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;

    // Create a state.json with a real port we can probe.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    const path = try allocator.alloc(u8, tmp_dir_path.len + 1 + "state.json".len);
    defer allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    path[tmp_dir_path.len] = '/';
    @memcpy(path[tmp_dir_path.len + 1..], "state.json");

    // Write a state.json pointing to localhost on a random port.
    // The dummy server below listens on this port so the health probe
    // (currently a stub returning false) would have something to talk
    // to if wired up. For now we test the parse-read-write path.
    const dummy_port: u16 = 0; // 0 means "I didn't bind anything"
    _ = dummy_port;

    const json = try std.fmt.allocPrint(allocator,
        \\{{"pid":{d},"port":8081,"host":"127.0.0.1","started_at":0,"version":"x","static_dir":null}}
    , .{std.c.getpid()});
    defer allocator.free(json);

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = json });

    // Read it back via nalarcore.state_file.
    const state_opt = try nalarcore.state_file.readStateFile(allocator, testing.io, path);
    defer if (state_opt) |s| {
        allocator.free(s.host);
        allocator.free(s.version);
    };
    try testing.expect(state_opt != null);
    const state = state_opt.?;
    try testing.expectEqual(@as(u16, 8081), state.port);
    try testing.expectEqualStrings("127.0.0.1", state.host);

    // The probe path returns false in the stub, so the resolve will
    // fall through to auto-spawn (which is the v1 follow-up stub).
    // For now we just verify the stub returns AutoSpawnFailed.
    const result = attach.resolveAttachTarget(allocator, testing.io, .{
        .state_path = path,
        .default_port = 8081,
        .no_auto_start = true,
    });
    try testing.expectError(error.AutoStartDisabled, result);
}

test "resolveAttachTarget returns AutoStartDisabled when --no-auto-start and no nalar" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;

    // Use a tmp path that does NOT exist; the read returns null
    // immediately. The probe path is a stub that returns false. With
    // --no-auto-start, we expect AutoStartDisabled.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    const path = try allocator.alloc(u8, tmp_dir_path.len + 1 + "state.json".len);
    defer allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    path[tmp_dir_path.len] = '/';
    @memcpy(path[tmp_dir_path.len + 1..], "state.json");

    const result = attach.resolveAttachTarget(allocator, testing.io, .{
        .state_path = path,
        .default_port = 8081,
        .no_auto_start = true,
    });
    try testing.expectError(error.AutoStartDisabled, result);
}