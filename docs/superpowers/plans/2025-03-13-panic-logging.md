# Panic Logging Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture and log all backend panics with full stack traces to file and notify connected TUI clients via SSE.

**Architecture:** Override Zig's default panic handler via `std_options` in `root.zig`. The panic handler will:
1. Write panic info (message + stack trace) to the log file
2. Send panic event to all connected SSE clients
3. Exit with error code

**Tech Stack:** Zig 0.15.2, httpz (for SSE), custom logger module

---

## Summary

| Task | Files Modified | Status |
|------|---------------|--------|
| 1 | `src/root.zig` | ✅ Complete - Add early panic log path storage |
| 2 | `src/root.zig` | ✅ Complete - Add panic handler with stack trace |
| 3 | `src/modules/http_server/http_server.zig` | ✅ Complete - Add SSE broadcast function |
| 4 | `src/main.zig` | ✅ Complete - Set panic log path early |
| 5 | - | ✅ Complete - Build and tests pass |

---

## Changes Made

### 1. src/root.zig
- Added `panic_log_path` global variable for early log path storage
- Added `setPanicLogPath()` and `getPanicLogPath()` functions
- Added `panicHandler()` function that:
  - Captures stack trace using `std.debug.getStackTrace()`
  - Formats panic message with `std.debug.formatStackTrace()`
  - Writes to log file (if path set)
  - Writes to stderr for visibility
  - Broadcasts to SSE clients
  - Exits with code 1
- Updated `std_options` to use the custom panic handler

### 2. src/modules/http_server/http_server.zig
- Added `broadcast()` method to `SseConnectionManager`
- Added `broadcastPanic()` function to send panic events to all connected clients

### 3. src/main.zig
- Added `tree1.setPanicLogPath(log_file_path)` call early in main()

---

## Verification

- ✅ Build compiles successfully
- ✅ Tests pass
