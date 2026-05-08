const std = @import("std");

/// Represents the type of XML tag that content was extracted from
pub const XmlType = enum {
    content,     // <content> tag inside <response> or <tool_result>
    response,    // <response> tag directly
    tool_result, // <tool_result> tag directly
};

/// Result from extracting content from XML
pub const ExtractResult = struct {
    content_results: std.ArrayListUnmanaged(ContentResult),
    finish_reason: ?[]const u8,
    tool_calls: ?[]ToolCallInfo,

    pub fn deinit(self: *ExtractResult, allocator: std.mem.Allocator) void {
        for (self.content_results.items) |*cr| {
            cr.deinit(allocator);
        }
        self.content_results.deinit(allocator);
        if (self.finish_reason) |fr| {
            allocator.free(fr);
        }
        if (self.tool_calls) |tc| {
            for (tc) |*call| {
                call.deinit(allocator);
            }
            allocator.free(tc);
        }
    }
};

/// Result from extracting a single content item
pub const ContentResult = struct {
    content: []const u8,
    xml_type: XmlType,

    pub fn deinit(self: *ContentResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

/// Tool call information extracted from XML
pub const ToolCallInfo = struct {
    name: []const u8,
    arguments: []const u8,

    pub fn deinit(self: *ToolCallInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.arguments);
    }
};

/// Extract content from XML - handles both <response> and <tool_result> tags.
/// Strips <think> blocks from extracted content.
/// Returns null if no matching tags found.
pub fn extract_content_result(allocator: std.mem.Allocator, xml: []const u8) !?ExtractResult {
    var results: std.ArrayListUnmanaged(ContentResult) = .empty;
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
    var tool_calls: std.ArrayListUnmanaged(ToolCallInfo) = .empty;
    errdefer tool_calls.deinit(allocator);
    var tc_pos: usize = 0;
    while (tc_pos < xml.len) {
        const tc_start = std.mem.indexOfPos(u8, xml, tc_pos, "<tool_call>") orelse break;
        const tc_end = std.mem.indexOfPos(u8, xml, tc_start, "</tool_call>") orelse break;
        const tc_block = xml[tc_start..tc_end];

        const name_start = std.mem.indexOf(u8, tc_block, "<name>") orelse continue;
        const name_end = std.mem.indexOf(u8, tc_block[name_start..], "</name>") orelse continue;
        const name = tc_block[name_start + "<name>".len .. name_end + "</name>".len];

        const args_start = std.mem.indexOf(u8, tc_block, "<arguments>") orelse continue;
        const args_end = std.mem.indexOf(u8, tc_block[args_start..], "</arguments>") orelse continue;
        const arguments = tc_block[args_start + "<arguments>".len .. args_start + args_end + "</arguments>".len];

        try tool_calls.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .arguments = try allocator.dupe(u8, arguments),
        });

        tc_pos = tc_end + "</tool_call>".len;
    }

    // If no content found, return null
    if (results.items.len == 0 and tool_calls.items.len == 0) {
        return null;
    }

    const tool_calls_slice = if (tool_calls.items.len > 0) try tool_calls.toOwnedSlice(allocator) else null;

    return ExtractResult{
        .content_results = results,
        .finish_reason = finish_reason,
        .tool_calls = tool_calls_slice,
    };
}

/// Helper function to extract content from a specific tag
fn extractTagContent(allocator: std.mem.Allocator, results: *std.ArrayListUnmanaged(ContentResult), xml: []const u8, open_tag: []const u8, close_tag: []const u8, xml_type: XmlType) !void {
    var pos: usize = 0;
    while (pos < xml.len) {
        const start = std.mem.indexOfPos(u8, xml, pos, open_tag) orelse break;
        const content_start = start + open_tag.len;
        const end = std.mem.indexOfPos(u8, xml, content_start, close_tag) orelse break;

        // Extract content between tags
        const inner = xml[content_start..end];

        // Check for <content> tag inside
        const content_tag_start = std.mem.indexOf(u8, inner, "<content>");
        const content_tag_end = std.mem.indexOf(u8, inner, "</content>");

        var extracted_content: []const u8 = undefined;
        var extracted_type: XmlType = undefined;

        if (content_tag_start != null and content_tag_end != null) {
            const content_inner_start = content_tag_start.? + "<content>".len;
            extracted_content = inner[content_inner_start..content_tag_end.?];
            extracted_type = .content;
        } else if (inner.len > 0) {
            // Use raw content as fallback
            extracted_content = inner;
            extracted_type = xml_type;
        } else {
            // Empty content - use raw tag as content
            extracted_content = try std.fmt.allocPrint(allocator, "{s}{s}", .{ open_tag, close_tag });
            extracted_type = xml_type;
        }

        // Strip <think> blocks from content
        const stripped = try stripThinkBlocks(allocator, extracted_content);

        try results.append(allocator, .{
            .content = stripped,
            .xml_type = extracted_type,
        });

        pos = end + close_tag.len;
    }
}

/// Strip <think> blocks from content
fn stripThinkBlocks(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (pos < content.len) {
        const think_start = std.mem.indexOfPos(u8, content, pos, "<think>");
        if (think_start == null) {
            try result.appendSlice(allocator, content[pos..]);
            break;
        }

        try result.appendSlice(allocator, content[pos..think_start.?]);

        const think_end = std.mem.indexOfPos(u8, content, think_start.?, "");
        if (think_end == null) {
            break;
        }

        pos = think_end.? + "".len;
    }

    return result.toOwnedSlice(allocator);
}