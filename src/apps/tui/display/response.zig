const std = @import("std");

/// Content result structure - represents extracted content from XML
pub const ContentResult = struct {
    content: []const u8,
};

/// Result structure containing extracted content and finish reason
pub const ExtractResult = struct {
    content_results: std.ArrayList(ContentResult),
    finish_reason: ?[]const u8,
};

/// Extract content and finish_reason from XML response
/// Finds all <content>...</content> tags and the last <finish_reason>...</finish_reason>
/// Returns null if no content found
pub fn extractContentResult(allocator: std.mem.Allocator, xml: []const u8) ?ExtractResult {
    var results = std.ArrayList(ContentResult).empty;
    errdefer results.deinit(allocator);

    // Extract all content tags
    var pos: usize = 0;
    while (pos < xml.len) {
        const content_start = std.mem.indexOfPos(u8, xml, pos, "<response>") orelse break;
        const content_end = std.mem.indexOfPos(u8, xml, content_start, "</response>") orelse break;
        const content = xml[content_start + "<response>".len .. content_end];
        pos = content_end + "</response>".len;
        if (content.len > 0) {
            results.append(allocator, .{ .content = content }) catch break;
        }
    }

    // Extract the LAST finish_reason tag (there may be multiple from streaming chunks)
    var finish_reason: ?[]const u8 = null;
    var fr_pos: usize = 0;
    while (fr_pos < xml.len) {
        const fr_start = std.mem.indexOfPos(u8, xml, fr_pos, "<finish_reason>") orelse break;
        const fr_end = std.mem.indexOfPos(u8, xml, fr_start, "</finish_reason>") orelse break;
        finish_reason = xml[fr_start + "<finish_reason>".len .. fr_end];
        fr_pos = fr_end + "</finish_reason>".len;
    }
    //
    // if (results.items.len == 0 and finish_reason == null) return null;
    return ExtractResult{
        .content_results = results,
        .finish_reason = finish_reason,
    };
}

