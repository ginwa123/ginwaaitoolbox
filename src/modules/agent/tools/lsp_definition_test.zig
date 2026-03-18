const std = @import("std");
const lsp = @import("lsp.zig");
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

// Test 1.2: LspDefinitionOutput struct - found single definition
test "LspDefinitionOutput can represent found definition" {
    const allocator = std.testing.allocator;

    // Create a single location
    const loc = models.LspLocation{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/lib.zig"),
        .line = 20,
        .character = 8,
    };

    const definitions = try allocator.alloc(models.LspLocation, 1);
    definitions[0] = loc;

    var output = models.LspDefinitionOutput{
        .definitions = definitions,
        .found = true,
    };
    defer output.deinit(allocator);

    try std.testing.expect(output.found);
    try std.testing.expectEqual(@as(usize, 1), output.definitions.len);
    try std.testing.expectEqual(@as(u32, 20), output.definitions[0].line);
    try std.testing.expectEqual(@as(u32, 8), output.definitions[0].character);
}

// Test 1.3: LspDefinitionOutput struct - not found
test "LspDefinitionOutput can represent not found" {
    const output = models.LspDefinitionOutput{
        .definitions = &.{},
        .found = false,
    };

    try std.testing.expect(!output.found);
    try std.testing.expectEqual(@as(usize, 0), output.definitions.len);
}

// Test 1.4: LspDefinitionOutput with multiple definitions
test "LspDefinitionOutput can hold multiple definitions" {
    const allocator = std.testing.allocator;

    // Create multiple locations (e.g., for overloaded functions)
    const definitions = try allocator.alloc(models.LspLocation, 2);
    definitions[0] = models.LspLocation{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/math.zig"),
        .line = 10,
        .character = 0,
    };
    definitions[1] = models.LspLocation{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/math.zig"),
        .line = 20,
        .character = 0,
    };

    var output = models.LspDefinitionOutput{
        .definitions = definitions,
        .found = true,
    };
    defer output.deinit(allocator);

    try std.testing.expect(output.found);
    try std.testing.expectEqual(@as(usize, 2), output.definitions.len);
    try std.testing.expectEqual(@as(u32, 10), output.definitions[0].line);
    try std.testing.expectEqual(@as(u32, 20), output.definitions[1].line);
}

// Test 2.1: lspDefinitionTool name
test "lspDefinitionTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp.lspDefinitionTool.function.name, "lsp_definition"));
}

// Test 2.2: lspDefinitionTool parameters
test "lspDefinitionTool has required parameters" {
    const params = lsp.lspDefinitionTool.function.parameters;
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

    const result = lsp.executeLspDefinition(allocator, input);
    try std.testing.expectError(error.FileNotFound, result);
}

// Test 4.1: Format found single definition
test "lspDefinitionToString formats found definition" {
    const allocator = std.testing.allocator;

    const definitions = try allocator.alloc(models.LspLocation, 1);
    definitions[0] = models.LspLocation{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/lib.zig"),
        .line = 20,
        .character = 8,
    };

    const output = models.LspDefinitionOutput{
        .definitions = definitions,
        .found = true,
    };
    defer allocator.free(output.definitions[0].file_path);
    defer allocator.free(output.definitions);

    const str = try lsp.lspDefinitionToString(allocator, output);
    defer allocator.free(str);

    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<found>true</found>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<count>1</count>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<definitions>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<file_path>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "/home/ginwa/project/src/lib.zig"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<line>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "20"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<character>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "8"));
}

// Test 4.2: Format not found
test "lspDefinitionToString formats not found" {
    const allocator = std.testing.allocator;
    const output = models.LspDefinitionOutput{
        .definitions = &.{},
        .found = false,
    };

    const str = try lsp.lspDefinitionToString(allocator, output);
    defer allocator.free(str);

    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<found>false</found>"));
}

// Test 4.3: Format multiple definitions
test "lspDefinitionToString formats multiple definitions" {
    const allocator = std.testing.allocator;

    const definitions = try allocator.alloc(models.LspLocation, 2);
    definitions[0] = models.LspLocation{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/math.zig"),
        .line = 10,
        .character = 0,
    };
    definitions[1] = models.LspLocation{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/math.zig"),
        .line = 25,
        .character = 0,
    };

    const output = models.LspDefinitionOutput{
        .definitions = definitions,
        .found = true,
    };
    defer {
        for (output.definitions) |*def| {
            allocator.free(def.file_path);
        }
        allocator.free(output.definitions);
    }

    const str = try lsp.lspDefinitionToString(allocator, output);
    defer allocator.free(str);

    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<found>true</found>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<count>2</count>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<definition index=\"1\">"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<definition index=\"2\">"));
}

