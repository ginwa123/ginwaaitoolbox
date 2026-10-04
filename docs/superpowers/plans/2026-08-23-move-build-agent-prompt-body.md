# Plan: Move `build_agent_prompt` body into `prompts_build_messages_for_agent_prompt.zig`

**Task:** task_1787504320295_0 ("refactor code" — move `build_agent_prompt` logic into the orchestrator-side prompt-assembly file)
**Date:** 2026-08-23
**Status:** PLANNED — awaiting human review. No code written yet.

---

## 1. Problem statement

`src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig:166` invokes
`prompt.build_agent_prompt(...)` to assemble the orchestrator's main system prompt. That callee
lives in `src/modules/agent/prompts.zig:299-502` and is 200+ lines of prompt-assembly code.

The user wants that body moved into `prompts_build_messages_for_agent_prompt.zig` as a new helper
so the orchestrator-side assembly (skills, memory, tools, agent config, sub-agent listing, workspace
context, kanban status, design status, plus all the static section loops) lives in **one place** —
the file that *calls* it. After the move, the call at line 166 collapses to a single helper
invocation, and `prompts.zig` becomes a thin re-export module instead of the de-facto assembly
orchestrator.

Why this matters today: every time a new section lands (plan content, agent knowledge, agent system
prompt, current plan, inherited history, etc.) the edit requires opening **two files** and threading
one more positional `[]const u8` parameter through every caller of `build_agent_prompt`. After the
move, only **one** file owns the rendering and only **one** place needs the new section hook.

---

## 2. Current architecture (verified by direct file reads)

### 2.1 The call site

`src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig:166`:

```zig
const systemContent = try prompt.build_agent_prompt(
    allocator,
    io,
    cwd,
    skills,
    memoryMd,
    "",                              // backgroundProcessContent — always empty
    agentUsed,                       // activeAgentContent
    filtered_tools,
    activity_info,                   // always "" today (commented-out makeActivityInfo)
    environment,                     // di.environment
    sub_agents_listing,
    workspaceContext,
    kanbanStatusContent,
    designStatusContent,
);
```

All 13 arguments are already `[]const u8` / `[]const AgentTool` / `?*const std.process.Environ.Map` slices — the
caller does the DB / IO work; the callee renders markdown into a single `[]u8`.

### 2.2 The callee (the body we'd move)

`src/modules/agent/prompts.zig:299-502` defines `pub fn build_agent_prompt(...)` as a single fat
function body. Internally it uses these helpers, **all already defined in `prompts.zig` itself**:

| Symbol               | File:line                     | Visibility  | Purpose                                                       |
| -------------------- | ----------------------------- | ----------- | ------------------------------------------------------------- |
| `PROMPT_SECTIONS`    | `prompts.zig:87-130`          | `const`     | Data-driven list of static section markdown + tool gates     |
| `PromptSection`      | `prompts.zig:66-70`           | `const`     | Row type used by `PROMPT_SECTIONS`                            |
| `hasTool`            | `prompts.zig:133-138`         | `fn`        | Tool-name lookup helper                                       |
| `appendSection`      | `prompts.zig:51-58`           | `const`     | Skip-empty + `"\n\n"` separator writer                       |
| `getCurrentOs`       | `prompts.zig:10-22`           | `fn`        | Returns `"Linux"` / `"macOS"` / etc.                          |
| `loadGlobalKnowledge`| `prompts.zig:159-219`         | `pub fn`    | Reads `~/.config/pabrik/memories/*.md`, returns empty on err  |
| `loadLocalKnowledge` | `prompts.zig:221-268`         | `pub fn`    | Reads `<cwd>/.pabrik/memories/*.md`, returns empty on err      |
| `appendToolListing`  | `prompts.zig:512-532`         | `fn`        | Renders `## Available Tools` bullet list                      |
| `appendSkillsListing`| `prompts.zig:550-604`         | `fn`        | Renders `## Available Skills` (global + local paths)          |
| `SubAgentListingRow` | `prompts.zig:615-627`         | `pub const` | Row type for sub-agent listing                                |
| `appendSubAgentsListing` | `prompts.zig:652-701`     | `pub fn`    | Renders `## Available Sub-Agents`                              |

