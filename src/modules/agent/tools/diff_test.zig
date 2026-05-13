const std = @import("std");
const diff = @import("diff.zig");

test "diff - no change" {
    const r = try diff.diff(std.testing.allocator, "hello", "hello");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .eq);
    try std.testing.expectEqualStrings("hello", r.chunks[0].text);
}

test "diff - pure insert" {
    const r = try diff.diff(std.testing.allocator, "", "hi");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .insert);
    try std.testing.expectEqualStrings("hi", r.chunks[0].text);
}

test "diff - pure delete" {
    const r = try diff.diff(std.testing.allocator, "bye", "");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .delete);
    try std.testing.expectEqualStrings("bye", r.chunks[0].text);
}

test "diff - mixed" {
    // "cat" → "car": eq "ca", delete "t", insert "r"
    const r = try diff.diff(std.testing.allocator, "cat", "car");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .eq);
    try std.testing.expectEqualStrings("ca", r.chunks[0].text);
    try std.testing.expect(r.chunks[1].kind == .delete);
    try std.testing.expectEqualStrings("t", r.chunks[1].text);
    try std.testing.expect(r.chunks[2].kind == .insert);
    try std.testing.expectEqualStrings("r", r.chunks[2].text);
}

test "diff - single char change" {
    // "a" → "b": delete "a", insert "b"
    const r = try diff.diff(std.testing.allocator, "a", "b");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .delete);
    try std.testing.expectEqualStrings("a", r.chunks[0].text);
    try std.testing.expect(r.chunks[1].kind == .insert);
    try std.testing.expectEqualStrings("b", r.chunks[1].text);
}

test "diff - empty both" {
    const r = try diff.diff(std.testing.allocator, "", "");
    defer r.deinit(std.testing.allocator);
    // Empty strings produce zero chunks
    try std.testing.expectEqual(@as(usize, 0), r.chunks.len);
}

test "splitLines - basic" {
    const lines = try diff.splitLines(std.testing.allocator, "line1\nline2\nline3\n");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("line1", lines[0]);
    try std.testing.expectEqualStrings("line2", lines[1]);
    try std.testing.expectEqualStrings("line3", lines[2]);
}

test "splitLines - no trailing newline" {
    const lines = try diff.splitLines(std.testing.allocator, "line1\nline2");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("line1", lines[0]);
    try std.testing.expectEqualStrings("line2", lines[1]);
}

test "splitLines - empty last line" {
    const lines = try diff.splitLines(std.testing.allocator, "line1\nline2\n");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
}

test "splitLines - single line no newline" {
    const lines = try diff.splitLines(std.testing.allocator, "single line");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("single line", lines[0]);
}

test "line diff - no change" {
    const bl = try diff.splitLines(std.testing.allocator, "line1\nline2\n");
    defer std.testing.allocator.free(bl);
    const al = try diff.splitLines(std.testing.allocator, "line1\nline2\n");
    defer std.testing.allocator.free(al);

    const r = try diff.diffLines(std.testing.allocator, bl, al);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .eq);
}

test "line diff - add line" {
    const bl = try diff.splitLines(std.testing.allocator, "line1\nline2\n");
    defer std.testing.allocator.free(bl);
    const al = try diff.splitLines(std.testing.allocator, "line1\nline2\nline3\n");
    defer std.testing.allocator.free(al);

    const r = try diff.diffLines(std.testing.allocator, bl, al);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .eq);
    try std.testing.expect(r.chunks[1].kind == .insert);
}

test "line diff - delete line" {
    const bl = try diff.splitLines(std.testing.allocator, "line1\nline2\nline3\n");
    defer std.testing.allocator.free(bl);
    const al = try diff.splitLines(std.testing.allocator, "line1\nline2\n");
    defer std.testing.allocator.free(al);

    const r = try diff.diffLines(std.testing.allocator, bl, al);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), r.chunks.len);
    try std.testing.expect(r.chunks[0].kind == .eq);
    try std.testing.expect(r.chunks[1].kind == .delete);
}

test "line diff - modify line" {
    const bl = try diff.splitLines(std.testing.allocator, "line1\nOLD\nline3\n");
    defer std.testing.allocator.free(bl);
    const al = try diff.splitLines(std.testing.allocator, "line1\nNEW\nline3\n");
    defer std.testing.allocator.free(al);

    const r = try diff.diffLines(std.testing.allocator, bl, al);
    defer r.deinit(std.testing.allocator);
    
    // Should have at least 2 chunks (delete + insert for the modified line)
    try std.testing.expect(r.chunks.len >= 2);
    
    // First chunk should be equal (line1)
    try std.testing.expect(r.chunks[0].kind == .eq);
    // Last chunk should be equal (line3)
    try std.testing.expect(r.chunks[r.chunks.len - 1].kind == .eq);
}

test "formatLinesAnsi - generates output" {
    const bl = try diff.splitLines(std.testing.allocator, "line1\nline2\n");
    defer std.testing.allocator.free(bl);
    const al = try diff.splitLines(std.testing.allocator, "line1\nmodified\n");
    defer std.testing.allocator.free(al);

    const r = try diff.diffLines(std.testing.allocator, bl, al);
    defer r.deinit(std.testing.allocator);

    const output = try diff.formatLinesAnsi(std.testing.allocator, r);
    defer std.testing.allocator.free(output);

    // Check that output contains expected content
    try std.testing.expect(std.mem.indexOf(u8, output, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "modified") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "│") != null); // divider
}

test "line diff - multiline change" {
    // Test a more complex scenario with multiple line changes
    const bl = try diff.splitLines(std.testing.allocator, "fn old() void { }\n");
    defer std.testing.allocator.free(bl);
    const al = try diff.splitLines(std.testing.allocator, "fn new() void { }\n");
    defer std.testing.allocator.free(al);

    const r = try diff.diffLines(std.testing.allocator, bl, al);
    defer r.deinit(std.testing.allocator);
    
    // Should have at least 2 chunks (delete + insert)
    try std.testing.expect(r.chunks.len >= 2);
    
    // First chunk should be delete, second should be insert
    try std.testing.expect(r.chunks[0].kind == .delete);
    try std.testing.expect(r.chunks[1].kind == .insert);
}