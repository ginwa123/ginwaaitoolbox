const std = @import("std");
const lsp_hover = @import("lsp_hover.zig");
const lsp_client_core = @import("lsp_client_core.zig");

test "LspHoverInput can be instantiated" {
    const input = lsp_hover.LspHoverInput{
        .session_id = "test-session",
        .file_uri = "file:///test/test.zig",
        .line = 10,
        .character = 5,
    };
    try std.testing.expect(std.mem.eql(u8, input.session_id, "test-session"));
    try std.testing.expect(input.line == 10);
    try std.testing.expect(input.character == 5);
}

test "LspHoverOutput can be instantiated" {
    const allocator = std.testing.allocator;
    const output = lsp_hover.LspHoverOutput{
        .file_uri = try allocator.dupe(u8, "file:///test/test.zig"),
        .line = 10,
        .character = 5,
        .contents = try allocator.dupe(u8, "type: i32"),
    };
    defer {
        allocator.free(output.file_uri);
        allocator.free(output.contents);
    }
    
    try std.testing.expect(std.mem.eql(u8, output.contents, "type: i32"));
}

test "lspHoverTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_hover.lspHoverTool.function.name, "lsp_hover"));
}

test "lspHoverTool has required parameters" {
    const params = lsp_hover.lspHoverTool.function.parameters;
    try std.testing.expect(params.properties.len == 4);
    
    var has_session_id = false;
    var has_file_uri = false;
    var has_line = false;
    var has_character = false;
    
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "session_id")) has_session_id = true;
        if (std.mem.eql(u8, prop.name, "file_uri")) has_file_uri = true;
        if (std.mem.eql(u8, prop.name, "line")) has_line = true;
        if (std.mem.eql(u8, prop.name, "character")) has_character = true;
    }
    
    try std.testing.expect(has_session_id);
    try std.testing.expect(has_file_uri);
    try std.testing.expect(has_line);
    try std.testing.expect(has_character);
}

test "executeLspHover returns error for non-existent session" {
    const allocator = std.testing.allocator;
    
    const result = lsp_hover.executeLspHover(allocator, .{
        .session_id = "non-existent-session-12345",
        .file_uri = "file:///test/test.zig",
        .line = 10,
        .character = 5,
    });
    
    try std.testing.expectError(lsp_client_core.LspError.SessionNotFound, result);
}

test "lspHoverToString formats output correctly" {
    const allocator = std.testing.allocator;
    const output = lsp_hover.LspHoverOutput{
        .file_uri = try allocator.dupe(u8, "file:///test/test.zig"),
        .line = 10,
        .character = 5,
        .contents = try allocator.dupe(u8, "type: i32"),
    };
    defer {
        allocator.free(output.file_uri);
        allocator.free(output.contents);
    }
    
    const str = try lsp_hover.lspHoverToString(allocator, output);
    defer allocator.free(str);
    
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<contents>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "type: i32"));
}
