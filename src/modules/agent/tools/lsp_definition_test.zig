const std = @import("std");
const lsp_definition = @import("lsp_definition.zig");
const lsp_types = @import("lsp_types.zig");

// Test 1.1: LspDefinitionInput struct
test "LspDefinitionInput has all required fields" {
    const input = lsp_types.LspDefinitionInput{
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
    
    // Create a location
    const locations = try allocator.alloc(lsp_types.LspLocation, 1);
    locations[0] = lsp_types.LspLocation{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/lib.zig"),
        .line = 20,
        .character = 8,
    };
    
    var output = lsp_types.LspDefinitionOutput{
        .definitions = locations,
        .found = true,
    };
    defer output.deinit(allocator);

    try std.testing.expect(output.found);
    try std.testing.expectEqual(@as(usize, 1), output.definitions.len);
}

// Test 1.3: LspDefinitionOutput struct - not found
test "LspDefinitionOutput can represent not found" {
    const allocator = std.testing.allocator;
    var output = lsp_types.LspDefinitionOutput{
        .definitions = &.{},
        .found = false,
    };
    defer output.deinit(allocator);

    try std.testing.expect(!output.found);
    try std.testing.expectEqual(@as(usize, 0), output.definitions.len);
}

// Test 2.1: lspDefinitionTool name
test "lspDefinitionTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_definition.lspDefinitionTool.function.name, "lsp_definition"));
}

// Test 2.2: lspDefinitionTool parameters
test "lspDefinitionTool has required parameters" {
    const params = lsp_definition.lspDefinitionTool.function.parameters;

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
}
