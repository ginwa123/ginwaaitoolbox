const std = @import("std");

pub fn extract_tag(xml: []const u8, tag: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const start_tag = std.fmt.allocPrint(allocator, "<{s}>", .{tag}) catch return null;
    defer allocator.free(start_tag);
    const end_tag = std.fmt.allocPrint(allocator, "</{s}>", .{tag}) catch return null;
    defer allocator.free(end_tag);

    const start_idx = std.mem.indexOf(u8, xml, start_tag) orelse return null;
    const content_start = start_idx + start_tag.len;
    const end_idx = std.mem.indexOf(u8, xml[content_start..], end_tag) orelse return null;

    return xml[content_start .. content_start + end_idx];
}