All used **only** by `build_agent_prompt` (verified by grepping the whole `src/` tree for each symbol
— zero external references). The only public visibility they need today is `pub` so unit tests in
`prompts_test.zig` can call them directly.

### 2.3 The wider prompt-assembly pipeline in `prompts_build_messages_for_agent_prompt.zig`

Section blocks the file already builds **outside** `build_agent_prompt`:

| Block                     | Line   | Built by (helpers in `workflow.zig`/`prompts_mod`)                                                                              |
| ------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `skills`                  | 83     | `agentic_loop.prompts_mod.makeSkillsEquippedContext`                                                                           |
| `memoryMd`                | 86     | `agentic_loop.prompts_mod.makeWorkingDirectoryContext`                                                                         |
| `agentUsed`               | 98-102 | `BuildDynamicAgentContent` OR `activeAgentContent` verbatim                                                                   |
| `activity_info`           | 108    | `""` literal (commented-out `makeActivityInfo` at line 106)                                                                   |
| `environment`             | 112-113| `di.environment`                                                                                                              |
| `sub_agents_listing`      | 120    | `BuildSubAgentsListing` (local in this file, lines 750-832)                                                                   |
| `workspaceContext`        | 127    | `agentic_loop.prompts_mod.makeWorkspaceContext`                                                                                |
| `agentKnowledgeContent`   | 134    | `agentic_loop.prompts_mod.makeAgentKnowledge`                                                                                  |
| `agentSystemPromptContent`| 142    | `agentic_loop.prompts_mod.makeAgentSystemPrompt`                                                                               |
| `filtered_tools`          | 153    | `filteringTools` (local, lines 859-904)                                                                                        |
| `kanbanStatusContent`     | 155    | `agentic_loop.prompts_mod.makeKanbanContext`                                                                                   |
| `designStatusContent`     | 163    | `buildDesignCanvasPrompt`                                                                                                     |

After `build_agent_prompt` returns at line 166, the file **still appends** these blocks into a
separate `final_system` ArrayList:

- `agentSystemPromptContent` (line 199-201) — persona-before-data injection from PR #294
- `agentKnowledgeContent` (line 205-207)
- `inherited_md` (line 208-211) — `inherited_context.formatHistory(...)`
- `planContent` (line 212-215) — `agentic_loop.prompts_mod.makePlanContext`

So the orchestrator-side file **already owns** the post-assembly ordering and four of the dynamic
sections. `build_agent_prompt` only owns the middle — it is structurally a peer of the
pre/post logic, not the owner.

### 2.4 Call-site blast radius (where `build_agent_prompt` is invoked today)

Verified by `rg 'prompt\.build_agent_prompt|prompts\.build_agent_prompt' src/`:

| Caller                                                    | Imports as               |
| --------------------------------------------------------- | ------------------------ |
| `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig:166` (1 call) | `prompt = pabrikcore.prompt` |
| `src/modules/agent/prompts_test.zig` — **22 calls** across the 1640+ test lines            | `prompts = @import("prompts.zig")` |

No other production or test code in the tree imports `build_agent_prompt`. The wire path is
narrow: one production caller + one in-module test file.

---

## 3. Goals and non-goals

### 3.1 Goals

1. The orchestrator-side prompt assembly lives in **one file**:
   `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig`.
2. `prompts.zig` stops being the de-facto assembly orchestrator. After the move it should not
   contain section rendering, tool-listing rendering, or any code that knows about
   `workspaceContext` / `kanbanStatusContent` / `designStatusContent` / `sub_agents_listing`.
