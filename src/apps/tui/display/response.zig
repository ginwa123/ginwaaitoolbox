const std = @import("std");

/// XML type enum for identifying source of extracted content
pub const XmlType = enum {
    response,
    tool_result,
    content,
};

/// Content result structure - represents extracted content from XML
pub const ContentResult = struct {
    content: []const u8,
    xml_type: XmlType,
};

/// Result structure containing extracted content and finish reason
pub const ExtractResult = struct {
    content_results: std.ArrayList(ContentResult),
    finish_reason: ?[]const u8,
};

/// Extract content from XML - handles both <response> and <tool_result> tags
/// Also extracts inner <content> tags from the extracted content
/// Finds all <content>...</content> tags and the last <finish_reason>...</finish_reason>
/// Returns null if no content found
pub fn extractContentResult(allocator: std.mem.Allocator, xml: []const u8) std.mem.Allocator.Error!?ExtractResult {
    var results = std.ArrayList(ContentResult).empty;
    errdefer results.deinit(allocator);

    // Try both <response> and <tool_result> tags
    const open_response = "<response>";
    const close_response = "</response>";
    const open_tool_result = "<tool_result>";
    const close_tool_result = "</tool_result>";

    // Extract from <response> tags
    var pos: usize = 0;
    while (pos < xml.len) {
        const content_start = std.mem.indexOfPos(u8, xml, pos, open_response) orelse break;
        const content_end = std.mem.indexOfPos(u8, xml, content_start, close_response) orelse break;
        const inner_content = xml[content_start + open_response.len .. content_end];
        pos = content_end + close_response.len;

        if (inner_content.len > 0) {
            // First, try to extract <content> tags from the inner content
            var extracted_something = false;
            var inner_pos: usize = 0;
            while (inner_pos < inner_content.len) {
                const c_start = std.mem.indexOfPos(u8, inner_content, inner_pos, "<content>") orelse break;
                const c_end = std.mem.indexOfPos(u8, inner_content, c_start, "</content>") orelse break;
                const c_text = inner_content[c_start + "<content>".len .. c_end];
                inner_pos = c_end + "</content>".len;

                if (c_text.len > 0) {
                    results.append(allocator, .{ .content = c_text, .xml_type = .content }) catch break;
                    extracted_something = true;
                }
            }

            // If no <content> tags found, use the raw inner content
            if (!extracted_something and inner_content.len > 0) {
                results.append(allocator, .{ .content = inner_content, .xml_type = .response }) catch break;
            }
        }
    }

    // Extract from <tool_result> tags
    pos = 0;
    while (pos < xml.len) {
        const content_start = std.mem.indexOfPos(u8, xml, pos, open_tool_result) orelse break;
        const content_end = std.mem.indexOfPos(u8, xml, content_start, close_tool_result) orelse break;
        const inner_content = xml[content_start + open_tool_result.len .. content_end];
        pos = content_end + close_tool_result.len;

        if (inner_content.len > 0) {
            // First, try to extract <content> tags from the inner content
            var extracted_something = false;
            var inner_pos: usize = 0;
            while (inner_pos < inner_content.len) {
                const c_start = std.mem.indexOfPos(u8, inner_content, inner_pos, "<content>") orelse break;
                const c_end = std.mem.indexOfPos(u8, inner_content, c_start, "</content>") orelse break;
                const c_text = inner_content[c_start + "<content>".len .. c_end];
                inner_pos = c_end + "</content>".len;

                if (c_text.len > 0) {
                    results.append(allocator, .{ .content = c_text, .xml_type = .content }) catch break;
                    extracted_something = true;
                }
            }

            // If no <content> tags found, use the raw inner content
            if (!extracted_something and inner_content.len > 0) {
                results.append(allocator, .{ .content = inner_content, .xml_type = .tool_result }) catch break;
            }
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

    // Return null if no content found
    if (results.items.len == 0 and finish_reason == null) return null;
    return ExtractResult{
        .content_results = results,
        .finish_reason = finish_reason,
    };
}

