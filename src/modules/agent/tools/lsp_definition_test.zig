const std = @import("std");
const lsp_definition = @import("lsp_definition.zig");
const lsp_client_core = @import("lsp_client_core.zig");

test "LspDefinitionInput can be instantiated" {
    const input = lsp_definition.LspDefinitionInput{
        .session_id = "test-session",
        .file_uri = "file:///test/test.zig",
        .line = 10,
        .character = 5,
    };
    try std.testing.expect(std.mem.eql(u8, input.session_id, "test-session"));
    try std.testing.expect(input.line == 10);
    try std.testing.expect(input.character == 5);
}

test "LspDefinitionOutput can be instantiated" {
    const allocator = std.testing.allocator;
    const output = lsp_definition.LspDefinitionOutput{
        .file_uri = try allocator.dupe(u8, "file:///test/test.zig"),
        .line = 10,
        .character = 5,
        .definitions = &.{},
    };
    defer allocator.free(output.file_uri);
    
    try std.testing.expect(output.definitions.len == 0);
}

test "lspDefinitionTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_definition.lspDefinitionTool.function.name, "lsp_definition"));
}

test "lspDefinitionTool has required parameters" {
    const params = lsp_definition.lspDefinitionTool.function.parameters;
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

test "executeLspDefinition returns error for non-existent session" {
    const allocator = std.testing.allocator;
    
    const result = lsp_definition.executeLspDefinition(allocator, .{
        .session_id = "non-existent-session-12345",
        .file_uri = "file:///test/test.zig",
        .line = 10,
        .character = 5,
    });
    
    try std.testing.expectError(lsp_client_core.LspError.SessionNotFound, result);
}

test "lspDefinitionToString formats output correctly" {
    const allocator = std.testing.allocator;
    const output = lsp_definition.LspDefinitionOutput{
        .file_uri = try allocator.dupe(u8, "file:///test/test.zig"),
        .line = 10,
        .character = 5,
        .definitions = &.{},
    };
    defer allocator.free(output.file_uri);
    
    const str = try lsp_definition.lspDefinitionToString(allocator, output);
    defer allocator.free(str);
    
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<file_uri>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<definitions>"));
}