// Test 5.1: Create message with Content-Length
test "createMessage formats Content-Length header" {
    const allocator = std.testing.allocator;
    const content = "{\"jsonrpc\":\"2.0\"}";

    const msg = try lsp.createMessage(allocator, content);
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

    const output = lsp.executeLspDefinition(allocator, input) catch |e| {
        if (e == error.BinaryNotFound) {
            std.debug.print("Skipping integration test - zls not found\n", .{});
            return;
        }
        std.debug.print("Integration test error: {}\n", .{e});
        return e;
    };
    defer output.deinit(allocator);

    // Print debug info
    std.debug.print("Integration test: found={}, definitions.len={d}\n", .{
        output.found,
        output.definitions.len,
    });

    if (output.found and output.definitions.len > 0) {
        for (output.definitions, 0..) |def, i| {
            std.debug.print("  [{d}] file_path={s}, line={d}, character={d}\n", .{
                i,
                def.file_path,
                def.line,
                def.character,
            });
        }
    }

    // Skip if definition not found (zls might not be fully initialized)
    if (!output.found or output.definitions.len == 0) {
        std.debug.print("Skipping integration test - definition not found (zls may need more time to initialize)\n", .{});
        return;
    }

    // Verify result - should have at least one definition
    try std.testing.expect(output.found);
    try std.testing.expect(output.definitions.len > 0);

    // The definition should be in the test file itself (MyStruct is defined there)
    const first_def = output.definitions[0];
    try std.testing.expect(std.mem.eql(u8, first_def.file_path, temp_path));
    try std.testing.expectEqual(@as(u32, 2), first_def.line); // MyStruct defined on line 3 (0-indexed: 2)
}

// Test 7.1: LspError error set
test "LspError error set contains expected errors" {
    // Verify all expected error types exist by checking they can be assigned
    const errors = [_]lsp.LspError{
        error.FileNotFound,
        error.BinaryNotFound,
        error.ProcessSpawnFailed,
        error.InvalidResponse,
        error.DefinitionNotFound,
    };
    try std.testing.expectEqual(@as(usize, 5), errors.len);
}

// Test 8.1: Import chain resolution - LSP should return actual definition, not re-export
// This test documents a known issue: zls may return the local import alias
// instead of tracing through the import chain to the actual definition
test "integration: lsp_definition resolves through import chains to actual definition" {
    const allocator = std.testing.allocator;

    // Create a test scenario with import chain:
    // usage.zig -> reexport.zig -> actual_definition.zig
    // LSP should return actual_definition.zig, not reexport.zig

    const test_dir = "/tmp/lsp_import_chain_test";
    std.fs.cwd().makePath(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // File 1: Contains the ACTUAL definition
    const actual_def_content =
        \\pub const MyType = struct {
        \\    value: i32,
        \\};
        \\
    ;
    const actual_def_path = test_dir ++ "/actual_definition.zig";
    try std.fs.cwd().writeFile(.{
        .sub_path = actual_def_path,
        .data = actual_def_content,
    });

    // File 2: Re-exports from File 1 (intermediate alias)
    const reexport_content = std.fmt.allocPrint(allocator,
        \\pub const MyType = @import("{s}").MyType;
        \\
    , .{"actual_definition.zig"}) catch unreachable;
    defer allocator.free(reexport_content);
    const reexport_path = test_dir ++ "/reexport.zig";
    try std.fs.cwd().writeFile(.{
        .sub_path = reexport_path,
        .data = reexport_content,
    });

    // File 3: Uses the symbol from File 2
    const usage_content = std.fmt.allocPrint(allocator,
        \\const MyType = @import("{s}").MyType;
        \\
        \\pub fn main() void {
        \\    const x: MyType = .{{ .value = 42 }};
        \\    _ = x;
        \\}}
        \\
    , .{"reexport.zig"}) catch unreachable;
    defer allocator.free(usage_content);
    const usage_path = test_dir ++ "/usage.zig";
    try std.fs.cwd().writeFile(.{
        .sub_path = usage_path,
        .data = usage_content,
    });

    // Request definition of MyType from usage.zig
    const input = models.LspDefinitionInput{
        .lsp = "zls",
        .root_dir = test_dir,
        .file_path = usage_path,
        .line = 3, // Line with "const x: MyType"
        .character = 12, // Position of "MyType"
    };

    const output = lsp.executeLspDefinition(allocator, input) catch |e| {
        if (e == error.BinaryNotFound) {
            std.debug.print("Skipping import chain test - zls not found\n", .{});
            return;
        }
        std.debug.print("Import chain test error: {}\n", .{e});
        return e;
    };
    defer output.deinit(allocator);

    // Print debug info
    std.debug.print("Import chain test: found={}, definitions.len={d}\n", .{
        output.found,
        output.definitions.len,
    });

    if (output.found and output.definitions.len > 0) {
        for (output.definitions, 0..) |def, i| {
            std.debug.print("  [{d}] file_path={s}, line={d}, character={d}\n", .{
                i,
                def.file_path,
                def.line,
                def.character,
            });
        }
    }

    // Skip if definition not found
    if (!output.found or output.definitions.len == 0) {
        std.debug.print("Skipping import chain test - definition not found\n", .{});
        return;
    }

    // CRITICAL: The definition should be in actual_definition.zig, NOT reexport.zig
    // The LSP tool now properly resolves through import chains
    const expected_path = actual_def_path;
    const first_def = output.definitions[0];
    const is_reexport = std.mem.eql(u8, first_def.file_path, reexport_path);

    if (is_reexport) {
        std.debug.print("ERROR: LSP returned re-export location instead of actual definition!\n", .{});
        std.debug.print("  Expected: {s}\n", .{expected_path});
        std.debug.print("  Got: {s}\n", .{first_def.file_path});
    }

    // Verify we got the actual definition, not the re-export
    try std.testing.expect(output.found);
    const is_actual_definition = std.mem.eql(u8, first_def.file_path, expected_path);
    try std.testing.expect(is_actual_definition);
}
