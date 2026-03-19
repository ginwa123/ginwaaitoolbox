# TUI read_file Display - Show Filename Only

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the TUI `read_file` tool display from `[read_file] lines X-Y/Total` to `[read_file] filename`

**Architecture:** Modify the `displayReadFileResult` function in `tool_results.zig` to parse and display the filename from the result XML instead of line counts. The file path is already available in the `<path>` tag within the result XML.

**Tech Stack:** Zig 0.15.2, TUI application

---

## Context

### Current Display Format
```
[read_file] lines 1-20/614
```

### Desired Display Format
```
[read_file] src/apps/tui/display/tool_results.zig
```

### Relevant Files

| File | Role |
|------|------|
| `src/apps/tui/display/tool_results.zig` | Contains `displayReadFileResult` function |
| `src/apps/tui/display/utils.zig` | `extractTag()` utility for parsing XML |
| `src/apps/tui/globals.zig` | Color constants (`cyan`, `reset`, etc.) |
| `src/apps/tui/tui_text.zig` | `print()` function for terminal output |

### XML Result Format (what's passed in)

The `result_xml` parameter contains:
```xml
<result>
  <path>/full/path/to/file.zig</path>
  <content>file contents...</content>
  <start_line>1</start_line>
  <end_line>20</end_line>
  <total_lines>614</total_lines>
</result>
```

---

## Chunk 1: Modify displayReadFileResult

**Files:**
- Modify: `src/apps/tui/display/tool_results.zig:118-136`

### Task 1: Update displayReadFileResult to Show Filename

- [ ] **Step 1: Read the current implementation**

Read `src/apps/tui/display/tool_results.zig` lines 118-136 to see current `displayReadFileResult` function.

- [ ] **Step 2: Modify the function signature and body**

Replace the entire `displayReadFileResult` function with:

```zig
pub fn displayReadFileResult(result_xml: []const u8, tool_name: []const u8) void {
    const path = utils.extractTag(result_xml, "path") orelse "unknown";
    if (std.mem.eql(u8, path, "")) return;
    
    tui_text.print("\r\x1b[2K\n{s}[{s}]{s} {s}\n", .{ 
        globals.cyan, 
        tool_name, 
        globals.reset, 
        path 
    });
}
```

- [ ] **Step 3: Build to verify**

Run: `zig build 2>&1`
Expected: No errors (empty output = success in Zig)

- [ ] **Step 4: Test with the TUI**

Run: `zig build run:tui`
Expected: When a read_file tool is called, display shows `[read_file] /path/to/file.zig` instead of `[read_file] lines 1-20/614`

---

## Chunk 2: Verify and Finalize

- [ ] **Step 5: Verify no other references to line count format**

Search for any other code that expects the old "lines X-Y/Total" format:

```bash
rg "lines.*-.*\/" src/apps/tui/ --type zig
```

Expected: No matches (or matches unrelated to read_file display)

- [ ] **Step 6: Build full project**

Run: `zig build 2>&1`
Expected: Success

- [ ] **Step 7: Commit changes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/tui-read-file-display
git add -A
git commit -m "feat(tui): show filename in read_file tool display

Change display from '[read_file] lines X-Y/Total' to '[read_file] filename'
to match user preference for cleaner output."
```

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-03-19-tui-read-file-display.md`**

**Worktree ready at:** `/home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/tui-read-file-display`

**Build status:** ✅ Passing (0 errors)

Ready to implement? Use `subagent-driven-development` skill to dispatch sub-agents for implementation.
