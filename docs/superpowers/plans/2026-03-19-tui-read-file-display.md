# TUI Display Improvements - read_file Filename + LLM Text Response

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two TUI display improvements:
1. Change `read_file` display from `[read_file] lines X-Y/Total` to `[read_file] filename`
2. Add formatted header for LLM text responses in TUI (NO double print)

**Architecture:** 
- Task 1: Modify `displayReadFileResult` in `tool_results.zig` to show filename instead of line counts
- Task 2: Modify end-of-stream logic in `streaming.zig` to add header only (content already streamed)

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

### Issue 2: LLM Text Response Header (No Double Print)

**Problem:** 
- Streaming already prints chunk content raw (line 163: `tuiText.print("{s}", .{content})`)
- End-of-stream logic discards content with `_ = content;`
- User wants to see formatted header but NO double print

**Current code (streaming.zig lines 226-238):**
```zig
if (utils.extractTag(final_xml, "content")) |content| {
    _ = content;  // ❌ Discarded - no header either
} else if (final_xml.len > 0) {
    if (utils.extractTag(final_xml, "message")) |msg| {
        _ = msg;  // ❌ Discarded - no header either
    } else {
        tuiText.print("{s}\n", .{final_xml});
    }
}
```

**Dead code function (streaming.zig lines 381-393):**
```zig
fn printFormattedResponse(content: []const u8) void {
    const agent_name = utils.extractTag(content, "agent") orelse "assistant";
    tuiText.print("{s}━━ {s} ━━{s}\n", .{ globals.cyan, agent_name, globals.reset });
    // ... prints content again - would cause double print!
}
```

**Correct approach:**
- During streaming: content printed raw ✅ (line 163)
- At end-of-stream: ONLY add `━━ agent ━━` header (NO content re-print)

**Expected output:**
```
Hello, how can I help you?
━━ assistant ━━
```

---

## Relevant Files

| File | Role |
|------|------|
| `src/apps/tui/display/tool_results.zig` | Contains `displayReadFileResult` function (Task 1) |
| `src/apps/tui/network/streaming.zig` | Contains streaming loop and header function (Task 2) |
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

## Chunk 2: Fix LLM Text Response Header (Header Only - No Double Print)

**Files:**
- Modify: `src/apps/tui/network/streaming.zig`

### IMPORTANT: Double-Print Prevention

| Phase | What Gets Printed |
|-------|-------------------|
| **Streaming** (line 163) | Raw content: `tuiText.print("{s}", .{content})` ✅ |
| **End-of-stream** | MUST NOT re-print content ❌ |

**Correct behavior:**
- Streaming phase: content printed raw ✅
- End-of-stream: `━━ assistant ━━` header added (no content) ✅

### Task 2: Add Header-Only PrintFormattedResponse

- [ ] **Step 1: Read the current printFormattedResponse function**

```bash
cat -n src/apps/tui/network/streaming.zig | sed -n '381,393p'
```

- [ ] **Step 2: Rename and simplify printFormattedResponse to printFormattedResponseHeader**

The current function prints BOTH header AND content. We need to change it to ONLY print header:

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

With:
```zig
/// Print formatted response header (content already streamed via chunks)
fn printFormattedResponseHeader(content: []const u8) void {
    const agent_name = utils.extractTag(content, "agent") orelse "assistant";
    tuiText.print("\n{s}━━ {s} ━━{s}\n", .{ globals.cyan, agent_name, globals.reset });
}
```

- [ ] **Step 3: Update end-of-stream logic to call printFormattedResponseHeader**

Find the section that discards content (around lines 226-238):

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
    // Content already streamed - just add formatted header
    printFormattedResponseHeader(content);
} else if (final_xml.len > 0) {
    if (utils.extractTag(final_xml, "message")) |msg| {
        // Content already streamed - just add formatted header
        printFormattedResponseHeader(msg);
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
Expected: When LLM sends a text response:
```
Hello, how can I help you?
━━ assistant ━━
```
(No double print - content appears once, header added at end)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(tui): add formatted header for LLM text responses

Print '━━ agent ━━' header at end of streaming without
re-printing content (content already streamed via chunks)."
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
