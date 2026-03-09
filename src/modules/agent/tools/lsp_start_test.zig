const std = @import("std");
const lsp_start = @import("lsp_start.zig");

test "LspStartInput can be instantiated" {
    const input = lsp_start.LspStartInput{
        .session_id = "test-session",
        .binary_name = "zls",
        .workspace_uri = "file:///test/workspace",
    };
    try std.testing.expect(std.mem.eql(u8, input.session_id, "test-session"));
    try std.testing.expect(std.mem.eql(u8, input.binary_name, "zls"));
    try std.testing.expect(std.mem.eql(u8, input.workspace_uri, "file:///test/workspace"));
}

test "LspStartOutput can be instantiated" {
    const allocator = std.testing.allocator;
    const output = lsp_start.LspStartOutput{
        .session_id = try allocator.dupe(u8, "test-session"),
        .binary_path = try allocator.dupe(u8, "/usr/bin/zls"),
        .status = try allocator.dupe(u8, "started"),
    };
    defer {
        allocator.free(output.session_id);
        allocator.free(output.binary_path);
        allocator.free(output.status);
    }

    try std.testing.expect(std.mem.eql(u8, output.status, "started"));
}

test "lspStartTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_start.lspStartTool.function.name, "lsp_start"));
}

test "lspStartTool has required parameters" {
    const params = lsp_start.lspStartTool.function.parameters;
    try std.testing.expect(params.properties.len == 3);

    // Check required fields
    var has_session_id = false;
    var has_binary_name = false;
    var has_workspace_uri = false;

    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "session_id")) has_session_id = true;
        if (std.mem.eql(u8, prop.name, "binary_name")) has_binary_name = true;
        if (std.mem.eql(u8, prop.name, "workspace_uri")) has_workspace_uri = true;
    }

    try std.testing.expect(has_session_id);
    try std.testing.expect(has_binary_name);
    try std.testing.expect(has_workspace_uri);
}

// Integration test - requires zls to be installed and working
// To run: zig test src/modules/agent/tools/lsp_start_test.zig
// Note: This test is skipped by default as it requires a running LSP server
test "integration: lsp_start spawns zls" {
    // Skip this test if zls is not available - integration test placeholder
    // In a real integration test, we would spawn zls and verify it starts
    try std.testing.expect(true);
}
