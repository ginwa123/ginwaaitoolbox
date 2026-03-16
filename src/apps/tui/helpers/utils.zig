const std = @import("std");

/// Trim leading and trailing whitespace from a string
pub fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\n')) start += 1;
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\n')) end -= 1;
    return s[start..end];
}

/// Extract content between XML-like tags
/// Uses stack buffer for better performance
pub fn extractTag(xml: []const u8, tag: []const u8) ?[]const u8 {
    // Use stack buffer instead of heap allocation for better performance
    var close_tag_buf: [128]u8 = undefined;
    var open_tag_buf: [128]u8 = undefined;

    const close_tag = std.fmt.bufPrint(&close_tag_buf, "</{s}>", .{tag}) catch return null;
    const open_tag = std.fmt.bufPrint(&open_tag_buf, "<{s}>", .{tag}) catch return null;

    const close_pos = std.mem.lastIndexOf(u8, xml, close_tag) orelse return null;
    const open_pos = std.mem.lastIndexOf(u8, xml[0..close_pos], open_tag) orelse return null;
    return xml[open_pos + open_tag.len .. close_pos];
}
