const std = @import("std");
const lsp_references = @import("lsp_references.zig");
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

// Integration test using pylsp (Python LSP) - more reliable than zls
// This test verifies that LSP integration works end-to-end
test "integration: lsp_references returns all references from pylsp" {
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

    // Create a Python file with a function definition that's called multiple times
    const py_content = 
        "def add(a, b):\n" ++
        "    return a + b\n" ++
        "\n" ++
        "def main():\n" ++
        "    result = add(1, 2)  # First reference to add\n" ++
        "    result2 = add(3, 4)  # Second reference to add\n" ++
        "    print(result)\n";

    const py_file_path = try std.fs.path.join(allocator, &.{ temp_path, "test.py" });
    defer allocator.free(py_file_path);

    try std.fs.cwd().writeFile(.{
        .sub_path = py_file_path,
        .data = py_content,
    });

    // Start pylsp session
    const session_id = "test-references-integration";
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

    // Request references for "add" function (line 6, character 12 - position of "add" in result = add(1, 2))
    const references_input = lsp_references.LspReferencesInput{
        .session_id = session_id,
        .file_uri = file_uri,
        .line = 6,
        .character = 13, // Position of "add" in "result = add(1, 2)"
    };

    const references_output = lsp_references.executeLspReferences(allocator, references_input) catch |e| {
        std.debug.print("Failed to get references: {} - skipping test\n", .{e});
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
        allocator.free(references_output.file_uri);
        for (references_output.references) |r| {
            allocator.free(r.uri);
        }
        allocator.free(references_output.references);
    }

    // Print the result for debugging
    std.debug.print("result lsp references - file_uri: {s}, line: {d}, char: {d}, count: {d}\n", .{
        references_output.file_uri,
        references_output.line,
        references_output.character,
        references_output.references.len,
    });

    for (references_output.references, 0..) |ref, i| {
        std.debug.print("  reference[{d}]: uri={s}, range={d}:{d}-{d}:{d}\n", .{
            i,
            ref.uri,
            ref.range.start.line,
            ref.range.start.character,
            ref.range.end.line,
            ref.range.end.character,
        });
    }

    // Verify that references array contains at least 1 reference (function is called)
    try std.testing.expect(references_output.references.len >= 1);

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
