# Flatten `src/ai_workflow/tui/` into `agentic_loop/` + Inline Tests

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every top-level `.zig` file under `src/ai_workflow/tui/` into the existing `src/ai_workflow/tui/agentic_loop/` directory, and convert each companion `<name>_test.zig` into an inline `test "..."` block at the bottom of its impl file — matching the convention already documented in `agentic_loop/README.md`. After this refactor, `src/ai_workflow/tui/` contains only the two entry-point files: `mod.zig` (re-exports) and `test_runner.zig` (test discovery).

**Architecture:** Three orthogonal moves:

1. **Move** — relocate each `.zig` from `src/ai_workflow/tui/<file>.zig` to `src/ai_workflow/tui/agentic_loop/<file>.zig`. Re-export from a new `agentic_loop/mod.zig` so the public `nalarcore.ai_mod.<symbol>` API surface stays identical.
2. **Inline** — for every `<file>_test.zig` that tests a file being moved, append its `test "..."` blocks to the bottom of `<file>.zig` and delete the separate test file. Register the impl file in `agentic_loop/test_runner.zig` so `zig build test` discovers the inline tests.
3. **Repoint imports** — replace every `@import("../<file>.zig")` and `@import("../../<file>.zig")` inside `agentic_loop/*.zig` with the bare filename; the files now sit in the same directory. Update external call sites in `src/root.zig`, `src/modules/agent/tools/*_test.zig`, `src/ai_workflow/tui/http_handlers/*_test.zig` (any string literal `LLM_HISTORY_PATH`, `DESIGN_MODEL_PATH`, `ON_EVENT_SENT_PATH`, etc.) to the new path.

The split into phases below follows dependency order (no file in a phase imports a file moved in a later phase), so each phase produces a green build + green test suite before the next phase starts.

**Tech Stack:** Zig 0.16 (test discovery requires direct `@import` registration), SQLite (in-memory `:memory:` test fixture pattern from `is_session_kanban.zig`), `zig build test --summary all` as the regression gate.

## Global Constraints

- **Test discovery is opt-in.** Zig 0.16 only auto-discovers `test "..."` blocks in files that are **directly `@import`ed** by the test runner's `test { ... }` block. Every file that gains inline tests MUST be added to `agentic_loop/test_runner.zig` in the same commit that adds the tests, or the tests will silently never run (the `is_session_kanban.zig` 6a6bea58 ship-without-`test_runner` bug).
- **Backward-compat re-exports.** `tui/mod.zig` re-exports 14 symbols (`models`, `http_handlers`, `ai_workflow`, `llm_history`, `on_event_sent`, `on_event_sent_kanban`, `on_event_design`, `on_event_sent_design`, `show_preview`, `generate_image`, `get_design_context`, `preview_design_page`, `active_loops`, `routines`, `startup`, `kanban_model`, `design_io`, `design_model`, plus the legacy aliases `workspace_items`, `workspace_item_tasks`, `registerSessionClient`, etc.). All of these MUST keep working under their existing `nalarcore.ai_mod.<symbol>` path. The plan accomplishes this by switching `tui/mod.zig` to import from `agentic_loop/mod.zig` instead of from local files.
- **No behavior changes.** This refactor moves bytes around — it does NOT fix bugs, add features, or rename any function/struct. Test assertions stay identical.
- **Path constants in static-contract tests.** Some test files use `const LLM_HISTORY_PATH = "src/ai_workflow/tui/llm_history.zig";` literals to grep the source under test (e.g. `http_handlers/task_create_test.zig:36`, `http_handlers/tasks_list_test.zig:36`). These MUST be updated to the new path in the same commit as the file move. A grep for the old path must return zero hits at the end of each phase.
- **No new commits mid-phase.** Each phase produces one commit. Don't leave the build red between phases — if you have to break it, revert.
- **Skill: `dispatching-parallel-agents` is applicable** — Phases 4, 5, 6 (kanban, llm_history, design_model) each have 3-5 independent test files that can be inlined in parallel by sub-agents. See the per-phase "Parallel execution" notes.
- **`zig build test --summary all` is the gate.** Every phase must end with a clean run. Same baseline as pre-refactor (~2264 pass, 6 skip, 0 fail per the recent changes log).

## File Inventory

Top-level files under `src/ai_workflow/tui/` that move (40 total, ~26,311 lines):

### Impl files (move + re-export)
| File | Lines | Tests to inline | External `@import` sites |
|---|---:|---|---|
| `ActiveLoops.zig` | 31 | (none — struct only) | `models.zig:7` |
| `agent_memories.zig` | 480 | `agent_memories_test.zig` (375 lines) | `root.zig:549` (legacy alias) |
| `background_process.zig` | 198 | (none) | none |
| `design_io.zig` | 497 | `design_io_test.zig` (229 lines) | `design_model.zig:35`, `mod.zig:19` |
| `design_model.zig` | 6055 | 7 test files (≈2,800 lines total: `design_model_test.zig`, `design_model_parent_id_test.zig`, `design_model_group_test.zig`, `design_model_delete_parent_test.zig`, `design_model_delete_page_test.zig`, `design_model_add_element_parent_test.zig`, `design_model_set_element_parent_test.zig`, `design_model_reorder_test.zig`) | `mod.zig:20`, `modules/agent/tools/*_test.zig` (8 sites), `http_handlers/design_elements_*.zig` |
| `inherited_context.zig` | 239 | `inherited_context_test.zig` (420 lines) | `mod.zig:?`, `modules/agent/tools/spawn_sub_agent.zig:7` |
| `kanban_model.zig` | 662 | 3 test files (≈1005 lines total: `kanban_model_test.zig`, `kanban_model_test_description.zig`, `kanban_copy_spec_test.zig`) | `mod.zig:18`, `http_handlers/http_response.zig` |
| `llm_history.zig` | 6030 | 8 test files (≈2,300 lines total: `llm_history_is_input_output_test.zig`, `llm_history_compacted_messages_test.zig`, `llm_history_search_messages_fts_test.zig`, `llm_history_search_fts_query_safety_test.zig`, `llm_history_worker_info_test.zig`, `llm_history_description_test.zig`, `llm_history_notification_test.zig`, `llm_history_tool_call_loading_test.zig`) | `mod.zig:6`, `root.zig:542-551` (8 aliases), `agentic_loop/workflow.zig:6`, `agentic_loop/workflow_compact_message.zig:45`, `agentic_loop/workflow_commpact_message.zig:16-17`, `agentic_loop/handle_tool.zig:9`, `agentic_loop/prompts_make_design_context.zig:4`, `agentic_loop/prompts_build_messages_for_agent_prompt.zig:5`, `agentic_loop/workflow_compaction_envelope_test.zig:6`, 9 `http_handlers/*_test.zig` (path constants) |
| `models.zig` | 53 | (none — re-export of ActiveLoops) | `llm_history.zig:8`, `on_event_sent.zig:6`, `agentic_loop/prompts_build_messages_for_agent_prompt.zig:9` |
| `on_event_design.zig` | 95 | (none) | `mod.zig:9` |
| `on_event_sent.zig` | 684 | `on_event_sent_sanitize_test.zig` (212 lines) | `mod.zig:7`, `agentic_loop/workflow.zig:9` |
| `on_event_sent_design.zig` | 200 | `on_event_sent_design_test.zig` (138 lines) | `mod.zig:10`, `apps/desktop/src/api/index.ts` (SSE comments), `apps/desktop/src/__tests__/unifiedSseBuffer.spec.ts` |
| `on_event_sent_kanban.zig` | 163 | (none) | `mod.zig:8`, `apps/desktop/src/api/index.ts` (SSE comments) |
| `save_agent.zig` | 50 | `save_agent_test.zig` (7 lines — placeholder, just delete the test file) | none (test imports it directly) |
| `save_skill.zig` | 142 | `save_skill_test.zig` (55 lines) | none (test imports it directly) |
| `startup.zig` | 50 | (none) | `mod.zig:17`, `main.zig:139` (via `ai_mod.startup`) |

