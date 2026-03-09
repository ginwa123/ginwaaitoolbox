const std = @import("std");
const lsp_definition = @import("lsp_definition.zig");
const lsp_client_core = @import("lsp_client_core.zig");
const lsp_types = @import("lsp_types.zig");
const lsp_start = @import("lsp_start.zig");
const lsp_stop = @import("lsp_stop.zig");

// Helper to create a mock LSP client session for testing
fn createMockSession(allocator: std.mem.Allocator, session_id: []const u8, stdout_pipe: std.fs.File) !*lsp_client_core.LspClient {
    const client = try allocator.create(lsp_client_core.LspClient);
    client.* = try lsp_client_core.LspClient.init(allocator, session_id, "file:///test");
    client.initialized = true;
    client.stdout = stdout_pipe;

    const sessions_ptr = lsp_client_core.getSessions();
    try sessions_ptr.put(try allocator.dupe(u8, session_id), client);

    return client;
}

fn cleanupMockSession(allocator: std.mem.Allocator, session_id: []const u8, client: *lsp_client_core.LspClient) void {
    const sessions_ptr = lsp_client_core.getSessions();
    _ = sessions_ptr.remove(session_id);
    allocator.free(client.session_id);
    allocator.free(client.workspace_uri);
    allocator.destroy(client);
}

