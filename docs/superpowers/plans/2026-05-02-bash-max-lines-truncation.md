# Bash `max_lines` Truncation Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `max_lines` parameter to the bash tool that truncates stdout/stderr output by line count (default 1000), exposing how many lines were produced and whether the output was truncated by lines.

**Architecture:** The bash tool already has `max_output` (byte-level truncation) and `max_lines` in the JSON schema. We need to: (1) add `max_lines` to `BashInput` struct, (2) add `stdout_lines`/`stderr_lines` to `BashOutput`, (3) count lines during execution, (4) use `max_lines` to truncate output by line count, (5) update `bashResultToString` to include line counts, (6) add tests.

**Tech Stack:** Zig 0.15.2, std.mem, std.json

---

## File Map

| File | Change |
|------|--------|
| `src/modules/agent/tools/schemas.zig` | Add fields to `BashInput` and `BashOutput` |
| `src/modules/agent/tools/bash.zig` | Line counting + truncation in `executeBash`, update `bashResultToString` |
| `src/modules/agent/tools/bash_test.zig` | Add tests for `max_lines` behavior |

---

## Chunk 1: Schema — Add `max_lines` to BashInput and `stdout_lines`/`stderr_lines` to BashOutput

**Files:**
- Modify: `src/modules/agent/tools/schemas.zig:7-30`

### Task 1: Update `BashInput`

**Files:**
- Modify: `src/modules/agent/tools/schemas.zig:7-16`

- [ ] **Step 1: Read current file**

```bash
cat -n src/modules/agent/tools/schemas.zig | head -30
```

Expected: Lines 7-16 show `BashInput` struct with `command`, `timeout`, `cwd`, `max_output`, `stdin_data`, `background`.

- [ ] **Step 2: Edit `BashInput` to add `max_lines`**

Old (lines 7-16):
```zig
pub const BashInput = struct {
    command: []const u8,
    timeout: ?u32 = 30,
    cwd: ?[]const u8 = null,
    max_output: ?usize = 1024 * 1024, // default 1MB
    stdin_data: ?[]const u8 = null, // optional stdin input, null = close stdin
    background: bool = false, // run in background using nohup
};
```

New:
```zig
pub const BashInput = struct {
    command: []const u8,
    timeout: ?u32 = 30,
    cwd: ?[]const u8 = null,
    max_output: ?usize = 1024 * 1024, // default 1MB
    stdin_data: ?[]const u8 = null, // optional stdin input, null = close stdin
    background: bool = false, // run in background using nohup
    max_lines: ?usize = 1000, // default 1000 lines per output stream
};
```

- [ ] **Step 3: Edit `BashOutput` to add line counts**

Old (lines 22-30):
```zig
pub const BashOutput = struct {
    command: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    truncated: bool,
    timeout: bool,
};
```

New:
```zig
pub const BashOutput = struct {
    command: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    truncated: bool,
    timeout: bool,
    stdout_lines: usize = 0, // total lines produced (before truncation)
    stderr_lines: usize = 0, // total lines produced (before truncation)
};
```

- [ ] **Step 4: Verify compilation**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 60 zig build 2>&1 | head -30
```

Expected: No errors (schema change only).

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/schemas.zig
git commit -m "feat(bash): add max_lines to BashInput, stdout_lines/stderr_lines to BashOutput"
```

---

## Chunk 2: Execution — Line Counting and Truncation in `executeBash`

**Files:**
- Modify: `src/modules/agent/tools/bash.zig:56-285`

### Task 2: Add line counting and `max_lines` truncation

**Files:**
- Modify: `src/modules/agent/tools/bash.zig:56-285`
- Reference: `src/modules/agent/tools/bash.zig:124` (existing `max_output` usage as pattern)

- [ ] **Step 1: Read the execution function signature and max_output usage**

```bash
sed -n '56,130p' src/modules/agent/tools/bash.zig
```

Expected: Line 124 has `const max_output = input.max_output orelse 1024 * 1024;`.

- [ ] **Step 2: Add `max_lines` variable after `max_output` (around line 125)**

Old (line ~124-125):
```zig
    const max_output = input.max_output orelse 1024 * 1024;
    const timeout_sec = input.timeout orelse 30;
```

New:
```zig
    const max_output = input.max_output orelse 1024 * 1024;
    const max_lines = input.max_lines orelse 1000;
    const timeout_sec = input.timeout orelse 30;
```

