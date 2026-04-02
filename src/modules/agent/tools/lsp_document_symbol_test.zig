const std = @import("std");
const lsp_document_symbol = @import("lsp_document_symbol.zig");
const lsp_types = @import("lsp_types.zig");

// Test 1.1: LspDocumentSymbolInput struct
test "LspDocumentSymbolInput has all required fields" {
    const input = lsp_types.LspDocumentSymbolInput{
        .lsp = "zls",
        .root_dir = "/home/ginwa/project",
        .file_path = "/home/ginwa/project/src/main.zig",
    };
    try std.testing.expect(std.mem.eql(u8, input.lsp, "zls"));
    try std.testing.expect(std.mem.eql(u8, input.root_dir, "/home/ginwa/project"));
    try std.testing.expect(std.mem.eql(u8, input.file_path, "/home/ginwa/project/src/main.zig"));
    try std.testing.expectEqual(@as(u32, 100), input.max_output.?);
}

// Test 1.2: LspDocumentSymbol struct
test "LspDocumentSymbol has all required fields" {
    const allocator = std.testing.allocator;

    const sym = lsp_types.LspDocumentSymbol{
        .name = try allocator.dupe(u8, "main"),
        .kind = 12, // Function
        .detail = null,
        .line = 10,
        .character = 0,
        .end_line = null,
        .end_character = null,
        .selection_line = null,
        .selection_character = null,
        .children = null,
    };
    defer sym.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, sym.name, "main"));
    try std.testing.expectEqual(@as(u32, 12), sym.kind);
    try std.testing.expectEqual(@as(u32, 10), sym.line);
    try std.testing.expectEqual(@as(u32, 0), sym.character);
}

// Test 1.3: LspDocumentSymbol with detail
test "LspDocumentSymbol can have detail" {
    const allocator = std.testing.allocator;

    const sym = lsp_types.LspDocumentSymbol{
        .name = try allocator.dupe(u8, "myFunction"),
        .kind = 12, // Function
        .detail = try allocator.dupe(u8, "fn myFunction(x: i32) void"),
        .line = 25,
        .character = 4,
        .end_line = null,
        .end_character = null,
        .selection_line = null,
        .selection_character = null,
        .children = null,
    };
    defer sym.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, sym.name, "myFunction"));
    try std.testing.expect(sym.detail != null);
    try std.testing.expect(std.mem.eql(u8, sym.detail.?, "fn myFunction(x: i32) void"));
}

// Test 1.4: LspDocumentSymbol with children
test "LspDocumentSymbol can have children" {
    const allocator = std.testing.allocator;

    const children = try allocator.alloc(lsp_types.LspDocumentSymbol, 1);
    children[0] = lsp_types.LspDocumentSymbol{
        .name = try allocator.dupe(u8, "childMethod"),
        .kind = 6, // Method
        .detail = null,
        .line = 15,
        .character = 4,
        .end_line = null,
        .end_character = null,
        .selection_line = null,
        .selection_character = null,
        .children = null,
    };

    const sym = lsp_types.LspDocumentSymbol{
        .name = try allocator.dupe(u8, "MyClass"),
        .kind = 5, // Class
        .detail = null,
        .line = 10,
        .character = 0,
        .end_line = null,
        .end_character = null,
        .selection_line = null,
        .selection_character = null,
        .children = children,
    };
    defer sym.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, sym.name, "MyClass"));
    try std.testing.expect(sym.children != null);
    try std.testing.expectEqual(@as(usize, 1), sym.children.?.len);
    try std.testing.expect(std.mem.eql(u8, sym.children.?[0].name, "childMethod"));
}

// Test 1.5: LspDocumentSymbolOutput struct - found symbols
test "LspDocumentSymbolOutput can represent found symbols" {
    const allocator = std.testing.allocator;

    const symbols = try allocator.alloc(lsp_types.LspDocumentSymbol, 2);
    symbols[0] = lsp_types.LspDocumentSymbol{
        .name = try allocator.dupe(u8, "main"),
        .kind = 12, // Function
        .detail = null,
        .line = 10,
        .character = 0,
        .end_line = null,
        .end_character = null,
        .selection_line = null,
        .selection_character = null,
        .children = null,
    };
    symbols[1] = lsp_types.LspDocumentSymbol{
        .name = try allocator.dupe(u8, "helper"),
        .kind = 12, // Function
        .detail = null,
        .line = 20,
        .character = 0,
        .end_line = null,
        .end_character = null,
        .selection_line = null,
        .selection_character = null,
        .children = null,
    };

    var output = lsp_types.LspDocumentSymbolOutput{
        .symbols = symbols,
        .found = true,
    };
    defer output.deinit(allocator);

    try std.testing.expect(output.found);
    try std.testing.expectEqual(@as(usize, 2), output.symbols.len);
    try std.testing.expect(std.mem.eql(u8, output.symbols[0].name, "main"));
    try std.testing.expect(std.mem.eql(u8, output.symbols[1].name, "helper"));
}

