const std = @import("std");

/// XML format detection result
pub const XmlFormat = enum {
    xml,
    json,
    unknown,
};

/// Decode XML entities in a string
/// Caller owns returned slice
pub fn decodeXmlEntities(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '&') {
            // Find semicolon after '&'
            const maybe_semicol = std.mem.indexOfScalar(u8, input[i..], ';');
            if (maybe_semicol) |semicol_offset| {
                // Entity is between '&' and ';'
                const entity = input[i + 1 .. i + semicol_offset];
                
                // Map known entities
                const decoded: ?[]const u8 = if (std.mem.eql(u8, entity, "lt"))
                    "<"
                else if (std.mem.eql(u8, entity, "gt"))
                    ">"
                else if (std.mem.eql(u8, entity, "amp"))
                    "&"
                else if (std.mem.eql(u8, entity, "quot"))
                    "\""
                else if (std.mem.eql(u8, entity, "apos"))
                    "'"
                else
                    null;

                if (decoded) |d| {
                    _ = try result.appendSlice(allocator, d);
                    i += semicol_offset + 1; // Skip past ';'
                    continue;
                }
            }
        }
        _ = try result.append(allocator, input[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

/// Extract content between XML tags (last occurrence)
/// Caller owns returned slice
pub fn extractTag(xml: []const u8, tag: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    const open_tag = try std.fmt.allocPrint(allocator, "<{s}>", .{tag});
    defer allocator.free(open_tag);

    const close_tag = try std.fmt.allocPrint(allocator, "</{s}>", .{tag});
    defer allocator.free(close_tag);

    // Find last occurrence of open_tag (handles nested tags)
    const open_pos = std.mem.lastIndexOf(u8, xml, open_tag) orelse return null;
    const close_pos = std.mem.lastIndexOf(u8, xml, close_tag) orelse return null;

    if (close_pos <= open_pos) return null;

    const content = xml[open_pos + open_tag.len .. close_pos];
    return try allocator.dupe(u8, content);
}

/// Detect if content is XML, JSON, or unknown format
pub fn detectFormat(text: []const u8) XmlFormat {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return .unknown;

    switch (trimmed[0]) {
        '<' => return .xml,
        '{', '[' => return .json,
        else => return .unknown,
    }
}

/// Check if content appears to be tool call XML format
pub fn isToolCallXml(content: []const u8) bool {
    if (content.len == 0) return false;
    return std.mem.indexOf(u8, content, "<tool_call>") != null or
           std.mem.indexOf(u8, content, "<tool_name>") != null;
}
