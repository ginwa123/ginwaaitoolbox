const std = @import("std");
const testing = std.testing;
const ctx = @import("compaction_context.zig");

test "enrichCompactionXml with empty user history and empty read files returns the original compacted_xml wrapped in <summary>" {
    const alloc = testing.allocator;
    const result = try ctx.enrichCompactionXml(
        alloc,
        "GOAL: ship X\nNEXT: test",
        &.{},
        &.{},
        "/tmp",
    );
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<compaction_context>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<user_history>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<read_files>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<summary>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "GOAL: ship X") != null);
    // No entries inside the empty-section blocks
    try testing.expect(std.mem.indexOf(u8, result, "<turn ") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<path ") == null);
}

test "enrichCompactionXml embeds user history and read files with the right content" {
    const alloc = testing.allocator;
    const user_turns = [_]ctx.UserTurn{
        .{ .content = "fix the bug", .created_at = "2026-01-01 00:00:01" },
        .{ .content = "now also write tests", .created_at = "2026-01-01 00:00:05" },
    };
    const read_files = [_]ctx.ReadFileTurn{
        .{
            .path = "/home/user/foo.zig",
            .raw_content = "<path>/home/user/foo.zig</path>",
            .created_at = "2026-01-01 00:00:02",
        },
    };
    const result = try ctx.enrichCompactionXml(
        alloc,
        "GOAL: ship X",
        &user_turns,
        &read_files,
        "/home/user",
    );
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<turn created_at=\"2026-01-01 00:00:01\">fix the bug</turn>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<turn created_at=\"2026-01-01 00:00:05\">now also write tests</turn>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<path abs=\"/home/user/foo.zig\">/home/user/foo.zig</path>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<summary>") != null);
}

test "enrichCompactionXml emits all 50 user turns when the cap is hit" {
    const alloc = testing.allocator;
    var turns: [50]ctx.UserTurn = undefined;
    var owned_strings: [50][]u8 = undefined;
    for (&turns, &owned_strings, 0..) |*t, *owned, i| {
        owned.* = try std.fmt.allocPrint(alloc, "turn {d}", .{i});
        t.* = .{
            .content = owned.*,
            .created_at = "2026-01-01 00:00:00",
        };
    }
    defer for (owned_strings) |s| alloc.free(s);

    const result = try ctx.enrichCompactionXml(
        alloc,
        "summary",
        &turns,
        &.{},
        "/tmp",
    );
    defer alloc.free(result);

    for (turns, 0..) |_, i| {
        const needle = try std.fmt.allocPrint(alloc, ">turn {d}</turn>", .{i});
        defer alloc.free(needle);
        try testing.expect(std.mem.indexOf(u8, result, needle) != null);
    }
}

test "enrichCompactionXml deduplicates read_file on the same path" {
    const alloc = testing.allocator;
    const read_files = [_]ctx.ReadFileTurn{
        .{ .path = "/home/user/foo.zig", .raw_content = "", .created_at = "t1" },
        .{ .path = "/home/user/bar.zig", .raw_content = "", .created_at = "t2" },
        .{ .path = "/home/user/foo.zig", .raw_content = "", .created_at = "t3" }, // dup
        .{ .path = "/home/user/baz.zig", .raw_content = "", .created_at = "t4" },
        .{ .path = "/home/user/bar.zig", .raw_content = "", .created_at = "t5" }, // dup
    };
    const result = try ctx.enrichCompactionXml(
        alloc,
        "summary",
        &.{},
        &read_files,
        "/home/user",
    );
    defer alloc.free(result);

    // Count <path * element occurrences — the dedup invariant.
    // Each absolute path also appears twice within each element (once in
    // `abs=` and once as content) so substring counting is brittle.
    try testing.expectEqual(@as(usize, 3), countSubstring(result, "<path "));
    try testing.expect(std.mem.indexOf(u8, result, "<path abs=\"/home/user/foo.zig\">/home/user/foo.zig</path>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<path abs=\"/home/user/bar.zig\">/home/user/bar.zig</path>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<path abs=\"/home/user/baz.zig\">/home/user/baz.zig</path>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "truncated_by") == null);
}

fn countSubstring(hay: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, needle)) |pos| {
        count += 1;
        i = pos + needle.len;
    }
    return count;
}