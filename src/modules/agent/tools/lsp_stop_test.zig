const std = @import("std");
const lsp_stop = @import("lsp_stop.zig");
const lsp_client_core = @import("lsp_client_core.zig");

test "LspStopInput can be instantiated" {
    const input = lsp_stop.LspStopInput{
        .session_id = "test-session",
    };
    try std.testing.expect(std.mem.eql(u8, input.session_id, "test-session"));
}

test "LspStopOutput can be instantiated" {
    const allocator = std.testing.allocator;
    const output = lsp_stop.LspStopOutput{
        .session_id = try allocator.dupe(u8, "test-session"),
        .status = try allocator.dupe(u8, "stopped"),
    };
    defer {
        allocator.free(output.session_id);
        allocator.free(output.status);
    }
    
    try std.testing.expect(std.mem.eql(u8, output.status, "stopped"));
}

test "lspStopTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_stop.lspStopTool.function.name, "lsp_stop"));
}

test "lspStopTool has session_id parameter" {
    const params = lsp_stop.lspStopTool.function.parameters;
    try std.testing.expect(params.properties.len == 1);
    try std.testing.expect(std.mem.eql(u8, params.properties[0].name, "session_id"));
}

test "executeLspStop returns error for non-existent session" {
    const allocator = std.testing.allocator;
    
    const result = lsp_stop.executeLspStop(allocator, .{
        .session_id = "non-existent-session-12345",
    });
    
    try std.testing.expectError(lsp_client_core.LspError.SessionNotFound, result);
}

test "lspStopToString formats output correctly" {
    const allocator = std.testing.allocator;
    const output = lsp_stop.LspStopOutput{
        .session_id = try allocator.dupe(u8, "my-session"),
        .status = try allocator.dupe(u8, "stopped"),
    };
    defer {
        allocator.free(output.session_id);
        allocator.free(output.status);
    }
    
    const str = try lsp_stop.lspStopToString(allocator, output);
    defer allocator.free(str);
    
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<session_id>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<status>"));
}
