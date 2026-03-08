const std = @import("std");
const lsp_references = @import("lsp_references.zig");
const lsp_client_core = @import("lsp_client_core.zig");

test "LspReferencesInput can be instantiated" {
    const input = lsp_references.LspReferencesInput{
        .session_id = "test-session",
        .file_uri = "file:///test/test.zig",
        .line = 10,
        .character = 5,
    };
    try std.testing.expect(std.mem.eql(u8, input.session_id, "test-session"));
    try std.testing.expect(input.line == 10);
    try std.testing.expect(input.character == 5);
}

test "LspReferencesOutput can be instantiated" {
    const allocator = std.testing.allocator;
    const output = lsp_references.LspReferencesOutput{
        .file_uri = try allocator.dupe(u8, "file:///test/test.zig"),
        .line = 10,
        .character = 5,
        .references = &.{},
    };
    defer allocator.free(output.file_uri);
    
    try std.testing.expect(output.references.len == 0);
}

test "lspReferencesTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_references.lspReferencesTool.function.name, "lsp_references"));
}

test "lspReferencesTool has required parameters" {
    const params = lsp_references.lspReferencesTool.function.parameters;
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

test "executeLspReferences returns error for non-existent session" {
    const allocator = std.testing.allocator;
    
    const result = lsp_references.executeLspReferences(allocator, .{
        .session_id = "non-existent-session-12345",
        .file_uri = "file:///test/test.zig",
        .line = 10,
        .character = 5,
    });
    
    try std.testing.expectError(lsp_client_core.LspError.SessionNotFound, result);
}

test "lspReferencesToString formats output correctly" {
    const allocator = std.testing.allocator;
    const output = lsp_references.LspReferencesOutput{
        .file_uri = try allocator.dupe(u8, "file:///test/test.zig"),
        .line = 10,
        .character = 5,
        .references = &.{},
    };
    defer allocator.free(output.file_uri);
    
    const str = try lsp_references.lspReferencesToString(allocator, output);
    defer allocator.free(str);
    
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<file_uri>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<references>"));
}
