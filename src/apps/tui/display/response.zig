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
    tool_calls: ?[]ToolCallInfo,
};

/// Strip <think>...</think> block (if any) and trim surrounding whitespace.
/// Only strips ONE leading think block — the model always emits it first.
fn stripThinkBlocks(text: []const u8) []const u8 {
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

/// ToolCallInfo holds the name and arguments of a tool call
pub const ToolCallInfo = struct {
    name: []const u8,
    arguments: []const u8,
};

/// Extract content from XML - handles both <response> and <tool_result> tags.
/// Strips <think> blocks from extracted content.
/// Returns null if no matching tags found.
pub fn extract_content_result(allocator: std.mem.Allocator, xml: []const u8) !?ExtractResult {
    var results = std.ArrayListUnmanaged(ContentResult){};
    errdefer results.deinit(allocator);

    try extractTagContent(allocator, &results, xml, "<response>", "</response>", .response);
    try extractTagContent(allocator, &results, xml, "<tool_result>", "</tool_result>", .tool_result);

    // Extract the LAST <finish_reason> tag (streaming may produce multiple)
    var finish_reason: ?[]const u8 = null;
    var fr_pos: usize = 0;
    while (fr_pos < xml.len) {
        const fr_start = std.mem.indexOfPos(u8, xml, fr_pos, "<finish_reason>") orelse break;
        const fr_end = std.mem.indexOfPos(u8, xml, fr_start, "</finish_reason>") orelse break;
        finish_reason = xml[fr_start + "<finish_reason>".len .. fr_end];
        fr_pos = fr_end + "</finish_reason>".len;
    }

    // Extract tool calls if present
    var tool_calls: std.ArrayListUnmanaged(ToolCallInfo) = .{};
    errdefer tool_calls.deinit(allocator);
    var tc_pos: usize = 0;
    while (tc_pos < xml.len) {
        const tc_start = std.mem.indexOfPos(u8, xml, tc_pos, "<tool_call>") orelse break;
        const tc_end = std.mem.indexOfPos(u8, xml, tc_start, "</tool_call>") orelse break;
        const tc_block = xml[tc_start..tc_end];
        tc_pos = tc_end + "</tool_call>".len;

        // Extract name from tool_call block
        var tool_name: []const u8 = "";
        var tool_args: []const u8 = "";
        if (std.mem.indexOf(u8, tc_block, "<name>")) |name_start| {
            const name_start_tag = name_start + "<name>".len;
            if (std.mem.indexOfPos(u8, tc_block, name_start_tag, "</name>")) |name_end| {
                tool_name = tc_block[name_start_tag..name_end];
            }
        }
        // Extract arguments from tool_call block
        if (std.mem.indexOf(u8, tc_block, "<arguments>")) |args_start| {
            const args_start_tag = args_start + "<arguments>".len;
            if (std.mem.indexOfPos(u8, tc_block, args_start_tag, "</arguments>")) |args_end| {
                tool_args = tc_block[args_start_tag..args_end];
            }
        }
        if (tool_name.len > 0) {
            try tool_calls.append(allocator, .{ .name = tool_name, .arguments = tool_args });
        }
    }

    // Return null only if there are no content_results, finish_reason, AND tool_calls
    if (results.items.len == 0 and finish_reason == null and tool_calls.items.len == 0) {
        return null;
    }

    return ExtractResult{
        .content_results = results,
        .finish_reason = finish_reason,
        .tool_calls = if (tool_calls.items.len > 0) try tool_calls.toOwnedSlice(allocator) else null,
    };
}

fn extractTagContent(
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
                const cleaned = stripThinkBlocks(c_text);
                if (cleaned.len > 0) {
                    try results.append(allocator, .{ .content = cleaned, .xml_type = .content });
                    extracted_any = true;
                }
            } else {
                // Empty <content></content>: fall back to raw inner XML as outer type
                try results.append(allocator, .{ .content = inner, .xml_type = outer_type });
                // extracted_any = true;
                extracted_any = true;
            }
        }

        if (!extracted_any and inner.len > 0) {
            const cleaned = stripThinkBlocks(inner);
            if (cleaned.len > 0) {
                try results.append(allocator, .{ .content = cleaned, .xml_type = outer_type });
            }
        }
    }
}
