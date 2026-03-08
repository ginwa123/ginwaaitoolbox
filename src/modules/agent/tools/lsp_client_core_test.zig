const std = @import("std");
const lsp_client_core = @import("lsp_client_core.zig");

test "findBinary finds zls if installed" {
    const allocator = std.testing.allocator;
    
    // Try to find zls - may not be installed on all systems
    const result = lsp_client_core.findBinary(allocator, "zls");
    
    if (result) |path| {
        defer allocator.free(path);
        // Found zls
        try std.testing.expect(path.len > 0);
        try std.testing.expect(path[0] == '/'); // Should be absolute path
    } else |err| {
        // zls not found is acceptable
        try std.testing.expect(err == lsp_client_core.LspError.BinaryNotFound);
    }
}

test "findBinary returns BinaryNotFound for nonexistent binary" {
    const allocator = std.testing.allocator;
    
    const result = lsp_client_core.findBinary(allocator, "nonexistent-binary-xyz-12345");
    
    try std.testing.expectError(lsp_client_core.LspError.BinaryNotFound, result);
}

test "LspClient can be initialized" {
    const allocator = std.testing.allocator;
    
    var client = try lsp_client_core.LspClient.init(allocator, "test-session", "file:///test/workspace");
    defer client.deinit();
    
    try std.testing.expect(std.mem.eql(u8, client.session_id, "test-session"));
    try std.testing.expect(std.mem.eql(u8, client.workspace_uri, "file:///test/workspace"));
    try std.testing.expect(client.initialized == false);
    try std.testing.expect(client.next_request_id == 1);
}

test "LspClient init and deinit" {
    const allocator = std.testing.allocator;
    
    var client = try lsp_client_core.LspClient.init(allocator, "test-session-2", "file:///test");
    client.deinit();
    
    // If we get here without memory issues, test passes
    try std.testing.expect(true);
}

test "getSessions returns valid pointer" {
    // getSessions always returns a valid pointer to the global sessions map
    _ = lsp_client_core.getSessions();
    try std.testing.expect(true);
}

test "common_binary_paths contains expected paths" {
    const paths = lsp_client_core.common_binary_paths;
    
    // Verify we have some common paths
    var found_test_path = false;
    for (paths) |path| {
        if (std.mem.eql(u8, path, "/usr/bin") or 
            std.mem.eql(u8, path, "/usr/local/bin") or
            std.mem.eql(u8, path, "/home/ginwa/.local/bin")) {
            found_test_path = true;
            break;
        }
    }
    try std.testing.expect(found_test_path);
}
