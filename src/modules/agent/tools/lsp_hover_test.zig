const std = @import("std");
const lsp_hover = @import("lsp_hover.zig");
const models = @import("models.zig");

// Test 1.1: LspHoverInput struct
test "LspHoverInput has all required fields" {
    const input = models.LspHoverInput{
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

// Test 1.2: LspHoverOutput struct - found
test "LspHoverOutput can represent found hover" {
    const allocator = std.testing.allocator;

    const output = models.LspHoverOutput{
        .contents = try allocator.dupe(u8, "fn main() void\n\nMain entry point"),
        .line = 10,
        .character = 0,
        .end_line = 10,
        .end_character = 4,
        .found = true,
    };
    defer output.deinit(allocator);

    try std.testing.expect(output.found);
    try std.testing.expect(std.mem.eql(u8, output.contents.?, "fn main() void\n\nMain entry point"));
    try std.testing.expectEqual(@as(u32, 10), output.line.?);
    try std.testing.expectEqual(@as(u32, 0), output.character.?);
}

// Test 1.3: LspHoverOutput struct - not found
test "LspHoverOutput can represent not found" {
    const output = models.LspHoverOutput{
        .contents = null,
        .line = null,
        .character = null,
        .end_line = null,
        .end_character = null,
        .found = false,
    };

    try std.testing.expect(!output.found);
    try std.testing.expect(output.contents == null);
}

// Test 2.1: lspHoverTool name
test "lspHoverTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_hover.lspHoverTool.function.name, "lsp_hover"));
}

// Test 2.2: lspHoverTool parameters
test "lspHoverTool has required parameters" {
    const params = lsp_hover.lspHoverTool.function.parameters;
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

// Test 3.1: Format found hover
test "lspHoverToString formats found hover" {
    const allocator = std.testing.allocator;

    const output = models.LspHoverOutput{
        .contents = try allocator.dupe(u8, "fn main() void"),
        .line = 10,
        .character = 0,
        .end_line = 10,
        .end_character = 4,
        .found = true,
    };
    defer allocator.free(output.contents.?);

    const result = try lsp_hover.lspHoverToString(allocator, output);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<found>true</found>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<line>10</line>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<character>0</character>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<end_line>10</end_line>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<end_character>4</end_character>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<contents>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "fn main() void") != null);
}

// Test 3.2: Format not found
test "lspHoverToString formats not found" {
    const allocator = std.testing.allocator;

    const output = models.LspHoverOutput{
        .contents = null,
        .line = null,
        .character = null,
        .end_line = null,
        .end_character = null,
        .found = false,
    };

    const result = try lsp_hover.lspHoverToString(allocator, output);
    defer allocator.free(result);

    try std.testing.expect(std.mem.eql(u8, result, "<found>false</found>"));
}

// Test 4.1: createMessage helper
test "createMessage creates valid LSP message" {
    const allocator = std.testing.allocator;

    const content = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const msg = try lsp_hover.createMessage(allocator, content);
    defer allocator.free(msg);

    try std.testing.expect(std.mem.startsWith(u8, msg, "Content-Length: "));
    try std.testing.expect(std.mem.indexOf(u8, msg, "\r\n\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, msg, content));
}

// Test 5.1: Non-existent file
test "executeLspHover returns error for non-existent file" {
    const allocator = std.testing.allocator;
    const input = models.LspHoverInput{
        .lsp = "zls",
        .root_dir = "/nonexistent/path",
        .file_path = "/nonexistent/path/that/does/not/exist.zig",
        .line = 0,
        .character = 0,
    };

    const result = lsp_hover.executeLspHover(allocator, input);
    try std.testing.expectError(error.FileNotFound, result);
}
