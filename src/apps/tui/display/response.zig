const std = @import("std");

/// Content result structure - represents extracted content from XML
pub const ContentResult = struct {
    content: []const u8,
};

/// Extract content from XML response
/// Finds all <content>...</content> tags and returns them as a list
/// Returns null if no content found
pub fn extractContentResult(allocator: std.mem.Allocator, xml: []const u8) ?std.ArrayList(ContentResult) {
    var results = std.ArrayList(ContentResult).empty;
    errdefer results.deinit(allocator);
    var pos: usize = 0;
    while (pos < xml.len) {
        const content_start = std.mem.indexOfPos(u8, xml, pos, "<content>") orelse break;
        const content_end = std.mem.indexOfPos(u8, xml, content_start, "</content>") orelse break;
        const content = xml[content_start + "<content>".len .. content_end];
        pos = content_end + "</content>".len;
        if (content.len > 0) {
            results.append(allocator, .{ .content = content }) catch break;
        }
    }
    if (results.items.len == 0) return null;
    return results;
}

