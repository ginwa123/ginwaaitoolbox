// =============================================================================
// text_replace AI WORKFLOW TEST - Simulating Real AI Usage
// =============================================================================
//
// These tests simulate how an AI agent should use read_file + text_replace:
// 1. First call read_file to get content AND sha256
// 2. Then call text_replace with the EXACT string from read_file result
//
// Common "OldStrNotFound" errors happen when:
// - AI copies string from memory instead of read_file result
// - Whitespace (tabs/spaces/newlines) doesn't match exactly
// - Partial strings are used instead of complete matches
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
// SCENARIO 1: Basic Edit - Read then Replace
// =============================================================================

test "ai_workflow - read_file then text_replace basic" {
    const allocator = std.testing.allocator;
    const test_path = "test_ai_basic.txt";
    const original_content = "const greeting = \"Hello, World!\";\n";
    
    // Setup: Create file
    try createTestFile(test_path, original_content);
    
    // Step 1: AI calls read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // read_file returns: content, sha256, total_lines, etc.
    // AI should copy the string from read_result.content
    // NOT from memory!
    
    // Step 2: AI calls text_replace with exact string from read_result
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ 
            .old_str = read_result.content,  // Use EXACT string from read_file!
            .new_str = "const greeting = \"Hi, Universe!\";\n" 
        },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    
    try std.testing.expectEqualStrings("const greeting = \"Hi, Universe!\";\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// SCENARIO 2: Partial Edit - Replace Only What You Need
// =============================================================================

test "ai_workflow - partial edit from read content" {
    const allocator = std.testing.allocator;
    const test_path = "test_ai_partial.txt";
    const original_content =
        \\pub fn main() void {
        \\    const x = 10;
        \\    const y = 20;
        \\    std.debug.print("{d} + {d}\n", .{x, y});
        \\}
    ;
    
    // Setup
    try createTestFile(test_path, original_content);
    
    // Step 1: Read file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Step 2: Extract just the line we want to change from read_result.content
    // This demonstrates copying partial content from read_file
    const old_str = "    const x = 10;";
    const new_str = "    const x = 99;";
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = old_str, .new_str = new_str },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    
    try std.testing.expect(std.mem.indexOf(u8, final_content, "const x = 99;") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_content, "const x = 10;") == null);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// SCENARIO 3: Multi-line Edit - Preserve Exact Formatting
// =============================================================================

test "ai_workflow - multiline edit preserving formatting" {
    const allocator = std.testing.allocator;
    const test_path = "test_ai_multiline.txt";
    const original_content =
        \\fn calculate() i32 {
        \\    const a = 1;
        \\    const b = 2;
        \\    return a + b;
        \\}
    ;
    
    // Setup
    try createTestFile(test_path, original_content);
    
    // Step 1: Read file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Step 2: Copy EXACT multiline string from read_result
    // AI must preserve all newlines and indentation
    const old_str = 
        \\    const a = 1;
        \\    const b = 2;
    ;
    const new_str = 
        \\    const a = 100;
        \\    const b = 200;
    ;
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = old_str, .new_str = new_str },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    
    try std.testing.expect(std.mem.indexOf(u8, final_content, "const a = 100;") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_content, "const b = 200;") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_content, "const a = 1;") == null);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// SCENARIO 4: Hash Validation - Stale Hash Fails
// =============================================================================

