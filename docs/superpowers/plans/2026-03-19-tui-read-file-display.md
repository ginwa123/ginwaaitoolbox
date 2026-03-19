# TUI Display Improvements - read_file Filename + LLM Text Response

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two TUI display improvements:
1. Change `read_file` display from `[read_file] lines X-Y/Total` to `[read_file] filename`
2. Ensure LLM text responses are always displayed with formatted header

**Architecture:** 
- Task 1: Modify `displayReadFileResult` in `tool_results.zig` to show filename instead of line counts
- Task 2: Track if content was streamed; at end-of-stream, print full response if none was streamed, or just header if it was

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

**Problem:** 
- Streaming prints chunk content (line 163: `tuiText.print("{s}", .{content})`)
- BUT: what if there are NO chunks? Then content is LOST (discarded with `_ = content;`)
- Need to print full response IF no content was streamed, or just header IF content was streamed

**Current code (streaming.zig lines 226-238):**
```zig
if (utils.extractTag(final_xml, "content")) |content| {
    _ = content;  // ❌ Lost if no chunks came
} else if (final_xml.len > 0) {
    if (utils.extractTag(final_xml, "message")) |msg| {
        _ = msg;  // ❌ Lost if no chunks came
    } else {
        tuiText.print("{s}\n", .{final_xml});
    }
}
```

**Streaming loop (line 163):**
```zig
tuiText.print("{s}", .{content});  // Raw content printed
```

**Correct approach:**
- Track if `streaming_started == true` during streaming
- If content was streamed (`streaming_started == true`) → add header only
- If NO content was streamed (`streaming_started == false`) → print FULL response (header + content)

---

## Relevant Files

| File | Role |
|------|------|
| `src/apps/tui/display/tool_results.zig` | Contains `displayReadFileResult` function (Task 1) |
| `src/apps/tui/network/streaming.zig` | Contains streaming loop, `streaming_started` flag, and printFormattedResponse (Task 2) |
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

## Chunk 2: Fix LLM Text Response Display (Smart Header/Content Logic)

**Files:**
- Modify: `src/apps/tui/network/streaming.zig`

### Logic

| `streaming_started` | Action at End-of-Stream |
|--------------------|-------------------------|
| `true` (content was streamed) | Print header only |
| `false` (no content streamed) | Print FULL response (header + content) |

### Task 2: Modify printFormattedResponse and End-of-Stream Logic

- [ ] **Step 1: Read the current printFormattedResponse function**

```bash
cat -n src/apps/tui/network/streaming.zig | sed -n '381,393p'
```

- [ ] **Step 2: Modify printFormattedResponse to print BOTH header AND content**

Replace:
```zig
/// Print formatted response from the AI
fn printFormattedResponse(content: []const u8) void {
    const agent_name = utils.extractTag(content, "agent") orelse "assistant";
    tuiText.print("{s}━━ {s} ━━{s}\n", .{ globals.cyan, agent_name, globals.reset });
    if (utils.extractTag(content, "markdown")) |md| {
        const trimmed = utils.trim(md);
        if (trimmed.len > 0) {
            tuiText.print("\n{s}{s}{s}\n", .{ globals.bold, trimmed, globals.reset });
        } else {
            tuiText.print("\n{s}{s}{s}\n", .{ globals.bold, content, globals.reset });
        }
    } else {
        tuiText.print("\n{s}{s}{s}\n", .{ globals.bold, content, globals.reset });
    }
}
```

With (keep the same - it already prints header + content):
```zig
/// Print formatted response from the AI (header + content)
fn printFormattedResponse(content: []const u8) void {
    const agent_name = utils.extractTag(content, "agent") orelse "assistant";
    tuiText.print("{s}━━ {s} ━━{s}\n", .{ globals.cyan, agent_name, globals.reset });
    if (utils.extractTag(content, "markdown")) |md| {
        const trimmed = utils.trim(md);
        if (trimmed.len > 0) {
            tuiText.print("\n{s}{s}{s}\n", .{ globals.bold, trimmed, globals.reset });
        } else {
            tuiText.print("\n{s}{s}{s}\n", .{ globals.bold, content, globals.reset });
        }
    } else {
        tuiText.print("\n{s}{s}{s}\n", .{ globals.bold, content, globals.reset });
    }
}
```

- [ ] **Step 3: Modify end-of-stream logic to check streaming_started**

Find the section (around lines 226-238):

Current code:
```zig
if (utils.extractTag(final_xml, "content")) |content| {
    // Skip duplicate printing - content was already streamed
    _ = content;
} else if (final_xml.len > 0) {
    if (utils.extractTag(final_xml, "message")) |msg| {
        // Skip duplicate printing - content was already streamed
        _ = msg;
    } else {
        tuiText.print("{s}\n", .{final_xml});
    }
}
```

Replace with:
```zig
if (utils.extractTag(final_xml, "content")) |content| {
    // If no content was streamed, print full response
    // If content was streamed, just add header
    if (!streaming_started) {
        printFormattedResponse(content);
    } else {
        // Content already streamed - just add formatted header
        const agent_name = utils.extractTag(content, "agent") orelse "assistant";
        tuiText.print("\n{s}━━ {s} ━━{s}\n", .{ globals.cyan, agent_name, globals.reset });
    }
} else if (final_xml.len > 0) {
    if (utils.extractTag(final_xml, "message")) |msg| {
        // If no content was streamed, print full response
        // If content was streamed, just add header
        if (!streaming_started) {
            printFormattedResponse(msg);
        } else {
            const agent_name = utils.extractTag(msg, "agent") orelse "assistant";
            tuiText.print("\n{s}━━ {s} ━━{s}\n", .{ globals.cyan, agent_name, globals.reset });
        }
    } else {
        tuiText.print("{s}\n", .{final_xml});
    }
}
```

- [ ] **Step 4: Build to verify**

```bash
zig build 2>&1
```
Expected: No errors (empty output = success in Zig)

- [ ] **Step 5: Test with the TUI**

```bash
zig build run:tui
```

Expected behavior:
- **If chunks came**: Content appears as it streams, then `━━ assistant ━━` header appears at end
- **If NO chunks**: Full formatted response appears with header: `━━ assistant ━━` + content

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(tui): display LLM text responses with smart header logic

Print full response if no streaming chunks came,
or just add header if content was already streamed."
```

---

## Chunk 3: Final Verification

- [ ] **Step 7: Build full project**

```bash
zig build 2>&1
```
Expected: Success

- [ ] **Step 8: Final commit**

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
