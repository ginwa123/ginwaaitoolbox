const std = @import("std");
const main = @import("main.zig");

test "extractTag finds finish_reason in response" {
    const xml = "<response><content>test</content><finish_reason>stop</finish_reason></response>";

    const result = main.extractTag(xml, "finish_reason");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?, "stop"));
}

test "extractTag returns null when tag not found" {
    const xml = "<response><content>test</content></response>";

    const result = main.extractTag(xml, "finish_reason");
    try std.testing.expect(result == null);
}

test "extractTag handles multiple responses returns last" {
    const xml = "<response><content>first</content><finish_reason>tool_calls</finish_reason></response><response><content>second</content><finish_reason>stop</finish_reason></response>";

    const result = main.extractTag(xml, "finish_reason");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?, "stop"));
}

test "extractTag handles tool_calls and stop in same buffer" {
    const xml = "<response><tool_calls><tool_call id=\"1\"/></tool_calls><finish_reason>tool_calls</finish_reason></response>";

    const result = main.extractTag(xml, "finish_reason");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?, "tool_calls"));
}