3. All 22 existing tests in `prompts_test.zig` for `build_agent_prompt` **continue to pass
   unchanged in intent** — the test surface is preserved (possibly re-pointed to the new helper).
4. All 2,401+ existing `zig build test` cases **continue to pass** with no new failures.
5. The `zig build pabrik-desktop` chain **continues to succeed** (webapp / codegen paths unchanged).

### 3.2 Non-goals

- **No behavior change** in the rendered prompt markdown. The output bytes must be identical
  (modulo any pre-existing inconsistency) before and after the move.
- **No renaming** of the public `prompts.build_agent_prompt` symbol required by callers
  *outside this module tree*. Since no such callers exist today, the function can be deleted
  outright once moved; or kept as a thin re-export for one release — see §5.2.
- **No reorganization** of `prompts_test.zig`. Tests still live next to the agent module and
  remain scopable from `prompts_test.zig`.
- **No migration / schema / frontend / wire changes.**
- **No edits** to `make_sub_agent_prompt` (sub-agent flow) — out of scope; only `build_agent_prompt`
  (main flow) is in this task.

---

## 4. Design — where the body lands

### 4.1 Topology of "one file"

After the move, `prompts_build_messages_for_agent_prompt.zig` owns:

- The 8 helpers (`hasTool`, `appendSection`, `getCurrentOs`, `appendToolListing`,
  `appendSkillsListing`, `appendSubAgentsListing`, `loadGlobalKnowledge`, `loadLocalKnowledge`,
  plus `PROMPT_SECTIONS` data and `PromptSection` / `SubAgentListingRow` types).
- A new `build_agent_prompt(...)` function — verbatim the body of today's
  `prompts.zig:299-502` — that takes the same 13 parameters and returns `![]const u8`.
- The existing `buildMessages(...)` orchestrator that already calls into that function.

### 4.2 Why move the helpers too

The body uses those 8 helpers in deeply intertwined ways (e.g. `appendSection` for memory content,
`appendToolListing` for the tool list, `PROMPT_SECTIONS` for the static loop). Splitting them
across two files would force `prompts.zig` to keep exporting a battery of internal symbols just so
the orchestrator can use them. That would worsen the status quo, not improve it. The full move
treats `build_agent_prompt` as a self-contained rendering helper the way
`makeKanbanContext` / `makeWorkspaceContext` already are.

### 4.3 What stays in `prompts.zig`

The narrow set of static-content re-exports + the universal rules / prompt-template constants
that downstream code still consumes:

- `UniversalRules`, `PromptAutoFix`, `Agent`, `ParallelWork`, `Classification`, `Execution`,
  `Escalation`, `MemoryPrompt`, `PabrikMdAutoUpdate`, `GitPrompt`, `GlobalMemorySystem`,
  `LocalMemorySystem`, `CompactionAgent`, `GenerateSessionNameAgent`, `ResponseFormatting`,
  `UpdateActivityRule`, `SearchToolRule`, the legacy history tool rule, `MemoryToolRule` (`prompts.zig:25-43`).

