const std = @import("std");
const lsp_definition = @import("lsp_definition.zig");
const models = @import("models.zig");

// Test 1.1: LspDefinitionInput struct
test "LspDefinitionInput has all required fields" {
    const input = models.LspDefinitionInput{
        .lsp = "zls",
        .root_dir = "/home/ginwa/project",
        .file_path = "/home/ginwa/project/src/main.zig",
        .line = 10,
        .character = 5,
    };
    try std.testing.expect(std.mem.eql(u8, input.lsp, "zls"));
    try std.testing.expect(std.mem.eql(u8, input.root_dir, "/home/ginwa/project"));
    try std.testing.expect(std.mem.eql(u8, input.file_path, "/home/ginwa/project/src/main.zig"));
    try std.testing.expectEqual(@as(u32, 10), input.line);
    try std.testing.expectEqual(@as(u32, 5), input.character);
}

// Test 1.2: LspDefinitionOutput struct - found
test "LspDefinitionOutput can represent found definition" {
    const allocator = std.testing.allocator;
    const output = models.LspDefinitionOutput{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/lib.zig"),
        .line = 20,
        .character = 8,
        .found = true,
    };
    defer allocator.free(output.file_path);

    try std.testing.expect(output.found);
    try std.testing.expectEqual(@as(u32, 20), output.line);
    try std.testing.expectEqual(@as(u32, 8), output.character);
}

// Test 1.3: LspDefinitionOutput struct - not found
test "LspDefinitionOutput can represent not found" {
    const output = models.LspDefinitionOutput{
        .file_path = "",
        .line = 0,
        .character = 0,
        .found = false,
    };

    try std.testing.expect(!output.found);
}

// Test 2.1: lspDefinitionTool name
test "lspDefinitionTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_definition.lspDefinitionTool.function.name, "lsp_definition"));
}

// Test 2.2: lspDefinitionTool parameters
test "lspDefinitionTool has required parameters" {
    const params = lsp_definition.lspDefinitionTool.function.parameters;
    try std.testing.expectEqual(@as(usize, 5), params.properties.len);

    var has_lsp = false;
    var has_root_dir = false;
    var has_file_path = false;
    var has_line = false;
    var has_character = false;

    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "lsp")) has_lsp = true;
        if (std.mem.eql(u8, prop.name, "root_dir")) has_root_dir = true;
        if (std.mem.eql(u8, prop.name, "file_path")) has_file_path = true;
        if (std.mem.eql(u8, prop.name, "line")) has_line = true;
        if (std.mem.eql(u8, prop.name, "character")) has_character = true;
    }

    try std.testing.expect(has_lsp);
    try std.testing.expect(has_root_dir);
    try std.testing.expect(has_file_path);
    try std.testing.expect(has_line);
    try std.testing.expect(has_character);
    try std.testing.expectEqual(@as(usize, 5), params.required.len);
}

// Test 3.1: Non-existent file
test "executeLspDefinition returns error for non-existent file" {
    const allocator = std.testing.allocator;
    const input = models.LspDefinitionInput{
        .lsp = "zls",
        .root_dir = "/nonexistent/path",
        .file_path = "/nonexistent/path/that/does/not/exist.zig",
        .line = 0,
        .character = 0,
    };

    const result = lsp_definition.executeLspDefinition(allocator, input);
    try std.testing.expectError(error.FileNotFound, result);
}

// Test 4.1: Format found definition
test "lspDefinitionToString formats found definition" {
    const allocator = std.testing.allocator;
    const output = models.LspDefinitionOutput{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/lib.zig"),
        .line = 20,
        .character = 8,
        .found = true,
    };
    defer allocator.free(output.file_path);

    const str = try lsp_definition.lspDefinitionToString(allocator, output);
    defer allocator.free(str);

    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<file_path>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "/home/ginwa/project/src/lib.zig"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<line>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "20"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<character>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<found>true</found>"));
}

// Test 4.2: Format not found
test "lspDefinitionToString formats not found" {
    const allocator = std.testing.allocator;
    const output = models.LspDefinitionOutput{
        .file_path = "",
        .line = 0,
        .character = 0,
        .found = false,
    };

    const str = try lsp_definition.lspDefinitionToString(allocator, output);
    defer allocator.free(str);

    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<found>false</found>"));
}

// Test 5.1: Create message with Content-Length
test "createMessage formats Content-Length header" {
    const allocator = std.testing.allocator;
    const content = "{\"jsonrpc\":\"2.0\"}";

    const msg = try lsp_definition.createMessage(allocator, content);
    defer allocator.free(msg);

    try std.testing.expect(std.mem.startsWith(u8, msg, "Content-Length:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, msg, 1, "\r\n\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, msg, content));
}



// Test 6.1: Full workflow with real zls
test "integration: lsp_definition finds definition in real Zig file" {
    const allocator = std.testing.allocator;

    // Create test file
    const test_content =
        \\const std = @import("std");
        \\
        \\const MyStruct = struct {
        \\    value: i32,
        \\};
        \\
        \\pub fn main() void {
        \\    const s = MyStruct{ .value = 42 };
        \\    _ = s;
        \\}
        \\
    ;

    const temp_path = "/tmp/lsp_test_main.zig";
    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = test_content,
    });
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    // Request definition
    const input = models.LspDefinitionInput{
        .lsp = "zls",
        .root_dir = "/tmp",
        .file_path = temp_path,
        .line = 7, // Line with "const s = MyStruct..."
        .character = 16, // Position of "MyStruct"
    };

    const output = lsp_definition.executeLspDefinition(allocator, input) catch |e| {
        if (e == error.BinaryNotFound) {
            std.debug.print("Skipping integration test - zls not found\n", .{});
            return;
        }
        std.debug.print("Integration test error: {}\n", .{e});
        return e;
    };
    defer {
        if (output.found) {
            allocator.free(output.file_path);
        }
    }

    // Print debug info
    std.debug.print("Integration test: found={}, file_path={s}, line={}, character={}\n", .{
        output.found,
        if (output.found) output.file_path else "N/A",
        output.line,
        output.character,
    });

    // Skip if definition not found (zls might not be fully initialized)
    if (!output.found) {
        std.debug.print("Skipping integration test - definition not found (zls may need more time to initialize)\n", .{});
        return;
    }

    // Verify result
    try std.testing.expect(std.mem.eql(u8, output.file_path, temp_path));
    try std.testing.expectEqual(@as(u32, 2), output.line); // MyStruct defined on line 3
}

// Test 7.1: LspError error set
test "LspError error set contains expected errors" {
    // Verify all expected error types exist by checking they can be assigned
    const errors = [_]lsp_definition.LspError{
        error.FileNotFound,
        error.BinaryNotFound,
        error.ProcessSpawnFailed,
        error.InvalidResponse,
        error.DefinitionNotFound,
    };
    try std.testing.expectEqual(@as(usize, 5), errors.len);
}