- [ ] **Step 3: Add line-counting arrays after the ArrayList declarations (around line 155)**

Read around line 150-165:
```bash
sed -n '150,170p' src/modules/agent/tools/bash.zig
```

Old (around lines 154-157):
```zig
    const ArrayList = std.ArrayList;
    var stdout_data: ArrayList(u8) = .empty;
    var stderr_data: ArrayList(u8) = .empty;
    defer {
        stdout_data.deinit(allocator);
        stderr_data.deinit(allocator);
    }
```

New:
```zig
    const ArrayList = std.ArrayList;
    var stdout_data: ArrayList(u8) = .empty;
    var stderr_data: ArrayList(u8) = .empty;
    var stdout_line_count: usize = 0;
    var stderr_line_count: usize = 0;
    defer {
        stdout_data.deinit(allocator);
        stderr_data.deinit(allocator);
    }
```

- [ ] **Step 4: Add line counting during stdout read (around line 216-219)**

Read around the stdout read section:
```bash
sed -n '210,230p' src/modules/agent/tools/bash.zig
```

Old:
```zig
                const bytes_read = child.stdout.?.read(&buf) catch 0;
                if (bytes_read > 0) {
                    any_read = true;
                    try stdout_data.appendSlice(allocator, buf[0..bytes_read]);
                    if (stdout_data.items.len >= max_output) break;
                }
```

New:
```zig
                const bytes_read = child.stdout.?.read(&buf) catch 0;
                if (bytes_read > 0) {
                    any_read = true;
                    try stdout_data.appendSlice(allocator, buf[0..bytes_read]);
                    // Count newlines in the just-read chunk
                    for (buf[0..bytes_read]) |byte| {
                        if (byte == '\n') stdout_line_count += 1;
                    }
                    if (stdout_data.items.len >= max_output or stdout_line_count >= max_lines) break;
                }
```

- [ ] **Step 5: Add line counting during stderr read (around line 228-232)**

Read around the stderr read section:
```bash
sed -n '225,245p' src/modules/agent/tools/bash.zig
```

Old:
```zig
                const bytes_read = child.stderr.?.read(&buf) catch 0;
                if (bytes_read > 0) {
                    any_read = true;
                    try stderr_data.appendSlice(allocator, buf[0..bytes_read]);
                    if (stderr_data.items.len >= max_output) break;
                }
```

New:
```zig
                const bytes_read = child.stderr.?.read(&buf) catch 0;
                if (bytes_read > 0) {
                    any_read = true;
                    try stderr_data.appendSlice(allocator, buf[0..bytes_read]);
                    // Count newlines in the just-read chunk
                    for (buf[0..bytes_read]) |byte| {
                        if (byte == '\n') stderr_line_count += 1;
                    }
                    if (stderr_data.items.len >= max_output or stderr_line_count >= max_lines) break;
                }
```

- [ ] **Step 6: Add post-execution truncation by lines (before the `BashOutput` return)**

Read around lines 256-290:
```bash
sed -n '256,295p' src/modules/agent/tools/bash.zig
```

**After** the `was_truncated` line (line ~258) and **before** the `command_copy` allocation, insert:

```zig
    // Truncate output by line count if max_lines was exceeded
    // Find the Nth newline in stdout
    var stdout_lines_to_keep = stdout_data.items.len;
    var stdout_truncation_needed = stdout_line_count > max_lines;
    if (stdout_truncation_needed) {
        var count: usize = 0;
        for (stdout_data.items, 0..) |byte, i| {
            if (byte == '\n') {
                count += 1;
                if (count == max_lines) {
                    stdout_lines_to_keep = i + 1;
                    break;
                }
            }
        }
    }

    // Find the Nth newline in stderr
    var stderr_lines_to_keep = stderr_data.items.len;
    var stderr_truncation_needed = stderr_line_count > max_lines;
    if (stderr_truncation_needed) {
        var count: usize = 0;
        for (stderr_data.items, 0..) |byte, i| {
            if (byte == '\n') {
                count += 1;
                if (count == max_lines) {
                    stderr_lines_to_keep = i + 1;
                    break;
                }
            }
        }
    }

    // Update truncated flag
    const was_truncated = stdout_truncation_needed or stderr_truncation_needed or (stdout_data.items.len >= max_output or stderr_data.items.len >= max_output);
```

