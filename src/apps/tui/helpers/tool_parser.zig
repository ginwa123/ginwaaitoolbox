const std = @import("std");
const xml_parser = @import("xml_parser.zig");

/// ToolFields holds the extracted fields for a tool
pub const ToolFields = struct {
    // Common fields
    command: []const u8 = "",
    result: []const u8 = "",
    exit_code: []const u8 = "",
    
    // File tool fields
    path: []const u8 = "",
    content: []const u8 = "",
    hash: []const u8 = "",
    show_line_numbers: []const u8 = "",
    
    // Search tool fields
    pattern: []const u8 = "",
    matches: []const u8 = "",
    results: []const u8 = "",
    
    // Web search fields
    query: []const u8 = "",
    url: []const u8 = "",
    
    // LSP tool fields
    file_path: []const u8 = "",
    line: []const u8 = "",
    character: []const u8 = "",
    symbol: []const u8 = "",
    
    // Spawn sub-agent fields
    agents: []const u8 = "",
    
    // Generic fallback
    raw: []const u8 = "",
};

/// ToolData holds parsed tool call information
pub const ToolData = struct {
    tool_name: []const u8,
    fields: ToolFields,
    is_parsed: bool,
    raw_content: []const u8,
    
    /// Get summary for collapsed display
    pub fn getToolSummary(self: *const ToolData, allocator: std.mem.Allocator) ![]u8 {
        if (std.mem.eql(u8, self.tool_name, "bash")) {
            return try allocator.dupe(u8, self.fields.command);
        } else if (std.mem.eql(u8, self.tool_name, "read_file")) {
            return try allocator.dupe(u8, self.fields.path);
        } else if (std.mem.eql(u8, self.tool_name, "write_file")) {
            if (self.fields.path.len > 0) {
                return try std.fmt.allocPrint(allocator, "Written: {s}", .{self.fields.path});
            } else {
                return try allocator.dupe(u8, "file");
            }
        } else if (std.mem.eql(u8, self.tool_name, "web_search") or std.mem.eql(u8, self.tool_name, "web_search_browse")) {
            if (self.fields.query.len > 0) {
                return try std.fmt.allocPrint(allocator, "Web: {s}", .{self.fields.query});
            } else if (self.fields.url.len > 0) {
                return try std.fmt.allocPrint(allocator, "Web: {s}", .{self.fields.url});
            } else {
                return try allocator.dupe(u8, "search");
            }
        } else if (std.mem.eql(u8, self.tool_name, "spawn_sub_agent")) {
            if (self.fields.agents.len > 0) {
                return try std.fmt.allocPrint(allocator, "Agents: {s}", .{self.fields.agents});
            } else {
                return try allocator.dupe(u8, "spawn");
            }
        } else {
            return try allocator.dupe(u8, self.tool_name);
        }
    }
};

/// ParseResult holds the result of parsing tool call XML
pub const ParseResult = struct {
    tools: []ToolData,
    is_complete: bool,
    
    /// Free owned memory
    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        for (self.tools) |tool| {
            allocator.free(tool.tool_name);
        }
        allocator.free(self.tools);
    }
};

/// Parse tool call XML content
/// Caller owns returned ParseResult
pub fn parseToolCallXml(content: []const u8, allocator: std.mem.Allocator) !ParseResult {
    if (content.len == 0) {
        return ParseResult{ .tools = &.{}, .is_complete = true };
    }
    
    // Check if content is tool call XML format
    if (!xml_parser.isToolCallXml(content)) {
        // Not tool call XML, return as single generic tool
        const tool = ToolData{
            .tool_name = try allocator.dupe(u8, "unknown"),
            .fields = ToolFields{ .raw = content },
            .is_parsed = false,
            .raw_content = content,
        };
        var tools = std.ArrayList(ToolData).empty;
        defer tools.deinit(allocator);
        try tools.append(allocator, tool);
        
        return ParseResult{
            .tools = try tools.toOwnedSlice(allocator),
            .is_complete = true,
        };
    }
    
    var tools = std.ArrayList(ToolData).empty;
    errdefer {
        for (tools.items) |*t| allocator.free(t.tool_name);
        tools.deinit(allocator);
    }
    
    // Handle multiple tool calls wrapped in <tool_calls>
    if (std.mem.indexOf(u8, content, "<tool_calls>")) |_| {
        const start = (std.mem.indexOf(u8, content, ">").?) + 1;
        const end = (std.mem.lastIndexOf(u8, content, "</tool_calls>").?);
        const tool_calls_section = content[start..end];
        
        var pos: usize = 0;
        while (pos < tool_calls_section.len) {
            const tc_start = std.mem.indexOf(u8, tool_calls_section[pos..], "<tool_call>") orelse break;
            const tc_start_pos = pos + tc_start;
            const tc_end = std.mem.indexOf(u8, tool_calls_section[tc_start_pos..], "</tool_call>") orelse break;
            const tc_block = tool_calls_section[tc_start_pos..tc_start_pos + tc_end + "</tool_call>".len];
            pos = tc_start_pos + tc_end + "</tool_call>".len;
            
            if (try parseSingleToolCall(tc_block, allocator)) |tool| {
                try tools.append(allocator, tool);
            }
        }
    } else {
        // Single tool call
        if (try parseSingleToolCall(content, allocator)) |tool| {
            try tools.append(allocator, tool);
        }
    }
    
    // Check completeness
    const is_complete = !isIncompleteToolXml(content);
    
    return ParseResult{
        .tools = try tools.toOwnedSlice(allocator),
        .is_complete = is_complete,
    };
}

