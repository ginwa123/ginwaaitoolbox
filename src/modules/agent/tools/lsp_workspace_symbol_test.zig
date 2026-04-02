const std = @import("std");
const lsp_workspace_symbol = @import("lsp_workspace_symbol.zig");
const lsp_types = @import("lsp_types.zig");

// Test 1.1: LspWorkspaceSymbolInput struct
test "LspWorkspaceSymbolInput has all required fields" {
    const input = lsp_types.LspWorkspaceSymbolInput{
        .lsp = "zls",
        .root_dir = "/home/ginwa/project",
        .query = "main",
    };
    try std.testing.expect(std.mem.eql(u8, input.lsp, "zls"));
    try std.testing.expect(std.mem.eql(u8, input.root_dir, "/home/ginwa/project"));
    try std.testing.expect(std.mem.eql(u8, input.query, "main"));
    try std.testing.expectEqual(@as(u32, 100), input.max_output.?);
}

// Test 1.2: LspWorkspaceSymbol struct
test "LspWorkspaceSymbol has all required fields" {
    const allocator = std.testing.allocator;

    const sym = lsp_types.LspWorkspaceSymbol{
        .name = try allocator.dupe(u8, "main"),
        .kind = 12, // Function
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/main.zig"),
        .line = 10,
        .character = 0,
        .container_name = null,
    };
    defer sym.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, sym.name, "main"));
    try std.testing.expectEqual(@as(u32, 12), sym.kind);
    try std.testing.expect(std.mem.eql(u8, sym.file_path, "/home/ginwa/project/src/main.zig"));
    try std.testing.expectEqual(@as(u32, 10), sym.line);
    try std.testing.expectEqual(@as(u32, 0), sym.character);
    try std.testing.expect(sym.container_name == null);
}

// Test 1.3: LspWorkspaceSymbol with container_name
test "LspWorkspaceSymbol can have container_name" {
    const allocator = std.testing.allocator;

    const sym = lsp_types.LspWorkspaceSymbol{
        .name = try allocator.dupe(u8, "myMethod"),
        .kind = 6, // Method
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/class.zig"),
        .line = 25,
        .character = 4,
        .container_name = try allocator.dupe(u8, "MyClass"),
    };
    defer sym.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, sym.name, "myMethod"));
    try std.testing.expect(sym.container_name != null);
    try std.testing.expect(std.mem.eql(u8, sym.container_name.?, "MyClass"));
}

// Test 1.4: LspWorkspaceSymbolOutput struct - found symbols
test "LspWorkspaceSymbolOutput can represent found symbols" {
    const allocator = std.testing.allocator;

    // Create symbols array
    const symbols = try allocator.alloc(lsp_types.LspWorkspaceSymbol, 2);
    symbols[0] = lsp_types.LspWorkspaceSymbol{
        .name = try allocator.dupe(u8, "main"),
        .kind = 12, // Function
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/main.zig"),
        .line = 10,
        .character = 0,
        .container_name = null,
    };
    symbols[1] = lsp_types.LspWorkspaceSymbol{
        .name = try allocator.dupe(u8, "helper"),
        .kind = 12, // Function
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/utils.zig"),
        .line = 5,
        .character = 0,
        .container_name = null,
    };

    var output = lsp_types.LspWorkspaceSymbolOutput{
        .symbols = symbols,
        .found = true,
    };
    defer output.deinit(allocator);

    try std.testing.expect(output.found);
    try std.testing.expectEqual(@as(usize, 2), output.symbols.len);
    try std.testing.expect(std.mem.eql(u8, output.symbols[0].name, "main"));
    try std.testing.expect(std.mem.eql(u8, output.symbols[1].name, "helper"));
}

// Test 1.5: LspWorkspaceSymbolOutput struct - not found
test "LspWorkspaceSymbolOutput can represent not found" {
    const output = lsp_types.LspWorkspaceSymbolOutput{
        .symbols = &.{},
        .found = false,
    };

    try std.testing.expect(!output.found);
    try std.testing.expectEqual(@as(usize, 0), output.symbols.len);
}

// Test 2.1: lsp_workspace_symbol_tool name
test "lsp_workspace_symbol_tool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_workspace_symbol.lsp_workspace_symbol_tool.function.name, "lsp_workspace_symbol"));
}

// Test 2.2: lsp_workspace_symbol_tool parameters
test "lsp_workspace_symbol_tool has required parameters" {
    const params = lsp_workspace_symbol.lsp_workspace_symbol_tool.function.parameters;
    try std.testing.expectEqual(@as(usize, 4), params.properties.len);

    var has_lsp = false;
    var has_root_dir = false;
    var has_query = false;
    var has_max_output = false;

    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "lsp")) has_lsp = true;
        if (std.mem.eql(u8, prop.name, "root_dir")) has_root_dir = true;
        if (std.mem.eql(u8, prop.name, "query")) has_query = true;
        if (std.mem.eql(u8, prop.name, "max_output")) has_max_output = true;
    }

    try std.testing.expect(has_lsp);
    try std.testing.expect(has_root_dir);
    try std.testing.expect(has_query);
    try std.testing.expect(has_max_output);
    try std.testing.expectEqual(@as(usize, 3), params.required.len);
}

// Test 3.1: Format found symbols
test "lspWorkspaceSymbolToString formats found symbols" {
    const allocator = std.testing.allocator;

    const symbols = try allocator.alloc(lsp_types.LspWorkspaceSymbol, 2);
    symbols[0] = lsp_types.LspWorkspaceSymbol{
        .name = try allocator.dupe(u8, "main"),
        .kind = 12, // Function
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/main.zig"),
        .line = 10,
        .character = 0,
        .container_name = null,
    };
    symbols[1] = lsp_types.LspWorkspaceSymbol{
        .name = try allocator.dupe(u8, "MyClass"),
        .kind = 5, // Class
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/class.zig"),
        .line = 5,
        .character = 0,
        .container_name = try allocator.dupe(u8, "myModule"),
    };

    const output = lsp_types.LspWorkspaceSymbolOutput{
        .symbols = symbols,
        .found = true,
    };
    defer output.deinit(allocator);

    const result = try lsp_workspace_symbol.lspWorkspaceSymbolToString(allocator, output);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<found>true</found>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<count>2</count>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<name>main</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<name>MyClass</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<kind>12</kind>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<kind>5</kind>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<container_name>myModule</container_name>") != null);
}

// Test 3.2: Format not found
test "lspWorkspaceSymbolToString formats not found" {
    const allocator = std.testing.allocator;

    const output = lsp_types.LspWorkspaceSymbolOutput{
        .symbols = &.{},
        .found = false,
    };

    const result = try lsp_workspace_symbol.lspWorkspaceSymbolToString(allocator, output);
    defer allocator.free(result);

    try std.testing.expect(std.mem.eql(u8, result, "<found>false</found>"));
}

// Test 4.1: createMessage helper
test "createMessage creates valid LSP message" {
    const allocator = std.testing.allocator;

    const content = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const msg = try lsp_workspace_symbol.createMessage(allocator, content);
    defer allocator.free(msg);

    try std.testing.expect(std.mem.startsWith(u8, msg, "Content-Length: "));
    try std.testing.expect(std.mem.indexOf(u8, msg, "\r\n\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, msg, content));
}
