const std = @import("std");
const text_replace_mod = @import("text_replace.zig");
const read_file_mod = @import("read_file.zig");

// Convenience type aliases
const TextReplaceOp = text_replace_mod.TextReplaceOp;
const text_replace_batch = text_replace_mod.text_replace_batch;

test "text_replace - basic replace single occurrence" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_basic.txt";
    const original_content = "Hello, World!\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Hello", .new_str = "Goodbye" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify file content was changed
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "Goodbye, World!\n";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - old_str not found returns error" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_notfound.txt";
    const original_content = "Hello, World!\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "nonexistent", .new_str = "new" },
    }, read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotFound, result);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - old_str appears twice returns OldStrNotUnique" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_duplicate.txt";
    const original_content = "const x = 0;\nconst x = 0;\n";
    
    // Create original file with two identical lines
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // This should fail because "const x = 0;" appears twice (both lines are identical)
    const result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "const x = 0;", .new_str = "const z = 1;" },
    }, read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotUnique, result);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - replace with empty string" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_empty.txt";
    const original_content = "Hello, World!\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = ", World!", .new_str = "" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "Hello\n";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - result serialization" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_serialize.txt";
    const original_content = "test content\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "test", .new_str = "new" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const serialized = try text_replace_mod.text_replace_batch_to_string_xml(allocator, result);
    defer allocator.free(serialized);
    
    // Should contain sha256_after
    try std.testing.expect(std.mem.indexOf(u8, serialized, "<sha256_after>") != null);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace tool definition exists" {
    try std.testing.expectEqualStrings("text_replace", text_replace_mod.text_replace_tool.function.name);
}

test "text_replace - unique match with surrounding context" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_context.txt";
    const original_content = "fn setup() void {\n    const x = 0;\n}\n\nfn other() void {\n    const x = 0;\n}\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Using context to make it unique - should succeed
    const old_str_with_context = "fn setup() void {\n    const x = 0;";
    const new_str = "fn setup() void {\n    const z = 1;";
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = old_str_with_context, .new_str = new_str },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify file was modified correctly
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    // First occurrence should be replaced, second should remain
    try std.testing.expect(std.mem.indexOf(u8, read_content, "const z = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_content, "const x = 0;") != null);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - multiline replace" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_multiline.txt";
    const original_content = "start\nold line 1\nold line 2\nend\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "old line 1\nold line 2", .new_str = "new line A\nnew line B" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "start\nnew line A\nnew line B\nend\n";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - forward slash" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_fwd_slash.txt";
    const original_content = "path: usr/local/bin";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "path: usr/local/bin", .new_str = "path: usr\\local\\bin" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify file content was changed
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "path: usr\\local\\bin";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - URL path" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_url.txt";
    const original_content = "https://example.com/path/to/resource";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "https://example.com", .new_str = "http://localhost:8080" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify file content was changed
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "http://localhost:8080/path/to/resource";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - replace at end of file" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_end.txt";
    const original_content = "start\nend";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "end", .new_str = "FINISH" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify sha256_after is set
    try std.testing.expect(result.sha256_after.len > 0);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "start\nFINISH";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - single backslash" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_backslash.txt";
    // In Zig string: \\ = single backslash \
    const original_content = "path\\to";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replace single backslash with forward slash
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\\", .new_str = "/" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "path/to";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - double backslash" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_double_backslash.txt";
    // In Zig string: \\\\ = double backslash \\
    const original_content = "escaped\\\\newline";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replace double backslash with underscore underscore
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\\\\", .new_str = "__" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "escaped__newline";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - backslash at end" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_trailing_backslash.txt";
    // In Zig string: \\ = single backslash \
    const original_content = "path\\";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replace trailing backslash with forward slash
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\\", .new_str = "/" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "path/";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - double quotes" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_double_quotes.txt";
    const original_content = "\"hello world\"";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replace content inside double quotes
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\"hello world\"", .new_str = "\"hi there\"" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "\"hi there\"";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - single quotes" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_single_quotes.txt";
    const original_content = "const c = 'a';\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replace character inside single quotes
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "'a'", .new_str = "'b'" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "const c = 'b';\n";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - curly braces" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_curly_braces.txt";
    const original_content = "fn foo() { return 42; }\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replace function body inside curly braces
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "fn foo() { return 42; }", .new_str = "fn foo() { return 0; }" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "fn foo() { return 0; }\n";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - angle brackets" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_angle_brackets.txt";
    const original_content = "<div class=\"test\">content</div>\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replace HTML-like tag with another
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "<div class=\"test\">", .new_str = "<span class=\"other\">" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "<span class=\"other\">content</div>\n";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - ambiguous backslash fails" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_ambig_backslash.txt";
    // In Zig string: a\\b a\\c = "a\b a\c" (backslash appears twice)
    const original_content = "a\\b a\\c";
    
    // Create original file with backslash appearing twice
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // This should fail because "\\" (single backslash) appears twice
    const result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\\", .new_str = "/" },
    }, read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotUnique, result);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - ambiguous slash in path fails" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_ambig_slash.txt";
    const original_content = "/a/b /a/c";
    
    // Create original file with forward slash appearing multiple times
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // This should fail because "/" appears multiple times
    const result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "/", .new_str = "-" },
    }, read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotUnique, result);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - empty old_str fails" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_empty_oldstr.txt";
    const original_content = "hello";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // This should fail because empty string matches everywhere (6 positions in "hello")
    const result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "", .new_str = "X" },
    }, read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotUnique, result);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}
