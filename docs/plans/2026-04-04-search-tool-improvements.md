# Search Tool Improvements — TDD Implementation Plan

**Date:** 2026-04-04
**Status:** Draft

**⚠️ Pre-existing Test Failure:** The test suite has a failing test (`modules.agent.tools.text_replace_edge_cases_test.test.edge_case - stale hash fails`) that causes `zig build test` to fail. This is unrelated to the search tool improvements. When running individual search tests, use the module path prefix:
```bash
zig build test -- modules.agent.tools.search_test
```

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve the search tool with bug fixes, new features, and performance optimizations using TDD approach.

**Architecture:** 
- Primary file: `src/modules/agent/tools/search.zig`
- Tests: `src/modules/agent/tools/search_test.zig`
- Handler: `src/ai_workflow/tui/handle_search_tool.zig`
- Registry: `src/ai_workflow/tui/tool_registry.zig`
- Tool parser: `src/apps/desktop-bun/src/mainview/utils/toolParser.ts`
- Renderer: `src/apps/desktop-bun/src/mainview/components/ToolCallRenderer.tsx`

**Tech Stack:** Zig 0.15.2, ripgrep (rg), TDD with Zig std.testing

---

## File Structure

| File | Purpose |
|------|---------|
| `src/modules/agent/tools/search.zig` | Core search logic, CLI execution, result parsing |
| `src/modules/agent/tools/search_test.zig` | All unit tests for search functionality |
| `src/ai_workflow/tui/handle_search_tool.zig` | Handler that parses tool_call → SearchInput |
| `src/ai_workflow/tui/tool_registry.zig` | Tool definitions (no changes needed) |
| `src/apps/desktop-bun/src/mainview/utils/toolParser.ts` | Parse search results for UI |
| `src/apps/desktop-bun/src/mainview/components/ToolCallRenderer.tsx` | Render search tool UI |

---

## Known Issues

1. **BUG (P0):** `@memcpy` in tail logic can corrupt memory when ranges overlap — need `@memmove`
2. **Missing features (P1):** `--type`, `--ignore-case`, `--hidden`
3. **Performance (P2):** JSON parsing is expensive, could use text output

---

## Chunks

### Chunk 1: Fix Critical Bug — Tail @memcpy → @memmove

**Files:**
- Modify: `src/modules/agent/tools/search.zig:190-200`
- Test: `src/modules/agent/tools/search_test.zig`

- [ ] **Step 1: Write failing test for tail bug**

```zig
test "search tail works correctly with overlapping memory" {
    const allocator = std.testing.allocator;
    
    // Create test directory and files
    const test_dir = "/tmp/search_tail_bug_test_xyz789";
    try std.fs.cwd().makePath(test_dir);
    defer _ = std.fs.cwd().deleteTree(test_dir) catch {};
    
    // Create files with content
    const test_file = try std.fs.cwd().createFile(test_dir ++ "/test.txt", .{});
    try test_file.writeAll("line1\nline2\nline3\nline4\nline5\n");
    test_file.close();
    
    // Search with tail=2 - should keep last 2 matches
    const input = search.SearchInput{
        .pattern = "line",
        .path = test_dir,
        .max_results = null,
        .tail = @as(?usize, 2),
        .max_output = 10000,
    };
    
    var result = try search.executeSearch(allocator, input);
    defer result.deinit(allocator);
    
    // Should have exactly 2 matches (last 2)
    try std.testing.expectEqual(@as(usize, 2), result.matches.items.len);
    // First match should be line3 (2 before last 2)
    // Last match should be line5
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `timeout 60 zig build test -- search_tail_bug_test 2>&1 | head -n 50`
Expected: FAIL (may crash or have wrong count)

- [ ] **Step 3: Fix the @memcpy bug**

In `search.zig` line ~195, change:
```zig
// OLD (BUG):
@memcpy(matches.items, kept);

