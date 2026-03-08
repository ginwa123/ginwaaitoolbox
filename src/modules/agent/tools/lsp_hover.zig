const std = @import("std");
const json = std.json;
const lsp_client_core = @import("lsp_client_core.zig");
const AgentTool = @import("models.zig").AgentTool;

pub const LspHoverInput = struct {
    session_id: []const u8,
    file_uri: []const u8,
    line: u32,
    character: u32,
};

pub const LspHoverOutput = struct {
    file_uri: []u8,
    line: u32,
    character: u32,
    contents: []u8,
};

pub fn executeLspHover(allocator: std.mem.Allocator, input: LspHoverInput) !LspHoverOutput {
    const sessions_ptr = lsp_client_core.getSessions();
    const client = sessions_ptr.get(input.session_id) orelse return lsp_client_core.LspError.SessionNotFound;
    
    if (!client.initialized) return lsp_client_core.LspError.NotInitialized;
    
    const request_id = client.next_request_id;
    client.next_request_id += 1;
    
    // Build hover request
    var req_json = std.ArrayList(u8).empty;
    defer req_json.deinit(allocator);
    
    try req_json.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try req_json.writer(allocator).print("{d}", .{request_id});
    try req_json.appendSlice(allocator, ",\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"");
    try req_json.appendSlice(allocator, input.file_uri);
    try req_json.appendSlice(allocator, "\"},\"position\":{\"line\":");
    try req_json.writer(allocator).print("{d}", .{input.line});
    try req_json.appendSlice(allocator, ",\"character\":");
    try req_json.writer(allocator).print("{d}", .{input.character});
    try req_json.appendSlice(allocator, "}}}");
    
    try lsp_client_core.writeMessage(client.stdin, req_json.items);
    
    // Read response
    const response = lsp_client_core.readMessage(client.stdout, allocator) catch return lsp_client_core.LspError.InvalidResponse;
    defer allocator.free(response);
    
    var parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
        return lsp_client_core.LspError.InvalidResponse;
    };
    defer parsed.deinit();
    
    var contents: []u8 = try allocator.dupe(u8, "");
    
    if (parsed.value == .object) {
        const result_val = parsed.value.object.get("result") orelse return lsp_client_core.LspError.InvalidResponse;
        
        if (result_val == .object) {
            const contents_val = result_val.object.get("contents") orelse return lsp_client_core.LspError.InvalidResponse;
            
            if (contents_val == .string) {
                contents = try allocator.dupe(u8, contents_val.string);
            } else if (contents_val == .object) {
                const value_val = contents_val.object.get("value") orelse return lsp_client_core.LspError.InvalidResponse;
                if (value_val == .string) {
                    contents = try allocator.dupe(u8, value_val.string);
                }
            }
        }
    }
    
    return .{
        .file_uri = try allocator.dupe(u8, input.file_uri),
        .line = input.line,
        .character = input.character,
        .contents = contents,
    };
}

pub fn lspHoverToString(allocator: std.mem.Allocator, result: LspHoverOutput) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<file_uri>{s}</file_uri>
        \\<line>{d}</line>
        \\<character>{d}</character>
        \\<contents>{s}</contents>
    , .{
        result.file_uri,
        result.line,
        result.character,
        result.contents,
    });
}

pub const lspHoverTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_hover",
        .description = "Get type information at cursor position",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "session_id",
                    .type = "string",
                    .description = "Session identifier",
                },
                .{
                    .name = "file_uri",
                    .type = "string",
                    .description = "File URI (e.g., file:///path/to/file.zig)",
                },
                .{
                    .name = "line",
                    .type = "number",
                    .description = "Line number (0-indexed)",
                },
                .{
                    .name = "character",
                    .type = "number",
                    .description = "Character position (0-indexed)",
                },
            },
            .required = &.{ "session_id", "file_uri", "line", "character" },
        },
    },
};
