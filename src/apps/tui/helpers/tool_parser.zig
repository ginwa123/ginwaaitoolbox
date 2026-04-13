const std = @import("std");
const json = std.json;

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

/// ParseResult holds the result of parsing tool call JSON
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

/// Parse tool call JSON content
/// Caller owns returned ParseResult
pub fn parseToolCallJson(content: []const u8, allocator: std.mem.Allocator) !ParseResult {
    if (content.len == 0) {
        return ParseResult{ .tools = &.{}, .is_complete = true };
    }

    // Try to parse as JSON
    var parsed = json.parseFromSlice(json.Value, allocator, content, .{}) catch {
        // Not JSON, return as single generic tool
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
    };
    defer parsed.deinit();

    const value = parsed.value;

    // Handle array of tool calls
    if (value == .array) {
        var tools = std.ArrayList(ToolData).empty;
        errdefer {
            for (tools.items) |*t| allocator.free(t.tool_name);
            tools.deinit(allocator);
        }

        for (value.array.items) |item| {
            if (item == .object) {
                if (try parseSingleToolCall(item.object, allocator)) |tool| {
                    try tools.append(allocator, tool);
                }
            }
        }

        return ParseResult{
            .tools = try tools.toOwnedSlice(allocator),
            .is_complete = true,
        };
    }

    // Handle single tool call object
    if (value == .object) {
        if (try parseSingleToolCall(value.object, allocator)) |tool| {
            var tools = std.ArrayList(ToolData).empty;
            errdefer {
                allocator.free(tool.tool_name);
                tools.deinit(allocator);
            }
            try tools.append(allocator, tool);

            return ParseResult{
                .tools = try tools.toOwnedSlice(allocator),
                .is_complete = true,
            };
        }
    }

    // Fallback: return as generic tool
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

/// Parse a single tool call object
fn parseSingleToolCall(obj: std.json.ObjectMap, allocator: std.mem.Allocator) !?ToolData {
    // Extract tool_name (try both "name" and "tool_name" for compatibility)
    const tool_name = blk: {
        if (obj.get("name")) |v| {
            if (v == .string) break :blk v.string;
        }
        if (obj.get("tool_name")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "";
    };

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
        fields.command = getStringField(obj, "command");
        fields.result = getStringField(obj, "result");
        fields.exit_code = getStringField(obj, "exit_code");
    } else if (std.mem.eql(u8, tool_name_lower, "read_file")) {
        fields.path = getStringField(obj, "path");
        fields.content = getStringField(obj, "content");
        fields.hash = getStringField(obj, "hash");
        fields.show_line_numbers = getStringField(obj, "show_line_numbers");
    } else if (std.mem.eql(u8, tool_name_lower, "write_file")) {
        fields.path = getStringField(obj, "path");
        fields.content = getStringField(obj, "content");
        fields.hash = getStringField(obj, "hash");
    } else if (std.mem.eql(u8, tool_name_lower, "web_search") or std.mem.eql(u8, tool_name_lower, "web_search_browse")) {
        fields.query = getStringField(obj, "query");
        fields.url = getStringField(obj, "url");
        fields.results = getStringField(obj, "results");
    } else if (std.mem.eql(u8, tool_name_lower, "lsp_definition") or
               std.mem.eql(u8, tool_name_lower, "lsp_hover") or
               std.mem.eql(u8, tool_name_lower, "lsp_references") or
               std.mem.eql(u8, tool_name_lower, "lsp_workspace_symbol") or
               std.mem.eql(u8, tool_name_lower, "lsp_document_symbol")) {
        fields.file_path = getStringField(obj, "file_path");
        fields.line = getStringField(obj, "line");
        fields.character = getStringField(obj, "character");
        fields.symbol = getStringField(obj, "symbol");
    } else if (std.mem.eql(u8, tool_name_lower, "spawn_sub_agent")) {
        fields.agents = getStringField(obj, "agents");
        fields.results = getStringField(obj, "results");
    } else if (std.mem.eql(u8, tool_name_lower, "search")) {
        fields.pattern = getStringField(obj, "pattern");
        fields.path = getStringField(obj, "path");
        fields.matches = getStringField(obj, "matches");
    } else if (std.mem.eql(u8, tool_name_lower, "glob")) {
        fields.pattern = getStringField(obj, "pattern");
        fields.results = getStringField(obj, "results");
    } else {
        // Generic fallback - serialize object back to JSON string
        is_parsed = false;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try json.stringify(buf.writer(allocator), obj, .{});
        fields.raw = try buf.toOwnedSlice(allocator);
    }

    const result_tool_name = try allocator.dupe(u8, tool_name_lower);
    allocator.free(tool_name_lower);

    return ToolData{
        .tool_name = result_tool_name,
        .fields = fields,
        .is_parsed = is_parsed,
        .raw_content = "",
    };
}

/// Get a string field from JSON object (borrowed slice from source)
fn getStringField(obj: std.json.ObjectMap, field: []const u8) []const u8 {
    if (obj.get(field)) |v| {
        if (v == .string) return v.string;
    }
    return "";
}

/// Legacy alias for backwards compatibility
pub const parseToolCallXml = parseToolCallJson;

test {}