test "ai_workflow - stale hash causes error" {
    const allocator = std.testing.allocator;
    const test_path = "test_ai_hash.txt";
    const original_content = "Original text\n";
    
    // Setup
    try createTestFile(test_path, original_content);
    
    // Step 1: Read file - get hash
    const read_result1 = try read_file_mod.read_file(allocator, test_path, .{});
    const hash1 = read_result1.sha256;
    read_result1.deinit(allocator);
    
    // Step 2: Make change using hash1
    _ = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Original", .new_str = "Changed" },
    }, hash1);
    
    // Step 3: Read file again - hash has CHANGED!
    const read_result2 = try read_file_mod.read_file(allocator, test_path, .{});
    const hash2 = read_result2.sha256;
    read_result2.deinit(allocator);
    
    // Step 4: WRONG - using old hash from step 1
    // This should FAIL with HashMismatch
    const bad_result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Changed", .new_str = "Final" },
    }, hash1);  // <-- WRONG: using stale hash
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.HashMismatch, bad_result);
    
    // Step 5: CORRECT - using new hash from step 3
    const good_result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Changed", .new_str = "Final" },
    }, hash2);  // <-- CORRECT: using fresh hash
    defer good_result.deinit(allocator);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// SCENARIO 5: Error Recovery - OldStrNotFound
// =============================================================================

test "ai_workflow - old_str_not_found error handling" {
    const allocator = std.testing.allocator;
    const test_path = "test_ai_notfound.txt";
    const original_content = "The quick brown fox\n";
    
    // Setup
    try createTestFile(test_path, original_content);
    
    // Step 1: Read file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Step 2: WRONG - using string from memory, not from read_result
    // This will FAIL because "lazy dog" is NOT in the file
    const bad_result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "lazy dog", .new_str = "sleepy cat" },  // <-- WRONG!
    }, read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotFound, bad_result);
    
    // CORRECT: Use string from read_result
    const good_result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "quick", .new_str = "slow" },
    }, read_result.sha256);
    defer good_result.deinit(allocator);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// SCENARIO 6: Whitespace Edge Cases
// =============================================================================

