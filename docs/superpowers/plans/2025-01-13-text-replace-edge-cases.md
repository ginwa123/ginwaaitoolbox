# text_replace Edge Case Tests - Implementation Plan

**Goal:** Add comprehensive test cases for difficult strings (escaped characters, special chars, unicode, control characters) to make `text_replace` more robust.

**Architecture:** Add edge case tests to existing test files, focusing on strings that are difficult to parse or match.

**Tech Stack:** Zig 0.15.2, std.testing

---

## Chunk 1: Single Operation Edge Cases

### Task 1: Backslash and Escape Sequence Tests

**Files:**
- Modify: `src/modules/agent/tools/text_replace_test.zig`

- [ ] **Step 1: Add test for single backslash `\`**

```zig
test "text_replace - single backslash" {
    const allocator = std.testing.allocator;
    const test_path = "test_escape_backslash.txt";
    const original_content = "path\\to\\file";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\\", .new_str = "/" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("path/to/file", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 2: Add test for double backslash `\\`**

```zig
test "text_replace - double backslash" {
    const allocator = std.testing.allocator;
    const test_path = "test_escape_double_backslash.txt";
    const original_content = "escaped\\\\newline";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\\\\", .new_str = "__" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("escaped__newline", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 3: Add test for backslash at end of string**

```zig
test "text_replace - backslash at end" {
    const allocator = std.testing.allocator;
    const test_path = "test_escape_trailing_backslash.txt";
    const original_content = "path\\";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\\", .new_str = "/" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("path/", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 4: Run tests to verify**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: All new tests pass

---

### Task 2: Forward Slash and Path Tests

**Files:**
- Modify: `src/modules/agent/tools/text_replace_test.zig`

- [ ] **Step 1: Add test for forward slash `/`**

```zig
test "text_replace - forward slash" {
    const allocator = std.testing.allocator;
    const test_path = "test_path_slash.txt";
    const original_content = "usr/local/bin";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "/", .new_str = "\\" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("usr\\local\\bin", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 2: Add test for URL paths**

```zig
test "text_replace - URL path" {
    const allocator = std.testing.allocator;
    const test_path = "test_url.txt";
    const original_content = "https://example.com/path/to/resource";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "https://example.com", .new_str = "http://localhost:8080" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("http://localhost:8080/path/to/resource", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 3: Run tests to verify**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: All new tests pass

---

### Task 3: Quote and Bracket Tests

**Files:**
- Modify: `src/modules/agent/tools/text_replace_test.zig`

- [ ] **Step 1: Add test for double quotes**

```zig
test "text_replace - double quotes" {
    const allocator = std.testing.allocator;
    const test_path = "test_double_quote.txt";
    const original_content = "const msg = \"hello world\";";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\"hello world\"", .new_str = "\"hi there\"" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("const msg = \"hi there\";", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 2: Add test for single quotes**

```zig
test "text_replace - single quotes" {
    const allocator = std.testing.allocator;
    const test_path = "test_single_quote.txt";
    const original_content = "const c = 'a';";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "'a'", .new_str = "'b'" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("const c = 'b';", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 3: Add test for curly braces**

```zig
test "text_replace - curly braces" {
    const allocator = std.testing.allocator;
    const test_path = "test_curly_braces.txt";
    const original_content = "fn foo() { return 42; }";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "{ return 42; }", .new_str = "{ return 0; }" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("fn foo() { return 0; }", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 4: Add test for angle brackets**

```zig
test "text_replace - angle brackets" {
    const allocator = std.testing.allocator;
    const test_path = "test_angle_brackets.txt";
    const original_content = "<div class=\"test\">content</div>";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "<div class=\"test\">", .new_str = "<span class=\"other\">" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("<span class=\"other\">content</div>", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 5: Run tests to verify**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: All new tests pass

---

### Task 4: Unicode and Special Character Tests

**Files:**
- Modify: `src/modules/agent/tools/text_replace_test.zig`

- [ ] **Step 1: Add test for emoji**

```zig
test "text_replace - emoji" {
    const allocator = std.testing.allocator;
    const test_path = "test_emoji.txt";
    const original_content = "Hello 👋 World!";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "👋", .new_str = "👋👋" },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("Hello 👋👋 World!", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 2: Add test for unicode arrows**

```zig
test "text_replace - unicode arrows" {
    const allocator = std.testing.allocator;
    const test_path = "test_unicode_arrows.txt";
    const original_content = "a → b → c";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = " → ", .new_str = " => " },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("a => b => c", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 3: Add test for non-breaking space**

```zig
test "text_replace - non-breaking space" {
    const allocator = std.testing.allocator;
    const test_path = "test_nbsp.txt";
    const original_content = "word\u{00A0}word";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\u{00A0}", .new_str = " " },
    }, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("word word", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 4: Run tests to verify**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: All new tests pass

---

## Chunk 2: Batch Operation Edge Cases

### Task 5: Multiple Escaped Characters in Batch

**Files:**
- Modify: `src/modules/agent/tools/text_replace_batch_test.zig`

- [ ] **Step 1: Add test for batch with multiple backslashes**

```zig
test "text_replace_batch - multiple backslashes" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_backslashes.txt";
    const original_content = "a\\b\\c\\d";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const ops = &.{
        TextReplaceOp{ .old_str = "\\", .new_str = "/" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("a/b/c/d", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 2: Add test for batch with quotes**

```zig
test "text_replace_batch - multiple quotes" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_quotes.txt";
    const original_content = "\"a\" \"b\" \"c\"";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replace first quote pair only
    const ops = &.{
        TextReplaceOp{ .old_str = "\"a\"", .new_str = "'x'" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("'x' \"b\" \"c\"", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 3: Add test for batch with mixed special chars**

```zig
test "text_replace_batch - mixed special chars" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_mixed.txt";
    const original_content = "http://example.com/path\\to\\file";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const ops = &.{
        TextReplaceOp{ .old_str = "http://example.com", .new_str = "https://localhost" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("https://localhost/path\\to\\file", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 4: Run tests to verify**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: All new tests pass

---

### Task 6: Control Characters and Binary Data Tests

**Files:**
- Modify: `src/modules/agent/tools/text_replace_batch_test.zig`

- [ ] **Step 1: Add test for newline characters**

```zig
test "text_replace_batch - newlines" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_newlines.txt";
    const original_content = "line1\nline2\nline3";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const ops = &.{
        TextReplaceOp{ .old_str = "\n", .new_str = "\r\n" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("line1\r\nline2\r\nline3", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 2: Add test for tab characters**

```zig
test "text_replace_batch - tabs" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_tabs.txt";
    const original_content = "col1\tcol2\tcol3";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const ops = &.{
        TextReplaceOp{ .old_str = "\t", .new_str = "    " }, // 4 spaces
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("col1    col2    col3", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 3: Add test for carriage return**

```zig
test "text_replace_batch - carriage return" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_cr.txt";
    const original_content = "Windows\r\nFile";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const ops = &.{
        TextReplaceOp{ .old_str = "\r\n", .new_str = "\n" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("Windows\nFile", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 4: Run tests to verify**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: All new tests pass

---

## Chunk 3: Error Case Edge Cases

### Task 7: Ambiguous and Error Edge Cases

**Files:**
- Modify: `src/modules/agent/tools/text_replace_test.zig`

- [ ] **Step 1: Add test for ambiguous backslash pattern**

```zig
test "text_replace - ambiguous backslash fails" {
    const allocator = std.testing.allocator;
    const test_path = "test_ambig_backslash.txt";
    const original_content = "a\\b a\\c";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // "\\" appears twice - should fail
    const result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "\\", .new_str = "/" },
    }, read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotUnique, result);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 2: Add test for ambiguous forward slash**

```zig
test "text_replace - ambiguous slash in path" {
    const allocator = std.testing.allocator;
    const test_path = "test_ambig_slash.txt";
    const original_content = "/a/b /a/c";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // "/" appears multiple times - should fail
    const result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "/", .new_str = "\\" },
    }, read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotUnique, result);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 3: Add test for empty string pattern**

```zig
test "text_replace - empty old_str fails" {
    const allocator = std.testing.allocator;
    const test_path = "test_empty_oldstr.txt";
    const original_content = "hello";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Empty string would match everywhere - should fail
    const result = text_replace_batch(allocator, test_path, &.{
        TextReplaceOp{ .old_str = "", .new_str = "x" },
    }, read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotUnique, result);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 4: Run tests to verify**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: All new tests pass

---

## Chunk 4: Batch Sequential Replacement Tests

### Task 8: Sequential Batch Replacement with Special Characters

**Files:**
- Modify: `src/modules/agent/tools/text_replace_batch_test.zig`

- [ ] **Step 1: Add test for sequential replacements affecting positions**

```zig
test "text_replace_batch - sequential special char replacements" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_sequential.txt";
    const original_content = "a\\b\\c";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Sequential replacements
    const ops = &.{
        TextReplaceOp{ .old_str = "a", .new_str = "X" },
        TextReplaceOp{ .old_str = "b", .new_str = "Y" },
        TextReplaceOp{ .old_str = "c", .new_str = "Z" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("X\\Y\\Z", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 2: Add test for replacing special chars that become special**

```zig
test "text_replace_batch - special chars becoming special" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_special_escape.txt";
    const original_content = "hello";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replace with something that contains backslash
    const ops = &.{
        TextReplaceOp{ .old_str = "hello", .new_str = "hel\\lo" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("hel\\lo", read_content);
    try std.fs.cwd().deleteFile(test_path);
}
```

- [ ] **Step 3: Run tests to verify**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: All new tests pass

---

## Summary

**Total Tasks:** 8
**Total Steps:** ~24

**Verification Commands:**
```bash
zig build test --summary all 2>&1 | head -n 200
```

**Expected Outcome:** All edge case tests pass, improving confidence in text_replace handling of difficult strings like `\\`, `/`, quotes, unicode, and control characters.
