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
    content_results: std.ArrayListUnmanaged(ContentResult),
    finish_reason: ?[]const u8,
};

/// Strip <think>...</think> block (if any) and trim surrounding whitespace.
/// Only strips ONE leading think block — the model always emits it first.
fn strip_think_blocks(text: []const u8) []const u8 {
    const think_open = "<think>";
    const think_close = "</think>";

    const trimmed = std.mem.trimLeft(u8, text, " \t\n\r");

    if (std.mem.startsWith(u8, trimmed, think_open)) {
        const close_pos = std.mem.indexOf(u8, trimmed, think_close) orelse
            return std.mem.trim(u8, text, " \t\n\r");
        const after = trimmed[close_pos + think_close.len ..];
        return std.mem.trim(u8, after, " \t\n\r");
    }

    return std.mem.trim(u8, text, " \t\n\r");
}

/// Extract content from XML - handles both <response> and <tool_result> tags.
/// Strips <think> blocks from extracted content.
/// Returns null if no matching tags found.
pub fn extract_content_result(allocator: std.mem.Allocator, xml: []const u8) !?ExtractResult {
    var results = std.ArrayListUnmanaged(ContentResult){};
    errdefer results.deinit(allocator);


    try extract_tag_content(allocator, &results, xml, "<response>", "</response>", .response);
    try extract_tag_content(allocator, &results, xml, "<tool_result>", "</tool_result>", .tool_result);

    // Extract the LAST <finish_reason> tag (streaming may produce multiple)
    var finish_reason: ?[]const u8 = null;
    var fr_pos: usize = 0;
    while (fr_pos < xml.len) {
        const fr_start = std.mem.indexOfPos(u8, xml, fr_pos, "<finish_reason>") orelse break;
        const fr_end = std.mem.indexOfPos(u8, xml, fr_start, "</finish_reason>") orelse break;
        finish_reason = xml[fr_start + "<finish_reason>".len .. fr_end];
        fr_pos = fr_end + "</finish_reason>".len;
    }

    if (results.items.len == 0 and finish_reason == null) {
        return null;
    }

    return ExtractResult{
        .content_results = results,
        .finish_reason = finish_reason,
    };
}

fn extract_tag_content(
    allocator: std.mem.Allocator,
    results: *std.ArrayListUnmanaged(ContentResult),
    xml: []const u8,
    open_tag: []const u8,
    close_tag: []const u8,
    outer_type: XmlType,
) !void {
    var pos: usize = 0;
    while (pos < xml.len) {
        const start = std.mem.indexOfPos(u8, xml, pos, open_tag) orelse break;
        const end = std.mem.indexOfPos(u8, xml, start + open_tag.len, close_tag) orelse break;
        const inner = xml[start + open_tag.len .. end];
        pos = end + close_tag.len;

        var inner_pos: usize = 0;
        var extracted_any = false;
        while (inner_pos < inner.len) {
            const c_start = std.mem.indexOfPos(u8, inner, inner_pos, "<content>") orelse break;
            const c_end = std.mem.indexOfPos(u8, inner, c_start + "<content>".len, "</content>") orelse break;
            const c_text = inner[c_start + "<content>".len .. c_end];
            inner_pos = c_end + "</content>".len;

            if (c_text.len > 0) {
                const cleaned = strip_think_blocks(c_text);
                if (cleaned.len > 0) {
                    try results.append(allocator, .{ .content = cleaned, .xml_type = .content });
                    extracted_any = true;
                }
            } else {
                // Empty <content></content>: fall back to raw inner XML as outer type
                try results.append(allocator, .{ .content = inner, .xml_type = outer_type });
                extracted_any = true;
            }
        }

        if (!extracted_any and inner.len > 0) {
            const cleaned = strip_think_blocks(inner);
            if (cleaned.len > 0) {
                try results.append(allocator, .{ .content = cleaned, .xml_type = outer_type });
            }
        }
    }
}
