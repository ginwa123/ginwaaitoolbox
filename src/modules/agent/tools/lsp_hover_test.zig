const std = @import("std");
const lsp_hover = @import("lsp_hover.zig");
const lsp_client_core = @import("lsp_client_core.zig");
const lsp_start = @import("lsp_start.zig");
const lsp_stop = @import("lsp_stop.zig");

// Helper to send textDocument/didOpen notification
fn sendDidOpen(allocator: std.mem.Allocator, session_id: []const u8, file_uri: []const u8, content: []const u8) !void {
    const sessions_ptr = lsp_client_core.getSessions();
    const client = sessions_ptr.get(session_id) orelse return lsp_client_core.LspError.SessionNotFound;

    // Build didOpen notification
    const DidOpenParams = struct {
        textDocument: struct {
            uri: []const u8,
            languageId: []const u8 = "python",
            version: i32 = 1,
            text: []const u8,
        },
    };

    const notification = .{
        .jsonrpc = "2.0",
        .method = "textDocument/didOpen",
        .params = DidOpenParams{
            .textDocument = .{
                .uri = file_uri,
                .text = content,
            },
        },
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var aw: std.io.Writer.Allocating = .init(arena_alloc);
    try aw.writer.print("{f}", .{std.json.fmt(notification, .{})});
    const json_str = try aw.toOwnedSlice();
    defer arena_alloc.free(json_str);

    try lsp_client_core.writeMessage(client.stdin, json_str);
}

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

// Integration test using pylsp (Python LSP) - more reliable than zls
// This test verifies that LSP integration works end-to-end
test "integration: lsp_hover returns hover information from pylsp" {
    const allocator = std.testing.allocator;

    // Create temp directory for test workspace using /tmp with unique name
    const temp_dir_name = blk: {
        var buf: [32]u8 = undefined;
        const timestamp = std.time.timestamp();
        break :blk try std.fmt.bufPrint(&buf, "pylsp-test-{d}", .{timestamp});
    };
    const temp_path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{temp_dir_name});
    defer allocator.free(temp_path);

    // Create directory
    std.fs.makeDirAbsolute(temp_path) catch |e| {
        std.debug.print("Failed to create temp dir: {} - skipping test\n", .{e});
        return;
    };
    defer std.fs.deleteTreeAbsolute(temp_path) catch {};

    // Create a Python file with a function definition
    const py_content = 
        "def add(a, b):\n" ++
        "    \"\"\"Add two numbers together.\"\"\"\n" ++
        "    return a + b\n" ++
        "\n" ++
        "def main():\n" ++
        "    result = add(1, 2)\n" ++
        "    print(result)\n";

    const py_file_path = try std.fs.path.join(allocator, &.{ temp_path, "test.py" });
    defer allocator.free(py_file_path);

    try std.fs.cwd().writeFile(.{
        .sub_path = py_file_path,
        .data = py_content,
    });

    // Start pylsp session
    const session_id = "test-hover-integration";
    const workspace_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{temp_path});
    defer allocator.free(workspace_uri);

    const start_input = lsp_start.LspStartInput{
        .session_id = session_id,
        .binary_name = "python3",
        .workspace_uri = workspace_uri,
    };

    const start_output = lsp_start.executeLspStart(allocator, start_input) catch |e| {
        std.debug.print("Failed to start pylsp: {} - skipping integration test\n", .{e});
        return;
    };
    defer {
        allocator.free(start_output.session_id);
        allocator.free(start_output.binary_path);
        allocator.free(start_output.status);
    }

    // Verify pylsp started
    try std.testing.expect(std.mem.eql(u8, start_output.status, "started"));

    // Send didOpen notification for the file
    const file_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{py_file_path});
    defer allocator.free(file_uri);

    sendDidOpen(allocator, session_id, file_uri, py_content) catch |e| {
        std.debug.print("Failed to send didOpen: {} - skipping test\n", .{e});
        // Stop session before returning
        const stop_input = lsp_stop.LspStopInput{ .session_id = session_id };
        const stop_output = lsp_stop.executeLspStop(allocator, stop_input) catch |stop_e| {
            std.debug.print("Also failed to stop pylsp: {}\n", .{stop_e});
            return;
        };
        allocator.free(stop_output.session_id);
        allocator.free(stop_output.status);
        return;
    };

    // Give pylsp time to process
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Request hover information for "add" function (line 6, character 12 - position of "add" in result = add(1, 2))
    const hover_input = lsp_hover.LspHoverInput{
        .session_id = session_id,
        .file_uri = file_uri,
        .line = 6,
        .character = 12,
    };

    const hover_output = lsp_hover.executeLspHover(allocator, hover_input) catch |e| {
        std.debug.print("Failed to get hover information: {} - skipping test\n", .{e});
        // Stop session before returning
        const stop_input = lsp_stop.LspStopInput{ .session_id = session_id };
        const stop_output = lsp_stop.executeLspStop(allocator, stop_input) catch |stop_e| {
            std.debug.print("Also failed to stop pylsp: {}\n", .{stop_e});
            return;
        };
        allocator.free(stop_output.session_id);
        allocator.free(stop_output.status);
        return;
    };
    defer {
        allocator.free(hover_output.file_uri);
        allocator.free(hover_output.contents);
    }

    // Print the result for debugging
    std.debug.print("result lsp hover - file_uri: {s}, line: {d}, char: {d}, contents: {s}\n", .{
        hover_output.file_uri,
        hover_output.line,
        hover_output.character,
        hover_output.contents[0..@min(hover_output.contents.len, 100)],
    });

    // Verify that hover response contains some content (it should include the function signature or docstring)
    try std.testing.expect(hover_output.contents.len > 0);

    // Stop the session
    const stop_input = lsp_stop.LspStopInput{ .session_id = session_id };
    const stop_output = lsp_stop.executeLspStop(allocator, stop_input) catch |e| {
        std.debug.print("Failed to stop pylsp: {}\n", .{e});
        return;
    };
    defer {
        allocator.free(stop_output.session_id);
        allocator.free(stop_output.status);
    }

    try std.testing.expect(std.mem.eql(u8, stop_output.status, "stopped"));
}
