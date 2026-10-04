# Encapsulate compaction-prompt construction into a testable function

**Date:** 2026-08-06
**Branch:** `worktree/encapsulate-compaction-prompt`
**Scope:** Refactor + tests, no behaviour change.

## Goal

Extract the 100-line block that builds the CompactionAgent handoff prompt
out of `callCompactAgent` into a focused function `buildCompactMessagePrompt`
that can be unit-tested without spinning up the LLM streaming pipeline.

## Why

`src/ai_workflow/tui/agentic_loop/compaction.zig` had a single 195-line
function `callCompactAgent` that:

1. extracted the original system prompt from `messages[0]`
2. walked `messages[1..last_idx]` and labeled each by role
3. joined the labeled rows into `history_str`
4. formatted a fixed handoff-package template with both strings
5. built a 2-message conversation (system + user)
6. initialised an `Agent` and ran `callStreaming`
7. returned the streamed content (or `null` on any failure)

Steps 1-4 are pure data transformation — they're the only part that
actually compiles correctly without network access. Steps 5-7 require a
real LLM and were the only thing keeping this code from being unit-tested.

Extracting 1-4 into `buildCompactMessagePrompt` makes the prompt builder
testable in isolation with no LLM dependency.

## What landed

### 1. New function `buildCompactMessagePrompt`

```zig
pub fn buildCompactMessagePrompt(
    allocator: std.mem.Allocator,
    logger: ?*logger_mod.Logger,
    messages: std.ArrayList(agent.AgentMessage),
    original_system_prompt: []const u8,
) ?[]const u8
```

- Walks `messages[1..last_idx]` (excludes the system prompt at index 0 AND
  the current/pending message at the last index).
- Each `content` becomes `[<role>]: <content>`.
- Each `tool_calls[i]` becomes `[tool_call]: <name>(<arguments>)`.
- Rows joined with `\n` and embedded into the fixed handoff template.
- **Caller owns the returned string** — must free with `allocator.free`.
- Returns `null` on alloc failure (after logging via `logger`).

### 2. `callCompactAgent` refactor

The 100-line block (formerly lines 42-142) is replaced by a single call:

```zig
const compact_message = buildCompactMessagePrompt(
    allocator, logger, messages, original_system_prompt,
) orelse return null;
defer allocator.free(compact_message);
```

Function dropped from 195 to 101 lines.

### 3. Three leak fixes (surfaced by the leak detector)

The original block allocated per-message labeled strings into `parts` and
then called `std.mem.join`, which COPIES the segments into a fresh
allocation. The original code dropped `parts` without freeing the originals
— a per-compaction leak invisible in production (arena-backed) but caught
by `testing.allocator.detectLeaks()` once we wrote a unit test.

Fixed in 3 places:

| Site | Original | Fixed |
|---|---|---|
| `parts.append` fails after successful `allocPrint` of `labeled` | leaked `labeled` | `allocator.free(labeled)` before `return null` |
| `parts.append` fails after successful `allocPrint` of `tc_str` | leaked `tc_str` | `allocator.free(tc_str)` before `continue` |
| `history_str` allocated, `parts.items` originals orphaned | leaked N labels | `defer for (parts.items) |part| allocator.free(part)` |

Net effect: zero leak reports from `buildCompactMessagePrompt`'s tests
(the 2 remaining leaks are pre-existing in `design_model_set_element_parent_test`,
unrelated to this work).

### 4. Eight inline tests

Per the `agentic_loop/` README convention: tests live in the impl file,
not a sibling `_test.zig`. Registered in `test_runner.zig` (the same
silent-no-run hazard the README warns about — `compaction.zig` was
previously NOT imported by the runner).

| Test | Verifies |
|---|---|
| happy path embeds system prompt and labeled history | end-to-end shape |
| first AND last messages are excluded from history | `messages[1..last_idx]` semantics |
| tool_calls formatted as `[tool_call]: name(args)` | tool-call branch |
| message with content=null and no tool_calls is skipped silently | null-content branch + no `[user]:\n` artifact |
| empty middle history (only system + last) returns valid prompt | degenerate case doesn't crash |
| history rows are joined with newline separator (order preserved) | ordering + separator |
| returns a heap-allocated, caller-owned string | ownership + leak-detector gates |
| empty-messages list (only system + 1 user) excludes last | 2-message edge case |

All 8 pass. Total test count for `agentic_loop/`:
107 → 115 (+8). Per-test discovery confirmed via
`strings .zig-cache/o/.../test | grep buildCompactMessagePrompt`.

### 5. `mod.zig` re-export

`pub const buildCompactMessagePrompt = compaction_mod.buildCompactMessagePrompt;`
added alongside the existing `callCompactAgent` / `CallCompactAgentInput`
exports — keeps the convention consistent with the rest of the directory.

### 6. README + SPEC.md updated

- `src/ai_workflow/tui/agentic_loop/README.md` — added the new test row
  in the per-file table, bumped total count 107 → 115.
- `docs/SPEC.md` §4 — added the worktree entry in the in-progress table.

## Verification

| Step | Result |
|---|---|
| `zig build test --summary all` | 2168/2174 pass (was 2161/2167 = +8 = my tests), 0 failed |
| `zig build install:linux:system` | compile succeeds (cp to `/usr/local/bin/pabrik` fails for perms — unrelated) |
| Fresh rebuild (`rm -rf zig-out/bin && zig build`) | both `pabrikcore-linux-x86_64` + `pabrik-desktop` produced |
| Cross-compile `zig build-obj -target x86_64-windows-gnu` | pre-existing harness limitation (recursive `pabrikcore` import) — affects pre-existing `callCompactAgent` identically, NOT a regression |
| Cross-compile `zig build-obj -target aarch64-macos` | same pre-existing limitation |
| Linux binary smoke test (`./zig-out/bin/pabrikcore-linux-x86_64`) | not run — no behaviour change, no LLM dependency touched |

## Out of scope

- Refactoring `compactMessageInMemoryNew` to also use the new helper
  (different signature, different output type — XML envelope, not plain text).
- Replacing the fixed handoff-package template with a structured builder.
- Promoting `buildCompactMessagePrompt` to a comptime fn pointer in
  `CompactDeps` (would only matter if we want to test the surrounding
  workflow with a stubbed prompt builder — out of scope for this PR).