Then **replace** the `stdout_copy` and `stderr_copy` lines to use the truncated slices:

Old:
```zig
    const stdout_copy = if (stdout_data.items.len == 0)
        try allocator.dupe(u8, "No output produced.")
    else
        try allocator.dupe(u8, stdout_data.items);
    errdefer allocator.free(stdout_copy);

    const stderr_copy = if (stderr_data.items.len == 0)
        try allocator.dupe(u8, "No errors.")
    else
        try allocator.dupe(u8, stderr_data.items);
    errdefer allocator.free(stderr_copy);
```

New:
```zig
    const stdout_copy = if (stdout_data.items.len == 0)
        try allocator.dupe(u8, "No output produced.")
    else if (stdout_truncation_needed)
        try allocator.dupe(u8, stdout_data.items[0..stdout_lines_to_keep])
    else
        try allocator.dupe(u8, stdout_data.items);
    errdefer allocator.free(stdout_copy);

    const stderr_copy = if (stderr_data.items.len == 0)
        try allocator.dupe(u8, "No errors.")
    else if (stderr_truncation_needed)
        try allocator.dupe(u8, stderr_data.items[0..stderr_lines_to_keep])
    else
        try allocator.dupe(u8, stderr_data.items);
    errdefer allocator.free(stderr_copy);
```

- [ ] **Step 7: Update the `BashOutput` return to include line counts**

Read around the return statement:
```bash
sed -n '310,330p' src/modules/agent/tools/bash.zig
```

Old:
```zig
    return BashOutput{
        .command = command_copy,
        .stdout = stdout_copy,
        .stderr = stderr_copy,
        .exit_code = exit_code,
        .truncated = was_truncated,
        .timeout = timeout_hit,
    };
```

New:
```zig
    return BashOutput{
        .command = command_copy,
        .stdout = stdout_copy,
        .stderr = stderr_copy,
        .exit_code = exit_code,
        .truncated = was_truncated,
        .timeout = timeout_hit,
        .stdout_lines = stdout_line_count,
        .stderr_lines = stderr_line_count,
    };
```

- [ ] **Step 8: Verify compilation**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 60 zig build 2>&1 | head -40
```

Expected: No errors. If there are compile errors, fix them before proceeding.

- [ ] **Step 9: Commit**

```bash
git add src/modules/agent/tools/bash.zig
git commit -m "feat(bash): add line-counting and max_lines truncation"
```

---

## Chunk 3: Update `bashResultToString` to Include Line Counts

**Files:**
- Modify: `src/modules/agent/tools/bash.zig:293-307`

### Task 3: Add line counts to XML output

- [ ] **Step 1: Read current function**

```bash
sed -n '293,310p' src/modules/agent/tools/bash.zig
```

- [ ] **Step 2: Update `bashResultToString`**

Old:
```zig
pub fn bashResultToString(allocator: std.mem.Allocator, result: BashOutput) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<stdout>{s}</stdout>
        \\<stderr>{s}</stderr>
        \\<exit_code>{d}</exit_code>
        \\<truncated>{}</truncated>
        \\<timeout>{}</timeout>
    , .{
        result.stdout,
        result.stderr,
        result.exit_code,
        result.truncated,
        result.timeout,
    });
}
```

New:
```zig
pub fn bashResultToString(allocator: std.mem.Allocator, result: BashOutput) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<stdout>{s}</stdout>
        \\<stderr>{s}</stderr>
        \\<exit_code>{d}</exit_code>
        \\<truncated>{}</truncated>
        \\<timeout>{}</timeout>
        \\<stdout_lines>{d}</stdout_lines>
        \\<stderr_lines>{d}</stderr_lines>
    , .{
        result.stdout,
        result.stderr,
        result.exit_code,
        result.truncated,
        result.timeout,
        result.stdout_lines,
        result.stderr_lines,
    });
}
```

- [ ] **Step 3: Verify compilation**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 60 zig build 2>&1 | head -20
```

Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add src/modules/agent/tools/bash.zig
git commit -m "feat(bash): include stdout_lines/stderr_lines in bashResultToString"
```

---

## Chunk 4: Update JSON Schema — `max_lines` Description

**Files:**
- Modify: `src/modules/agent/tools/bash.zig:373-378`

### Task 4: Improve `max_lines` description in tool schema

- [ ] **Step 1: Read current max_lines parameter**

```bash
sed -n '370,385p' src/modules/agent/tools/bash.zig
```

- [ ] **Step 2: Update description**

Old:
```zig
                .{
                    .name = "max_lines",
                    .type = "number",
                    .description = "default 1000",
                },