// NEW (FIX):
@memmove(matches.items.ptr, kept.ptr, kept.len);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `timeout 60 zig build test -- search_tail_bug_test 2>&1 | head -n 50`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/search.zig src/modules/agent/tools/search_test.zig
git commit -m "fix(search): use @memmove instead of @memcpy for tail operation"
```

---

### Chunk 2: Add ignore_case Parameter

**Files:**
- Modify: `src/modules/agent/tools/search.zig` (SearchInput, executeSearch, search_tool)
- Modify: `src/modules/agent/tools/search_test.zig`

- [ ] **Step 1: Write failing test for ignore_case**

```zig
test "search ignore_case option works" {
    const allocator = std.testing.allocator;
    
    const test_path = "/tmp/search_ignore_case_test_xyz789.txt";
    try std.fs.cwd().makePath("/tmp");
    const test_file = try std.fs.cwd().createFile(test_path, .{});
    try test_file.writeAll("Hello WORLD hello world\n");
    test_file.close();
    defer _ = std.fs.cwd().deleteFile(test_path) catch {};
    
    // Search with ignore_case = true for "hello"
    const input = search.SearchInput{
        .pattern = "hello",
        .path = test_path,
        .ignore_case = true,
        .max_results = 10,
        .max_output = 10000,
    };
    
    var result = try search.executeSearch(allocator, input);
    defer result.deinit(allocator);
    
    // Should find both "Hello" and "hello"
    try std.testing.expect(result.matches.items.len >= 2);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `timeout 60 zig build test -- search_ignore_case 2>&1 | head -n 50`
Expected: FAIL with "unknown field 'ignore_case'"

- [ ] **Step 3: Add ignore_case to SearchInput struct**

Add to `SearchInput` struct in `search.zig`:
```zig
pub const SearchInput = struct {
    pattern: []const u8,
    path: []const u8,
    max_results: ?usize = null,
    head: ?usize = null,
    tail: ?usize = null,
    max_output: ?usize = 1024 * 1024,
    ignore_case: ?bool = null,  // NEW
};
```

- [ ] **Step 4: Update executeSearch to use ignore_case**

In `executeSearch`, add to argv:
```zig
if (input.ignore_case == true) {
    try args.append(allocator, "-i");
}
```

- [ ] **Step 5: Update search_tool definition**

Add to `search_tool.function.parameters.properties`:
```zig
.{
    .name = "ignore_case",
    .type = "boolean",
    .description = "Case insensitive search (-i flag). Default: false.",
},
```

- [ ] **Step 6: Run test to verify it passes**

Run: `timeout 60 zig build test -- search_ignore_case 2>&1 | head -n 50`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add src/modules/agent/tools/search.zig src/modules/agent/tools/search_test.zig
git commit -m "feat(search): add ignore_case parameter (-i flag)"
```

---

### Chunk 3: Add fixed_strings Parameter

**Files:**
- Modify: `src/modules/agent/tools/search.zig`
- Modify: `src/modules/agent/tools/search_test.zig`

- [ ] **Step 1: Write failing test for fixed_strings**

```zig
test "search fixed_strings option works" {
    const allocator = std.testing.allocator;
    
    const test_path = "/tmp/search_fixed_strings_test_xyz789.txt";
    const test_file = try std.fs.cwd().createFile(test_path, .{});
    try test_file.writeAll("hello.world\nhello*world\n");
    test_file.close();
    defer _ = std.fs.cwd().deleteFile(test_path) catch {};
    
    // Search with fixed_strings = true for "hello.world"
    const input = search.SearchInput{
        .pattern = "hello.world",
        .path = test_path,
        .fixed_strings = true,
        .max_results = 10,
        .max_output = 10000,
    };
    
    var result = try search.executeSearch(allocator, input);
    defer result.deinit(allocator);
    
    // Should only match literal "hello.world", not "hello*world"
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `timeout 60 zig build test -- search_fixed_strings 2>&1 | head -n 50`
Expected: FAIL with "unknown field 'fixed_strings'"

- [ ] **Step 3: Add fixed_strings to SearchInput struct**

```zig
fixed_strings: ?bool = null,  // NEW
```

- [ ] **Step 4: Update executeSearch to use fixed_strings**

```zig
if (input.fixed_strings == true) {
    try args.append(allocator, "-F");
}
```

- [ ] **Step 5: Update search_tool definition**

Add to parameters:
```zig
.{
    .name = "fixed_strings",
    .type = "boolean",
    .description = "Treat pattern as literal string, not regex (-F flag). Default: false.",
},
```

- [ ] **Step 6: Run test to verify it passes**

Run: `timeout 60 zig build test -- search_fixed_strings 2>&1 | head -n 50`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add src/modules/agent/tools/search.zig src/modules/agent/tools/search_test.zig
git commit -m "feat(search): add fixed_strings parameter (-F flag)"
```

---

### Chunk 4: Add type_filter Parameter

**Files:**
- Modify: `src/modules/agent/tools/search.zig`
- Modify: `src/modules/agent/tools/search_test.zig`

- [ ] **Step 1: Write failing test for type_filter**

```zig
test "search type_filter option works" {
    const allocator = std.testing.allocator;
    
    const test_dir = "/tmp/search_type_filter_test_xyz789";
    try std.fs.cwd().makePath(test_dir);
    defer _ = std.fs.cwd().deleteTree(test_dir) catch {};
    
    // Create .zig and .txt files
    const zig_file = try std.fs.cwd().createFile(test_dir ++ "/test.zig", .{});
    try zig_file.writeAll("const foo = 123;\n");
    zig_file.close();
    
    const txt_file = try std.fs.cwd().createFile(test_dir ++ "/test.txt", .{});
    try txt_file.writeAll("const foo = 123;\n");
    txt_file.close();
    
    // Search only in .zig files
    const input = search.SearchInput{
        .pattern = "foo",
        .path = test_dir,
        .type_filter = "zig",
        .max_results = 10,
        .max_output = 10000,
    };
    
    var result = try search.executeSearch(allocator, input);
    defer result.deinit(allocator);
    
    // Should only find match in .zig file
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches.items[0].file, ".zig"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `timeout 60 zig build test -- search_type_filter 2>&1 | head -n 50`
Expected: FAIL with "unknown field 'type_filter'"

- [ ] **Step 3: Add type_filter to SearchInput struct**

```zig
type_filter: ?[]const u8 = null,  // e.g., "zig", "js", "py", "txt"
```

- [ ] **Step 4: Update executeSearch to use type_filter**

```zig
if (input.type_filter) |type| {
    try args.append(allocator, "-t");
    try args.append(allocator, type);
}
```

- [ ] **Step 5: Update search_tool definition**

Add to parameters:
```zig
.{
    .name = "type_filter",
    .type = "string",
    .description = "Filter by file type: 'zig', 'js', 'ts', 'py', 'txt', etc. Default: all types.",
},
```

- [ ] **Step 6: Run test to verify it passes**

Run: `timeout 60 zig build test -- search_type_filter 2>&1 | head -n 50`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add src/modules/agent/tools/search.zig src/modules/agent/tools/search_test.zig
git commit -m "feat(search): add type_filter parameter (-t flag)"
```

---

### Chunk 5: Add context_before and context_after Parameters

**Files:**
- Modify: `src/modules/agent/tools/search.zig`
- Modify: `src/modules/agent/tools/search_test.zig`

- [ ] **Step 1: Write failing test for context lines**

```zig
test "search context options work" {
    const allocator = std.testing.allocator;
    
    const test_path = "/tmp/search_context_test_xyz789.txt";
    const test_file = try std.fs.cwd().createFile(test_path, .{});
    try test_file.writeAll("line0\nline1\nMATCH\nline3\nline4\n");
    test_file.close();
    defer _ = std.fs.cwd().deleteFile(test_path) catch {};
    
    // Search with context_after = 1 (show 1 line after match)
    const input = search.SearchInput{
        .pattern = "MATCH",
        .path = test_path,
        .context_after = 1,
        .max_results = 10,
        .max_output = 10000,
    };
    
    var result = try search.executeSearch(allocator, input);
    defer result.deinit(allocator);
    
    // Snippet should include line after MATCH
    try std.testing.expect(result.matches.items.len == 1);
    const snippet = result.matches.items[0].snippet;
    // Snippet should contain both MATCH and line3
    try std.testing.expect(std.mem.indexOf(u8, snippet, "MATCH") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `timeout 60 zig build test -- search_context 2>&1 | head -n 50`
Expected: FAIL with "unknown field 'context_after'"

- [ ] **Step 3: Add context fields to SearchInput**

```zig
context_before: ?usize = null,  // -B num
context_after: ?usize = null,    // -A num
```

- [ ] **Step 4: Update executeSearch to use context**

```zig
if (input.context_before) |n| {
    try args.append(allocator, "-B");
    try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{n}));
}
if (input.context_after) |n| {
    try args.append(allocator, "-A");
    try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{n}));
}
```

- [ ] **Step 5: Update search_tool definition**

Add to parameters:
```zig
.{
    .name = "context_before",
    .type = "number",
    .description = "Show N lines before each match (-B flag).",
},
.{
    .name = "context_after",
    .type = "number",
    .description = "Show N lines after each match (-A flag).",
},
```

- [ ] **Step 6: Run test to verify it passes**

Run: `timeout 60 zig build test -- search_context 2>&1 | head -n 50`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add src/modules/agent/tools/search.zig src/modules/agent/tools/search_test.zig
git commit -m "feat(search): add context_before and context_after parameters"
```

---

### Chunk 6: Performance — Use Text Output Instead of JSON

**Files:**
- Modify: `src/modules/agent/tools/search.zig`

> **Note:** This is a refactor that changes internal implementation but not the API. No new tests needed, but existing tests must still pass.

- [ ] **Step 1: Comment out JSON parsing test (verify it fails first)**

Run: `timeout 60 zig build test -- search 2>&1 | head -n 100`
Expected: See all existing search tests pass

- [ ] **Step 2: Implement text output parsing**

Change `executeSearch` to use simpler ripgrep format:
```zig
const argv = &[_][]const u8{
    "rg",
    "--line-number",
    "--with-filename",
    "--no-heading",
    input.pattern,
    input.path,
};
```

Parse output like:
```
file.zig:10:match content here
file.zig:20:another match
```

- [ ] **Step 3: Run all tests to verify nothing broke**

Run: `timeout 120 zig build test 2>&1 | head -n 100`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add src/modules/agent/tools/search.zig
git commit -m "perf(search): use text output instead of JSON for faster parsing"
```

---

### Chunk 7: Memory Optimization — Pre-allocate ArrayList

**Files:**
- Modify: `src/modules/agent/tools/search.zig`

- [ ] **Step 1: Add pre-allocation in executeSearch**

```zig
var matches = std.ArrayList(SearchMatch).empty;
// Pre-allocate based on max_results
try matches.ensureTotalCapacity(allocator, max_results);
```

- [ ] **Step 2: Verify tests still pass**

Run: `timeout 60 zig build test -- search 2>&1 | head -n 50`
Expected: All search tests pass

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/tools/search.zig
git commit -m "perf(search): pre-allocate matches ArrayList to reduce allocations"
```

---

## Summary

| Chunk | Task | Priority |
|-------|------|----------|
| 1 | Fix tail @memcpy bug | P0 |
| 2 | Add ignore_case | P1 |
| 3 | Add fixed_strings | P1 |
| 4 | Add type_filter | P1 |
| 5 | Add context lines | P2 |
| 6 | Use text output (perf) | P2 |
| 7 | Pre-allocate arrays | P2 |

**Total:** 7 chunks, ~21 steps

---

## Verification Commands

| Step | Run This |
|------|----------|
| Run search tests (specific) | `timeout 60 zig build test -- modules.agent.tools.search_test 2>&1 | head -n 100` |
| Run single test | `timeout 60 zig build test -- modules.agent.tools.search_test.test.<name> 2>&1 | head -n 50` |
| Build project | `timeout 60 zig build 2>&1 | head -n 50` |

**⚠️ Note:** `zig build test` (without specific target) fails due to pre-existing `text_replace_edge_cases_test` bug. Always use `-- modules.agent.tools.search_test` for search tests.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Tail bug fix causes regression | High | Run all tests after change |
| JSON → Text change breaks parsing | Medium | Keep JSON as fallback option |
| New parameters break existing code | Low | Add defaults, use `?` optional types |

---

**Plan complete.** Ready to execute with TDD approach.