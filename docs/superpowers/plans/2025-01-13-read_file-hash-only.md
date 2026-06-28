# read_file Tool: Add `hash_only` Parameter

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional `hash_only` parameter to `read_file` tool that returns only SHA256 hash without reading full file content.

**Architecture:** When `hash_only=true`, compute SHA256 hash from first bytes of file without loading entire content into memory. This is useful for fast file verification/caching without expensive full reads.

**Tech Stack:** Zig 0.15.2, standard library crypto (SHA256)

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src/modules/agent/tools/read_file.zig` | Core implementation: add `hash_only` option, optimize for hash-only reads |
| `src/modules/agent/tools/schemas.zig` | Add `hash_only` field to `ReadFileInput` struct |
| `src/ai_workflow/tui/handle_read_file_tool.zig` | Pass `hash_only` from tool call to `ReadFileOptions` |
| `src/modules/agent/tools/read_file_test.zig` | TDD tests for hash_only functionality |

---

## Chunk 1: Schema & Types

### Task 1: Add `hash_only` to schemas.zig

**Files:**
- Modify: `src/modules/agent/tools/schemas.zig:39-44`

- [ ] **Step 1: Add `hash_only` field to `ReadFileInput`**

```zig
pub const ReadFileInput = struct {
    path: []const u8,
    offset: ?usize = null,
    limit: ?usize = null,
    show_line_numbers: ?bool = null,
    hash_only: ?bool = null,  // NEW: Only return hash, skip content
};
```

- [ ] **Step 2: Run build to verify changes**

Run: `zig build 2>&1 | head -n 50`
Expected: No errors related to schema changes

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/tools/schemas.zig
git commit -m "feat(read_file): add hash_only field to ReadFileInput schema"
```

---

## Chunk 2: Core Implementation

### Task 2: Add `hash_only` to `ReadFileOptions` and implement hash-only optimization

**Files:**
- Modify: `src/modules/agent/tools/read_file.zig:23-26` (ReadFileOptions struct)
- Modify: `src/modules/agent/tools/read_file.zig:28-80` (read_file function)
- Modify: `src/modules/agent/tools/read_file.zig:116-122` (readFileTool schema)

- [ ] **Step 1: Write the failing test**

Create file: `src/modules/agent/tools/read_file_test.zig`

```zig
const std = @import("std");
const read_file = @import("read_file.zig");

test "hash_only returns only hash without content" {
    const allocator = std.testing.allocator;
    
    // Create a temp file with known content
    const test_content = "Hello, World!\n";
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const test_path = try tmp_dir.dir.realpath("test.txt");
    try tmp_dir.dir.writeFile("test.txt", test_content);
    
    // Test with hash_only = true
    const opts = read_file.ReadFileOptions{
        .hash_only = true,
    };
    
    const result = try read_file.read_file(allocator, test_path, opts);
    defer result.deinit(allocator);
    
    // Hash should be present
    try std.testing.expect(result.sha256.len > 0);
    
    // Content should be empty when hash_only
    try std.testing.expect(result.content.len == 0);
    
    // Line info should be zero
    try std.testing.expect(result.total_lines == 0);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -n 50`
Expected: FAIL - `hash_only` field does not exist in `ReadFileOptions`

- [ ] **Step 3: Add `hash_only` to `ReadFileOptions`**

```zig
pub const ReadFileOptions = struct {
    offset: ?usize = null,
    limit: ?usize = null,
    show_line_numbers: ?bool = null,
    hash_only: ?bool = null,  // NEW
};
```

- [ ] **Step 4: Run test again to verify new failure**

Run: `zig build test 2>&1 | head -n 50`
Expected: FAIL - hash_only path not implemented in `read_file` function

- [ ] **Step 5: Implement hash-only optimization in `read_file`**

Modify `read_file` function to add this logic after opening the file:

```zig
pub fn read_file(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: ReadFileOptions,
) !ReadFileResult {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // NEW: If hash_only is true, compute hash from file without loading full content
    if (opts.hash_only orelse false) {
        var hash: [32]u8 = undefined;
        
        // Read file in chunks to hash without full memory allocation
        var chunk_buf: [8192]u8 = undefined;
        var hasher = Sha256.init(.{});
        
        while (true) {
            const bytes_read = try file.read(&chunk_buf);
            if (bytes_read == 0) break;
            hasher.update(chunk_buf[0..bytes_read]);
        }
        
        hasher.final(&hash);
        const sha256_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(hash, .lower)});
        
        return ReadFileResult{
            .content = &.{},
            .sha256 = sha256_hex,
            .total_lines = 0,
            .start_line = 0,
            .end_line = 0,
        };
    }
    
    // ... existing code continues below ...
```

- [ ] **Step 6: Update `readFileTool` schema to include `hash_only`**

Add to `readFileTool` properties:

```zig
.{
    .name = "hash_only",
    .type = "boolean",
    .description = "If true, only return SHA256 hash without reading file content. Default: false.",
},
```

Also update the description:

```zig
.description =
\\Read a file by path. Returns content, sha256, total_lines, start_line, end_line.
\\
\\- Omit offset and limit to read the whole file.
\\- Use offset + limit to paginate large files (recommended page: 500 lines).
\\- Never guess offsets — check total_lines from a prior call first.
\\- Set show_line_numbers to true to prefix each line with its line number.
\\- Set hash_only to true to only compute hash without reading content.
\\- Returns SHA256 hash of file content - save this for text_replace to prevent blind edits.
,
```

- [ ] **Step 7: Run tests to verify all pass**

Run: `zig build test 2>&1 | head -n 100`
Expected: PASS - test should pass

- [ ] **Step 8: Commit**

```bash
git add src/modules/agent/tools/read_file.zig src/modules/agent/tools/read_file_test.zig
git commit -m "feat(read_file): implement hash_only option for fast hash computation"
```

---

## Chunk 3: TUI Handler Integration

### Task 3: Pass `hash_only` through TUI handler

**Files:**
- Modify: `src/ai_workflow/tui/handle_read_file_tool.zig:24-30`

- [ ] **Step 1: Add `hash_only` to handler options**

```zig
const read_opts = read_file_mod.ReadFileOptions{
    .offset = parsed.value.offset,
    .limit = parsed.value.limit,
    .show_line_numbers = parsed.value.show_line_numbers,
    .hash_only = parsed.value.hash_only,  // NEW
};
```

- [ ] **Step 2: Build and verify**

Run: `zig build 2>&1 | head -n 50`
Expected: No errors

- [ ] **Step 3: Run tests**

Run: `zig build test 2>&1 | head -n 50`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/handle_read_file_tool.zig
git commit -m "feat(read_file): wire hash_only parameter through TUI handler"
```

---

## Verification Checklist

After all tasks:

- [ ] `zig build` succeeds
- [ ] `zig build test` passes (including new test)
- [ ] New test `hash_only returns only hash without content` passes
- [ ] Tool schema includes `hash_only` parameter
- [ ] TUI handler passes `hash_only` correctly

---

## Summary

| Task | Files | Lines |
|------|-------|-------|
| Schema update | `schemas.zig` | +2 lines |
| Core implementation | `read_file.zig` | +25 lines |
| Test | `read_file_test.zig` | +35 lines |
| TUI integration | `handle_read_file_tool.zig` | +1 line |

**Total: ~65 lines changed, 1 new file, 1 new test**