```

New:
```zig
                .{
                    .name = "max_lines",
                    .type = "number",
                    .description = "Maximum number of lines to capture from stdout/stderr. Default: 1000. Output exceeding this limit is truncated and stdout_lines/stderr_lines will report the true total.",
                },
```

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/tools/bash.zig
git commit -m "docs(bash): improve max_lines parameter description"
```

---

## Chunk 5: Tests — `max_lines` Behavior

**Files:**
- Modify: `src/modules/agent/tools/bash_test.zig`

### Task 5: Add `max_lines` truncation tests

- [ ] **Step 1: Read end of test file**

```bash
tail -20 src/modules/agent/tools/bash_test.zig
```

Expected: Last test is `bash_background_long_running`.

- [ ] **Step 2: Add tests for `max_lines`**

Append to `bash_test.zig`:

```zig
test "bash max_lines stdout truncation" {
    const allocator = std.testing.allocator;
    // Generate 20 lines but cap at 5
    const input = BashInput{
        .command = "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do echo \"line $i\"; done",
        .timeout = 5,
        .cwd = null,
        .max_output = null,
        .max_lines = 5,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer {
        allocator.free(r.stderr);
        allocator.free(r.command);
    }

    // Should have 20 lines produced but only 5 returned
    try std.testing.expectEqual(@as(usize, 20), r.stdout_lines);
    try std.testing.expect(r.truncated);
    // The returned output should have exactly 5 lines
    const line_count = std.mem.count(u8, r.stdout, "\n");
    try std.testing.expectEqual(@as(usize, 5), line_count);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "line 5") != null);
}

test "bash max_lines default is 1000" {
    const allocator = std.testing.allocator;
    // Generate 50 lines with default max_lines (1000)
    const input = BashInput{
        .command = "for i in $(seq 1 50); do echo \"line $i\"; done",
        .timeout = 5,
        .cwd = null,
        .max_output = null,
        // max_lines not set - should default to 1000
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer {
        allocator.free(r.stderr);
        allocator.free(r.command);
    }

    // All 50 lines should be returned, not truncated
    try std.testing.expectEqual(@as(usize, 50), r.stdout_lines);
    try std.testing.expect(!r.truncated);
    // Verify all lines present
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "line 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "line 50") != null);
}

test "bash max_lines stderr truncation" {
    const allocator = std.testing.allocator;
    // Generate 20 stderr lines but cap at 3
    const input = BashInput{
        .command = "for i in 1 2 3 4 5 6 7 8 9 10; do echo \"error $i\" >&2; done",
        .timeout = 5,
        .cwd = null,
        .max_output = null,
        .max_lines = 3,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer {
        allocator.free(r.stderr);
        allocator.free(r.command);
    }

    // Should have 10 stderr lines produced but only 3 returned
    try std.testing.expectEqual(@as(usize, 10), r.stderr_lines);
    try std.testing.expect(r.truncated);
    // The returned stderr should have exactly 3 lines
    const line_count = std.mem.count(u8, r.stderr, "\n");
    try std.testing.expectEqual(@as(usize, 3), line_count);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "error 3") != null);
}
```

- [ ] **Step 3: Run the new tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test 2>&1 | grep -A5 "max_lines\|FAIL\|PASS\|test"
```

Expected: All `max_lines` tests pass. No failures.

- [ ] **Step 4: Commit**

```bash
git add src/modules/agent/tools/bash_test.zig
git commit -m "test(bash): add max_lines truncation tests"
```

---

## Summary

After all chunks:

| Chunk | Change | Files |
|-------|--------|-------|
| 1 | `BashInput.max_lines` + `BashOutput.stdout_lines/stderr_lines` | `schemas.zig` |
| 2 | Line counting during read, truncation by line count after execution | `bash.zig` |
| 3 | `bashResultToString` includes `<stdout_lines>` + `<stderr_lines>` | `bash.zig` |
| 4 | Improved `max_lines` JSON schema description | `bash.zig` |
| 5 | 3 new tests covering truncation, default, stderr | `bash_test.zig` |

**Total commits:** 5

**Final verification:** `zig build test` passes with all new tests green.
