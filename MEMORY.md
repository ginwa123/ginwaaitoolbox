# MEMORY — Agentic AI Learning System

> **Always Learning:** This file is the single source of truth for all agent learning. Every mistake is captured here with its root cause and prevention strategy.

---

## Table of Contents

1. [Quick Reference](#quick-reference) — Fast lookup for common patterns
2. [Mistakes & Solutions](#mistakes--solutions) — Record of errors and how to prevent them
3. [Language & Environment Facts](#language--environment-facts) — API changes, syntax rules
4. [Tool Optimization](#tool-optimization) — RTK commands, token-saving strategies
5. [Protocols](#protocols) — Agent behavior rules

---

## Quick Reference

### Before Any Task
- [ ] Load skills: `list_skills()` → `get_skill("skill_name")`
- [ ] Check MEMORY.md for relevant past mistakes
- [ ] Classify complexity: Simple | Moderate | Complex

### When Error Occurs
1. **Capture** — Record in Mistakes & Solutions section below
2. **Fix** — Solve the immediate problem
3. **Learn** — Write prevention strategy
4. **Apply** — Consult before similar tasks

---

## Mistakes & Solutions

<!-- Add new mistakes using this template:
### [Unique ID] - [Brief Title]
**Date:** YYYY-MM-DD
**Error Type:** syntax | type | logic | query | command | other
**Context:** What you were trying to do

**Error Message:**
```
[Exact error text]
```

**Root Cause:** One-line explanation

**Fix:** What was changed to resolve it

**Prevention:**
- [ ] Specific actionable step to avoid this
- [ ] Check this section before similar tasks

**Lessons:**
- [Generalizable takeaway]
-->

### ZIG-001 - ArrayList.init deprecated in Zig 0.15
**Date:** 2024-03-11
**Error Type:** syntax
**Context:** Creating ArrayList in Zig

**Error Message:**
```
error: container 'std.ArrayList' has no member called 'init'
```

**Root Cause:** Zig 0.15 renamed `ArrayList.init()` to `ArrayList.empty()`

**Fix:** Changed `ArrayList.init(allocator)` to `ArrayList.empty`

**Prevention:**
- [ ] Check Zig 0.15 API changelog before using standard library
- [ ] Use `ArrayList.empty` instead of `ArrayList.init`

---

### ZIG-002 - ArrayList.deinit requires allocator parameter
**Date:** 2024-03-11
**Error Type:** syntax
**Context:** Cleaning up ArrayList

**Error Message:**
```
error: expected 1 argument(s), found 0
```

**Root Cause:** Zig 0.15 changed ArrayList.deinit signature to require allocator

**Fix:** Changed `list.deinit()` to `list.deinit(allocator)`

**Prevention:**
- [ ] Always pass allocator to deinit in Zig 0.15+

---

### ZIG-003 - {s} format string requires []u8
**Date:** 2024-03-11
**Error Type:** type
**Context:** Using std.fmt.format for error messages

**Error Message:**
```
error: format string '{s}' expects argument type '[]const u8', found 'enum@...'
```

**Root Cause:** Zig 0.15 requires explicit type conversion for format strings

**Fix:** Use `@errorName(err)` to convert error types to `[]u8`

**Prevention:**
- [ ] Use `@errorName(err)` for error type to string conversion

---

### ZIG-004 - std.fs.File.createFile replaces writeFile
**Date:** 2024-03-11
**Error Type:** syntax
**Context:** Creating/overwriting files

**Error Message:**
```
error: container 'std.fs.File' has no member called 'writeFile'
```

**Root Cause:** Zig 0.15 renamed writeFile to createFile

**Fix:** Use `std.fs.createFileAbsolute(path, .{})` instead

**Prevention:**
- [ ] Use createFile for creating/overwriting files

---

### ZIG-005 - std.fs.accessableAbsolute doesn't exist
**Date:** 2024-03-11
**Error Type:** syntax
**Context:** Checking if file exists

**Error Message:**
```
error: container 'std.fs' has no member called 'accessableAbsolute'
```

**Root Cause:** Typo - correct function doesn't exist, use openFileAbsolute with try/catch

**Fix:** Use `std.fs.openFileAbsolute(path, .{}) catch |err| if (err == error.FileNotFound) ...`

**Prevention:**
- [ ] Always verify std.fs function names in Zig 0.15 docs

---

### ZIG-006 - ArrayList.writer() requires allocator
**Date:** 2024-03-11
**Error Type:** syntax
**Context:** Getting writer from ArrayList

**Error Message:**
```
error: expected 1 argument(s), found 0
```

**Root Cause:** Zig 0.15 changed ArrayList.writer() to require allocator

**Fix:** Use `list.writer(allocator)` instead of `list.writer()`

**Prevention:**
- [ ] Pass allocator to all ArrayList methods that require it

---

### ZIG-007 - std.os.pid doesn't exist
**Date:** 2024-03-11
**Error Type:** syntax
**Context:** Getting process ID for LSP init

**Error Message:**
```
error: container 'std.os' has no member called 'pid'
```

**Root Cause:** Zig 0.15 removed std.os.pid

**Fix:** Use literal `0` for processId in LSP init

**Prevention:**
- [ ] Use literal 0 for processId in LSP configuration

---

### ZIG-008 - std.fs.File.flush() doesn't exist
**Date:** 2024-03-11
**Error Type:** syntax
**Context:** Flushing file buffer

**Error Message:**
```
error: container 'std.fs.File' has no member called 'flush'
```

**Root Cause:** File writes are immediate in Zig, flush not needed

**Fix:** Remove flush call - writes are immediate

**Prevention:**
- [ ] Don't call flush - Zig file writes are synchronous

---

### ZIG-009 - json.Value.get() doesn't exist
**Date:** 2024-03-11
**Error Type:** syntax
**Context:** Parsing JSON values

**Error Message:**
```
error: container 'json.Value' has no member called 'get'
```

**Root Cause:** Zig 0.15 json API changed

**Fix:** Use `.object.get()` for object values

**Prevention:**
- [ ] Use `.object.get()` for accessing JSON object values

---

### ZIG-010 - process.Child.kill() returns Term
**Date:** 2024-03-11
**Error Type:** type
**Context:** Killing child process

**Error Message:**
```
error: expected type 'void', found 'Term'
```

**Root Cause:** process.Child.kill() returns Term, not void

**Fix:** Use `_ = process.kill()` to discard the return value

**Prevention:**
- [ ] Use `_ = ` to discard Term return value

---

### ZIG-011 - allocator.dupeZ() returns [:0]u8 but argv needs [*:0]const u8
**Date:** 2024-03-11
**Error Type:** type
**Context:** Preparing command-line arguments

**Error Message:**
```
error: expected type '[*:0]const u8', found '[:0]u8'
```

**Root Cause:** Type mismatch between dupeZ result and argv requirement

**Fix:** Use stack buffer approach instead of dupeZ

**Prevention:**
- [ ] Use stack buffers for argv preparation

---

### ZIG-012 - std.posix.Sigaction initialization
**Date:** 2024-03-11
**Error Type:** syntax
**Context:** Setting up signal handlers

**Error Message:**
```
error: expected expression, found ';'
```

**Root Cause:** std.posix.Sigaction is not a struct literal type

**Fix:** Initialize fields individually

**Prevention:**
- [ ] Initialize Sigaction fields individually, not as struct literal

---

### ZIG-013 - std.posix.sigaction() returns void
**Date:** 2024-03-11
**Error Type:** syntax
**Context:** Registering signal handler

**Error Message:**
```
error: expected error union type, found 'void'
```

**Root Cause:** sigaction returns void, not error union

**Fix:** Remove `catch` - call directly without error handling

**Prevention:**
- [ ] std.posix.sigaction() returns void, no catch needed

---

### ZIG-014 - std.posix.execveZ() returns error union
**Date:** 2024-03-11
**Error Type:** syntax
**Context:** Executing external command

**Error Message:**
```
error: expected error union type
```

**Root Cause:** execveZ returns error union, needs catch

**Fix:** Use `catch` without `|err|` - just `catch` 

**Prevention:**
- [ ] Use catch without |err| for execveZ

---

### ZIG-015 - std.posix.sigemptyset() returns sigset_t
**Date:** 2024-03-11
**Error Type:** type
**Context:** Initializing signal mask

**Error Message:**
```
error: expected type 'sigset_t', found 'void'
```

**Root Cause:** sigemptyset returns the sigset_t, doesn't take out parameter

**Fix:** Use `const mask = std.posix.sigemptyset()` 

**Prevention:**
- [ ] sigemptyset() returns sigset_t, assign the result

---

## Language & Environment Facts

<!-- Known API changes, syntax rules, and environment behaviors for this codebase. -->
<!-- Format: - [lang@version] <fact in one sentence> -->

- [zig@0.15] `{s}` format string requires `[]u8` — use `@errorName(err)` to convert error types to string
- [zig@0.15] ArrayList API changed: `.init` → `.empty`, all of `.appendSlice`, `.deinit`, `.toOwnedSlice` now require allocator as first arg
- [zig@0.15] `std.fs.File.createFile` replaces `writeFile` for creating/overwriting files
- [zig@0.15] `ArrayList.deinit` requires allocator parameter
- [zig@0.15] Line collection must include newlines explicitly when building strings
- [zig@0.15] `std.fs.accessableAbsolute` doesn't exist — use `std.fs.openFileAbsolute` with try/catch
- [zig@0.15] `ArrayList.init(allocator)` → `ArrayList.empty`
- [zig@0.15] `ArrayList.writer()` → `ArrayList.writer(allocator)`
- [zig@0.15] `std.os.pid` doesn't exist — use literal 0 for processId in LSP init
- [zig@0.15] `std.fs.File.flush()` doesn't exist — not needed, write is immediate
- [zig@0.15] `std.fs.File.readByte()` doesn't exist — use `file.read()` instead
- [zig@0.15] `json.Value.get()` doesn't exist — use `.object.get()` for object values
- [zig@0.15] `process.Child.kill()` returns `Term`, not void — use `_ = ` to discard
- [zig@0.15] `allocator.dupeZ()` returns `[:0]u8` but argv needs `[*:0]const u8` — use stack buffer approach
- [zig@0.15] `std.posix.Sigaction` is not a struct literal type — initialize fields individually
- [zig@0.15] `std.posix.sigaction()` returns `void`, not error union — no `catch` needed
- [zig@0.15] `std.posix.execveZ()` returns error union directly — use `catch` without `|err|`
- [zig@0.15] `std.posix.sigemptyset()` returns `sigset_t` for signal mask initialization

---

## Tool Optimization

### RTK (Rust Token Killer) Commands

**Always prefix commands with `rtk`** for 60-90% token savings:

```bash
# Build & Compile (80-90% savings)
rtk cargo build
rtk cargo check
rtk cargo clippy
rtk tsc
rtk lint

# Test (90-99% savings)
rtk cargo test
rtk vitest run
rtk playwright test

# Git (59-80% savings)
rtk git status
rtk git log
rtk git diff
rtk git add
rtk git commit
rtk git push

# Files & Search (60-75% savings)
rtk ls <path>
rtk read <file>
rtk grep <pattern>
```

---

## Protocols

### Mistake Capture Protocol

When an error occurs:
```
1. Identify: What type of error? (syntax, type, logic, query, command)
2. Record: Exact error message, context, location
3. Fix: Solve the immediate problem
4. Document: Root cause, fix applied, prevention strategy
5. Add to MEMORY.md in Mistakes & Solutions section
```

### Before Similar Tasks
- [ ] Search MEMORY.md for related mistakes
- [ ] Apply prevention strategies proactively
- [ ] Test thoroughly in affected areas

---

## Notes

- **Do not run:** `zig build run` or `zig build run:tui` — kills the process itself
- Always verify changes compile before claiming completion
- Check MEMORY.md first when encountering errors
