# Migrate compaction.zig → workflow_commpact_message.zig

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete `compaction.zig` entirely by moving its three remaining exports — `CallCompactAgentInput`, `callCompactAgent`, and `noopStreamCallbackNew` — into the orchestrator file `workflow_commpact_message.zig` (the typo'd "commpact" with 3 m's, where `maybeCompactMessagesNew` already lives).

**Architecture:** The orchestrator (`workflow_commpact_message.zig`) already owns `maybeCompactMessagesNew`, `compactMessageInMemoryNew`, `defaultCompactDeps`, and all the mock infrastructure for testing. The pure LLM-orchestration function `callCompactAgent` (builds a 2-message convo, instantiates `agent.Agent`, calls `callStreaming`) is its only remaining external collaborator and conceptually belongs with it. After this move, `compaction.zig` has no callers and can be deleted; `workflow_compact_message.zig` (the 2-m file I created last round) keeps the pure-data helpers and stays as a peer to the orchestrator.

**Tech Stack:** Zig 0.16, pabrikcore.agent / pabrikcore.agent.prompt / pabrikcore.loggermod / pabrikcore.config.

## Global Constraints

- **One worktree per task.** Branch: `worktree/migrate-compaction-into-workflow-commpact`.
- **Public API stays binary-compatible.** All 8 callers of `workflow.callCompactAgent` / `workflow.CallCompactAgentInput` (HTTP handler `session_compact.zig`, workflow orchestrator, regression test, etc.) must keep working without changes outside this plan.
- **No behaviour change.** Pure file move + import rewrite. Test counts unchanged (2338 pass / 6 skip on `main`).
- **`workflow_compact_message.zig` (2 m's, pure-data helpers) is untouched.** This plan only moves LLM-call orchestration into the orchestrator file, not the data helpers.
- **Mock infrastructure stays private to the orchestrator file.** `mockCallCompactAgent` already references `CallCompactAgentInput` — once both types live in the same file, the import goes away.

## File map

### Edited

- `src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig` — add `CallCompactAgentInput`, `callCompactAgent`, `noopStreamCallbackNew` at the top of the file (above `ThresholdCtx`). Drop the two `@import("compaction.zig")` import lines.
- `src/ai_workflow/tui/agentic_loop/workflow.zig` — drop the `const compaction_mod = @import("compaction.zig");` line; source `CallCompactAgentInput` + `callCompactAgent` from the same module that owns `maybeCompactMessagesNew` (the typo'd orchestrator).
- `src/ai_workflow/tui/agentic_loop/workflow_compact_call_agent_test.zig` — change `@import("compaction.zig")` → `@import("workflow_commpact_message.zig")` on lines 67-68.
- `src/ai_workflow/tui/agentic_loop/README.md` — drop the `compaction.zig` row from the file table.
- `docs/SPEC.md` — add the worktree row to the in-progress table.

### Deleted

- `src/ai_workflow/tui/agentic_loop/compaction.zig` — entire file (127 lines after last round's consolidation; this round removes the last 3 exports + the file).

## Tasks

### Task 1: Move LLM-call orchestration into `workflow_commpact_message.zig`

**Files:** EDIT `src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig`

- [ ] At the top of the file (replace lines 3-4 — the two `@import("compaction.zig")` lines), paste the three pieces from `compaction.zig`:
  - `pub const CallCompactAgentInput = struct { ... };` (compaction.zig:16-33)
  - `pub fn callCompactAgent(obj: CallCompactAgentInput) ?[]const u8 { ... }` (compaction.zig:37-125)
  - `fn noopStreamCallbackNew(_: ?*anyopaque, _: agent.StreamChunk) void {}` (compaction.zig:127)
- [ ] The `buildCompactMessagePrompt` call inside `callCompactAgent` already imports via `compact_message = @import("workflow_compact_message.zig")` (line 6) — keep the import name but rename the local constant to `buildCompactMessagePrompt = compact_message.buildCompactMessagePrompt;` so the function body doesn't need editing.
- [ ] Delete lines 3-4 (`@import("compaction.zig")` lines). Add a top-of-file note: `// LLM-call orchestration moved here from the deleted compaction.zig (PR this file's task card).`
- [ ] Move `agent.prompt` into the local const aliases at the top of the file — `callCompactAgent` references `prompt.CompactionAgent`. Add `const prompt = pabrikcore.agent.prompt;` next to the existing `agent = pabrikcore.agent` line.

**Verify:** `rg 'compaction\.zig' src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig` returns zero matches (the file should no longer mention the deleted path).

### Task 2: Update `workflow.zig` re-exports

**Files:** EDIT `src/ai_workflow/tui/agentic_loop/workflow.zig`

- [ ] Delete line 27: `const compaction_mod = @import("compaction.zig");`.
- [ ] Add a new module import: `const commpact_message_mod = @import("workflow_commpact_message.zig");` (note the typo `commpact` to match the file name).
- [ ] Replace lines 76-77 (`pub const CallCompactAgentInput = compaction_mod.CallCompactAgentInput;` + `pub const callCompactAgent = compaction_mod.callCompactAgent;`) with:
  - `pub const CallCompactAgentInput = commpact_message_mod.CallCompactAgentInput;`
  - `pub const callCompactAgent = commpact_message_mod.callCompactAgent;`

**Verify:** `rg 'compaction_mod' src/ai_workflow/tui/agentic_loop/workflow.zig` returns zero matches.

### Task 3: Update `workflow_compact_call_agent_test.zig` import path

**Files:** EDIT `src/ai_workflow/tui/agentic_loop/workflow_compact_call_agent_test.zig`

- [ ] Change line 67: `const CallCompactAgentInput = @import("compaction.zig").CallCompactAgentInput;` → `const CallCompactAgentInput = @import("workflow_commpact_message.zig").CallCompactAgentInput;`.
- [ ] Change line 68: `const callCompactAgent = @import("compaction.zig").callCompactAgent;` → `const callCompactAgent = @import("workflow_commpact_message.zig").callCompactAgent;`.
- [ ] Update the docstring on lines 5, 233: replace `compaction.zig` with `workflow_commpact_message.zig` (these are reference notes, not import paths — keep them accurate so future readers find the code).

**Verify:** `rg '@import\("compaction' src/ai_workflow/tui/agentic_loop/workflow_compact_call_agent_test.zig` returns zero matches.

### Task 4: Delete `compaction.zig`

**Files:** DELETE `src/ai_workflow/tui/agentic_loop/compaction.zig`

- [ ] Run `git rm src/ai_workflow/tui/agentic_loop/compaction.zig`.

**Verify:** `ls src/ai_workflow/tui/agentic_loop/compaction.zig` reports "No such file or directory".

### Task 5: Update README.md + SPEC.md

**Files:** EDIT `src/ai_workflow/tui/agentic_loop/README.md`, `docs/SPEC.md`

- [ ] Remove the `compaction.zig` row from the README file table (the file no longer exists, so no inline tests, no documentation row needed). If there is a corresponding row, delete it; otherwise no change.
- [ ] Add a worktree row to the SPEC.md in-progress table:
  ```
  | `2026-08-14-migrate-compaction-into-workflow-commpact.md` | Worktree branch | `worktree/migrate-compaction-into-workflow-commpact` — moves remaining `compaction.zig` exports (`CallCompactAgentInput`, `callCompactAgent`, `noopStreamCallbackNew`) into the orchestrator file `workflow_commpact_message.zig` (3 m's); `compaction.zig` deleted. |
  ```

**Verify:** `rg 'compaction\.zig' docs/SPEC.md` returns zero matches (the new row doesn't reference the deleted file by name).

### Task 6: Build + full test suite

**Files:** none — verification only

- [ ] Run `zig build test --summary all` from the worktree root. Expected: **2338 / 2344 pass (6 skip)** — identical to `main` baseline.
- [ ] Confirm no orphan references to the deleted file:
  ```
  rg -n 'compaction\.zig|compaction_mod' src/
  ```
  Expected: zero matches outside documentation comments that mention the old name in past-tense context. Specifically: `workflow_compact_message.zig:6` (`compaction.zig::buildCompactMessagePrompt`) and `:21` (`compaction.zig — that file owns the agent.Agent lifecycle`) are in the file's docstring and need to be updated to reflect that `compaction.zig` is gone — change both to `workflow_commpact_message.zig`.
- [ ] Confirm `workflow_commpact_message.zig`'s inline tests still pass (the existing 30 from `workflow_compact_message.zig` plus the mock-state tests in the orchestrator file).

### Task 7: Commit + push + open PR

**Files:** none — git workflow

- [ ] `git add -A` and commit with the message:
  ```
  refactor(compaction): migrate remaining compaction.zig exports into workflow_commpact_message.zig
  ```
- [ ] Push the branch: `git push -u origin worktree/migrate-compaction-into-workflow-commpact`.
- [ ] Open a PR against `main` with a body summarising the move.
- [ ] Move the kanban task to `in_review_task` column.

**Verify:** PR exists on GitHub and the kanban task is in `in_review_task`.

## Pitfalls

- **`prompt` import missing.** `callCompactAgent` references `prompt.CompactionAgent` (Zig 0.16's agent prompt module). The orchestrator file does NOT currently import `prompt` — only `agent`. Task 1 adds `const prompt = pabrikcore.agent.prompt;` to fix this.
- **Doc comment reference in `workflow_compact_message.zig`.** That file's docstring still says "compaction.zig owns the agent.Agent lifecycle" (line 21). After this round's move, that statement is stale — Task 6 catches the stale reference and rewrites the docstring to point at `workflow_commpact_message.zig`.
- **`workflow_compact_call_agent_test.zig` doc comments.** Lines 5 and 233 reference `compaction.zig` as the home of `callCompactAgent`. After this round, that's no longer true. Task 3 updates the references (low risk, but grep `rg 'compaction\.zig' src/ai_workflow/tui/agentic_loop/workflow_compact_call_agent_test.zig` should return zero after Task 3 — the test file uses `compaction.zig` only in past-tense commentary).
- **`noopStreamCallbackNew` visibility.** It's `fn` (private) in the original `compaction.zig`. Keep it private in the new home too — it's only used by `callCompactAgent` inside the same file.
- **Mock infrastructure coupling.** `mockCallCompactAgent` references `CallCompactAgentInput`. Both live in the same file after this round, so the comptime fn-pointer signature stays trivially compatible — no `@import` indirection.

## Verification

- [ ] Plan saved to `docs/superpowers/plans/2026-08-14-migrate-compaction-into-workflow-commpact.md`
- [ ] `CallCompactAgentInput`, `callCompactAgent`, `noopStreamCallbackNew` live in `workflow_commpact_message.zig`
- [ ] `compaction.zig` deleted
- [ ] `workflow.zig` re-exports the moved names from the new home
- [ ] `workflow_compact_call_agent_test.zig` import path updated
- [ ] `README.md` + `SPEC.md` updated
- [ ] `zig build test --summary all` passes with same totals as `main`
- [ ] PR opened against `main`
- [ ] Kanban task moved to `in_review_task`
