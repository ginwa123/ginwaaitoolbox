# save_memory + load_memory — tags wire format bug (2026-08-06)

## Symptom (user report, task_1785990166273)

User: "save_memory failed to parse input: UnexpectedToken" — every call
failed regardless of tags format tried (JSON array, `||` separator, single
tag, space separator, empty string).

Live evidence from session-1785986173692: the LLM faithfully sent the
tags as a STRING (per the schema `type: "string"`), but the parser
expected a JSON array. Every string-form failed with `UnexpectedToken`
at `/usr/lib/zig/std/json/static.zig:487:54`.

## Root cause (TWO contradictory contracts)

1. **Schema declared `tags: { type: "string" }`** in both
   `save_memory_tool.function.parameters.properties` and
   `load_memory_tool.function.parameters.properties`. The LLM faithfully
   sent a string.

2. **Parser expected `tags: []const []const u8`** (JSON array) in
   `SaveMemoryInput` and `LoadMemoryInput`. `std.json.parseFromSlice`
   threw `UnexpectedToken` because the wire JSON had a STRING where an
   array was expected.

The mismatch is silent: the schema says one thing, the parser expects
something else. The description says "Joined with `||` in storage" —
which implies a string with separator — but the type is `[]const
[]const u8`.

## Fix (surgical, 4 files)

### 1. `SaveMemoryInput.tags` and `LoadMemoryInput.tags` → `[]const u8`

```zig
// Before (silently broken for LLM-wired strings):
tags: []const []const u8 = &.{},

// After (matches schema + matches LLM intuition):
tags: []const u8 = "",
```

### 2. New `splitTagsString` helper at the wire boundary

```zig
pub fn splitTagsString(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    // First pass: count tags (skip empty segments).
    // Accepts ||, |, comma, and space as separators.
    // ...
}
```

Splitting happens at the tool boundary, NOT in `agent_memories`. The
storage layer still uses `[]const []const u8` (joined with `||` for
storage) — the boundary split is purely a wire concern.

### 3. Wired into `executeSaveMemory` and `executeLoadMemory`

```zig
const tags_array = try splitTagsString(allocator, input.tags);
defer allocator.free(tags_array);

const row = agent_memories.saveMemory(allocator, db, .{
    .content = input.content,
    .tags = tags_array,  // ← was input.tags (array)
    .id = input.id,
}) catch ...
```

### 4. Schema description updated

```zig
.{ .name = "tags", .type = "string", .description =
    "Optional labels as a single string. Multiple tags separated by `||` (preferred), " ++
    "e.g. 'preferences||user'. Also accepts `|`, `,`, or space as separators for robustness. " ++
    "Empty string = no tags."
},
```

## Tests (4 new, all green)

- `save_memory_tool: tags wire format is a string (parses without UnexpectedToken)` — the EXACT LLM call from session-1785986173692
- `save_memory_tool: single tag (no separator) round-trips`
- `save_memory_tool: empty tags string saves empty tags`
- `save_memory_tool: splitTagsString accepts ||, |, comma, and space separators` (7 sub-cases inside)

Plus updated all existing tests to use strings instead of arrays.

Plus fixed 11 leaks in `load_memory_test.zig` (the `_ = try save_memory_mod.executeSaveMemory(...)` pattern dropped the returned slice).

## TDD trace

- **RED**: `std.json.parseFromSlice` with `SaveMemoryInput` exported as
  `[]const []const u8` throws `UnexpectedToken` at offset 487 of
  `std/json/static.zig` when the wire JSON has `tags="..."` (string).
  Confirmed by writing a regression test that uses the EXACT LLM call
  payload from the user's bug session.
- **GREEN**: change `tags` to `[]const u8`, add `splitTagsString`,
  split at boundary, pass array to storage. All 4 new tests pass.
- **No regressions**: total test count went from 2336 (main) to 2343
  (with fix, +7 net). The 6 failures + 1 crash + 18 leaks are pre-existing
  baseline (`inserLLMHistories`, `design_model_set_element_parent`,
  `show_preview`, etc — documented in AGENTS.md).

## Verification

```bash
# Backend tests
timeout 180 zig build test --summary all
# 2343 pass, 6 skip, 6 fail, 1 crash (baseline), 18 leaks (baseline)
# Zero new failures from this fix.

# Cross-compile smoke (mandatory for SQL helpers / lazy analysis)
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# clean
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# clean

# Build
rm -rf zig-out/bin && zig build
# All 3 binaries produced (nalarcore-linux-x86_64 86 MB, nalar-desktop 35 MB, nalarcli 12 MB)
```

## Why "splitTagsString" instead of "accept both array AND string"

The schema clearly says `type: "string"`. The LLM faithfully sends a
string. The mismatch is a one-line struct field change. Trying to
"accept both" would require:
- A `json.Value` field instead of `[]const u8`
- Runtime type-check (`if (value == .string) ... else if (value == .array) ...`)
- More complex tests

The "split at boundary" approach is simpler and matches the documented
contract. The array-form is never used by the LLM (the schema says
string), so removing the array-form codepath is safe.

## Why NOT keep the array-form for back-compat

If a programmatic caller (CLI, test code, internal helper) wanted to
send an array, they bypass `executeSaveMemory` and call
`agent_memories.saveMemory` directly (which still takes
`[]const []const u8`). The boundary split is ONLY at the tool layer.

This is the same pattern as `agent_memories` itself: backend takes
array, tool layer takes string. Two layers, two contracts.

## Why lenient separators (acceptance of `|`, `,`, space)

The LLM tried 5 different separators when the parser failed:
- `demo|tool-test|nalar` (single `|`)
- `demo tool-test nalar` (space)
- `demo-tag` (single tag, no separator)
- `["demo-tag"]` (JSON array stringified)
- `` (empty)

Being lenient avoids the user reporting the same bug again. The strict
contract (`||` is the canonical separator) is documented in the
schema description. The implementation accepts all common separators
and normalizes to `||` at storage time.

## Related

- Plan: `docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md` (the original plan)
- AGENTS.md changelog entry: `### 2026-08-06: save_memory + load_memory tags wire format (user bug fix)`
- Cross-project memory: `static-contract-test-when-to-prefer-behavioural` (the no-static-contract rule)
- Project memory: `zig-slice-headers-across-defer-lifetimes` (relevant for the memory-row ownership)
- This is the SECOND bug discovered in the save/load_memory agents (the first was the missing tool def schema — see 2026-08-06 search-history-v2). Always validate wire-format alignment between schema and parser.

## Pitfall (record for future agents)

Three-part contract that must stay in sync:
1. **Schema** (LLM-visible tool definition) declares `tags: string`
2. **Parser** (`SaveMemoryInput` / `LoadMemoryInput` struct) declares `tags: []const u8`
3. **Storage** (`agent_memories.saveMemory` / `loadMemoriesByFts`) takes `tags: []const []const u8`

The boundary split (string → array) happens in the tool layer. The
storage layer keeps the array shape because it's the right primitive
for SQL bind loops (`LIKE '%tag%'` per tag).

If you ever change the schema, change the parser; the storage layer
should stay the same.
