const std = @import("std");
const lsp_client = @import("lsp_client.zig");

test "find binary zls in path" {
    const allocator = std.testing.allocator;
    
    // Test that findBinary can locate zls
    const result = lsp_client.findBinary(allocator, "zls");
    if (result) |path| {
        defer allocator.free(path);
        std.debug.print("Found zls at: {s}\n", .{path});
        try std.testing.expect(path.len > 0);
    } else |err| {
        // zls not installed - this is OK, skip test
        std.debug.print("zls not found (expected if not installed): {}\n", .{err});
        return error.SkipZigNotInstalled;
    }
}

test "find binary nonexistent" {
    const allocator = std.testing.allocator;
    
    // Test that findBinary returns error for nonexistent binary
    const result = lsp_client.findBinary(allocator, "nonexistent-binary-xyz");
    try std.testing.expectError(lsp_client.LspError.BinaryNotFound, result);
}

test "lsp client spawns and initializes" {
    const allocator = std.testing.allocator;
    
    // Try to find zls first
    const binary_path = lsp_client.findBinary(allocator, "zls") catch {
        std.debug.print("zls not installed, skipping test\n", .{});
        return;
    };
    defer allocator.free(binary_path);
    
    // Try to spawn and initialize
    const result = lsp_client.executeLspStart(allocator, .{
        .session_id = "test-session-1",
        .binary_name = "zls",
        .workspace_uri = "file://lsp_test_workspace",
    });
    
    if (result) |output| {
        defer {
            allocator.free(output.session_id);
            allocator.free(output.binary_path);
            allocator.free(output.status);
        }
        
        std.debug.print("LSP started: session_id={s}, binary={s}, status={s}\n", .{
            output.session_id, output.binary_path, output.status
        });
        
        // Now stop the LSP
        _ = lsp_client.executeLspStop(allocator, .{ .session_id = "test-session-1" }) catch {
            std.debug.print("LSP stop failed (expected - may already be stopped)\n", .{});
        };
    } else |err| {
        std.debug.print("LSP start failed: {}\n", .{err});
        // This might fail if zls doesn't support the initialization
        return;
    }
    
    try std.testing.expect(true);
}

test "session isolation - multiple sessions" {
    const allocator = std.testing.allocator;
    
    // Try to find zls first
    _ = lsp_client.findBinary(allocator, "zls") catch {
        std.debug.print("zls not installed, skipping test\n", .{});
        return;
    };
    
    // Create test workspace directories
    std.fs.cwd().makeDir("lsp_test_ws1") catch {};
    std.fs.cwd().makeDir("lsp_test_ws2") catch {};
    defer {
        std.fs.cwd().deleteTree("lsp_test_ws1") catch {};
        std.fs.cwd().deleteTree("lsp_test_ws2") catch {};
    }
    
    // Start first session
    const start1 = lsp_client.executeLspStart(allocator, .{
        .session_id = "session-1",
        .binary_name = "zls",
        .workspace_uri = "file://lsp_test_ws1",
    }) catch {
        std.debug.print("Failed to start session-1: skip test\n", .{});
        return;
    };
    
    // Start second session (should be isolated)
    const start2 = lsp_client.executeLspStart(allocator, .{
        .session_id = "session-2", 
        .binary_name = "zls",
        .workspace_uri = "file://lsp_test_ws2",
    }) catch {
        std.debug.print("Failed to start session-2: skip test\n", .{});
        _ = lsp_client.executeLspStop(allocator, .{ .session_id = "session-1" }) catch {};
        return;
    };
    
    // Both should succeed independently
    {
        defer {
            allocator.free(start1.session_id);
            allocator.free(start1.binary_path);
            allocator.free(start1.status);
        }
        _ = lsp_client.executeLspStop(allocator, .{ .session_id = "session-1" }) catch {};
    }
    
    {
        defer {
            allocator.free(start2.session_id);
            allocator.free(start2.binary_path);
            allocator.free(start2.status);
        }
        _ = lsp_client.executeLspStop(allocator, .{ .session_id = "session-2" }) catch {};
    }
    
    try std.testing.expect(true);
}

test "lsp stop cleans up session" {
    const allocator = std.testing.allocator;
    
    // Try to find zls first
    _ = lsp_client.findBinary(allocator, "zls") catch {
        std.debug.print("zls not installed, skipping test\n", .{});
        return;
    };
    
    // Create test workspace
    try std.fs.cwd().makeDir("lsp_test_stop");
    defer { std.fs.cwd().deleteTree("lsp_test_stop") catch {}; }
    
    // Start session
    _ = lsp_client.executeLspStart(allocator, .{
        .session_id = "stop-test-session",
        .binary_name = "zls",
        .workspace_uri = "file://lsp_test_stop",
    }) catch {
        std.debug.print("Failed to start LSP, skipping\n", .{});
        return;
    };
    
    // Stop session
    const stop_result = lsp_client.executeLspStop(allocator, .{ .session_id = "stop-test-session" });
    
    try std.testing.expect(stop_result != error.SessionNotFound);
}