// Test 1.6: LspDocumentSymbolOutput struct - not found
test "LspDocumentSymbolOutput can represent not found" {
    const output = lsp_types.LspDocumentSymbolOutput{
        .symbols = &.{},
        .found = false,
    };

    try std.testing.expect(!output.found);
    try std.testing.expectEqual(@as(usize, 0), output.symbols.len);
}

// Test 2.1: lsp_document_symbol_tool name
test "lsp_document_symbol_tool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_document_symbol.lsp_document_symbol_tool.function.name, "lsp_document_symbol"));
}

// Test 2.2: lsp_document_symbol_tool parameters
test "lsp_document_symbol_tool has required parameters" {
    const params = lsp_document_symbol.lsp_document_symbol_tool.function.parameters;
    try std.testing.expectEqual(@as(usize, 4), params.properties.len);

    var has_lsp = false;
    var has_root_dir = false;
    var has_file_path = false;
    var has_max_output = false;

    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "lsp")) has_lsp = true;
        if (std.mem.eql(u8, prop.name, "root_dir")) has_root_dir = true;
        if (std.mem.eql(u8, prop.name, "file_path")) has_file_path = true;
        if (std.mem.eql(u8, prop.name, "max_output")) has_max_output = true;
    }

    try std.testing.expect(has_lsp);
    try std.testing.expect(has_root_dir);
    try std.testing.expect(has_file_path);
    try std.testing.expect(has_max_output);
    try std.testing.expectEqual(@as(usize, 3), params.required.len);
}

// Test 3.1: Format found symbols
test "lspDocumentSymbolToString formats found symbols" {
    const allocator = std.testing.allocator;

    const symbols = try allocator.alloc(lsp_types.LspDocumentSymbol, 2);
    symbols[0] = lsp_types.LspDocumentSymbol{
        .name = try allocator.dupe(u8, "main"),
        .kind = 12, // Function
        .detail = try allocator.dupe(u8, "fn main() void"),
        .line = 10,
        .character = 0,
        .end_line = 20,
        .end_character = 1,
        .selection_line = 10,
        .selection_character = 3,
        .children = null,
    };
    symbols[1] = lsp_types.LspDocumentSymbol{
        .name = try allocator.dupe(u8, "MyStruct"),
        .kind = 23, // Struct
        .detail = null,
        .line = 25,
        .character = 0,
        .end_line = null,
        .end_character = null,
        .selection_line = null,
        .selection_character = null,
        .children = null,
    };

    var output = lsp_types.LspDocumentSymbolOutput{
        .symbols = symbols,
        .found = true,
    };
    defer output.deinit(allocator);

    const result = try lsp_document_symbol.lspDocumentSymbolToString(allocator, output);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<found>true</found>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<count>2</count>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<name>main</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<name>MyStruct</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<kind>12</kind>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<kind>23</kind>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<detail>fn main() void</detail>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<line>10</line>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<end_line>20</end_line>") != null);
}

// Test 3.2: Format not found
test "lspDocumentSymbolToString formats not found" {
    const allocator = std.testing.allocator;

    const output = lsp_types.LspDocumentSymbolOutput{
        .symbols = &.{},
        .found = false,
    };

    const result = try lsp_document_symbol.lspDocumentSymbolToString(allocator, output);
    defer allocator.free(result);

    try std.testing.expect(std.mem.eql(u8, result, "<found>false</found>"));
}

// Test 4.1: createMessage helper
test "createMessage creates valid LSP message" {
    const allocator = std.testing.allocator;

    const content = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const msg = try lsp_document_symbol.createMessage(allocator, content);
    defer allocator.free(msg);

    try std.testing.expect(std.mem.startsWith(u8, msg, "Content-Length: "));
    try std.testing.expect(std.mem.indexOf(u8, msg, "\r\n\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, msg, content));
}

// Test 5.1: Non-existent file
test "executeLspDocumentSymbol returns error for non-existent file" {
    const allocator = std.testing.allocator;
    const input = lsp_types.LspDocumentSymbolInput{
        .lsp = "zls",
        .root_dir = "/nonexistent/path",
        .file_path = "/nonexistent/path/that/does/not/exist.zig",
        .max_output = 100,
    };

    const result = lsp_document_symbol.executeLspDocumentSymbol(allocator, input);
    try std.testing.expectError(error.FileNotFound, result);
}
