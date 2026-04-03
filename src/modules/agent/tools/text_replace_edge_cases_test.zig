// =============================================================================
// text_replace EDGE CASES TEST - Preventing "OldStrNotFound" errors
// =============================================================================
//
// This test file documents common mistakes that cause "OldStrNotFound" errors
// and provides examples of CORRECT usage.
//
const std = @import("std");
const text_replace_mod = @import("text_replace.zig");
const read_file_mod = @import("read_file.zig");

const TextReplaceOp = text_replace_mod.TextReplaceOp;
const text_replace_batch = text_replace_mod.text_replace_batch;

// Helper to create test file with content
fn createTestFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

// Helper to read file content
fn readTestFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

// =============================================================================
// RULE #1: ALWAYS read_file FIRST, then copy the EXACT string
// =============================================================================

test "edge_case - MUST read_file FIRST before text_replace" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_read_first.txt";
    const original_content = "const x = 42;\n";
    
    try createTestFile(test_path, original_content);
    
    // CORRECT WAY:
    // Step 1: read_file to get content AND hash
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Step 2: Copy EXACT string from read_file result, not from memory!
    // The string "const x = 42;" must match EXACTLY
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "const x = 42;", .new_str = "const y = 100;" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("const y = 100;\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// RULE #2: Trailing whitespace MUST match exactly
// =============================================================================

test "edge_case - trailing spaces must match" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_trailing_space.txt";
    // Note: This has a trailing space after "Hello"
    const original_content = "Hello \n";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // WRONG: "Hello " vs "Hello" - missing trailing space!
    // This will FAIL with OldStrNotFound:
    // const result = text_replace_batch(allocator, test_path, &.{
    //     TextReplaceOp{ .old_str = "Hello", .new_str = "Hi" },  // <-- ERROR!
    // }, read_result.sha256);
    
    // CORRECT: Include trailing space
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Hello ", .new_str = "Hi " },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("Hi \n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "edge_case - multiple trailing spaces" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_multi_trailing_space.txt";
    // Line with 3 trailing spaces
    const original_content = "Item1   \nItem2\n";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Copy EXACT string including spaces
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Item1   ", .new_str = "First   " },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("First   \nItem2\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// RULE #3: Tabs vs Spaces - indentation must match
// =============================================================================

test "edge_case - tabs vs spaces mismatch" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_tab_space.txt";
    // File uses TAB for indentation
    const original_content = "\tconst x = 1;\n\tconst y = 2;\n";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // WRONG: Using spaces instead of tab
    // This will FAIL:
    // const result = text_replace_batch(allocator, test_path, &.{
    //     TextReplaceOp{ .old_str = "    const x = 1;", .new_str = "    const x = 99;" },  // <-- ERROR!
    // }, read_result.sha256);
    
    // CORRECT: Use TAB character
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\tconst x = 1;", .new_str = "\tconst x = 99;" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("\tconst x = 99;\n\tconst y = 2;\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "edge_case - mixed tabs and spaces" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_mixed_indent.txt";
    // 2 spaces + tab mixed indentation
    const original_content = "  \tfn foo() {}\n";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Copy EXACT indentation including both spaces and tab
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "  \tfn foo() {}", .new_str = "  \tfn bar() {}" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("  \tfn bar() {}\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// RULE #4: Newlines - \n vs \r\n vs \r must match exactly
// =============================================================================

test "edge_case - missing newline at end of file" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_no_final_newline.txt";
    // File WITHOUT trailing newline
    const original_content = "No newline at end";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // WRONG: Adding \n that doesn't exist
    // This will FAIL:
    // const result = text_replace_batch(allocator, test_path, &.{
    //     TextReplaceOp{ .old_str = "No newline at end\n", .new_str = "Has newline\n" },  // <-- ERROR!
    // }, read_result.sha256);
    
    // CORRECT: Match without trailing \n
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "No newline at end", .new_str = "Also no newline" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("Also no newline", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "edge_case - CRLF vs LF mismatch" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_crlf.txt";
    // Windows-style line endings
    const original_content = "Line1\r\nLine2\r\n";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // WRONG: Using \n instead of \r\n
    // This will FAIL:
    // const result = text_replace_batch(allocator, test_path, &.{
    //     TextReplaceOp{ .old_str = "Line1\nLine2\n", .new_str = "A\nB\n" },  // <-- ERROR!
    // }, read_result.sha256);
    
    // CORRECT: Use \r\n for Windows files
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Line1\r\n", .new_str = "First\r\n" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("First\r\nLine2\r\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// RULE #5: Empty lines must be included
// =============================================================================

test "edge_case - empty line in middle" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_empty_line.txt";
    // Note the empty line between "One" and "Two"
    const original_content = "One\n\nTwo\n";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // WRONG: Missing the empty line
    // This will FAIL:
    // const result = text_replace_batch(allocator, test_path, &.{
    //     TextReplaceOp{ .old_str = "One\nTwo", .new_str = "First\nSecond" },  // <-- ERROR!
    // }, read_result.sha256);
    
    // CORRECT: Include the empty line
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "One\n\nTwo", .new_str = "First\n\nSecond" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("First\n\nSecond\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// RULE #6: Whitespace-only lines must match exactly
// =============================================================================

test "edge_case - whitespace-only line" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_whitespace_line.txt";
    // Line with only spaces
    const original_content = "Start\n   \nEnd\n";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // WRONG: Using tab instead of spaces
    // This will FAIL:
    // const result = text_replace_batch(allocator, test_path, &.{
    //     TextReplaceOp{ .old_str = "\t\n", .new_str = ">\n" },  // <-- ERROR!
    // }, read_result.sha256);
    
    // CORRECT: Match exact whitespace
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "   \n", .new_str = "---\n" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("Start\n---\nEnd\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// RULE #7: Unicode and special characters
// =============================================================================

test "edge_case - unicode characters" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_unicode.txt";
    const original_content = "Héllo Wörld!\n";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Copy EXACT unicode string
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Héllo", .new_str = "Hello" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("Hello Wörld!\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "edge_case - emoji in content" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_emoji.txt";
    const original_content = "Status: ✅ Done\n";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Copy EXACT string with emoji
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "✅", .new_str = "❌" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("Status: ❌ Done\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// RULE #8: Consecutive identical lines need unique context
// =============================================================================

test "edge_case - duplicate lines need surrounding context" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_duplicate_lines.txt";
    const original_content =
        \\fn setup() void {
        \\    const x = 1;
        \\}
        \\
        \\fn test() void {
        \\    const x = 1;
        \\}
    ;
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // WRONG: Just "const x = 1;" appears twice - will get OldStrNotUnique
    // This will FAIL:
    // const result = text_replace_batch(allocator, test_path, &.{
    //     TextReplaceOp{ .old_str = "const x = 1;", .new_str = "const y = 99;" },  // <-- ERROR!
    // }, read_result.sha256);
    
    // CORRECT: Include surrounding context to make it unique
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "fn setup() void {\n    const x = 1;", .new_str = "fn setup() void {\n    const y = 99;" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    
    // Only first occurrence should change
    try std.testing.expect(std.mem.indexOf(u8, final_content, "const y = 99;") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_content, "const x = 1;") != null);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// RULE #9: Leading whitespace matters
// =============================================================================

test "edge_case - leading whitespace" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_leading_ws.txt";
    // Note: line 2 has leading spaces
    const original_content = "No indent\n   Has indent\n";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // WRONG: Missing leading spaces
    // This will FAIL:
    // const result = text_replace_batch(allocator, test_path, &.{
    //     TextReplaceOp{ .old_str = "Has indent", .new_str = "Changed" },  // <-- ERROR!
    // }, read_result.sha256);
    
    // CORRECT: Include leading spaces
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "   Has indent", .new_str = "   Changed" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("No indent\n   Changed\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// RULE #10: Real-world Zig code example
// =============================================================================

test "edge_case - real zig code" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_zig.zig";
    const original_content =
        \\pub fn main() void {
        \\    const allocator = std.heap.page_allocator;
        \\    std.debug.print("Hello\n", .{});
        \\}
    ;
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Copy EXACT code including all whitespace
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "    std.debug.print(\"Hello\\n\", .{});", .new_str = "    std.debug.print(\"Goodbye\\n\", .{});" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expect(std.mem.indexOf(u8, final_content, "Goodbye") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_content, "Hello") == null);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// RULE #11: Hash becomes invalid after ANY change
// =============================================================================

test "edge_case - stale hash fails" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_stale_hash.txt";
    const original_content = "Original content\n";
    
    try createTestFile(test_path, original_content);
    
    // First read to get hash
    const read_result1 = try read_file_mod.read_file(allocator, test_path, .{});
    const hash1 = read_result1.sha256;
    read_result1.deinit(allocator);
    
    // Now make a change using the hash
    _ = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Original", .new_str = "Modified" },
    }, hash1);
    
    // Second read - hash has CHANGED
    const read_result2 = try read_file_mod.read_file(allocator, test_path, .{});
    const hash2 = read_result2.sha256;
    read_result2.deinit(allocator);
    
    // WRONG: Using old hash from read_result1
    // This will FAIL with HashMismatch:
    const bad_result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Modified", .new_str = "Final" },
    }, hash1);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.HashMismatch, bad_result);
    
    // CORRECT: Use NEW hash from read_result2
    const good_result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Modified", .new_str = "Final" },
    }, hash2);
    defer good_result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    try std.testing.expectEqualStrings("Final content\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// RULE #12: Partial matches don't work
// =============================================================================

test "edge_case - partial string fails" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_partial.txt";
    const original_content = "abc def ghi\n";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // WRONG: "bcd" is NOT in the file
    // This will FAIL:
    const bad_result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "bcd", .new_str = "XYZ" },
    }, read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotFound, bad_result);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// QUICK REFERENCE - Common Mistakes
// =============================================================================

test "quick_ref - common mistakes summary" {
    const allocator = std.testing.allocator;
    const test_path = "test_edge_quickref.txt";
    // File has: leading spaces, trailing spaces, mixed indent
    const original_content = "  Hello   \n\tconst x = 1;\n";
    
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Copy EXACT strings from read_file result:
    // - "  Hello   " (2 leading + 3 trailing spaces)
    // - "\tconst x = 1;" (tab indentation)
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "  Hello   ", .new_str = "  Hi      " },
        TextReplaceOp{ .old_str = "\tconst x = 1;", .new_str = "\tconst y = 2;" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    
    try std.testing.expectEqualStrings("  Hi      \n\tconst y = 2;\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}
