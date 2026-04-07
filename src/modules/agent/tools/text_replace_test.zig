const std = @import("std");
const text_replace_mod = @import("text_replace.zig");

// Convenience type aliases
const TextReplaceOp = text_replace_mod.TextReplaceOp;
const text_replace = text_replace_mod.text_replace;

test "text_replace - basic replace" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_basic.txt";
    const original_content = "Hello, World!\n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    _ = try text_replace(allocator, test_path, 
        TextReplaceOp{ .old_str = "Hello", .new_str = "Goodbye" });
    
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
    
    const result = text_replace(allocator, test_path, 
        TextReplaceOp{ .old_str = "nonexistent", .new_str = "new" });
    
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
    
    const result = text_replace(allocator, test_path, 
        TextReplaceOp{ .old_str = "const x = 0;", .new_str = "const z = 1;" });
    
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
    
    _ = try text_replace(allocator, test_path, 
        TextReplaceOp{ .old_str = ", World!", .new_str = "" });
    
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
    
    _ = try text_replace(allocator, test_path, 
        TextReplaceOp{ .old_str = "old line 1\nold line 2", .new_str = "new line A\nnew line B" });
    
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
    
    _ = try text_replace(allocator, test_path, 
        TextReplaceOp{ .old_str = "fn setup() void {\n    const x = 0;", .new_str = "fn setup() void {\n    const z = 1;" });
    
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
    
    _ = try text_replace(allocator, test_path, 
        TextReplaceOp{ .old_str = "https://example.com", .new_str = "http://localhost:8080" });
    
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
    
    _ = try text_replace(allocator, test_path, 
        TextReplaceOp{ .old_str = "\\", .new_str = "/" });
    
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
    
    _ = try text_replace(allocator, test_path, 
        TextReplaceOp{ .old_str = "\\\\", .new_str = "__" });
    
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
    
    _ = try text_replace(allocator, test_path, 
        TextReplaceOp{ .old_str = "\"hello world\"", .new_str = "\"hi there\"" });
    
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
    
    const result = text_replace(allocator, test_path, 
        TextReplaceOp{ .old_str = "", .new_str = "X" });
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotUnique, result);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace tool definition" {
    try std.testing.expectEqualStrings("text_replace", text_replace_mod.text_replace_tool.function.name);
}