/// Check if content appears to be incomplete (streaming)
fn isIncompleteToolXml(content: []const u8) bool {
    const opens = std.mem.count(u8, content, "<tool_call>");
    const closes = std.mem.count(u8, content, "</tool_call>");
    if (opens > closes) return true;
    
    const opens_multi = std.mem.count(u8, content, "<tool_calls>");
    const closes_multi = std.mem.count(u8, content, "</tool_calls>");
    if (opens_multi > closes_multi) return true;
    
    return false;
}

/// Parse a single <tool_call>...</tool_call> block
fn parseSingleToolCall(tool_call_xml: []const u8, allocator: std.mem.Allocator) !?ToolData {
    // Extract tool_name
    const tool_name = extractField(tool_call_xml, "tool_name") orelse return null;
    if (tool_name.len == 0) return null;
    
    // Lowercase for case-insensitive matching
    const tool_name_lower = blk: {
        const buf = try allocator.alloc(u8, tool_name.len);
        @memcpy(buf, tool_name);
        for (buf) |*c| c.* = std.ascii.toLower(c.*);
        break :blk buf;
    };
    errdefer allocator.free(tool_name_lower);
    
    var fields = ToolFields{};
    var is_parsed = true;
    
    // Route to appropriate parser based on tool type
    if (std.mem.eql(u8, tool_name_lower, "bash")) {
        fields.command = extractField(tool_call_xml, "command") orelse "";
        fields.result = extractField(tool_call_xml, "result") orelse "";
        fields.exit_code = extractField(tool_call_xml, "exit_code") orelse "";
    } else if (std.mem.eql(u8, tool_name_lower, "read_file")) {
        fields.path = extractField(tool_call_xml, "path") orelse "";
        fields.content = extractField(tool_call_xml, "content") orelse "";
        fields.hash = extractField(tool_call_xml, "hash") orelse "";
        fields.show_line_numbers = extractField(tool_call_xml, "show_line_numbers") orelse "";
    } else if (std.mem.eql(u8, tool_name_lower, "write_file")) {
        fields.path = extractField(tool_call_xml, "path") orelse "";
        fields.content = extractField(tool_call_xml, "content") orelse "";
        fields.hash = extractField(tool_call_xml, "hash") orelse "";
    } else if (std.mem.eql(u8, tool_name_lower, "web_search") or std.mem.eql(u8, tool_name_lower, "web_search_browse")) {
        fields.query = extractField(tool_call_xml, "query") orelse "";
        fields.url = extractField(tool_call_xml, "url") orelse "";
        fields.results = extractField(tool_call_xml, "results") orelse "";
    } else if (std.mem.eql(u8, tool_name_lower, "lsp_definition") or
               std.mem.eql(u8, tool_name_lower, "lsp_hover") or
               std.mem.eql(u8, tool_name_lower, "lsp_references") or
               std.mem.eql(u8, tool_name_lower, "lsp_workspace_symbol") or
               std.mem.eql(u8, tool_name_lower, "lsp_document_symbol")) {
        fields.file_path = extractField(tool_call_xml, "file_path") orelse "";
        fields.line = extractField(tool_call_xml, "line") orelse "";
        fields.character = extractField(tool_call_xml, "character") orelse "";
        fields.symbol = extractField(tool_call_xml, "symbol") orelse "";
    } else if (std.mem.eql(u8, tool_name_lower, "spawn_sub_agent")) {
        fields.agents = extractField(tool_call_xml, "agents") orelse "";
        fields.results = extractField(tool_call_xml, "results") orelse "";
    } else {
        // Generic fallback
        is_parsed = false;
        fields.raw = tool_call_xml;
    }
    
    const result_tool_name = try allocator.dupe(u8, tool_name_lower);
    allocator.free(tool_name_lower);
    
    return ToolData{
        .tool_name = result_tool_name,
        .fields = fields,
        .is_parsed = is_parsed,
        .raw_content = tool_call_xml,
    };
}

/// Extract a field value from tool call XML (borrowed slice)
fn extractField(xml: []const u8, field_name: []const u8) ?[]const u8 {
    const start_tag = std.fmt.allocPrint(std.heap.page_allocator, "<{s}>", .{field_name}) catch return null;
    defer std.heap.page_allocator.free(start_tag);
    const end_tag = std.fmt.allocPrint(std.heap.page_allocator, "</{s}>", .{field_name}) catch return null;
    defer std.heap.page_allocator.free(end_tag);
    
    const open_pos = std.mem.indexOf(u8, xml, start_tag) orelse return null;
    const close_pos = std.mem.indexOf(u8, xml, end_tag) orelse return null;
    
    if (close_pos <= open_pos + start_tag.len) return null;
    
    return xml[open_pos + start_tag.len .. close_pos];
}