test "ai_workflow - trailing spaces must match" {
    const allocator = std.testing.allocator;
    const test_path = "test_ai_trailing.txt";
    // Note: "Item " has trailing space, "End" has no trailing space
    const original_content = "Item \nEnd\n";
    
    // Setup
    try createTestFile(test_path, original_content);
    
    // Step 1: Read file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Step 2: Copy EXACT string including trailing space
    // "Item " NOT "Item"
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Item ", .new_str = "Entry " },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    
    try std.testing.expectEqualStrings("Entry \nEnd\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "ai_workflow - tab indentation preserved" {
    const allocator = std.testing.allocator;
    const test_path = "test_ai_tabs.txt";
    // Tab-indented content
    const original_content = "\tconst x = 1;\n\tconst y = 2;\n";
    
    // Setup
    try createTestFile(test_path, original_content);
    
    // Step 1: Read file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Step 2: Copy EXACT string with tab
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\tconst x = 1;", .new_str = "\tconst z = 99;" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    
    try std.testing.expectEqualStrings("\tconst z = 99;\n\tconst y = 2;\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// SCENARIO 7: Multiple Operations in Sequence
// =============================================================================

test "ai_workflow - sequential edits with fresh hash each time" {
    const allocator = std.testing.allocator;
    const test_path = "test_ai_sequential.txt";
    const original_content = "a = 1\nb = 2\nc = 3\n";
    
    // Setup
    try createTestFile(test_path, original_content);
    
    // Edit 1: Change "a = 1" to "x = 99"
    {
        const read_result1 = try read_file_mod.read_file(allocator, test_path, .{});
        defer read_result1.deinit(allocator);
        
        _ = try text_replace_batch(allocator, test_path, &.{
            TextReplaceOp{ .old_str = "a = 1", .new_str = "x = 99" },
        }, read_result1.sha256);
    }
    
    // Edit 2: Change "c = 3" to "z = 100"
    // MUST read file again to get NEW hash!
    {
        const read_result2 = try read_file_mod.read_file(allocator, test_path, .{});
        defer read_result2.deinit(allocator);
        
        _ = try text_replace_batch(allocator, test_path, &.{
            TextReplaceOp{ .old_str = "c = 3", .new_str = "z = 100" },
        }, read_result2.sha256);
    }
    
    // Verify final state
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    
    try std.testing.expectEqualStrings("x = 99\nb = 2\nz = 100\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// SCENARIO 8: Real-world JSON-like Content
// =============================================================================

test "ai_workflow - json config edit" {
    const allocator = std.testing.allocator;
    const test_path = "test_ai_json.txt";
    const original_content =
        \\{
        \\  "name": "myapp",
        \\  "version": "1.0.0",
        \\  "port": 8080
        \\}
    ;
    
    // Setup
    try createTestFile(test_path, original_content);
    
    // Step 1: Read file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Step 2: Edit specific field
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "  \"version\": \"1.0.0\",", .new_str = "  \"version\": \"2.0.0\"," },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    
    try std.testing.expect(std.mem.indexOf(u8, final_content, "\"version\": \"2.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_content, "\"version\": \"1.0.0\"") == null);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// SCENARIO 9: Duplicate Content Requires Context
// =============================================================================

test "ai_workflow - duplicate lines need context" {
    const allocator = std.testing.allocator;
    const test_path = "test_ai_dup.txt";
    const original_content =
        \\fn init() void {
        \\    const value = 1;
        \\}
        \\
        \\fn process() void {
        \\    const value = 1;
        \\}
    ;
    
    // Setup
    try createTestFile(test_path, original_content);
    
    // Step 1: Read file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Step 2: WRONG - "const value = 1;" appears twice!
    // This will FAIL with OldStrNotUnique
    const bad_result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "const value = 1;", .new_str = "const result = 42;" },
    }, read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotUnique, bad_result);
    
    // Step 3: CORRECT - include function context to make unique
    const good_result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "fn init() void {\n    const value = 1;", .new_str = "fn init() void {\n    const result = 42;" },
    }, read_result.sha256);
    defer good_result.deinit(allocator);
    
    // Verify only first occurrence changed
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    
    // Should have both: changed in init, unchanged in process
    try std.testing.expect(std.mem.indexOf(u8, final_content, "const result = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_content, "const value = 1;") != null);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// SCENARIO 10: Empty Lines Handling
// =============================================================================

test "ai_workflow - empty line between content" {
    const allocator = std.testing.allocator;
    const test_path = "test_ai_empty.txt";
    // Note: blank line between sections
    const original_content = "Section A\n\nSection B\n";
    
    // Setup
    try createTestFile(test_path, original_content);
    
    // Step 1: Read file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Step 2: Replace including empty line
    // Must include the "\n\n" between sections
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "Section A\n\nSection B", .new_str = "Part One\n\nPart Two" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    
    try std.testing.expectEqualStrings("Part One\n\nPart Two\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

// =============================================================================
// QUICK REFERENCE: Common Mistakes and Fixes
// =============================================================================

test "quick_ref - mistake vs correct" {
    const allocator = std.testing.allocator;
    const test_path = "test_ai_quickref.txt";
    // Content uses 4 spaces for indentation
    const original_content = "    const x = 1;\n";
    
    // Setup
    try createTestFile(test_path, original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // ❌ MISTAKE 1: Using tab instead of spaces
    // const bad1 = text_replace_batch(allocator, test_path, &.{
    //     TextReplaceOp{ .old_str = "\tconst x = 1;", .new_str = "\tconst y = 2;" },
    // }, read_result.sha256);  // FAILS: actual content uses 4 spaces!
    
    // ❌ MISTAKE 2: Missing indentation entirely
    // const bad2 = text_replace_batch(allocator, test_path, &.{
    //     TextReplaceOp{ .old_str = "const x = 1;", .new_str = "const y = 2;" },
    // }, read_result.sha256);  // FAILS: actual content has leading spaces!
    
    // ✅ CORRECT: Copy exact string including 4 spaces
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "    const x = 1;", .new_str = "    const y = 2;" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify
    const final_content = try readTestFile(allocator, test_path);
    defer allocator.free(final_content);
    
    try std.testing.expectEqualStrings("    const y = 2;\n", final_content);
    
    try std.fs.cwd().deleteFile(test_path);
}
