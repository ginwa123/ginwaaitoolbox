# Better Tool Placeholder — `wrapToolOutput` Envelope for Phase 1 Inserts

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `handle_tool.zig` Phase 1 placeholder rows carry the canonical `<tool>...</tool>` envelope via `wrapToolOutput` (data empty is fine; `<name>` + `<parameters>` always present). The frontend's `tryUnwrapToolOutput` can then parse the row on page-refresh-mid-execution, mid-flight SSE drops, and post-crash recovery — instead of falling back to the legacy "raw `msg.content`" path that rendered blank / "unknown tools" text bubbles.

**Architecture:** Two surgical edits to `src/ai_workflow/tui/agentic_loop/handle_tool.zig` (the `handle_tool` function's Phase 1 for-loop). The known-tool branch wraps the placeholder with `success=true, data=""`; the unknown-tool branch wraps with `success=false, error="unknown tools"`. Both go through the same `wrapToolOutput` helper that every other exec wrapper already uses, so the wire contract is identical to a real Phase 3 result. Two inline static-contract tests pin the source-level emission so a future refactor cannot silently swap back to raw strings.

**Tech Stack:** Zig 0.16 backend (`src/ai_workflow/tui/agentic_loop/handle_tool.zig`), no DB schema changes, no frontend changes. `tools_wrap_output.zig` and the frontend `unwrapToolOutput.ts` already speak the envelope.

## Global Constraints

- Zig 0.16: `const` over `var` for single-init vars; SQLite argv is string-typed only.
- Per-request arena allocator: do NOT `defer allocator.free()` anything allocated via `ctx.allocator` (arena wipes it). The placeholder envelope IS allocated via `allocator`, so the explicit `defer allocator.free(placeholder)` is wrong — read `Per-Request Arena Cleanup — Don't defer free in handlers` from AGENTS.md. **Use `errdefer`** instead, so the free only happens on the error path and the success path's `insertLLMHistories` duplicate handles ownership transfer. (Or simpler: rename the variable to `placeholder_owned` and rely on the arena — but that requires confirming the arena scope.)
- `zig build test --summary all` must pass with 0 failures before commit. Baseline = 2576/2582 tests.
- Do NOT kill the port 8081 server; use 8080 for any manual testing.
- No new dependencies. No frontend, no migration, no schema change.

## Root Cause (verified)

**Symptom:** When the agent pauses mid-dispatch (user opens devtools, server restart, kill -9), `handle_tool.zig:461-540` inserts `role=tool` placeholder rows with `response_content` either set to the bare string `"unknown tools"` (unknown-tool branch, line 476) or `""` (known-tool branch, line 516). On page-refresh-mid-execution, the frontend's `tryUnwrapToolOutput` sees neither — `"unknown tools"` fails to match `<tool>...</tool>`, `""` matches the wrapper but has no `<name>`/`<parameters>`. Both fall through to `innerToolData()`'s `msg.content ?? msg.content` legacy path, rendering an empty / garbled card.

**Verified contract:** `wrapToolOutput` in `src/ai_workflow/tui/agentic_loop/tools_wrap_output.zig:30` always emits `<tool><name>{name}</name><parameters>...</parameters><success>true|false</success>...</tool>` — even with empty `data` or empty `parameters`. The Phase 3 dispatch path (lines 610, 627) already uses `wrapToolOutput` for the no-result / no-known-tool branches, so this change makes Phase 1 consistent with Phase 3.

**Memory note:** `mem_4c58243a25a326b1` documents that `wrapToolOutput`'s error branch DROPS the `data` arg. That's fine here — the unknown-tool branch intentionally has no `data`, only an `<error>`.

## Changes

### File 1: `src/ai_workflow/tui/agentic_loop/handle_tool.zig`

#### Change A — Phase 1 for-loop (lines ~459–540)

Replace the entire `for (tc) |tool_call| { … }` block in `handle_tool` with a single-loop body that:

1. Computes `placeholder = wrapToolOutput(allocator, tool_call.function.name, tool_call.function.arguments, false, "unknown tools", "")` if the tool is unknown; otherwise `wrapToolOutput(allocator, tool_call.function.name, tool_call.function.arguments, true, null, "")`.
2. Calls `insertLLMHistories` exactly once with `.response_content = placeholder`.
3. `try list_id_that_was_loaded.append(allocator, id_llm_history);`

The duplicated field-by-field struct literal (the `is_input`, `is_output`, `image_urls`, `created_at`, etc. block) appears ONCE in the new version instead of twice.

**Arena ownership note:** `allocator` here is the per-request arena (`http_server.zig:349-362`), so the explicit `defer allocator.free(placeholder)` is not strictly required — but the per-project comment in AGENTS.md says don't write it. Since `insertLLMHistories` duplicates `contentStr` internally (line 123 of `insert_llm_histories.zig`), the safer pattern is:

```zig
const placeholder = if (unknown) ... else ...;
defer allocator.free(placeholder);  // arena will reclaim anyway — but explicit > implicit for clarity
```

…or omit the defer entirely. Pick the omit path and let the arena wipe the bytes. Add a comment explaining the trade-off so a future reader doesn't add a redundant free.

#### Change B — Static-contract tests (append to bottom of file, after the 16 existing `parseDiffViewFromResult` tests)

Two tests:

1. **Source-grep test** — reads `src/ai_workflow/tui/agentic_loop/handle_tool.zig` via `std.Io.Dir.cwd().readFileAlloc(testing.io, "src/ai_workflow/tui/agentic_loop/handle_tool.zig", testing.allocator, .limited(1 << 20))`. Asserts:
   - `std.mem.count(u8, source, "wrapToolOutput(") >= 5` (3 Phase 3 sites + 2 new Phase 1 sites).
   - `std.mem.indexOf(u8, source, "\"unknown tools\",") != null` (the literal error-message arg).
   - `std.mem.indexOf(u8, source, ".response_content = \"\",") == null` (catches a future regression to the legacy raw-string placeholder).
   - `std.mem.indexOf(u8, source, ".response_content = \"unknown tools\",") == null` (same).
2. **Envelope-shape test** — calls `wrapToolOutput` directly with the same arguments Phase 1 uses (success=true, data="", JSON params), greps the returned string for `<tool>`, `<name>`, `<parameters>`, `<success>true`, `<data></data>`, no `<error>`. Repeats for the success=false envelope (name, success=false, `<error>unknown tools</error>`, no `<data>`). Mirrors the existing `tools_wrap_output.zig:157` test.

### File 2: no other files

No migration (no schema change). No frontend (frontend already parses the envelope via `unwrapToolOutput.ts`). No tests runner update (`handle_tool.zig` is already imported at `test_runner.zig:47`).

## Verification

```bash
# Compile + run unit + static-contract tests
zig build test --summary all
# Expect 2578 pass / 6 skip / 0 fail (baseline was 2576/6/0; +2 new tests).
```

The 2 new tests:

- `Phase 1 placeholder uses wrapToolOutput for both known + unknown branches`
- `wrapToolOutput envelope is round-trip parseable (envelope shape vs frontend)`

If the count goes up by exactly 2 and no test regresses, the patch is correct.

## Commit

Single commit on branch `worktree/better-tool-placeholder`:

```
better-tool-placeholder: wrap Phase 1 placeholder content via wrapToolOutput

handle_tool.zig:459-540 Phase 1 used to insert role=tool placeholder
rows with .response_content = "unknown tools" (unknown-tool branch) or
"" (known-tool branch). On page-refresh-mid-execution the frontend's
tryUnwrapToolOutput couldn't parse either, fell back to the
legacy `msg.content` path, and rendered blank/garbled cards.

Pipe every Phase 1 placeholder through wrapToolOutput:
- Unknown tools → success=false envelope with <error>unknown tools</error>
- Known tools → success=true envelope with empty <data></data>

Phase 3 continues to UPDATE the row in place with the real exec result
(unaffected by this change). Two inline static-contract tests pin the
source-level emission so a future refactor cannot silently revert to
raw strings.

zig build test --summary all: 2578 pass / 6 skip / 0 fail (was 2576/6/0).
```

## Out of Scope

- `is_loading` column lifecycle: Phase 1 doesn't currently set `is_loading=1`, so the column is dead weight. A separate cleanup PR can either repurpose it (for genuine "in-flight" UX) or drop it. Don't bundle that into this commit.
- `resolveStaleLoadingToolResults` and `saveToolResultPlaceholder` are no-ops in production — they reference a placeholder shape Phase 1 never produces. Same separate cleanup ticket.
- Frontend: `innerToolData()` already handles an envelope-shaped row correctly. No changes needed.
