const std = @import("std");
const lsp_diagnostics = @import("lsp_diagnostics.zig");
const lsp_client_core = @import("lsp_client_core.zig");

test "LspDiagnosticsInput can be instantiated" {
    const input = lsp_diagnostics.LspDiagnosticsInput{
        .session_id = "test-session",
        .file_uri = "file:///test/test.zig",
    };
    try std.testing.expect(std.mem.eql(u8, input.session_id, "test-session"));
    try std.testing.expect(std.mem.eql(u8, input.file_uri, "file:///test/test.zig"));
}

test "LspDiagnosticsOutput can be instantiated" {
    const allocator = std.testing.allocator;
    const output = lsp_diagnostics.LspDiagnosticsOutput{
        .file_uri = try allocator.dupe(u8, "file:///test/test.zig"),
        .diagnostics = &.{},
    };
    defer allocator.free(output.file_uri);
    
    try std.testing.expect(output.diagnostics.len == 0);
}

test "lspDiagnosticsTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_diagnostics.lspDiagnosticsTool.function.name, "lsp_diagnostics"));
}

test "lspDiagnosticsTool has required parameters" {
    const params = lsp_diagnostics.lspDiagnosticsTool.function.parameters;
    try std.testing.expect(params.properties.len == 2);
    
    var has_session_id = false;
    var has_file_uri = false;
    
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "session_id")) has_session_id = true;
        if (std.mem.eql(u8, prop.name, "file_uri")) has_file_uri = true;
    }
    
    try std.testing.expect(has_session_id);
    try std.testing.expect(has_file_uri);
}

test "executeLspDiagnostics returns error for non-existent session" {
    const allocator = std.testing.allocator;
    
    const result = lsp_diagnostics.executeLspDiagnostics(allocator, .{
        .session_id = "non-existent-session-12345",
        .file_uri = "file:///test/test.zig",
    });
    
    try std.testing.expectError(lsp_client_core.LspError.SessionNotFound, result);
}

// Note: Testing uninitialized session requires a running LSP server
// This would be an integration test