### Test-only files (no impl in `tui/`)
| File | Lines | Real impl | Disposition |
|---|---:|---|---|
| `extract_base64_image_urls_test.zig` | 766 | `src/helpers/image.zig:6` | Move to `src/helpers/image_test.zig` (NOT into `agentic_loop/`) — it tests a helper, not the agentic loop. Add inline test block to `helpers/image.zig` instead. |
| `migration_057_test.zig` | 183 | `src/migrations/migration_*.zig` | Move to `src/migrations/migration_057_test.zig` (it lives there conceptually — the migrations module's own `test_runner.zig:43` already imports it via `../ai_workflow/tui/migration_057_test.zig`; flip the path) |
| `migration_063_runtime_test.zig` | 210 | `src/migrations/migration_063.zig` | Move to `src/migrations/migration_063_runtime_test.zig` |
| `compaction_config_threshold_test.zig` | 227 | `src/ai_workflow/tui/agentic_loop/workflow_compact_message.zig` (via `LlmConfig.compactionThresholdPercent`) | Inline at the bottom of `agentic_loop/workflow_compact_message.zig`. This file already imports from `nalarcore.llm_models` + `nalarcore.config` so no path changes needed beyond the `@import` in the bottom of `workflow_compact_message.zig`. |
| `compaction_long_context_test.zig` | 132 | `agentic_loop/workflow.zig` (the `runLoop` path) | Inline at the bottom of `agentic_loop/workflow.zig` — keep it next to the function it exercises. |
| `gitignore_vendor_sqlite3_test.zig` | 134 | `build.zig` (vendor sqlite3 fetch) | Delete (per comment in `test_runner.zig:136`, this is a meta-test of build.zig behavior; it can move to a top-level `tests/` dir or be deleted if redundant) |
| `session_update_test.zig` | 175 | `llm_history.zig` (session update helpers) | Inline at the bottom of `agentic_loop/llm_history.zig` (after Phase 5) |
| `update_activity_test.zig` | 175 | `src/modules/agent/tools/update_activity.zig` | Move to `src/modules/agent/tools/update_activity_test.zig` |
| `workspace_items_update_name_test.zig` | 160 | `llm_history.zig` (`updateWorkspaceItemName` or similar) | Inline at the bottom of `agentic_loop/llm_history.zig` |

### Stay at `src/ai_workflow/tui/` (entry points)
| File | Why |
|---|---|
| `mod.zig` | Re-export surface for `nalarcore.ai_mod.*`. Re-point each `@import` to `agentic_loop/<file>.zig`. |
| `test_runner.zig` | Top-level test discovery for everything under `tui/`. After this refactor it imports (a) `agentic_loop/test_runner.zig` (which discovers all inline tests in the new home) and (b) a few stragglers that live outside `agentic_loop/`. |

### Subdirs (untouched)
- `agentic_loop/` — already the destination.
- `http_handlers/` — its own concern, no move.
- `routines/` — its own concern, no move.

## Phase Plan Overview

8 phases, each a self-contained commit. After each phase: `zig build test --summary all` must report `0 fail`. Test count baseline is ~2264 / 6 skip / 0 fail (per recent changes log).

- [ ] **Phase 0** — Baseline + create `agentic_loop/mod.zig` skeleton
- [ ] **Phase 1** — Leaf files: `ActiveLoops.zig`, `models.zig`, `background_process.zig`, `save_agent.zig`, `save_skill.zig`, `startup.zig`
- [ ] **Phase 2** — Event handlers: `on_event_sent.zig`, `on_event_design.zig`, `on_event_sent_design.zig`, `on_event_sent_kanban.zig` + inline `on_event_sent_sanitize_test.zig` + `on_event_sent_design_test.zig`
- [ ] **Phase 3** — Agent helpers: `inherited_context.zig`, `agent_memories.zig` + inline their test files
- [ ] **Phase 4** — Mid-size data models: `kanban_model.zig`, `design_io.zig` + inline test files (≈5 inline blocks)
- [ ] **Phase 5** — `llm_history.zig` (6030 lines, 8 test files) — **largest phase**
- [ ] **Phase 6** — `design_model.zig` (6055 lines, 9 test files) — **tied for largest**
- [ ] **Phase 7** — Orphan test files: `extract_base64_image_urls_test.zig`, `migration_*_test.zig`, `gitignore_vendor_sqlite3_test.zig`, `session_update_test.zig`, `update_activity_test.zig`, `workspace_items_update_name_test.zig`, `compaction_*_test.zig`
- [ ] **Phase 8** — Cleanup: update `agentic_loop/README.md`, `tui/mod.zig` final pass, delete `tui/test_runner.zig`'s now-stale lines

---

## Phase 0 — Baseline + `agentic_loop/mod.zig` skeleton

**Goal:** Establish the green-test baseline that every subsequent phase must preserve, and create the new `agentic_loop/mod.zig` re-export surface (initially empty / a no-op) so subsequent phases can fill it incrementally.

- [ ] **0.1** Capture baseline.
  - Run `timeout 300 zig build test --summary all 2>&1 | tail -n 20` from `/home/ginwa/ginwaaitoolbox`.
  - Save the test count + skip count to a sticky: write `mem_<random>` with tags `refactor||baseline` containing the exact line `phase 0 baseline: <N> pass, <M> skip, 0 fail`.
  - If the baseline already shows failures, **STOP and report to the user** — do not refactor on a broken baseline.
- [ ] **0.2** Create `src/ai_workflow/tui/agentic_loop/mod.zig`:
  ```zig
  //! Re-exports for the `agentic_loop/` directory.
  //!
  //! Tests in this directory use inline `test "..." { ... }` blocks at the
  //! bottom of each impl file (NOT separate `<file>_test.zig` files) — see
  //! README.md and `agentic_loop/test_runner.zig` for the discovery
  //! convention.

  // Phase 0 — placeholder. Each subsequent phase adds the moved files
  // here as `pub const <symbol> = @import("<file>.zig");`.
  ```
- [ ] **0.3** No `tui/mod.zig` change yet — that's Phase 1. Verify `zig build test --summary all` still passes (it should — the new `mod.zig` is unused so far).
- [ ] **0.4** Commit: `chore(refactor): add agentic_loop/mod.zig skeleton (phase 0 of tui flatten)`.

**Verification:**
- `zig build test --summary all` — same pass/skip/fail counts as step 0.1.
- `ls src/ai_workflow/tui/agentic_loop/mod.zig` exists.

---

## Phase 1 — Leaf files (no test files or trivial test merges)

**Goal:** Move the 6 files that have no dependencies on other files being moved. Update `tui/mod.zig` imports and the `models.zig → ActiveLoops` import.

Files in this phase (6 impl + 2 trivial tests):

- [ ] **1.1** `git mv src/ai_workflow/tui/ActiveLoops.zig src/ai_workflow/tui/agentic_loop/ActiveLoops.zig`
- [ ] **1.2** `git mv src/ai_workflow/tui/models.zig src/ai_workflow/tui/agentic_loop/models.zig` and fix its internal import:
  - Old: `pub const ActiveLoops = @import("ActiveLoops.zig").ActiveLoops;`
  - New: `pub const ActiveLoops = @import("ActiveLoops.zig").ActiveLoops;` (no change — they're now in the same dir).
- [ ] **1.3** `git mv src/ai_workflow/tui/background_process.zig src/ai_workflow/tui/agentic_loop/background_process.zig`
- [ ] **1.4** `git mv src/ai_workflow/tui/save_agent.zig src/ai_workflow/tui/agentic_loop/save_agent.zig`
  - **Inline test:** Append the 1 `test "..."` block from `save_agent_test.zig` (after translating its `const save_agent = @import("save_agent.zig");` import — which becomes redundant inside the same file). `save_agent_test.zig` is 229 bytes and contains one test stub; delete the test file.
- [ ] **1.5** `git mv src/ai_workflow/tui/save_skill.zig src/ai_workflow/tui/agentic_loop/save_skill.zig`
  - **Inline test:** Append all `test "..."` blocks from `save_skill_test.zig` (55 lines, multiple `test "save_skill ..."` blocks) to the bottom of `save_skill.zig`. Strip the `const llm_history = @import("llm_history.zig");` import line — `save_skill.zig` already imports what it needs. Delete `save_skill_test.zig`.
- [ ] **1.6** `git mv src/ai_workflow/tui/startup.zig src/ai_workflow/tui/agentic_loop/startup.zig`
- [ ] **1.7** Update `src/ai_workflow/tui/agentic_loop/mod.zig` to re-export the new arrivals:
  ```zig
  pub const ActiveLoops = @import("ActiveLoops.zig").ActiveLoops;
  pub const models = @import("models.zig");
  pub const background_process = @import("background_process.zig");
  pub const save_agent = @import("save_agent.zig");
  pub const save_skill = @import("save_skill.zig");
  pub const startup = @import("startup.zig");
  ```
- [ ] **1.8** Update `src/ai_workflow/tui/mod.zig` — replace each `@import("<file>.zig")` with `@import("agentic_loop/mod.zig").<symbol>` (or directly `@import("agentic_loop/<file>.zig")` if cleaner). Specifically:
  - `pub const models = @import("models.zig");` → `pub const models = @import("agentic_loop/models.zig");`
  - `pub const active_loops = @import("ActiveLoops.zig").ActiveLoops;` → `pub const active_loops = @import("agentic_loop/ActiveLoops.zig").ActiveLoops;`
  - `pub const startup = @import("startup.zig");` → `pub const startup = @import("agentic_loop/startup.zig");`
  - Verify `main.zig` still compiles: `main.zig:139` does `ai_mod.startup.start(...)` — `ai_mod` is `nalarcore.ai_mod` = `src/ai_workflow/tui/mod.zig`, so the path change propagates transitively.
- [ ] **1.9** Register the new inline-test-bearing files in `src/ai_workflow/tui/agentic_loop/test_runner.zig`:
  ```zig
  _ = @import("save_agent.zig");
  _ = @import("save_skill.zig");
  ```
- [ ] **1.10** Update `src/ai_workflow/tui/test_runner.zig`:
  - Remove `_ = @import("save_agent_test.zig");` (line 8)
  - Remove `_ = @import("save_skill_test.zig");` (line 9)
- [ ] **1.11** Run `timeout 300 zig build test --summary all` and confirm:
  - Same pass count as baseline (delta 0).
  - `save_agent.zig` and `save_skill.zig` appear in the test output (grep `.zig-cache/o/*/test` for `agentic_loop.save_`).
- [ ] **1.12** Commit: `refactor(tui): move leaf files into agentic_loop/ (phase 1: ActiveLoops, models, background_process, save_agent, save_skill, startup)`.

**Verification:**
- `git status` — only the expected moves + `mod.zig` edits + 2 test-file deletions. No stray untracked files.
- `rg "src/ai_workflow/tui/(ActiveLoops|models|background_process|save_agent|save_skill|startup)\.zig" src/` returns ZERO hits (other than in `mod.zig` of `tui/` itself, which now points to `agentic_loop/<file>`).
- `zig build test --summary all` — pass count matches baseline.

---

## Phase 2 — Event handlers (`on_event_*`)

**Goal:** Move the 4 event-handler files + inline their 2 test files. Update `workflow.zig`'s relative import.

Files in this phase (4 impl + 2 tests):

- [ ] **2.1** `git mv src/ai_workflow/tui/on_event_sent.zig src/ai_workflow/tui/agentic_loop/on_event_sent.zig`
  - Fix internal import: `const models = @import("models.zig");` already correct (siblings in new location).
- [ ] **2.2** `git mv src/ai_workflow/tui/on_event_design.zig src/ai_workflow/tui/agentic_loop/on_event_design.zig`
- [ ] **2.3** `git mv src/ai_workflow/tui/on_event_sent_design.zig src/ai_workflow/tui/agentic_loop/on_event_sent_design.zig`
- [ ] **2.4** `git mv src/ai_workflow/tui/on_event_sent_kanban.zig src/ai_workflow/tui/agentic_loop/on_event_sent_kanban.zig`
- [ ] **2.5** **Inline `on_event_sent_sanitize_test.zig` (212 lines, 3+ tests) into `on_event_sent.zig`:**
  - Open `on_event_sent_sanitize_test.zig` — it imports `const on_event_sent = @import("on_event_sent.zig");` and calls e.g. `try on_event_sent.sanitizeContent(...)` or whatever the function is.
  - Append each `test "..." { ... }` block to the bottom of `on_event_sent.zig`.
  - Strip the `const on_event_sent = @import(...)` line — it's now redundant.
  - Delete the standalone test file.
- [ ] **2.6** **Inline `on_event_sent_design_test.zig` (138 lines, ~3 tests) into `on_event_sent_design.zig`** — same pattern.
- [ ] **2.7** Update `src/ai_workflow/tui/agentic_loop/mod.zig`:
  ```zig
  pub const on_event_sent = @import("on_event_sent.zig");
  pub const on_event_design = @import("on_event_design.zig");
  pub const on_event_sent_design = @import("on_event_sent_design.zig");
  pub const on_event_sent_kanban = @import("on_event_sent_kanban.zig");
  ```
- [ ] **2.8** Update `src/ai_workflow/tui/mod.zig` — replace 4 `@import("on_event_*.zig")` lines with `agentic_loop/...`.
- [ ] **2.9** **Critical:** `src/ai_workflow/tui/agentic_loop/workflow.zig:9` does:
  ```zig
  pub const on_event_sent = @import("../on_event_sent.zig");
  ```
  After the move, this becomes:
  ```zig
  pub const on_event_sent = @import("on_event_sent.zig");
  ```
  Same for any other relative imports from this file. Grep first:
  ```
  rg -n "@import\(\"\.\./" src/ai_workflow/tui/agentic_loop/
  ```
  Each `@import("../<file>.zig")` → `@import("<file>.zig")` (only if `<file>.zig` is in the moved-in set; otherwise leave alone).
- [ ] **2.10** Register inline-test files in `agentic_loop/test_runner.zig`:
  ```zig
  _ = @import("on_event_sent.zig");
  _ = @import("on_event_sent_design.zig");
  ```
- [ ] **2.11** Update `src/ai_workflow/tui/test_runner.zig`:
  - Remove `_ = @import("on_event_sent_sanitize_test.zig");` (line 134)
  - Remove `_ = @import("on_event_sent_design_test.zig");` (line 135)
- [ ] **2.12** Run `zig build test --summary all` and confirm:
  - New tests appear (search for `agentic_loop.on_event_sent.test.sanitize*`).
  - Pass count delta = +N (where N = tests inlined from the 2 deleted files).
  - 0 failures.
- [ ] **2.13** Commit: `refactor(tui): move on_event_* into agentic_loop/ + inline sanitize + design tests (phase 2)`.

**Verification:**
- `rg "on_event_sent\.zig|on_event_design\.zig|on_event_sent_design\.zig|on_event_sent_kanban\.zig" src/ai_workflow/tui/mod.zig` shows all paths prefixed `agentic_loop/`.
- `rg "@import\(\"\.\./on_event" src/ai_workflow/tui/agentic_loop/` returns 0 hits.
- `zig build test --summary all` — pass count = baseline + tests inlined.

---

## Phase 3 — Agent helpers (`inherited_context.zig`, `agent_memories.zig`)

**Goal:** Move 2 medium-sized files + inline their test files. Update `root.zig` legacy alias and the `spawn_sub_agent.zig` tool's relative import.

Files in this phase (2 impl + 2 tests):

- [ ] **3.1** `git mv src/ai_workflow/tui/inherited_context.zig src/ai_workflow/tui/agentic_loop/inherited_context.zig`
- [ ] **3.2** **Inline `inherited_context_test.zig` (420 lines) into `inherited_context.zig`** — append all `test "..."` blocks. Strip the `const ic = @import("inherited_context.zig");` import line. Delete the test file.
- [ ] **3.3** `git mv src/ai_workflow/tui/agent_memories.zig src/ai_workflow/tui/agentic_loop/agent_memories.zig`
  - Fix internal import: `const llm_history = @import("llm_history.zig");` — keep as-is, `llm_history.zig` is still at `tui/`. **This will break in Phase 5** when `llm_history.zig` itself moves. Acceptable: we touch it again in 5.x.
- [ ] **3.4** **Inline `agent_memories_test.zig` (375 lines) into `agent_memories.zig`** — append all `test "..."` blocks. Strip the `const agent_memories = @import("agent_memories.zig");` import line. Delete the test file.
- [ ] **3.5** Update `src/ai_workflow/tui/agentic_loop/mod.zig`:
  ```zig
  pub const inherited_context = @import("inherited_context.zig");
  pub const agent_memories = @import("agent_memories.zig");
  ```
- [ ] **3.6** Update `src/ai_workflow/tui/mod.zig`:
  - Currently `mod.zig` does NOT import `inherited_context.zig` directly (it's reached via `ai_mod.ai_workflow.workflow` chain — see Phase 5). Skip the `mod.zig` line. **Verify** by `rg "inherited_context" src/ai_workflow/tui/mod.zig` → expect 0 hits.
  - `agent_memories` — check `mod.zig`. If `mod.zig` doesn't reference it, skip. `root.zig:549` does `pub const agent_memories = @import("ai_workflow/tui/agent_memories.zig");` — update to `pub const agent_memories = @import("ai_workflow/tui/agentic_loop/agent_memories.zig");`.
- [ ] **3.7** **Critical:** `src/modules/agent/tools/spawn_sub_agent.zig:7` does:
  ```zig
  const inherited_context_helper = @import("../../../ai_workflow/tui/inherited_context.zig");
  ```
  Update to `../../../ai_workflow/tui/agentic_loop/inherited_context.zig`.
- [ ] **3.8** Register inline-test files in `agentic_loop/test_runner.zig`:
  ```zig
  _ = @import("inherited_context.zig");
  _ = @import("agent_memories.zig");
  ```
- [ ] **3.9** Update `src/ai_workflow/tui/test_runner.zig`:
  - Remove `_ = @import("inherited_context_test.zig");` (line 3)
  - Remove `_ = @import("agent_memories_test.zig");` (line 148)
- [ ] **3.10** Run `zig build test --summary all` — pass count delta = tests inlined, 0 fail.
- [ ] **3.11** Commit: `refactor(tui): move inherited_context + agent_memories into agentic_loop/ + inline tests (phase 3)`.

**Verification:**
- `rg "inherited_context\.zig|agent_memories\.zig" src/` — all paths outside `tui/agentic_loop/` should be `agentic_loop/inherited_context.zig` or `agentic_loop/agent_memories.zig`. Zero hits at the old path.
- `zig build test --summary all` — green.

---

## Phase 4 — Mid-size data models (`kanban_model.zig`, `design_io.zig`)

**Goal:** Move `kanban_model.zig` (662 lines) + 3 test files, and `design_io.zig` (497 lines) + 1 test file. Total ~2,400 lines moved.

**Parallel execution:** The two impl files are independent (`kanban_model.zig` does not import `design_io.zig` or vice versa). The 4 test files are also independent. Consider dispatching 4 sub-agents:
- Sub-agent A: move + inline kanban_model + its 3 tests
- Sub-agent B: move + inline design_io + its 1 test
Then a final sequential step merges their `mod.zig` + `test_runner.zig` edits.

If you split the work, **each sub-agent must commit to its own branch** and you merge them after both pass `zig build test` independently.

Files in this phase (2 impl + 4 tests):

- [ ] **4.1** `git mv src/ai_workflow/tui/kanban_model.zig src/ai_workflow/tui/agentic_loop/kanban_model.zig`
- [ ] **4.2** **Inline `kanban_model_test.zig` (480 lines) into `kanban_model.zig`** — append all `test "..."` blocks. Strip the `const kanban = @import("kanban_model.zig");` import. Delete the standalone file.
- [ ] **4.3** **Inline `kanban_model_test_description.zig` (238 lines) into `kanban_model.zig`** — append after the previous inlined tests. Strip the `const kanban_model = @import("kanban_model.zig");` import. Delete.
- [ ] **4.4** **Inline `kanban_copy_spec_test.zig` (287 lines) into `kanban_model.zig`** — append. Strip the `const kanban_model = @import("kanban_model.zig");` import + the `const DESIGN_MODEL_PATH = "src/ai_workflow/tui/design_model.zig";` (Phase 6 will update this string — leave as-is for now and add a `// TODO(phase-6): update to agentic_loop/design_model.zig` comment).
- [ ] **4.5** `git mv src/ai_workflow/tui/design_io.zig src/ai_workflow/tui/agentic_loop/design_io.zig`
- [ ] **4.6** **Inline `design_io_test.zig` (229 lines) into `design_io.zig`** — append. Strip the `const design_io = @import("design_io.zig");` import. Delete.
- [ ] **4.7** Update `src/ai_workflow/tui/agentic_loop/mod.zig`:
  ```zig
  pub const kanban_model = @import("kanban_model.zig");
  pub const design_io = @import("design_io.zig");
  ```
- [ ] **4.8** Update `src/ai_workflow/tui/mod.zig`:
  - `pub const kanban_model = @import("kanban_model.zig");` → `pub const kanban_model = @import("agentic_loop/kanban_model.zig");`
  - `pub const design_io = @import("design_io.zig");` → `pub const design_io = @import("agentic_loop/design_io.zig");`
- [ ] **4.9** **Critical:** `src/ai_workflow/tui/agentic_loop/agentic_loop/design_model.zig:35` does `const design_io = @import("design_io.zig");` — no change needed yet (Phase 6).
- [ ] **4.10** **Critical:** `src/ai_workflow/tui/http_handlers/http_response.zig` references `src/ai_workflow/tui/kanban_model.zig` in a doc comment (lines 13, 808). Update those comment strings to `agentic_loop/kanban_model.zig`. Same for `src/migrations/migration_072_test.zig:157` which references `src/ai_workflow/tui/kanban_model.zig:306` in a comment.
- [ ] **4.11** Register inline-test files in `agentic_loop/test_runner.zig`:
  ```zig
  _ = @import("kanban_model.zig");
  _ = @import("design_io.zig");
  ```
- [ ] **4.12** Update `src/ai_workflow/tui/test_runner.zig`:
  - Remove `_ = @import("kanban_model_test.zig");` (line 72)
  - Remove `_ = @import("kanban_model_test_description.zig");` (line 73)
  - Remove `_ = @import("kanban_copy_spec_test.zig");` (line 74)
  - Remove `_ = @import("design_io_test.zig");` (line 52)
- [ ] **4.13** Run `zig build test --summary all`. Pass count delta = ~30 tests (kanban has many, design_io has fewer). 0 fail.
- [ ] **4.14** Commit: `refactor(tui): move kanban_model + design_io into agentic_loop/ + inline tests (phase 4)`.

**Verification:**
- `rg "src/ai_workflow/tui/(kanban_model|design_io)\.zig" src/` — returns 0 hits at the old path (except in doc comments, which Phase 4.10 fixed).
- `zig build test --summary all` — green.

---

## Phase 5 — `llm_history.zig` (6030 lines, 8 test files)

**Goal:** Move the largest file in `tui/`. Touches the most call sites (8 `root.zig` aliases, 7 `agentic_loop/` files, 9 `http_handlers/` test paths).

Files in this phase (1 impl + 9 tests — 8 inline + 1 standalone delete):

- [ ] **5.1** `git mv src/ai_workflow/tui/llm_history.zig src/ai_workflow/tui/agentic_loop/llm_history.zig`
  - **Conflict check:** there is ALREADY an `agentic_loop/llm_history.zig` (190 lines, defines `LLMHistory` struct). The `tui/llm_history.zig` (6030 lines) is a different file. The `git mv` will overwrite the small one with the big one.
  - **Step to avoid data loss:** BEFORE the move, read the small `agentic_loop/llm_history.zig` carefully — its `LLMHistory` struct + 4 inline tests. The big `tui/llm_history.zig` already imports `TUIHistory` from `models.zig` but does NOT use `LLMHistory` (the small file's struct). After the move, the small file's struct is lost.
  - **Resolution:** the small `agentic_loop/llm_history.zig` exists as a sibling module because of how the existing agentic_loop was structured. Its `LLMHistory` struct IS used by `agentic_loop/insert_llm_histories.zig`, `agentic_loop/get_llm_histories.zig`, `agentic_loop/parsing.zig`, and `agentic_loop/workflow.zig` (re-exported at line 67: `pub const LLMHistory = @import("llm_history.zig").LLMHistory;`).
  - **Plan:** the `LLMHistory` struct and its 4 inline tests must be preserved. After the move, the new `agentic_loop/llm_history.zig` (the big one) MUST re-export the struct OR contain it. **Recommended:** rename the small struct's file to `agentic_loop/llm_history_row.zig` BEFORE the move, then update its 4 callers:
    - `agentic_loop/insert_llm_histories.zig:3`: `const LLMHistory = @import("llm_history.zig").LLMHistory;` → `const LLMHistory = @import("llm_history_row.zig").LLMHistory;`
    - `agentic_loop/get_llm_histories.zig:3`: same swap
    - `agentic_loop/parsing.zig:4`: same swap
    - `agentic_loop/workflow.zig:67`: `pub const LLMHistory = @import("llm_history.zig").LLMHistory;` → `pub const LLMHistory = @import("llm_history_row.zig").LLMHistory;`
    - Then `agentic_loop/llm_history.zig` is free for the big file's `git mv` to land in.
  - Register `agentic_loop/llm_history_row.zig` in `agentic_loop/test_runner.zig`.
  - Document this in the commit message: `BREAKING: agentic_loop.LLMHistory now in agentic_loop/llm_history_row.zig`.
- [ ] **5.2** **Inline 8 test files into the new `agentic_loop/llm_history.zig`** (in this order, to match the existing test_runner ordering):
  1. `llm_history_is_input_output_test.zig` (175 lines)
  2. `llm_history_compacted_messages_test.zig` (495 lines)
  3. `llm_history_search_messages_fts_test.zig` (424 lines)
  4. `llm_history_search_fts_query_safety_test.zig` (182 lines)
  5. `llm_history_worker_info_test.zig` (237 lines)
  6. `llm_history_description_test.zig` (164 lines)
  7. `llm_history_notification_test.zig` (370 lines)
  8. `llm_history_tool_call_loading_test.zig` (247 lines)
  For each: append `test "..." { ... }` blocks; strip the `const llm_history = @import("llm_history.zig");` import; delete the file.
  - **Watch out:** `llm_history_search_messages_fts_test.zig` and `llm_history_compacted_messages_test.zig` use `const LLM_HISTORY_PATH = "src/ai_workflow/tui/llm_history.zig";` for static-contract assertions (grep the source for column names). Update those constants to `"src/ai_workflow/tui/agentic_loop/llm_history.zig"` as you go.
- [ ] **5.3** Update internal imports inside `agentic_loop/llm_history.zig`:
  - `const TUIHistory = @import("models.zig").TUIHistory;` → keep (Phase 1 already moved `models.zig`).
  - `const ai_mod = @import("mod.zig");` → `const ai_mod = @import("../mod.zig");` — this points UP to the `tui/mod.zig` which still works. Or break the cycle by inlining: `ai_mod.on_event_sent` → `const on_event_sent = @import("on_event_sent.zig");` (which is in the same dir after Phase 2). **Use the latter — avoid `../` references.**
- [ ] **5.4** Update `src/ai_workflow/tui/agentic_loop/mod.zig`:
  ```zig
  pub const llm_history = @import("llm_history.zig");
  pub const llm_history_row = @import("llm_history_row.zig");
  ```
- [ ] **5.5** Update `src/ai_workflow/tui/mod.zig`:
  - `pub const llm_history = @import("llm_history.zig");` → `pub const llm_history = @import("agentic_loop/llm_history.zig");`
- [ ] **5.6** **Critical — `src/root.zig`** (lines 542-551) — 8 legacy aliases point to `ai_workflow/tui/llm_history.zig`:
  ```
  pub const kerjabot_get_session = @import("ai_workflow/tui/llm_history.zig");
  pub const kerjabot_create_session = @import("ai_workflow/tui/llm_history.zig");
  pub const kerjabot_get_list_session = @import("ai_workflow/tui/llm_history.zig");
  pub const tui_check_session_exists = @import("ai_workflow/tui/llm_history.zig");
  pub const session_helpers = @import("ai_workflow/tui/llm_history.zig");
  pub const session_db = @import("ai_workflow/tui/llm_history.zig");
  pub const llm_history = @import("ai_workflow/tui/llm_history.zig");
  pub const workspace_items = @import("ai_workflow/tui/llm_history.zig");
  pub const workspace_item_tasks = @import("ai_workflow/tui/llm_history.zig");
  ```
  Replace each path with `ai_workflow/tui/agentic_loop/llm_history.zig`. Also `pub const agent_memories = @import("ai_workflow/tui/agent_memories.zig");` (line 549) → `agentic_loop/agent_memories.zig` (Phase 3 moved it).
- [ ] **5.7** **Critical — update 7 `agentic_loop/*.zig` files** that currently do `@import("../llm_history.zig")`:
  - `src/ai_workflow/tui/agentic_loop/workflow.zig:6`
  - `src/ai_workflow/tui/agentic_loop/workflow_compact_message.zig:45`
  - `src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig:16-17`
  - `src/ai_workflow/tui/agentic_loop/handle_tool.zig:9`
  - `src/ai_workflow/tui/agentic_loop/prompts_make_design_context.zig:4`
  - `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig:5`
  - `src/ai_workflow/tui/agentic_loop/workflow_compaction_envelope_test.zig:6`
  - All change `@import("../llm_history.zig")` → `@import("llm_history.zig")`.
  - Verify with `rg "@import\(\"\.\./llm_history\." src/ai_workflow/tui/agentic_loop/` returns 0 hits.
- [ ] **5.8** **Critical — update `LLM_HISTORY_PATH` constants in 9 `http_handlers/*_test.zig` files** (grep to find):
  ```
  rg -l "LLM_HISTORY_PATH = \"src/ai_workflow/tui/llm_history" src/ai_workflow/tui/http_handlers/
  ```
  Update each to `"src/ai_workflow/tui/agentic_loop/llm_history.zig"`.
- [ ] **5.9** **Critical — update `src/ai_workflow/tui/http_handlers/tasks_reorder_pinned_test.zig:25`, `task_pin_test.zig:20`, `task_delete_test.zig:36`, `tasks_list_test.zig:36`, `task_create_description_test.zig:22`, `task_update_test.zig:43`, `workspace_items_reorder_test.zig:24`** — same `LLM_HISTORY_PATH` constant update.
- [ ] **5.10** **Critical — `src/migrations/migration.zig:1107`** has a comment referencing `src/ai_workflow/tui/llm_history.zig:1861`. Update to the new path.
- [ ] **5.11** **Critical — `src/helpers/mod.zig:493`** has a comment referencing `src/ai_workflow/tui/llm_history.zig (#unixMillisNow)`. Update.
- [ ] **5.12** **Critical — `src/modules/agent/tools/text_replace.zig:9`** has a doc comment `Mirrors src/ai_workflow/tui/llm_history.zig xmlEscape exactly so the ...`. Update.
- [ ] **5.13** Register inline-test file in `agentic_loop/test_runner.zig`:
  ```zig
  _ = @import("llm_history.zig");
  ```
- [ ] **5.14** Update `src/ai_workflow/tui/test_runner.zig`:
  - Remove 8 `_ = @import("llm_history_*_test.zig");` lines (40, 41, 42, 43, 44, 45, 46, 47).
- [ ] **5.15** Run `zig build test --summary all`. Pass count delta ≈ +30-50 tests (8 test files × ~5 tests each). 0 fail.
- [ ] **5.16** Commit: `refactor(tui): move llm_history into agentic_loop/ + inline 8 test files (phase 5)`.

**Verification:**
- `rg "src/ai_workflow/tui/llm_history\.zig" src/` — returns 0 hits at the OLD path. Only the NEW `agentic_loop/llm_history.zig` should appear.
- `rg "@import\(\"\.\./llm_history\." src/ai_workflow/tui/agentic_loop/` returns 0 hits.
- `zig build test --summary all` — green.

---

## Phase 6 — `design_model.zig` (6055 lines, 9 test files)

**Goal:** Move the largest file. Touches 8 `modules/agent/tools/*_test.zig` path constants and the `http_handlers/design_elements_*` chain.

Files in this phase (1 impl + 9 tests):

- [ ] **6.1** `git mv src/ai_workflow/tui/design_model.zig src/ai_workflow/tui/agentic_loop/design_model.zig`
  - Internal imports to verify:
    - `const design_io = @import("design_io.zig");` — keep, sibling in new location.
- [ ] **6.2** **Inline 9 test files into `agentic_loop/design_model.zig`** (preserve ordering):
  1. `design_model_test.zig` (720 lines, the largest)
  2. `design_model_parent_id_test.zig` (432 lines)
  3. `design_model_group_test.zig` (625 lines — contains a static-contract test for `groupElements z_index = min_z - 1`)
  4. `design_model_delete_parent_test.zig` (266 lines)
  5. `design_model_delete_page_test.zig` (467 lines)
  6. `design_model_add_element_parent_test.zig` (319 lines)
  7. `design_model_set_element_parent_test.zig` (289 lines)
  8. `design_model_reorder_test.zig` (290 lines)
  9. **MISSING:** if you find a `design_model_resize_test.zig` or similar in the file list, add it. Check `ls src/ai_workflow/tui/design_model_*_test.zig` to confirm the full list.
  For each: append `test "..." { ... }` blocks; strip the `const design_model = @import("design_model.zig");` import + the `const DESIGN_MODEL_PATH = "src/ai_workflow/tui/design_model.zig";` constant — update to `"src/ai_workflow/tui/agentic_loop/design_model.zig"` if used in static-contract grep assertions.
- [ ] **6.3** Update `src/ai_workflow/tui/agentic_loop/mod.zig`:
  ```zig
  pub const design_model = @import("design_model.zig");
  ```
- [ ] **6.4** Update `src/ai_workflow/tui/mod.zig`:
  - `pub const design_model = @import("design_model.zig");` → `pub const design_model = @import("agentic_loop/design_model.zig");`
- [ ] **6.5** **Critical — update 8 `src/modules/agent/tools/*_test.zig` files** that do `@import("../../../ai_workflow/tui/design_model.zig")`:
  - `preview_design_page_test.zig:21`
  - `get_design_context_test.zig:20`
  - `set_element_parent_test.zig:23`
  - `move_design_element_test.zig:22`
  - `group_design_elements_test.zig:22`
  - `update_design_element_test.zig:17`
  - `set_design_page_test.zig:19`
  - `add_design_element_test.zig:17`
  - All change `ai_workflow/tui/design_model.zig` → `ai_workflow/tui/agentic_loop/design_model.zig`.
- [ ] **6.6** **Critical — update `http_handlers/design_elements_*.zig` source files** (not test files) that do `@import("design_model.zig")` from a sibling. Verify with:
  ```
  rg -n "@import\(\"\.\./design_model\." src/ai_workflow/tui/http_handlers/
  ```
  If found, change `../design_model.zig` → `../../agentic_loop/design_model.zig`.
- [ ] **6.7** **Critical — frontend comment paths** — `src/apps/desktop/src/api/index.ts:175,1843,3028,3077` and `src/apps/desktop/src/__tests__/unifiedSseBuffer.spec.ts:602` reference `src/ai_workflow/tui/design_model.zig` and `src/ai_workflow/tui/on_event_sent_design.zig` in JS/TS doc comments. Update those string literals (these don't affect runtime, but `rg` should return 0 hits at the old paths to confirm cleanup).
- [ ] **6.8** Register inline-test file in `agentic_loop/test_runner.zig`:
  ```zig
  _ = @import("design_model.zig");
  ```
- [ ] **6.9** Update `src/ai_workflow/tui/test_runner.zig`:
  - Remove 9 `_ = @import("design_model_*_test.zig");` lines (53, 54, 55, 56, 57, 58, 59, 60 — and remove the inline-test reference at line 63).
- [ ] **6.10** Run `zig build test --summary all`. Pass count delta ≈ +60-80 tests. 0 fail.
- [ ] **6.11** Commit: `refactor(tui): move design_model into agentic_loop/ + inline 9 test files (phase 6)`.

**Verification:**
- `rg "src/ai_workflow/tui/design_model\.zig" src/` — 0 hits at the old path.
- `zig build test --summary all` — green.

---

## Phase 7 — Orphan test files (move out of `tui/` or inline where appropriate)

**Goal:** Handle the 9 test-only files in `tui/` whose impl is elsewhere.

- [ ] **7.1** `extract_base64_image_urls_test.zig` (766 lines, tests `helpers.image.extractBase64ImageUrls`)
  - **Decision:** the impl `src/helpers/image.zig` is not in `agentic_loop/`. The test file is misplaced.
  - **Action:** Move to `src/helpers/image_test.zig`. Inline the tests as `test "..." { ... }` blocks at the bottom of `src/helpers/image.zig`. Delete the standalone file from `tui/`.
  - Register `src/helpers/image.zig` for test discovery — find the appropriate test_runner (likely `src/helpers/test_runner.zig` if it exists, otherwise add to `src/root.zig`'s top-level `test` block).
- [ ] **7.2** `migration_057_test.zig` (183 lines)
  - **Action:** `git mv src/ai_workflow/tui/migration_057_test.zig src/migrations/migration_057_test.zig`. Update `src/migrations/test_runner.zig:43` from `@import("../ai_workflow/tui/migration_057_test.zig")` → `@import("migration_057_test.zig")`.
- [ ] **7.3** `migration_063_runtime_test.zig` (210 lines)
  - **Action:** `git mv src/ai_workflow/tui/migration_063_runtime_test.zig src/migrations/migration_063_runtime_test.zig`. Add `_ = @import("migration_063_runtime_test.zig");` to `src/migrations/test_runner.zig`.
- [ ] **7.4** `compaction_config_threshold_test.zig` (227 lines, tests `LlmConfig.compactionThresholdPercent`)
  - **Decision:** the impl lives in `nalarcore.config.LlmConfig` (config module). Tests belong there or next to the agentic_loop workflow that consumes them.
  - **Action:** Inline the tests at the bottom of `src/ai_workflow/tui/agentic_loop/workflow_compact_message.zig` (the file that calls `compactionThresholdPercent`). Strip the standalone imports — the file already has `nalarcore.config.LlmConfig.LlmProfile` available. Delete the standalone test file.
  - **Add to `agentic_loop/test_runner.zig`:** the new tests are in `workflow_compact_message.zig` which is already imported.
- [ ] **7.5** `compaction_long_context_test.zig` (132 lines, tests `runLoop` compaction path)
  - **Action:** Inline at the bottom of `src/ai_workflow/tui/agentic_loop/workflow.zig`. Strip the `const llm_history = @import("llm_history.zig");` import (already available in `workflow.zig`). Delete the standalone test file.
  - `workflow.zig` is already in `agentic_loop/test_runner.zig`, so no registration needed.
- [ ] **7.6** `gitignore_vendor_sqlite3_test.zig` (134 lines, tests `build.zig` behavior)
  - **Decision:** not an agentic_loop concern. Either move to a top-level `build_tests/` dir OR delete (per the test_runner.zig comment it's a meta-test).
  - **Action (default):** delete. If the user wants to preserve, move to `tests/build_vendor_sqlite3_test.zig` and wire it into `src/root.zig`'s top-level `test` block. **Ask the user.**
- [ ] **7.7** `session_update_test.zig` (175 lines, tests session update helpers in `llm_history.zig`)
  - **Action:** Inline at the bottom of `src/ai_workflow/tui/agentic_loop/llm_history.zig` (already registered in `agentic_loop/test_runner.zig` via Phase 5). Strip imports. Delete the standalone file.
- [ ] **7.8** `update_activity_test.zig` (175 lines, tests `modules/agent/tools/update_activity.zig`)
  - **Action:** `git mv src/ai_workflow/tui/update_activity_test.zig src/modules/agent/tools/update_activity_test.zig`. Find `src/modules/agent/test_runner.zig` and add `_ = @import("update_activity_test.zig");`.
- [ ] **7.9** `workspace_items_update_name_test.zig` (160 lines, tests `llm_history.zig` workspace name update)
  - **Action:** Inline at the bottom of `src/ai_workflow/tui/agentic_loop/llm_history.zig`. Strip imports. Delete the standalone file.
- [ ] **7.10** Update `src/ai_workflow/tui/test_runner.zig`:
  - Remove `_ = @import("compaction_config_threshold_test.zig");` (line 16)
  - Remove `_ = @import("compaction_long_context_test.zig");` (line 48)
  - Remove `_ = @import("gitignore_vendor_sqlite3_test.zig");` (line 136)
  - Remove `_ = @import("session_update_test.zig");` (line 131)
  - Remove `_ = @import("update_activity_test.zig");` (line 149)
  - Remove `_ = @import("workspace_items_update_name_test.zig");` (line 81)
  - The line `_ = @import("extract_base64_image_urls_test.zig");` is already commented out (line 143 — disabled). Nothing to do.
- [ ] **7.11** Run `zig build test --summary all`. Pass count delta = tests inlined into `llm_history.zig` + `workflow.zig` + `workflow_compact_message.zig`. 0 fail.
- [ ] **7.12** Commit: `refactor(tui): relocate orphan test files (phase 7: extract_base64, migration_*, compaction_*, session_update, update_activity, workspace_items_update_name, gitignore_vendor_sqlite3)`.

**Verification:**
- `ls src/ai_workflow/tui/*.zig` returns only `mod.zig` + `test_runner.zig` (and the 3 subdirectories).
- `zig build test --summary all` — green.

---

## Phase 8 — Cleanup + README

**Goal:** Final polish. Update `agentic_loop/README.md` to reflect the new layout. Verify no stale paths remain.

- [ ] **8.1** Run final invariant grep:
  ```
  rg "src/ai_workflow/tui/[a-z_]+\.zig" src/ --type zig --type-add 'zig:*.zig'
  ```
  Expected output: ONLY references to `mod.zig`, `test_runner.zig`, and `agentic_loop/*.zig`, `http_handlers/*.zig`, `routines/*.zig`. ZERO references to moved files at the old top-level paths.
- [ ] **8.2** Run final invariant grep for HTML/TS comment drift:
  ```
  rg "src/ai_workflow/tui/(llm_history|on_event_sent|design_model|kanban_model|inherited_context|agent_memories|save_agent|save_skill|startup|ActiveLoops|models|background_process)\.zig" src/ --type-add 'all:*.{zig,ts,tsx,js,jsx,html,md}'
  ```
  Expected: 0 hits (Phase 5.10-5.12, 6.7 cleaned these up).
- [ ] **8.3** Update `src/ai_workflow/tui/agentic_loop/README.md`:
  - Append to the file table: rows for each moved file (ActiveLoops, agent_memories, background_process, design_io, design_model, inherited_context, kanban_model, llm_history, llm_history_row, models, on_event_*, save_*, startup).
  - Update the "Total" line at the bottom with the new test count.
  - Add a "Phase history" section: "Files in this directory were consolidated from `src/ai_workflow/tui/` as part of the tui-flatten refactor (2026-08-14). Before the move, top-level files in `tui/` were split between agent-loop plumbing and sibling concerns (design, kanban, llm_history); the move brings all of them under the agentic_loop/ umbrella and aligns their test convention."
- [ ] **8.4** Update `src/ai_workflow/tui/mod.zig` — final pass:
  - Add a one-line header comment:
    ```zig
    //! Thin re-export surface for the `nalar_core.ai_mod.*` API.
    //!
    //! As of 2026-08-14, all implementation files live under
    //! `agentic_loop/`; this `mod.zig` re-exports them so existing
    //! `nalarcore.ai_mod.<symbol>` call sites keep working unchanged.
    ```
  - Replace each `@import("agentic_loop/<file>.zig")` (added in Phases 1-6) with `@import("agentic_loop/mod.zig").<symbol>` for consistency with how `ai_mod.ai_workflow` is wired. (Or keep the direct imports — both work. **Decision:** use `agentic_loop/mod.zig` indirection so adding a new file to `agentic_loop/` doesn't require touching `tui/mod.zig`.)
- [ ] **8.5** Final run: `zig build test --summary all`. Pass count should match `phase 0 baseline + sum(phases 1-7 test deltas)`. 0 fail.
- [ ] **8.6** Manual smoke test:
  ```
  timeout 60 zig build 2>&1 | tail -n 20
  ```
  Confirm clean build. (Don't run the full server — this is just compile.)
- [ ] **8.7** Commit: `docs(refactor): update agentic_loop/README + tui/mod.zig after tui flatten (phase 8)`.

**Verification:**
- `tree src/ai_workflow/tui/ -L 2` shows ONLY: `mod.zig`, `test_runner.zig`, `agentic_loop/`, `http_handlers/`, `routines/`.
- `ls src/ai_workflow/tui/agentic_loop/*.zig | wc -l` ≥ 95 (was 87 before, +8 net for `llm_history_row` rename, ~+20 net from moves).
- `zig build test --summary all` — pass count = expected baseline + deltas, 0 fail.

---

## Risks & Mitigations

- **Test count drift:** If `zig build test --summary all` reports a different pass count than `phase 0 baseline + deltas`, the most likely cause is a missed `_ = @import(...)` registration in `agentic_loop/test_runner.zig`. Run:
  ```
  TEST_BIN=$(find .zig-cache/o -name test -type f -executable | tail -n 1 | cut -d: -f1)
  "$TEST_BIN" 2>&1 | rg 'agentic_loop\.([a-z_]+)\.test\.' | sort -u > /tmp/discovered_tests.txt
  wc -l /tmp/discovered_tests.txt
  ```
  Cross-check against the expected list in `agentic_loop/README.md`. Add missing `@import`s.
- **Circular `@import("../mod.zig")`:** the existing `tui/llm_history.zig` had `const ai_mod = @import("mod.zig");` — this only worked because `mod.zig` is the parent. After Phase 5, this becomes `const ai_mod = @import("../mod.zig");` (works) OR break the cycle (preferred, see Phase 5.3). If Zig's compile-time cycle detector trips, fall back to the `../mod.zig` form.
- **Static-contract tests with path constants:** Phase 5.2 and Phase 6.2 call out the path constants that need updating as part of the inline. Miss one and the test will still compile but assert on the wrong file. A grep for the old path at the end of each phase is the catch.
- **Hidden `agent_memories.zig` reference in `root.zig`:** Phase 5.6 covers this — but if `root.zig` is rebuilt and the alias fails, the entire binary fails to link. Verify the binary compiles (`zig build`) BEFORE running tests in Phase 5.
- **`extract_base64_image_urls_test.zig` is currently disabled** (`_ = @import("extract_base64_image_urls_test.zig"); // DISABLED` at `test_runner.zig:143`). Don't try to re-enable it — Phase 7.1 just moves the file. Re-enable is a separate task.

## Verification (final, run after Phase 8)

- [ ] `zig build test --summary all` — pass count = expected baseline + deltas. 0 fail.
- [ ] `tree src/ai_workflow/tui/ -L 2` shows ONLY: `mod.zig`, `test_runner.zig`, `agentic_loop/`, `http_handlers/`, `routines/`.
- [ ] `rg "src/ai_workflow/tui/[a-z_]+\.zig" src/ --type zig` — only `mod.zig`, `test_runner.zig`, `agentic_loop/`, `http_handlers/`, `routines/` paths.
- [ ] No separate `<file>_test.zig` files at `src/ai_workflow/tui/` top level. All inline tests live at the bottom of their impl file in `agentic_loop/`.
- [ ] `agentic_loop/README.md` documents all moved files.
- [ ] User has reviewed the plan before execution begins (per writing-plans skill).