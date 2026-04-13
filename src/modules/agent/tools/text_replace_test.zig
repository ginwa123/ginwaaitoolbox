const std = @import("std");
const text_replace_mod = @import("text_replace.zig");

// Convenience type aliases
const text_replace = text_replace_mod.text_replace;
const TextReplaceError = text_replace_mod.TextReplaceError;

test "text_replace - basic replace" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_basic.txt";
    const original_content = "Hello, World!\n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    _ = try text_replace(allocator, test_path, "Hello", "Goodbye");
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("Goodbye, World!\n", read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - old_str not found" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_notfound.txt";
    const original_content = "Hello, World!\n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const result = text_replace(allocator, test_path, "nonexistent", "new");
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotFound, result);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - old_str appears twice" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_duplicate.txt";
    const original_content = "const x = 0;\nconst x = 0;\n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const result = text_replace(allocator, test_path, "const x = 0;", "const z = 1;");
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotUnique, result);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - replace with empty string" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_empty.txt";
    const original_content = "Hello, World!\n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    _ = try text_replace(allocator, test_path, ", World!", "");
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("Hello\n", read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - multiline replace" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_multiline.txt";
    const original_content = "start\nold line 1\nold line 2\nend\n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    _ = try text_replace(allocator, test_path, "old line 1\nold line 2", "new line A\nnew line B");
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("start\nnew line A\nnew line B\nend\n", read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - unique match with context" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_context.txt";
    const original_content = "fn setup() void {\n    const x = 0;\n}\n\nfn other() void {\n    const x = 0;\n}\n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    _ = try text_replace(allocator, test_path, "fn setup() void {\n    const x = 0;", "fn setup() void {\n    const z = 1;");
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expect(std.mem.indexOf(u8, read_content, "const z = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_content, "const x = 0;") != null);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - URL path" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_url.txt";
    const original_content = "https://example.com/path/to/resource";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    _ = try text_replace(allocator, test_path, "https://example.com", "http://localhost:8080");
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("http://localhost:8080/path/to/resource", read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - single backslash" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_backslash.txt";
    const original_content = "path\\to";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    _ = try text_replace(allocator, test_path, "\\", "/");
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("path/to", read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - double backslash" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_double_backslash.txt";
    const original_content = "escaped\\\\newline";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    _ = try text_replace(allocator, test_path, "\\\\", "__");
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("escaped__newline", read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - double quotes" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_double_quotes.txt";
    const original_content = "\"hello world\"";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    _ = try text_replace(allocator, test_path, "\"hello world\"", "\"hi there\"");
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("\"hi there\"", read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - empty old_str fails" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_empty_oldstr.txt";
    const original_content = "hello";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const result = text_replace(allocator, test_path, "", "X");
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotUnique, result);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - CRLF line endings in file" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_crlf.txt";
    // File written with CRLF (Windows line endings)
    const original_content = "Hello,\r\n World!\r\n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // old_str uses LF only — should still match because we normalize
    _ = try text_replace(allocator, test_path, "Hello,\n World!", "Goodbye,\n World!");
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("Goodbye,\n World!\r\n", read_content);

    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - trailing whitespace in file" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_trailing_ws.txt";
    // File has trailing spaces on lines
    const original_content = "Hello,   \n  World!   \n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // old_str without trailing spaces — should match (whitespace stripped before compare)
    _ = try text_replace(allocator, test_path, "Hello,   ", "Goodbye,");
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("Goodbye,\n  World!   \n", read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - mixed tabs and spaces indentation" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_mixed_indent.txt";
    // File uses tabs, user provides spaces
    const original_content = "fn test() void {\n\tconst x = 0;\n}";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // old_str uses spaces instead of tab
    const result = text_replace(allocator, test_path, "    const x = 0;", "    const y = 1;");
    
    // This should fail since mixed tabs/spaces don't normalize to each other
    try std.testing.expectError(TextReplaceError.OldStrNotFound, result);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - CRLF with trailing spaces combo" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_crlf_trailing.txt";
    // Most complex case: CRLF + trailing spaces
    const original_content = "Hello,   \r\n  World!   \r\n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // old_str uses LF and no trailing spaces
    _ = try text_replace(allocator, test_path, "Hello,   ", "Goodbye,");
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("Goodbye,\r\n  World!   \r\n", read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace tool definition" {
    try std.testing.expectEqualStrings("text_replace", text_replace_mod.text_replace_tool.function.name);
}