These are **template strings**, not assembly code. They belong in `prompts.zig` (the agent
module's text-constants file) — moving them too would only renoise without simplifying.

### 4.4 Public API surface decisions

Two options for the moved function signature:

**Option A (recommended).** Define a new function with the same signature in
`prompts_build_messages_for_agent_prompt.zig` and **delete** the old one in `prompts.zig`.

Trade-off: simplest. Removes the duplicate entry point entirely. Slight churn in
`prompts_test.zig` (22 `prompts.build_agent_prompt(...)` calls — see §5.4).

**Option B.** Define a thin re-export `pub fn build_agent_prompt(...)` in `prompts.zig` that
delegates to the moved helper. Keeps the old call sites compiling unchanged.

Trade-off: zero churn for tests. But leaves a brittle indirection that everyone will need to
learn and that defeats the "one place" goal.

The user said "move code into this file" — that's option A. Plan A; option B is mentioned so
the human reviewer can override.

### 4.5 Header dependency footprint (what gets `@import`ed in the new helper file)

The new file `prompts_build_messages_for_agent_prompt.zig` already imports most of the needed
modules (verified by reading lines 1-67 of the file). The move only requires:

- `const builtin = @import("builtin");` (for `getCurrentOs`)
- `const prompts_const = @import("prompts/prompts.zig");` (for the universal-rules / prompt-template
  re-exports that `PROMPT_SECTIONS` references)
- `const memory_prompts = @import("prompts/memory.zig");` (for `memory_prompts.skills_system_prompt`)
- `const tool_models = pabrikcore.tool_models;` (already imported, line 10)
- `const tool_list_skills_mod = @import("tools/list_skills.zig");` (for `appendSkillsListing`)
- `const builtin = @import("builtin");` (already needed for `getCurrentOs` via a Zig builtin)

Two new `@import` lines, two pre-existing lines. Total file top grows by ~6 lines.

### 4.6 File size impact

- `prompts.zig`: 701 → ~50 lines (only the `prompts/prompts.zig` re-exports + section-template
  constants). Shrinks by ~650 lines.
- `prompts_build_messages_for_agent_prompt.zig`: 905 → ~1,210 lines. Grows by ~305 lines
  (the moved body + the 8 helper functions).

The orchestrator file is the file that already has the rest of the prompt-assembly pipeline; the
growth is a one-time hit that buys "one file = one place to read" forever after.

---

## 5. Implementation steps (in order)

> Each step is independently buildable + testable. Verification at every checkpoint.

### 5.1 Step 1 — Create a worktree

```
cd /home/ginwa/ginwaaitoolbox
zig build install:linux: --build-file build.zig 2>/dev/null || true  # for the cwd sanity check
git checkout -b worktree/move-build-agent-prompt-body
# OR use the conventional path:
# /home/ginwa/ginwaaitoolbox/.worktrees/move-build-agent-prompt-body
```

Branch default: `worktree/move-build-agent-prompt-body`. Use the `set_git_worktree` tool with
that path so subsequent bash/read/edit operations live in the worktree.

### 5.2 Step 2 — Move the body

Edits to **`prompts_build_messages_for_agent_prompt.zig` only**:

1. Add new `@import`s:
   - `const builtin = @import("builtin");`
   - `const prompts_const = @import("prompts/prompts.zig");` (or pick a non-clashing name)
   - `const memory_prompts = @import("prompts/memory.zig");`
   - `const tool_list_skills_mod = @import("tools/list_skills.zig");`

2. Append the 8 helpers + the data structures in **this exact order**, matching today's
   layout in `prompts.zig`:
   - `getCurrentOs` (line 10-22)
   - `appendSection` anonymous-struct pattern (line 51-58)
   - `PromptSection` (line 66-70)
   - `PROMPT_SECTIONS` (line 87-130) — references
     `UniversalRules / SearchToolRule / legacy history tool rule / MemoryToolRule / Agent / ParallelWork /
      Classification / Execution / Escalation / GitPrompt / UpdateActivityRule /
      memory_prompts.skills_system_prompt / ResponseFormatting` (all
      needed via the new `prompts_const` / `memory_prompts` imports)
   - `hasTool` (line 133-138)
   - `loadGlobalKnowledge` (line 159-219)
   - `loadLocalKnowledge` (line 221-268)
   - `build_agent_prompt` (line 299-502) — header comments preserved verbatim
   - `appendToolListing` (line 512-532)
   - `appendSkillsListing` (line 550-604)
   - `SubAgentListingRow` (line 615-627)
   - `appendSubAgentsListing` (line 652-701)

3. The moved `build_agent_prompt` references `agentic_loop.LLMHistory` indirectly via `tools`
   parameter (a `[]const tool_models.AgentTool`), no inner-workflow imports needed — keep the
   body byte-for-byte identical (no refactorings inside the function body itself).

4. The call at line 166 stays as-is — same argument list, same name. It now resolves to the
   local `build_agent_prompt` instead of `prompt.build_agent_prompt`.

### 5.3 Step 3 — Update `prompts.zig`

Delete:
- `fn getCurrentOs() []const u8 { ... }` (lines 10-22)
- `const appendSection = ...` (lines 51-58)
- `const PromptSection = struct { ... };` (lines 66-70)
- `const PROMPT_SECTIONS: []const PromptSection = &.{ ... };` (lines 87-130)
- `fn hasTool(...) bool { ... }` (lines 133-138)
- `pub fn loadGlobalKnowledge(...) {...}` (lines 159-219)
- `pub fn loadLocalKnowledge(...) {...}` (lines 221-268)
- `pub fn build_agent_prompt(...) {...}` (lines 299-502 — the giant one)
- `fn appendToolListing(...) {...}` (lines 512-532)
- `fn appendSkillsListing(...) {...}` (lines 550-604)
- `pub const SubAgentListingRow = struct {...};` (lines 615-627)
- `pub fn appendSubAgentsListing(...) {...}` (lines 652-701)

Keep: the 19 `pub const` re-exports of static template strings (lines 25-43).

Result: `prompts.zig` becomes a ~50-line module that only re-exports the prompt-template
constants. **No public symbols are lost** — every constant the function *used* remains
accessible (the function just no longer lives here).

### 5.4 Step 4 — Re-point test imports

`src/modules/agent/prompts_test.zig` contains 22 invocations of `prompts.build_agent_prompt(...)`.
Search-and-replace them all to `prompt_mod.build_agent_prompt(...)` where
`const prompt_mod = @import("../ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig");`
is a new top-of-file import.

**Important — parallel-import aliasing caveat.** The test file's existing
`const prompts = @import("prompts.zig");` line (line 2) stays — `prompts_test.zig` still needs
the helpers `prompts.loadGlobalKnowledge` / `prompts.loadLocalKnowledge` (35 callsites verified
at test lines 982-1445). Either:

  (a) Make the moved `loadGlobalKnowledge` and `loadLocalKnowledge` reachable via the **same**
      `prompts.zig` re-export path. Easiest path: keep them as `pub fn` re-exports in
      `prompts.zig` that delegate to the moved versions — i.e. option B **only for these two
      helpers**, not for `build_agent_prompt` itself.

  (b) Update each `prompts.loadGlobalKnowledge` call in the test to `prompt_mod.loadGlobalKnowledge`.

The simplest mechanical path is **(a)** — keep `prompts.zig` re-exporting the two helpers for
backward test compatibility, while every other internal helper (and `build_agent_prompt` itself)
moves cleanly to the orchestrator file. Zero churn in `prompts_test.zig` for `loadGlobalKnowledge`
/ `loadLocalKnowledge`; only the 22 `build_agent_prompt` calls move.

Plan **does (a)**. Cleanup of the delegating re-exports can be a follow-up card.

### 5.5 Step 5 — Run full verification battery (mandatory)

In this exact order. Each step's failure blocks the next:

```bash
# 1. Inline unit tests for the new home of the function.
zig build test --summary all
# Expected: 2401+ pass (existing), 0 new failures. The 22 build_agent_prompt
# tests in prompts_test.zig now call the orchestrator file's helper.

# 2. Static-contract grep on the new file (no orphan helpers in
#    prompts.zig; no extra @import('prompts.zig') inside the
#    orchestrator file — it imports `prompts/prompts.zig` directly
#    rather than the agent-module wrapper).
rg -n '^pub fn (build_agent_prompt|loadGlobalKnowledge|loadLocalKnowledge|appendToolListing|appendSkillsListing|appendSubAgentsListing)\b' \
    src/modules/agent/prompts.zig
# Expected: empty for build_agent_prompt, appendToolListing,
# appendSkillsListing, appendSubAgentsListing. OK to keep loadGlobalKnowledge
# and loadLocalKnowledge as thin re-exports per §5.4 (a).

rg -n '^pub fn build_agent_prompt\b' \
    src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig
# Expected: exactly 1 hit.

# 3. Frontend chain still compiles.
zig build pabrik-desktop --summary all
# Expected: 10/10 steps succeeded.

# 4. Behavior parity (manual prompt diff): a static snapshot test that
#    the rendered prompt bytes match the pre-move output for the same
#    inputs. Add a new assertion in prompts_test.zig that calls
#    `prompt_mod.build_agent_prompt(...)` and asserts a stable
#    substring from each rendered section. (Cheap regression —
#    ~30 lines of test code; protects against accidental re-ordering
#    during the move.)
```

**WARNING — DO NOT** spin up `pabrik --port 8080` + `curl` to verify (see the verification rule at
the top of `AGENTS.md`). Functional behavior is asserted through the Zig unit + static-contract
tests above.

### 5.6 Step 6 — Commit sequence (small commits per logical chunk)

Follow the repo's established commit pattern from prior refactor PRs (e.g. PR #215, PR #294):
one commit per atomic move, each with a self-contained message.

1. `refactor(prompts): move build_agent_prompt + helpers into orchestrator file`
2. `chore(prompts): drop moved helpers from prompts.zig` (only after step 1 compiles green)
3. `test(prompts_test): re-point build_agent_prompt calls to orchestrator module` (only after step 2)
4. `test(prompts_test): add prompt-byte regression assertion`

Push sequence so `zig build test` passes after **each** commit, not just at the end. Safer for
mid-PR review.

---

## 6. Backward compatibility & migration notes

- **No migration.** No schema, no DB, no wire format, no frontend change. This is a pure
  internal refactor.
- **No deprecation.** `build_agent_prompt` was an internal-only symbol (zero external callers
  outside `prompts_test.zig`), so removing it from `prompts.zig` does not require a deprecation
  window.
- **`loadGlobalKnowledge` / `loadLocalKnowledge`** stay re-exported from `prompts.zig` as thin
  delegations (per §5.4 (a)) so `prompts_test.zig`'s 35 helper-tests don't need churn. A follow-up
  card can clean those up.

---

## 7. Pitfalls and known failure modes (learned from past refactor PRs)

### 7.1 `@import("prompts.zig")` vs. `@import("prompts/prompts.zig")`

`prompts.zig` (the file we're trimming) and `prompts/prompts.zig` (the const-templates file)
are two different files. The orchestrator file will need to import the **inner**
`prompts/prompts.zig`, not the outer `prompts.zig`, to access `UniversalRules`, `Agent`, etc.
Forgetting this distinction breaks the build with "no member named 'Agent' in struct 'prompts'".

### 7.2 Test runner discovery (from PR #294 gotcha #1)

`zig build test` aggregates tests by walking the `tests/` tree. New `test "..."` blocks added
directly to `prompts_build_messages_for_agent_prompt.zig` (for the prompt-byte regression in
§5.5 / step 4) require Zig to pick them up automatically — they're in the same module so they
should be; but if a *new separate file* is added (e.g. `prompts_build_messages_for_agent_prompt_test.zig`),
make sure it's listed in `src/ai_workflow/tui/test_runner.zig` AND `src/root.zig` (`mod.zig`
re-export alone does NOT make inline tests discoverable — see PR #294 gotcha).

### 7.3 Don't rename `appendSection`

`appendSection` is an anonymous-struct-namespaced function (`const appendSection = struct { fn func(...) ... }.func`).
It's called 4 times inside the moved body. A naive rename to a regular `fn` would *work* but
changes its visibility trace. Keep the structure bit-for-bit.

### 7.4 `PROMPT_SECTIONS` is a `const` initialized `[]const PromptSection`

It must live next to `PromptSection` so the type is in scope. Don't try to split them across
files — Zig const-initialization requires the row type visible at parse time.

### 7.5 Arena allocator discipline (from AGENTS.md "Per-Request Arena Cleanup" rule)

The new helper's allocations all flow through `allocator: std.mem.Allocator` (the caller's
arena). Existing `defer allocator.free(local_knowledge)` / `defer allocator.free(knowledge)` lines
in the moved body are technically no-ops under the arena (will be auto-freed on request scope
end), but are HARMLESS because they target a non-arena-safe cleanup. **Keep them** for safety
under any future allocator swap (per the AGENTS.md rule). Don't "improve" them away.

### 7.6 Don't refactor inside the moved body

Discipline rule from AGENTS.md: this is a SURGICAL MOVE. The 200-line body must be copied
verbatim — including whitespace, comment blocks, variable names. Zero drive-by cleanups. A
byte-level diff of just the moved block must show 0 changes.

---

## 8. Verification — final acceptance

| Gate                                                    | Pass criterion                                                            |
| ------------------------------------------------------- | ------------------------------------------------------------------------- |
| `zig build test --summary all`                          | Same or higher pass count as `main` (currently 2401), 0 fail, 0 leak     |
| `zig build pabrik-desktop --summary all`                 | 10/10 steps green (no webapp / codegen regressions)                       |
| `rg '^pub fn build_agent_prompt\b' src/modules/agent/prompts.zig` | Zero matches — function moved out cleanly                            |
| `rg '^pub fn build_agent_prompt\b' src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig` | Exactly 1 match                                                         |
| `rg 'prompt\.build_agent_prompt\|prompts\.build_agent_prompt' src/` | All 22 hits in `prompts_test.zig` updated to `prompt_mod.build_agent_prompt`; the 1 hit in `prompts_build_messages_for_agent_prompt.zig` updated to bare `build_agent_prompt` (local) |
| Static regression test in `prompts_test.zig`            | A new `test "build_agent_prompt renders sections in expected order (regression after 2026-08-23 move)"` passes — asserts a stable substring per section in the expected order |
| `git log --oneline main..HEAD`                          | 4 atomic commits, each with `zig build test` green at the time of push   |

---

## 9. Open questions for the human reviewer

1. **Option A vs. Option B for `build_agent_prompt` public surface?** Plan recommends A (delete
   the old symbol). If you'd prefer the thin re-export indirection, swap to B — see §4.4.
2. **Keep `loadGlobalKnowledge` / `loadLocalKnowledge` re-exported from `prompts.zig`?** Plan
   says yes (zero churn for `prompts_test.zig`). If you'd rather clean them up in the same
   PR, the test edits are mechanical — add 20 minutes to the estimate.
3. **Workspace path.** The conventional path is
   `/home/ginwa/ginwaaitoolbox/.worktrees/move-build-agent-prompt-body`. Confirm before I
   switch cwd.
4. **Branch name.** `worktree/move-build-agent-prompt-body`. Confirm.

---

## 10. Files this plan touches

- **EDIT** `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig`
  — add helpers, add the body, line 166 stays as a bare-name call.
- **EDIT** `src/modules/agent/prompts.zig` — delete 12 helpers + `build_agent_prompt`; keep the
  19 const-template re-exports.
- **EDIT** `src/modules/agent/prompts_test.zig` — re-import + re-point 22 calls (or none, if §5.4
  (a) approved).
- **NEW** (optional) a `test "..."` block in either of the two files for the §8 prompt-byte
  regression. One small commit.

**No** other files. No routes, no migrations, no frontend, no Agent.zig, no workflow.zig, no
test_runner.zig (the moved helpers live inline; no new test files needed unless §8 regression
lives in its own file).
