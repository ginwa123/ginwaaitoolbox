---
name: zig-slice-headers-across-defer-lifetimes
description: "Detect and fix the use-after-free anti-pattern where a `[]const u8` slice header (pointer + length) is copied from a defer-managed lifetime into a second structure, then read after the source's defer fires. Classic symptom: 0xAA bytes in output looking like an encoding bug."
---
---
name: zig-slice-headers-across-defer-lifetimes
description: Detect and fix the use-after-free anti-pattern where a []const u8 slice header is copied from a defer-managed lifetime into a second structure, then read after the source's defer fires. Classic symptom: 0xAA bytes in output looking like an encoding bug.
tags: [zig, fix, memory-safety, use-after-free, defer]
---

## When to Use

Trigger this skill when:
- A function builds a list/ArrayList of `[]const u8` slices that point into a structure that has its own `defer free_*(...)` cleanup
- The cleanup defer fires before the second list is consumed
- The output contains "garbled" bytes, especially `0xAA` (Zig debug allocator's free-fill pattern)
- A function that aggregates from `list_*_from_dir_path` / `parse_*` style helpers that return allocated slices, and stores those slices into an intermediate ArrayList

## Context

Zig's debug allocator fills every freed allocation with the byte `0xAA`. When you read from a freed buffer you don't get a segfault — you get the `0xAA` pattern. This **looks exactly like a UTF-8/UTF-16 encoding bug** because the output is full of unrecognized byte sequences that render as `U+FFFD` (replacement character) in terminals.

**The anti-pattern:**
```zig
// Source structure owns allocated strings
const source_list = some_api.list_things(allocator);  // returns []T with .name pointers
defer some_api.free_things(allocator, source_list);   // (A) frees the .name memory

// Bug: copy slice headers into a second structure
var second_list: std.ArrayList([]const u8) = .empty;
defer second_list.deinit(allocator);
for (source_list) |thing| {
    second_list.append(allocator, thing.name) catch break;  // (B) slice header only
}
// source_list's defer (A) fires here, freeing thing.name memory
// second_list now holds DANGLING POINTERS

// Later: read from dangling pointers
for (second_list.items) |name| {           // (C) reads freed 0xAA memory
    out.appendSlice(allocator, name);
}
```

## Procedure

1. **Identify the source of the slice header.** Where does the `[]const u8` originate? Is there a `defer free_*` that owns it?
2. **Eliminate the intermediate ArrayList if possible.** The cleanest fix: build the final output directly inside the same scope that owns the source slices — let the source's `defer` fire *after* you've finished reading from it.
3. **If you must keep the intermediate list:** `allocator.dupe` every entry at append time, and explicitly `free` every entry at cleanup time. The list of slice headers alone is not enough — you need ownership.
4. **Add a regression test** that asserts `std.mem.indexOfScalar(u8, output, 0xAA) == null`. The `0xAA` byte is a reliable marker for this specific bug because no legitimate UTF-8/ASCII/UTF-16LE byte stream contains it.

## Pitfalls

- **`std.ArrayList([]const u8)` does NOT own the inner slices.** `.deinit(allocator)` only frees the ArrayList's storage, not the slices it references. You need to manually free each entry.
- **`ArrayList.append(arr, slice)` copies the slice header (pointer + length), not the data.** It looks like ownership transfer but isn't.
- **`defer` ordering in Zig is LIFO.** The LAST `defer` declared runs FIRST. If two defers interact with the same data, declare them carefully.
- **Don't confuse "use-after-free" with "encoding bug".** The `0xAA` fill pattern is a definitive signal — if you see it, hex-dump the output and look for the run of `0xAA` bytes. The Zig debug allocator enables this in debug builds to catch exactly this bug.
- **`std.testing.io` does NOT support `std.Io.Dir.cwd().realPath`** reliably. Tests that need to exercise code paths using `get_local_skills_path_from_io` (or any `realPath`-dependent path) should use HOME/XDG env vars instead, or the test will silently find zero skills.

## Verification

To confirm the fix is correct:
1. **Build clean:** `zig build`
2. **All tests pass:** `zig build test` (207/207)
3. **Regression test catches the bug:** temporarily revert the fix, re-run tests, confirm the new test fails with `0xAA` assertion
4. **Hex-dump the database:** `sqlite3 ~/.config/pabrik/agent.db "SELECT response_content FROM llm_history WHERE tool_name='get_skill' AND response_content LIKE '%Skill not found%' ORDER BY created_at DESC LIMIT 1;" | xxd` — should show real skill names, not `aaaa` runs

## Real-World Case Study

Fixed in this codebase: `get_skill.zig:loadSkillByName` and `view_skill.zig:buildSkillNotFoundResponse` (June 2026). Both had the exact same anti-pattern — copy `skill.name` slice headers into `all_skills: ArrayList([]const u8)`, then `defer free_skills_list` freed the source. The fix dropped the intermediate list entirely and built the final `available_str: ArrayList(u8)` directly while each `global_list`/`local_list` was still in scope. The `<skill_name>` field was unaffected because it came from a different code path (function argument, not the list).

The user-reported symptom was: "<skill></skill><skill></skill>..." in the LLM's response — `<skill>` and `</skill>` were intact (allocated by `appendSlice("<skill>")` and `appendSlice("</skill>")` which use literal strings), but the *name* content was `0xAA` filled (freed memory).

## See Also

- `get_skill_test.zig` and `view_skill_test.zig` for regression test patterns
- The "Never share `[]const u8` slice headers between two `defer`-managed lifetimes" entry in PABRIK.md
- `add_skill.zig` and `edit_skill.zig` had a related (but different) use-after-free that was previously fixed — see the `[add_skill.zig, edit_skill.zig]` entry in PABRIK.md's Bug Fixes section

