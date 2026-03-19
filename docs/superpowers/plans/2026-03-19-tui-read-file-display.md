# TUI Display Improvements - read_file Filename + LLM Text Response

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two TUI display improvements:
1. Change `read_file` display from `[read_file] lines X-Y/Total` to `[read_file] filename`
2. Ensure LLM text responses (non-tool calls) are printed in TUI

**Architecture:** 
- Task 1: Modify `displayReadFileResult` in `tool_results.zig` to show filename instead of line counts
- Task 2: Modify end-of-stream logic in `streaming.zig` to call `printFormattedResponse()` for text responses

**Tech Stack:** Zig 0.15.2, TUI application

---

## Context

### Issue 1: read_file Tool Display

**Current format:**
```
[read_file] lines 1-20/614
```

**Desired format:**
```
[read_file] src/apps/tui/display/tool_results.zig
```

### Issue 2: LLM Text Response Display

**Problem:** The `printFormattedResponse()` function exists but is never called. End-of-stream logic discards text content with `_ = content;` instead of printing it.

**Current code (streaming.zig lines 226-238):**
```zig
if (utils.extractTag(final_xml, "content")) |content| {
    _ = content;  // ❌ Discarded - not printed
} else if (final_xml.len > 0) {
    if (utils.extractTag(final_xml, "message")) |msg| {
        _ = msg;  // ❌ Discarded - not printed
    } else {
        tui_text.print("{s}\n", .{final_xml});  // Falls through to raw XML
    }
}
```

**Dead code function (streaming.zig lines 381-393):**
```zig
fn printFormattedResponse(content: []const u8) void {
    const agent_name = utils.extractTag(content, "agent") orelse "assistant";
    tui_text.print("{s}━━ {s} ━━{s}\n", .{ globals.cyan, agent_name, globals.reset });
    if (utils.extractTag(content, "markdown")) |md| {
        const trimmed = utils.trim(md);
        if (trimmed.len > 0) {
            tui_text.print("\n{s}{s}{s}\n", .{ globals.bold, trimmed, globals.reset });
        }
    }
}
```

---

## Relevant Files

| File | Role |
|------|------|
| `src/apps/tui/display/tool_results.zig` | Contains `displayReadFileResult` function (Task 1) |
| `src/apps/tui/network/streaming.zig` | Contains streaming loop and `printFormattedResponse` (Task 2) |
| `src/apps/tui/display/utils.zig` | `extractTag()` utility for XML parsing |
| `src/apps/tui/globals.zig` | Color constants (`cyan`, `reset`, `bold`, etc.) |

---

## Chunk 1: Fix read_file Display (Show Filename Only)

**Files:**
- Modify: `src/apps/tui/display/tool_results.zig:118-136`

### Task 1: Update displayReadFileResult to Show Filename

- [ ] **Step 1: Read the current implementation**

```bash
cat -n src/apps/tui/display/tool_results.zig | sed -n '115,140p'
```

- [ ] **Step 2: Modify displayReadFileResult function**

Replace the `displayReadFileResult` function with:

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

```bash
zig build 2>&1
```
Expected: No errors (empty output = success in Zig)

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(tui): show filename in read_file tool display"
```

---

## Chunk 2: Fix LLM Text Response Display

**Files:**
- Modify: `src/apps/tui/network/streaming.zig:220-245` (end-of-stream logic)

### Task 2: Call printFormattedResponse for Text Responses

- [ ] **Step 1: Read the current end-of-stream logic**

```bash
cat -n src/apps/tui/network/streaming.zig | sed -n '220,250p'
```

- [ ] **Step 2: Modify the end-of-stream response handling**

Find and replace the section that discards content. The current code:

```zig
if (utils.extractTag(final_xml, "content")) |content| {
    _ = content;  // Skip duplicate printing - content was already streamed
} else if (final_xml.len > 0) {
    if (utils.extractTag(final_xml, "message")) |msg| {
        _ = msg;  // Skip duplicate printing - content was already streamed
    } else {
        tui_text.print("{s}\n", .{final_xml});
    }
}
```

Replace with:

```zig
if (utils.extractTag(final_xml, "content")) |content| {
    // Print final formatted response
    printFormattedResponse(content);
} else if (final_xml.len > 0) {
    if (utils.extractTag(final_xml, "message")) |msg| {
        // Print final formatted response
        printFormattedResponse(msg);
    } else {
        // No structured content - print raw XML as fallback
        tui_text.print("{s}\n", .{final_xml});
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
zig build 2>&1
```
Expected: No errors (empty output = success in Zig)

- [ ] **Step 4: Test with the TUI**

```bash
zig build run:tui
```
Expected: When LLM sends a text response (no tool call), it displays as:
```
━━ assistant ━━

**formatted markdown content**
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(tui): display LLM text responses in TUI

Call printFormattedResponse() at end of streaming to show
non-tool LLM responses with proper formatting."
```

---

## Chunk 3: Final Verification

- [ ] **Step 6: Build full project**

```bash
zig build 2>&1
```
Expected: Success

- [ ] **Step 7: Final commit**

```bash
git add -A
git commit -m "feat(tui): improve TUI display for read_file and LLM responses"
```

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-03-19-tui-read-file-display.md`**

**Worktree ready at:** `/home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/tui-read-file-display`

**Build status:** ✅ Passing (0 errors)

Ready to implement? Use `subagent-driven-development` skill to dispatch sub-agents for implementation.