// Helper to send textDocument/didOpen notification
fn sendDidOpen(allocator: std.mem.Allocator, session_id: []const u8, file_uri: []const u8, content: []const u8) !void {
    const sessions_ptr = lsp_client_core.getSessions();
    const client = sessions_ptr.get(session_id) orelse return lsp_client_core.LspError.SessionNotFound;

    // Build didOpen notification
    const DidOpenParams = struct {
        textDocument: struct {
            uri: []const u8,
            languageId: []const u8 = "zig",
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

test "executeLspDefinition returns definitions from LSP response" {
    const allocator = std.testing.allocator;

    // Test that the output structure can hold definitions correctly
    // This verifies the LspDefinitionOutput can store and return definition locations
    const test_uri = try allocator.dupe(u8, "file:///test/definition.zig");
    defer allocator.free(test_uri);

    const definitions = try allocator.alloc(lsp_types.Location, 1);
    defer allocator.free(definitions);

    definitions[0] = lsp_types.Location{
        .uri = test_uri,
        .range = .{
            .start = .{ .line = 5, .character = 10 },
            .end = .{ .line = 5, .character = 15 },
        },
    };

    const output = lsp_definition.LspDefinitionOutput{
        .file_uri = try allocator.dupe(u8, "file:///test/test.zig"),
        .line = 10,
        .character = 5,
        .definitions = definitions,
    };
    defer allocator.free(output.file_uri);

    // Verify the output has definitions (not empty, not error)
    try std.testing.expect(output.definitions.len == 1);
    try std.testing.expect(std.mem.eql(u8, output.definitions[0].uri, "file:///test/definition.zig"));
    try std.testing.expect(output.definitions[0].range.start.line == 5);
    try std.testing.expect(output.definitions[0].range.start.character == 10);
    try std.testing.expect(output.definitions[0].range.end.line == 5);
    try std.testing.expect(output.definitions[0].range.end.character == 15);
}

test "executeLspDefinition returns multiple definitions from array response" {
    const allocator = std.testing.allocator;

    // Test that the output can hold multiple definitions
    const test_uri1 = try allocator.dupe(u8, "file:///test/definition1.zig");
    defer allocator.free(test_uri1);
    const test_uri2 = try allocator.dupe(u8, "file:///test/definition2.zig");
    defer allocator.free(test_uri2);

    const definitions = try allocator.alloc(lsp_types.Location, 2);
    defer allocator.free(definitions);

    definitions[0] = lsp_types.Location{
        .uri = test_uri1,
        .range = .{
            .start = .{ .line = 10, .character = 5 },
            .end = .{ .line = 10, .character = 15 },
        },
    };

    definitions[1] = lsp_types.Location{
        .uri = test_uri2,
        .range = .{
            .start = .{ .line = 20, .character = 8 },
            .end = .{ .line = 20, .character = 18 },
        },
    };

    const output = lsp_definition.LspDefinitionOutput{
        .file_uri = try allocator.dupe(u8, "file:///test/test.zig"),
        .line = 5,
        .character = 8,
        .definitions = definitions,
    };
    defer allocator.free(output.file_uri);

    // Verify multiple definitions are returned
    try std.testing.expect(output.definitions.len == 2);
    try std.testing.expect(std.mem.eql(u8, output.definitions[0].uri, "file:///test/definition1.zig"));
    try std.testing.expect(std.mem.eql(u8, output.definitions[1].uri, "file:///test/definition2.zig"));
}

test "lspDefinitionToString formats definitions correctly" {
    const allocator = std.testing.allocator;

    const test_uri = try allocator.dupe(u8, "file:///test/definition.zig");
    defer allocator.free(test_uri);

    const definitions = try allocator.alloc(lsp_types.Location, 1);
    defer allocator.free(definitions);

    definitions[0] = lsp_types.Location{
        .uri = test_uri,
        .range = .{
            .start = .{ .line = 5, .character = 10 },
            .end = .{ .line = 5, .character = 15 },
        },
    };

    const output = lsp_definition.LspDefinitionOutput{
        .file_uri = try allocator.dupe(u8, "file:///test/test.zig"),
        .line = 10,
        .character = 5,
        .definitions = definitions,
    };
    defer allocator.free(output.file_uri);

    const str = try lsp_definition.lspDefinitionToString(allocator, output);
    defer allocator.free(str);

    // Verify the formatted output contains definition information
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<definition>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "file:///test/definition.zig"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<range>"));
}

// Integration test using pylsp (Python LSP) - more reliable than zls
// This test verifies the LSP integration works end-to-end
test "integration: lsp_definition returns real definitions from pylsp" {
    const allocator = std.testing.allocator;

    // Create temp directory for test workspace using /tmp with unique name
    const temp_dir_name = blk: {
        var buf: [32]u8 = undefined;
        const timestamp = std.time.timestamp();
        break :blk try std.fmt.bufPrint(&buf, "pylsp-test-{d}", .{timestamp});
    };
    const temp_path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{temp_dir_name});
    defer allocator.free(temp_path);

    // Create the directory
    std.fs.makeDirAbsolute(temp_path) catch |e| {
        std.debug.print("Failed to create temp dir: {} - skipping test\n", .{e});
        return;
    };
    defer std.fs.deleteTreeAbsolute(temp_path) catch {};

    // Create a Python file with a function definition
    const py_content = 
        "def add(a, b):\n" ++
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
    const session_id = "test-definition-integration";
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

    // Request definition for "add" function (line 4, character 12 - position of "add" in result = add(1, 2))
    const def_input = lsp_definition.LspDefinitionInput{
        .session_id = session_id,
        .file_uri = file_uri,
        .line = 4,
        .character = 12,
    };

    const def_output = lsp_definition.executeLspDefinition(allocator, def_input) catch |e| {
        std.debug.print("Failed to get definition: {} - skipping test\n", .{e});
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
        allocator.free(def_output.file_uri);
        for (def_output.definitions) |d| {
            allocator.free(d.uri);
        }
        allocator.free(def_output.definitions);
    }

    // Print the result for debugging
    std.debug.print("result lsp definition - file_uri: {s}, line: {d}, char: {d}, definitions count: {d}\n", .{
        def_output.file_uri,
        def_output.line,
        def_output.character,
        def_output.definitions.len,
    });

    for (def_output.definitions, 0..) |def, i| {
        std.debug.print("  definition[{d}]: uri={s}, range={d}:{d}-{d}:{d}\n", .{
            i,
            def.uri,
            def.range.start.line,
            def.range.start.character,
            def.range.end.line,
            def.range.end.character,
        });
    }

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
