# TUI Display Improvements - read_file Filename + LLM Text Response

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two TUI display improvements:
1. Change `read_file` display from `[read_file] lines X-Y/Total` to `[read_file] filename`
2. Ensure LLM text responses are always displayed with formatted header

**Architecture:** 
- Task 1: Modify `displayReadFileResult` in `tool_results.zig` to show filename instead of line counts
- Task 2: Modify end-of-stream logic in `streaming.zig` to print formatted response

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

**Server sends response via `sendResponse()` in `on_event_sent.zig`:**
```xml
<response>
  <content>Hello, how can I help?</content>
</response>
```

**TUI streaming in `streaming.zig`:**
- Streaming loop (lines 127-180): Processes `<chunk>` tags → prints content raw
- End-of-stream (lines 226-238): Extracts `<content>` → **DISCARDS it** (`_ = content;`)

**Current buggy code (streaming.zig lines 226-238):**
```zig
if (utils.extractTag(final_xml, "content")) |content| {
    _ = content;  // ❌ LOST! Never displayed!
} else if (final_xml.len > 0) {
    if (utils.extractTag(final_xml, "message")) |msg| {
        _ = msg;  // ❌ LOST! Never displayed!
    } else {
        tuiText.print("{s}\n", .{final_xml});
    }
}
```

**Dead code function (`streaming.zig` lines 381-393):**
```zig
fn printFormattedResponse(content: []const u8) void {
    const agent_name = utils.extractTag(content, "agent") orelse "assistant";
    tuiText.print("{s}━━ {s} ━━{s}\n", .{ globals.cyan, agent_name, globals.reset });
    // ...prints content...
}
```
This function exists but is **NEVER CALLED**!

### Expected Behavior

| Scenario | What Should Happen |
|----------|---------------------|
| Chunks came | Content streamed + `━━ assistant ━━` header at end |
| No chunks (instant) | Full response: `━━ assistant ━━` + content |

---

## Relevant Files

| File | Role |
|------|------|
| `src/apps/tui/display/tool_results.zig` | Contains `displayReadFileResult` function (Task 1) |
| `src/apps/tui/network/streaming.zig` | Contains streaming loop, end-of-stream logic, `printFormattedResponse` (Task 2) |
| `src/ai_workflow/tui/on_event_sent.zig` | Server-side: sends `<response><content>` to TUI |
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
- Modify: `src/apps/tui/network/streaming.zig`

### Task 2: Call printFormattedResponse Instead of Discarding Content

- [ ] **Step 1: Read the current end-of-stream logic**

```bash
cat -n src/apps/tui/network/streaming.zig | sed -n '220,250p'
```

- [ ] **Step 2: Modify the end-of-stream logic**

Find the section that discards content (around lines 226-238):

Current code:
```zig
if (utils.extractTag(final_xml, "content")) |content| {
    _ = content;  // ❌ Lost!
} else if (final_xml.len > 0) {
    if (utils.extractTag(final_xml, "message")) |msg| {
        _ = msg;  // ❌ Lost!
    } else {
        tuiText.print("{s}\n", .{final_xml});
    }
}
```

Replace with:
```zig
if (utils.extractTag(final_xml, "content")) |content| {
    // Print formatted response if no streaming happened
    if (!streaming_started) {
        printFormattedResponse(content);
    } else {
        // Content already streamed - just add formatted header
        const agent_name = utils.extractTag(content, "agent") orelse "assistant";
        tuiText.print("\n{s}━━ {s} ━━{s}\n", .{ globals.cyan, agent_name, globals.reset });
    }
} else if (final_xml.len > 0) {
    if (utils.extractTag(final_xml, "message")) |msg| {
        // Print formatted response if no streaming happened
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

- [ ] **Step 3: Build to verify**

```bash
zig build 2>&1
```
Expected: No errors (empty output = success in Zig)

- [ ] **Step 4: Test with the TUI**

```bash
zig build run:tui
```
Expected:
- **If chunks came**: Content streams → `━━ assistant ━━` header at end
- **If NO chunks**: Full formatted response: `━━ assistant ━━` + content

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(tui): display LLM text responses with formatted header

Print full response if no streaming chunks came,
or just add header if content was already streamed."
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
