# Agentic Loop (`runAgenticMultiStepnew`) Performance & Memory Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut CPU, SQLite work, disk I/O and peak memory of one agent turn by ~60–80% without changing a single byte of the LLM-visible prompt payload, the SSE wire, or the DB schema contract.

**Architecture:** `runAgenticMultiStepnew` (`src/ai_workflow/tui/agentic_loop/workflow.zig:412-1327`) runs one LLM turn per `while (true)` iteration. Today every iteration **re-derives the entire world from scratch**: the whole conversation is re-SELECTed and re-duped (≈27 heap slices/row), the whole ~150 KB system prompt is rebuilt (≈98 KB of `PABRIK.md`/`AGENTS.md` read from disk + ≈70 KB of `SKILL.MD` files read to print 2 KB of listings + ~130 SQLite round-trips), the tool table is duplicated twice, and the work heartbeat is written twice. The plan attacks the four places where work is **repeated instead of cached** or **materialised instead of streamed**, plus the two genuine leaks.

**Tech Stack:** Zig 0.16.0 (`/usr/bin/zig`, std at `/usr/lib/zig/std`), SQLite via `SqliteBackend` (`sqlite3_*`), `std.Io` (0.16 async I/O), Vue 3 frontend (untouched), pytest functional harness (`tests/functional/harness.py`).

---

## Global Constraints

1. **Do not change the LLM-visible bytes.** Prompt sections, ordering, and content must stay byte-identical unless the task explicitly says otherwise. Provider prefix-caching is a real cost — an accidental reordering of the "Available Skills" list silently invalidates it. Every prompt-caching task must add a "prompt is byte-identical" assertion test.
2. **Do not change the SSE event names or payload shapes** (`src/apps/desktop/src/api/index.ts` `additionalEventTypes` + named-event dispatch chain are one contract). Only *fewer* emissions, never renamed ones. `dual-write` rule applies if you ever add one.
3. **No DB schema break.** New indexes go through `src/modules/databases/.../migration.zig` as a new numbered migration; additive only.
4. **Zig 0.16 idioms only:** `std.ArrayList(T).empty` + explicit-allocator calls (`append(allocator, x)`), `std.Io` timestamp/clock APIs (`std.Io.Timestamp.now(io, .real).nanoseconds`), `std.Io.Dir.cwd()`, `rawFree`/`rawAlloc` for vtable work. There is no `std.fs.cwd()`, no `std.Thread.Mutex`.
5. **Arena discipline (project rule):** never `defer free` memory that came from a request/iteration arena. `defer` *is* required for non-memory resources (SQLite statement handles via `rows.deinit()`, fds, sockets).
6. **Test floors:** `zig build test --summary all` must keep `0 fail` and `0 leak`. `zig build pabrik-desktop --summary all` must stay `N/N steps succeeded`. Frontend untouched, so `pnpm test:unit` is a no-op check.
7. **Functional verification, not a live server.** Any HTTP/wire behaviour is verified with `tests/functional/` against an isolated tmpdir HOME; never `nohup ... --port 8080` + `curl`. (Port 8081 belongs to the user's running server — never kill it.)
8. **One commit per task.** Conventional message, `perf(agentic-loop): …` / `fix(agentic-loop): …`.
9. **Git worktree.** Execute this plan inside a worktree, e.g.
   `git worktree add ../worktrees_agent_perf -b worktree/agentic-loop-perf` — note this repo's `.git/config` has `core.bare = true`, so prefix git commands with `-c core.bare=false` (or `--work-tree=.`) when run from `/home/ginwa/ginwaaitoolbox`. Open a PR when Phase 1 + Phase 2 land, so a human can review before Phase 3/4 land. Do NOT `rm -rf` the shared working directory — sibling agents are working in it.
10. **Do not include unrelated sibling agents' in-flight edits** in your commits. `/home/ginwa/ginwaaitoolbox` is shared; `git status` before staging shows other tasks' modifications (`ChatView.vue`, `Agent.zig`, …). Stage explicitly by path.

---

## Verified Baseline (evidence)

All claims below were read out of the tree on 2026-09-11. `file:line` are the audit handles.

### Per iteration (the `while (true)` body, `workflow.zig:588-1316`)

| # | Cost | Where | Per-iteration |
|---|---|---|---|
| B1 | **Full conversation re-read + re-dupe** — 27 columns × 1 `allocator.dupe` per column per row, no `LIMIT`, `LEFT JOIN sessions`, no covering index | `get_llm_histories.zig:27-119` ← `workflow.zig:991` | O(H) rows, ≈27 allocs/row |
| B2 | **Full prompt rebuild** — 3 disk reads + ~130 SQL round-trips + 2 large concatenations | `prompts_build_messages_for_agent_prompt.zig:77` ← `workflow.zig:1028` | ≈150 KB + ≈130 queries (workspace-bound) |
| B2a | `getWorkspaceContext` implemented **4×** and called 4× per turn (2 of the 4 impls do a per-sibling-item N+1: 2 queries × ≤20 items) | `llm_history.zig:4089` (called by `pbfap:1222` + `prompts_make_design_context.zig:33`), `prompts_make_workspace_context.zig:101`, `prompts_make_kanban_context.zig:175` | 3+2N ×2, 3 ×1, 3+2N+1 ×1 |
| B2b | ~98 KB of `PABRIK.md` (49 193 B) + `AGENTS.md` (49 282 B) read every turn, each file opened **twice** (probe then read) | `prompts_make_working_directory_context.zig:29,39,47` | ≈98 KB read + ≥6 syscalls |
| B2c | ~70 KB of `SKILL.MD` files read (17 files, each opened+stat'd twice) to emit ≈2 KB of `- **name**: description` lines | `:1710` → `list_skills.zig:47` → `skills.zig:575,547-556,302-323` | ≈70 KB + ≥34 syscalls |
| B3 | **`equips()` called twice in one expression**, each `allocator.dupe`-ing the 34-tool comptime array (`tools_equipped.zig:65,116`) | `workflow.zig:1735` + `:1736` | 2 × 34-struct dupes + 3 `toOwnedSlice` |
| B4 | **Worker heartbeat twice** — each is 5 statements (SELECT 1; INSERT worker upsert; INSERT OR IGNORE sessions; UPDATE sessions; UPDATE workspace_item_tasks) + SSE | `touchCheckpointWorkers` `workflow.zig:594` and `updateWorker` `workflow.zig:781` → `update_worker.zig:42,72,100,105,112` | 10 write statements |
| B5 | **Two separate O(H) scans** of `db_messages` (max `total_tokens`, max `loop_index`) | `workflow.zig:998-1006` and `:1007-1016` | 2 × O(H) |
| B6 | **150 KB formatted into a debug log every turn**, even when DEBUG is filtered — `logFmt` runs `allocPrint` *before* the level check inside `log` | `workflow.zig:1041` → `Logger.zig:248-252` (`allocPrint` at :249, level check at :211) | ≈150 KB alloc + format |
| B7 | Per-message `std.json.parseFromSlice` inside `transformLLMHistoryToAgentMessage`, including for **plain assistant text** rows whose `tool_calls_json` is empty | `parsing.zig:40` (per audit) ← `pbfap` loop at `:266-271` | O(H) JSON parses |
| B8 | Tool-call args re-parsed purely to validate on every historical message when building the OpenAI body | `Agent.zig` `buildJsonOpenAIRequest` (≈:1666) | O(H) parses + discarded |

### Per streamed chunk

| # | Cost | Where |
|---|---|---|
| C1 | One `json.Value` parse + per-chunk JSON re-encode with `.whitespace = .indent_4`, `session_id` re-embedded, `event_bus.emit` called **twice**, one SSE event per chunk | `Agent.zig` parse/aggregate; `workflow.zig:1665-1722` `stream_callback`; `on_event_sent.zig:538-553,505-510,636,640` |
| C2 | **Process-global spinlock + `StringHashMap` lookup per delta**, buffers on `page_allocator`, never evicted | `stream_snapshot.zig:38-42,88-105` |

### Memory

| # | Verdict |
|---|---|
| M1 | **Per-iteration memory IS reclaimed to the parent arena** (not to the OS). `ArenaAllocator.deinit` (`/usr/lib/zig/std/heap/ArenaAllocator.zig:51-62`) `rawFree`s each node to the child allocator; `free` (:608-636) rewinds the child's bump cursor when the freed slice is its newest allocation. The child's nodes are allocated from the parent (`alloc` :520) and pushed LIFO (`tryPushNode`), so the parent rewinds fully. **RSS = max(per-iteration working set) + run-lifetime objects — it does NOT grow with iteration count.** So the memory problem is *peak working set*, not a per-iteration leak. |
| M2 | **The per-iteration arena leaks permanently if the parent allocates after it in the same iteration** — the parent's bump cursor no longer sits at the child node's end, `free` bails (`:620-623`), and the whole iteration is stranded for the run. Only in-loop parent allocations are the MCP refresh (`workflow.zig:640,646`) and the `McpCancelCtx` box (`:395`), so this fires on every mid-run MCP toggle. |
| M3 | **Latent cross-iteration use-after-rewind:** `last_retry_server_detail` (declared `workflow.zig:545`, assigned from the *per-iteration* arena at `:1065` via `callDynamicAgentNew`'s `out_last_error_message` dupe) is read at the top of the next iteration (`:890,:936,:938`) after the arena has been reused. Currently benign (parent-owned bytes stay mapped) — undefined behaviour in principle. |
| M4 | **3–4 simultaneous copies of the transcript** are alive at peak: `db_messages` (B1) → `initialMessages` (`:1028`) → `messagesLists` `appendSlice` (`:1030`) → JSON request body (`Agent.zig`). A 500-message history with tool results is MBs ×4. |
| M5 | `stream_snapshot` registry entries are **never freed**; each holds the full streamed content on `page_allocator`. Grows with number of sessions since boot. |
| M6 | `stream_callback` holds a process-global spinlock while appending — **cross-session contention**: N concurrent sessions serialise on it per token. |

### What is already fine (do not “fix”)

- MCP tools fetch-once cache (`workflow.zig:573-586`, in-loop invalidation `:639-647`) — one `tools/list` per boot/config-mutation.
- `maybeCompactMessagesNew`'s no-op path (`workflow_compact_message.zig:887-895`) — early `return false` *before* any copy/DB.
- `generateSessionNameNew` — correctly gated to `loop_counter == 1 && !is_task_kanban` (`workflow.zig:1018-1020`).
- The token accumulator is a geometric `std.ArrayList` (`Agent.zig` ≈:980) — not O(n²).
- `event_bus.emit` is a synchronous direct call — no queue, no unbounded growth.

### Metrics to move

| ID | Metric | Baseline procedure |
|---|---|---|
| M-1 | Wall time per iteration (`[CHECKPOINT] LLM responded … duration_ms`) p50/p95 over a scripted 30-turn tool-heavy session | Phase 0 harness |
| M-2 | Peak RSS of the `pabrik` process at end of that session | `/usr/bin/time -v` or `/proc/<pid>/status` VmHWM |
| M-3 | Prompt bytes + message count per iteration (`[PERF]` line, Phase 0) | Phase 0 harness |
| M-4 | SQLite statements per iteration (`[PERF]` line) | Phase 0 harness |
| M-5 | Bytes allocated per iteration under a counting allocator (unit level) | `std.testing` + `CountingAllocator` |

Targets after Phases 1–3: **M-4 ≤ 25 statements/iteration** (from ~140 worst / ~12 typical-workspace), **M-3 prompt bytes unchanged** (byte-identical), **M-1 −40% or better**, **M-2 −50%** on a 200-message session.

---

## File Structure

**New files**

- `src/ai_workflow/tui/agentic_loop/iter_metrics.zig` — tiny process-wide relaxed-atomic counters + a `logIterationSummary` helper; test-only reset.
- `src/ai_workflow/tui/agentic_loop/test_support/counting_allocator.zig` — `CountingAllocator` wrapper (`total_bytes`, `alloc_count`) for deterministic unit budgets.
- `src/ai_workflow/tui/agentic_loop/prompts_workspace_context_cache.zig` — one canonical `getWorkspaceContext` + a per-run cache handle threaded through `buildMessages`.
- `src/ai_workflow/tui/agentic_loop/run_file_cache.zig` — run-scoped `(path, mtime, size) → bytes` cache for prompt-injected files, with an explicit invalidation hook.
- `src/ai_workflow/tui/agentic_loop/perf_guard_test.zig` — static-contract + counting-allocator guard tests (the regression net for every task below).
- `docs/bench/agentic-loop-baseline.md` — recorded M-1…M-4 before/after numbers.
- Migration in `src/modules/databases/<pkg>/migration.zig` (next free number) — covering index on `llm_history`.

**Modified files (by phase)**

- Phase 1: `workflow.zig`, `parsing.zig`, `update_worker.zig`, `retry_delay_ms.zig`, `src/modules/logger/Logger.zig`.
- Phase 2: `prompts_build_messages_for_agent_prompt.zig`, `prompts_make_workspace_context.zig`, `prompts_make_kanban_context.zig`, `prompts_make_design_context.zig`, `prompts_make_working_directory_context.zig`, `llm_history.zig`, `tools_exec_write_file.zig`, `tools_exec_text_replace.zig`, `tools_exec_remove_file.zig`.
- Phase 3: `workflow.zig`, `prompts_build_messages_for_agent_prompt.zig`, `parsing.zig`.
- Phase 4: `workflow.zig`, `stream_snapshot.zig`, `tools_exec_read_file.zig`, `tools_exec_command.zig`/`command.zig`, `handle_tool.zig`.
- Phase 5: `migration.zig`, `workflow.zig`, `handle_tool.zig`, `insert_llm_histories.zig`, `session_skills.zig`.

---

## Phase 0 — Measurement & regression guards

> Ship Phase 0 first and record the baseline numbers in `docs/bench/agentic-loop-baseline.md`. Without it, Phases 1–5 are unverifiable and will be argued about in review.

### Task 0.1 — Counting allocator test helper

**Files:** create `src/ai_workflow/tui/agentic_loop/test_support/counting_allocator.zig`; register the test in `src/ai_workflow/tui/agentic_loop/test_runner.zig`.

- [ ] **Step 1: Write the failing test.** In the new file, a test that wraps `std.testing.allocator`, allocates 3 known sizes, frees one, and expects `total_bytes == 300` and `live_bytes == 200`.
- [ ] **Step 2: Implement `CountingAllocator`** — a `std.mem.Allocator` vtable wrapper holding `total_bytes`, `live_bytes`, `alloc_count`, `free_count` with `@atomicLoad/.monotonic` accessors. Delegate `rawAlloc`/`rawResize`/`rawRemap`/`rawFree`.
- [ ] **Step 3: Run it** — `zig build test --summary all 2>&1 | tail -n 20`, expect the test to pass and 0 fails.
- [ ] **Step 4: Commit** — `test(agentic-loop): add CountingAllocator test helper`.

### Task 0.2 — Per-iteration telemetry

**Files:** create `iter_metrics.zig`; edit `workflow.zig` (emit one summary per iteration at the *end* of the loop body); edit `src/modules/databases/<pkg>/` to expose `pub var statements_executed: std.atomic.Value(u64)` incremented in `SqliteBackend.query`/`exec`.

- [ ] **Step 1: Write the failing test.** `test "iter_metrics: summary is NOT logged below info level"` + `test "iter_metrics: reset() zeroes counters"`.
- [ ] **Step 2: Implement** `iter_metrics.zig` with `pub fn onSql()`, `pub fn addBytes(n: usize)`, `pub fn snapshot() Snapshot{iter_ms, history_rows, prompt_bytes, tool_count, sql_statements, arena_capacity}`, `pub fn reset()`.
- [ ] **Step 3: Wire** — increment on every `db.query`/`db.exec`; at `workflow.zig:1316` (loop bottom) and before each `continue`, call `logIterationSummary(logger, …)` emitting exactly one `[PERF] session=<id> iter=<n> ms=<n> hist=<n> prompt_bytes=<n> tools=<n> sql=<n>` line at INFO. Use `parent_arena_allocator.queryCapacity()` for `arena_capacity`.
- [ ] **Step 4: Verify** — run the app once against a scratch session, confirm exactly one `[PERF]` line per iteration, and paste 5 lines into `docs/bench/agentic-loop-baseline.md`.
- [ ] **Step 5: Commit** — `feat(agentic-loop): per-iteration [PERF] telemetry`.

### Task 0.3 — Guard-test scaffold

**Files:** create `perf_guard_test.zig`; register in `test_runner.zig`.

Write static-contract tests (the repo's established pattern: read the source file into an arena, `std.mem.indexOf`) that will FAIL now and PASS after each phase. Start with:

- [ ] `equips(` appears **exactly once** inside `fn filterAndMergeTools` (`workflow.zig`).
- [ ] `updateWorker(` appears **exactly once** in `runAgenticMultiStepnew` between the loop opening brace and the loop closing brace.
- [ ] `getWorkspaceContext(` appears **exactly once** in `fn buildMessages` (`prompts_build_messages_for_agent_prompt.zig`).
- [ ] `for (db_messages) |msg|` appears **at most once** in `runAgenticMultiStepnew`.
- [ ] `arenaAllocatorWhileLoop = std.heap.ArenaAllocator.init(di.allocator)` (Phase 4 target) — mark with a `TODO(phase-4)` comment so the failure is explicit.

Expected: **5 failures**. That is the point — commit them **disabled via `if (false)`** OR land Tasks 0.3 per-phase (preferred: put each assertion in its own test inside the phase that fixes it). Choose per-phase placement so `zig build test` stays green on `main`.

- [ ] **Commit** — `test(agentic-loop): perf guard-test scaffold`.

### Task 0.4 — Scripted benchmark session

**Files:** create `scripts/bench_agentic_loop.sh`; append procedure to `docs/bench/agentic-loop-baseline.md`.

- [ ] Write a script that starts a scratch `pabrik` on a free port in **8080..8199 excluding 8081**, with an isolated `HOME`, POSTs a scripted conversation that forces ~30 tool-heavy turns (e.g. repeated `list_directory` + `read_file` on a fixture tree), then prints p50/p95 of the `[CHECKPOINT] LLM responded … duration_ms` lines plus `VmHWM` from `/proc/<pid>/status` at the end. Record the output.
- [ ] **Commit** — `chore(bench): scripted agentic-loop benchmark`.

---

## Phase 1 — Cheap wins (low risk, ship together, PR #1)

### Task 1.1 — `filterAndMergeTools`: duplicate the tool table once, per run

**Files:** `workflow.zig:1729-1779`; `tools_equipped.zig:65-117`.

- [ ] **Failing guard test** (in `perf_guard_test.zig`): `equips(` occurs once in `filterAndMergeTools`.
- [ ] **Fix** — replace lines 1735-1736 with a single binding:
  ```zig
  const base_all = tools.all_agent_tools(allocator);
  var base_tools = try allocator.alloc(agent.AgentTool, base_all.len);
  @memcpy(base_tools, base_all);
  ```
  Then hoist further: build the *unfiltered* base list **once before the loop** on `parent_allocator`, and have `filterAndMergeTools` only copy + filter it. Rationale: the comptime list never changes during a run; only the allowlist and `is_sub_agent` do. Keep the function signature (it is exported and used by tests) but add an optional `base` parameter defaulting to `null` → falls back to the current behaviour, so no call site outside the loop breaks.
- [ ] **Counting-allocator test**: `filterAndMergeTools` with `allowed_tools = "all"` and `is_sub_agent = false` allocates **exactly one** 34-element copy.
- [ ] `zig build test --summary all` → 0 fail.
- [ ] **Commit** — `perf(agentic-loop): bind equips() once; hoist static tool table out of the loop`.

### Task 1.2 — One heartbeat per iteration, in one transaction

**Files:** `workflow.zig:594,781`; `update_worker.zig:42-131`.

- [ ] **Failing guard test**: `updateWorker(` occurs once in the loop body.
- [ ] **Fix (a)** — delete the `updateWorker` call at `:781`. `touchCheckpointWorkers` at `:594` already passes the *same* arguments (`worker_id == session_id == copy_session_id`, same cwd) and runs first; the second is pure duplication. Verify by diffing the two call sites before deleting.
- [ ] **Fix (b)** — wrap the 5 statements in `update_worker.zig` into one transaction: `BEGIN IMMEDIATE` … `COMMIT` with a `ROLLBACK` on error. Add `pub fn updateWorkerTx(...)` (or an `in_tx: bool` field) so the existing 1-statement-per-exec tests still pass; migrate call sites.
- [ ] **Behaviour test** — a new Zig test asserting that one `updateWorker` call emits exactly **one** worker SSE event and bumps `sessions.updated_at` exactly once, and that a mid-transaction failure leaves the pre-state unchanged (inject a bad statement).
- [ ] `zig build test --summary all` + `pytest tests/functional/ -k "worker or session_list" -v` → 0 fail.
- [ ] **Commit** — `perf(agentic-loop): single per-iteration heartbeat, one transaction`.

### Task 1.3 — One pass over `db_messages`

**Files:** `workflow.zig:998-1017`.

- [ ] **Failing guard test**: `for (db_messages) |msg|` appears once in `runAgenticMultiStepnew`.
- [ ] **Fix** — merge the two blocks into one loop computing both maxima:
  ```zig
  var max_token: u32 = 0;
  var max_loop: u32 = 0;
  for (db_messages) |msg| {
      if (msg.total_tokens > max_token) max_token = msg.total_tokens;
      if (msg.loop_index > max_loop) max_loop = msg.loop_index;
  }
  ```
- [ ] **Unit test** — a fixture with deliberately divergent maxima (`total_tokens` peak on row 1, `loop_index` peak on row 9) proves both are found and `loop_counter == max_loop + 1`.
- [ ] **Commit** — `perf(agentic-loop): single scan for total_tokens + loop_index`.

### Task 1.4 — Gate log formatting by level (project-wide win)

**Files:** `src/modules/logger/Logger.zig:209-296`; `workflow.zig:1041`.

- [ ] **Failing test** in `logger_test.zig`: with `min_level = .warn`, `infoFmt` must **not** invoke the formatting path. Implement the assertion with a comptime-counted side effect — e.g. a custom struct whose `format` increments a global counter — so the test proves `allocPrint` never ran.
- [ ] **Fix** — move the level check *before* formatting:
  ```zig
  pub fn logFmt(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) !void {
      if (@intFromEnum(level) < @intFromEnum(self.config.min_level)) return;
      const message = try std.fmt.allocPrint(self.allocator, fmt, args);
      defer self.allocator.free(message);
      try self.log(level, message);
  }
  ```
  Keep `log()`'s own check for direct callers.
- [ ] **Fix `workflow.zig:1041`** — guard the 150 KB dump explicitly so it costs nothing when DEBUG is off:
  `if (logger.isEnabled(.debug)) logger.debugFmt(…)` (add `pub fn isEnabled(self: *const Logger, level: LogLevel) bool`).
- [ ] **Verify** — re-run `zig build test --summary all` (0 fail) and the benchmark: M-3 prompt bytes unchanged, M-1 improves on iterations where debug is off.
- [ ] **Commit** — `perf(logger): check level before formatting; skip 150KB debug dump`.

### Task 1.5 — Don't JSON-parse things that cannot be JSON

**Files:** `parsing.zig` (the `transformLLMHistoryToAgentMessage` body), `Agent.zig` `buildJsonOpenAIRequest` (≈:1666).

- [ ] **Failing test** — feed `LLMHistory{ .role = "assistant", .response_content = "plain prose, not json", .tool_calls_json = "" }` through a `CountingAllocator`; assert **zero** JSON parses (via a test-only counter or a `no_parse` hook) and that a row with real `tool_calls_json` still parses.
- [ ] **Fix** — gate the parse on the *shape*, not the field name: only attempt `parseFromSlice` when the trimmed source starts with `{` or `[` **and** the row is a tool/assistant-with-tool-calls row. Same gate in `buildJsonOpenAIRequest`'s validate-only parse — or drop that parse entirely (it discards the result; validation happens again on the wire by the provider).
- [ ] **Prompt byte-identity test**: for a 20-row fixture containing text, tool-call, and tool-result rows, the produced `[]AgentMessage` list is byte-identical before/after the change (serialise both to a canonical JSON string and compare).
- [ ] **Commit** — `perf(agentic-loop): skip doomed JSON parses in history transform`.

### Task 1.6 — Retry-delay cancellation poll: 50 ms → 250 ms

**Files:** `retry_delay_ms.zig:114`.

- [ ] **Test** — `retryDelayMs` with `delay_ms = 1000` issues **≤ 5** `isWorkerCancelled` calls (wrap the DB in a counting type — the input takes `*sqlite.SqliteBackend`, so add a small test-only counter in `SqliteBackend.query` reused from Task 0.2).
- [ ] **Fix** — `const chunk_ms: u32 = if (remaining_ms > 250) 250 else remaining_ms;`
- [ ] **Verify** — cancellation UX: a functional test cancels a worker during a retry delay and asserts the workflow breaks out within ~300 ms.
- [ ] **Commit** — `perf(agentic-loop): coarser retry-delay cancellation poll`.

---

## Phase 2 — Prompt build: stop rebuilding the world every turn (PR #2)

> These four tasks are the single biggest CPU/IO lever. They touch only *how* the prompt is assembled, never *what* it contains. Every task must land with a byte-identity assertion.

### Task 2.1 — One canonical `WorkspaceContext`, fetched once per turn

**Files:** create `prompts_workspace_context_cache.zig`; edit `pbfap.zig:1221-1230` (`filteringTools`) and `:77-273` (`buildMessages`); edit `prompts_make_workspace_context.zig:10-17,101`, `prompts_make_kanban_context.zig:53-61,175`, `prompts_make_design_context.zig:26-39`; `llm_history.zig:4089`.

- [ ] **Failing guard test** — `getWorkspaceContext(` occurs once in `fn buildMessages`'s call tree (assert exactly one call in `pbfap.zig`, and that it precedes `filteringTools`).
- [ ] **Fix (a)** — in `buildMessages`, fetch `const ws_ctx = try llm_history.getWorkspaceContext(allocator, db, session_id);` once, `defer if (ws_ctx) |c| c.deinit(allocator);`, and pass `?*const WorkspaceContext` into `filteringTools`, `makeWorkspaceContext`, `makeKanbanContext`, `buildDesignCanvasPrompt`.
- [ ] **Fix (b)** — make each of those four renderers accept the pre-fetched context and **delete** their local `getWorkspaceContext` implementations (`prompts_make_workspace_context.zig:101-200`, `prompts_make_kanban_context.zig:175-355`). Keep `llm_history.getWorkspaceContext` as the only implementation.
- [ ] **Fix (c)** — make the *single* implementation lazy about siblings: add `pub fn getWorkspaceAnchorOnly(allocator, db, session_id) !?WorkspaceAnchor` (anchor row + item type, 1 query) and have `getWorkspaceContext` build on it. Callers that only need `self_item_type` (design gating, kanban gating) use the anchor-only variant.
- [ ] **Counting test** — for a session bound to a workspace item with 20 siblings: SQL statements per `buildMessages` drop from ≈142 to ≤ 55. Assert with the Task 0.2 counter, as a hard budget: `expect(sql_stmt_delta <= 60)`.
- [ ] **Byte-identity test** — build the prompt for a kanban-bound session and a design-bound session before/after; assert identical bytes.
- [ ] **Functional** — `pytest tests/functional/agent_knowledge_edit_test.py tests/functional/kanban_task_get_test.py -v` (both exercise workspace-item prompt paths).
- [ ] **Commit** — `perf(prompt): fetch WorkspaceContext once per turn; drop 3 duplicate impls`.

### Task 2.2 — Gate workspace enumeration on item type *before* the N+1

**Files:** `llm_history.zig:4128-4240`, `prompts_make_kanban_context.zig` (post-2.1: consumed context only).

- [ ] **Failing test** — building a prompt for a session bound to a `chat` item with 20 siblings must issue **zero** per-item task queries (today it issues ≤ 40).
- [ ] **Fix** — add a `include_siblings: bool` (or `depth: enum { anchor, siblings, siblings_with_tasks }`) parameter to `getWorkspaceContext`. `buildMessages` requests `siblings_with_tasks` **only** when `self_item_type` is `kanban`; `siblings` for design/folder; `anchor` for `chat`/agent.
- [ ] **Byte-identity test** — kanban prompt unchanged; chat prompt unchanged.
- [ ] **Commit** — `perf(prompt): skip sibling/task enumeration for non-kanban items`.

### Task 2.3 — Run-scoped file cache for prompt-injected files

**Files:** create `run_file_cache.zig`; edit `prompts_make_working_directory_context.zig:17-60`; edit `pbfap.zig:136,150` (local/global knowledge listing); wire invalidation into `tools_exec_write_file.zig`, `tools_exec_text_replace.zig`, `tools_exec_remove_file.zig`.

- [ ] **Failing test** — with a counting allocator + a `readFile` counter, `buildMessages` called twice in a row reads `PABRIK.md`/`AGENTS.md` **once** (today: twice, each opened twice).
- [ ] **Fix (a)** — `RunFileCache` keyed by absolute path, value `{ bytes: []const u8, mtime_ns: i128, size: u64 }`, owned by the **parent (run) arena**, created once before the loop and threaded into `buildMessages`. On lookup: `statFile` (or `Dir.statFile`) and compare `(mtime, size)`; on miss/change, re-read. This keeps a self-modifying `PABRIK.md` correct (the agent edits it) at the cost of one `stat` per file per turn instead of a full read.
- [ ] **Fix (b)** — read each file **once**: drop the "probe with `openFileAbsolute` then `readFileAlloc`" double-open at `prompts_make_working_directory_context.zig:39,47` — attempt the read and treat `FileNotFound` as "absent".
- [ ] **Fix (c)** — invalidation: in the three write tools, after a successful write call `cache.invalidate(abs_path)` (pass the cache through `ToolExecContext` or a thread-local handle — mirror the `mcp_cancel_thunk` thread-local pattern at `workflow.zig:382-400`). A test must prove that writing `PABRIK.md` mid-run causes the *next* turn to see the new content even with a warm cache.
- [ ] **Commit** — `perf(prompt): run-scoped memoized file reads for PABRIK.md/AGENTS.md`.

### Task 2.4 — Skills listing: one scan, frontmatter-only reads, deterministic order

**Files:** `skills.zig:302-323,541-580`, `list_skills.zig:47`, `pbfap.zig:1710`.

- [ ] **Failing test** — `appendSkillsListing` for 17 skills reads ≤ 3 000 bytes total (today ≈70 000) and returns the same rendered lines as before.
- [ ] **Fix** — in `skills.zig`, read only the frontmatter prefix (bounded, e.g. 4 KiB or up to the second `---`) when the caller only needs `name` + `description`; expose `listSkillSummaries()` and have `appendSkillsListing` use it. Remove the redundant second `open`/`stat` path (`:547-556` then `:302-323`).
- [ ] **Fix (c)** — sort entries deterministically (`std.mem.sort` by name) before rendering, so a directory-order change cannot invalidate the provider prefix cache.
- [ ] **Byte-identity test** — rendered listing string identical for the same skill set (order included).
- [ ] **Commit** — `perf(prompt): frontmatter-only skill scans + stable ordering`.

### Task 2.5 — Memoize the profile/tool-set static prefix

**Files:** `pbfap.zig:1669` (`appendToolBehaviorSection`), `:1118` (`BuildSubAgentsListing`), new cache in `run_file_cache.zig` or a sibling.

- [ ] **Failing test** — two consecutive `buildMessages` calls with the same profile + tool set allocate the tool-behaviour block once.
- [ ] **Fix** — key on `(profile_name, sorted tool-name list hash)`; store on the parent arena; invalidate when `filterAndMergeTools` produces a different tool-name set (which already happens whenever MCP tools or the allowlist change).
- [ ] **Byte-identity test** + **Commit** — `perf(prompt): memoize tool-behaviour block per tool set`.

---

## Phase 3 — Conversation materialisation

### Task 3.1 — Incremental history: append only what the last turn created

**Files:** `workflow.zig:991,1028`, `pbfap.zig:266-273`, `get_llm_histories.zig` (new `getLLMHistoriesSince(allocator, db, session_id, after_created_at_nano)`).

- [ ] **Failing test** — a 200-message fixture: `buildMessages` on turn k performs `O(new rows)` dupe work, not `O(200)`; assert with the counting allocator that bytes per turn are flat as k grows.
- [ ] **Fix** — add a per-run `HistoryCursor { last_created_at_nano: i128, feed_count: usize, messages: std.ArrayList(AgentMessage) }`. Each turn: SELECT only rows with `created_at_nano > cursor.last_created_at_nano` (`ORDER BY created_at_nano ASC`), transform them, append to the retained list.
- [ ] **Correctness fallbacks (mandatory, test each):**
  - If `loop_counter == 1` **or** the previous turn triggered compaction (`maybeCompactMessagesNew` returned true, `workflow.zig:1032-1039`) → full rebuild from scratch.
  - If `markHistoryNotForLLMRun` flipped rows to `is_feed_to_llm = 0` (compaction, history restore) → detect via a cheap `SELECT COUNT(*) FROM llm_history WHERE session_id = ? AND (is_feed_to_llm = 1 OR is_feed_to_llm IS NULL)` compared against `cursor.feed_count`; on mismatch, full rebuild.
  - Tool/assistant pairing: the retained list must never split a `tool_calls` row from its matching `tool` rows — since the cursor only ever appends whole turns and a compaction resets everything, this holds; add an explicit assertion in the test.
- [ ] **Byte-identity test** — for a 5-turn scripted session with tool calls, the prompt at each turn is byte-identical to the from-scratch build.
- [ ] **Commit** — `perf(agentic-loop): incremental history materialisation with full-rebuild fallbacks`.

### Task 3.2 — One message buffer, not two

**Files:** `workflow.zig:990-1030`.

- [ ] **Failing test** — the message-array bytes alive at the `callDynamicAgentNew` call site equal one copy (±constant), not two (`CountingAllocator.live_bytes` peak assertion).
- [ ] **Fix** — have `buildMessages` take `*std.ArrayList(agent.AgentMessage)` and append directly into `messagesLists` (or return the list and delete the `initialMessages` + `appendSlice` pair). Compaction already mutates `messagesLists` by pointer (`workflow.zig:1032`), so the shape fits.
- [ ] **Verify** — `zig build test --summary all`; compaction tests still green.
- [ ] **Commit** — `perf(agentic-loop): build the message list in place (drop double buffer)`.

### Task 3.3 — Cache the parsed `AgentMessage[]` per history row

**Files:** `parsing.zig`, `pbfap.zig:266-273`.

- [ ] **Failing test** — with the Task 3.1 cursor in place, rows already transformed are not re-transformed (counter + counting allocator).
- [ ] **Fix** — store `{ history_id: []const u8, messages: []agent.AgentMessage }` alongside the cursor; on append, transform only new ids. Ties into 3.1 — if 3.1 landed first this is a small delta, so land them together or drop this task if 3.1 already covers it. **Decision rule:** if 3.1's measurement shows no re-transform of old rows, mark this task `dropped (superseded by 3.1)` in the PR description rather than open-coding a second cache.
- [ ] **Commit** — only if implemented.

---

## Phase 4 — Memory bounding

### Task 4.1 — Decouple the per-iteration arena from the run arena

**Files:** `workflow.zig:590`.

- [ ] **Failing test / guard** — the static-contract assertion from Task 0.3.
- [ ] **Fix**
  ```zig
  var arenaAllocatorWhileLoop = std.heap.ArenaAllocator.init(di.allocator);   // was parent_allocator
  defer arenaAllocatorWhileLoop.deinit();
  ```
  **Why:** the current nesting means (a) any parent allocation after the child's nodes strands the *entire* iteration for the rest of the run (M2 — reachable via a mid-run MCP toggle, `workflow.zig:640,646`), and (b) under `DebugAllocator`, freed bytes get poisoned, which is the only way to catch cross-iteration escapes (M3) instead of shipping latent UB.
- [ ] **Audit before landing** — grep every value that escapes the iteration: `last_retry_server_detail` (Task 4.2 fixes it), `stream_snapshot` (copies into its own `page_allocator` buffers — safe), `ActiveLoops` (uses the parent-allocated `copy_session_id` — safe). Add `zig build test` under `std.testing.allocator` and watch for *new* use-after-free reports.
- [ ] **Verify** — full `zig build test --summary all` (0 fail / 0 leak) + `zig build pabrik-desktop --summary all`. Compare M-2 before/after; expect a small improvement (the callback-run arena no longer holds the iteration high-water mark).
- [ ] **Commit** — `perf(agentic-loop): per-iteration arena parented to the run allocator`.

### Task 4.2 — Fix the cross-iteration retry-detail escape

**Files:** `workflow.zig:545,1065`, `1546-1660` (`callDynamicAgentNew`).

- [ ] **Failing test** — a unit test that sets `last_retry_server_detail` from iteration N, forces an N+1 iteration to allocate ≥ the same bytes, and asserts the string is still intact (guard with `std.testing.allocator` poisoning so it fails *before* the fix under Task 4.1's change).
- [ ] **Fix** — dupe `out_last_error_message.*` into `parent_allocator` before returning it from `callDynamicAgentNew` (or into a run-scoped scratch buffer owned by the caller). Update the stale comment at `:1628-1629` which only argues arena-outlives-call.
- [ ] **Verify/Commit** — `fix(agentic-loop): own the retry-detail string for the run, not the iteration`.

### Task 4.3 — Bound one iteration's tool output

**Files:** `handle_tool.zig`, `tools_exec_read_file.zig`, `tools_exec_command.zig` / `command.zig`, `tools_wrap_output.zig`.

- [ ] **Measure first** — log the size of each `ToolExecResult` payload at DEBUG for one session; note the max in `docs/bench/agentic-loop-baseline.md`. Do NOT guess a cap.
- [ ] **Fix** — when a single tool result exceeds a cap (`max_tool_result_bytes`, default 256 KiB, config-overridable), retain the head + tail with an explicit, LLM-visible elision marker (the CLI already does this in places — extend that pattern rather than invent one). The elision text must tell the model how to get the rest (e.g. re-run with `offset`/`limit`), because silent truncation causes agent loops.
- [ ] **Test** — a `read_file` of a 5 MiB fixture returns a bounded payload; `command` producing 10 MiB similarly; the marker is present; the DB row stores the bounded payload (so the next turn's history re-read stays bounded too — this is the interaction with B1/M4 that makes the whole plan pay off).
- [ ] **Functional** — `pytest tests/functional/command_tool_test.py -v`.
- [ ] **Commit** — `perf(tools): cap per-result payload with explicit elision marker`.

### Task 4.4 — `stream_snapshot`: evict, cap, and de-globalise the lock

**Files:** `stream_snapshot.zig:38-105`.

- [ ] **Failing test** — after `endStream`, the session's buffer is released (or capped at a documented max) and the registry size does not grow unboundedly across 100 synthetic session ids.
- [ ] **Fix** — on `endStream`, either evict the entry (if the resume endpoint already fetched it) or `shrinkAndFree` the buffer down to a cap; add `pub fn evict(session_id)` called from the workflow's run-end path. Replace the single global sink mutex with a per-entry lock so concurrent sessions stop serialising per token.
- [ ] **Wire-contract test** — `GET /api/llm/session/:id/stream` still returns `{active, content}` after a mid-stream re-select (functional test with the real endpoint; do NOT hand-roll a second endpoint).
- [ ] **Commit** — `perf(stream): evict snapshot buffers; per-entry locking`.

### Task 4.5 — Free the run-scoped scratch the parent arena pins

**Files:** `workflow.zig:395,573-586,639-647`.

- [ ] **Fix** — the `McpCancelCtx` box (`:395`) and any abandoned `mcp_tools` slice on a mid-run toggle are never freed (they die with the run arena — acceptable but wasteful on toggle-heavy sessions). Either free them explicitly with an `errdefer`/run-end sweep on `parent_allocator`, or allocate the cancel box on the **callback** allocator (`di.allocator`) so it is reclaimed one level up. Document the choice in the comment.
- [ ] **Test** — a test that toggles MCP twice mid-run and asserts the parent arena's `queryCapacity()` does not grow by two tool-list copies.
- [ ] **Commit** — `fix(mcp): reclaim cancel-box + stale tool slices on config invalidation`.

---

## Phase 5 — Database

### Task 5.1 — Covering index for the per-turn history read

**Files:** `src/modules/databases/<pkg>/migration.zig` (next free number; follow the existing `addColumnIfMissing`/idempotent-create pattern), plus a test.

- [ ] **Migration** — `CREATE INDEX IF NOT EXISTS idx_llm_history_session_feed_nano ON llm_history(session_id, is_feed_to_llm, created_at_nano)`.
- [ ] **Test** — migration applies to a fresh DB and is idempotent on re-run; `EXPLAIN QUERY PLAN` for the `get_llm_histories.zig:27-61` SELECT no longer says `USE TEMP B-TREE FOR ORDER BY`.
- [ ] **Verify** — M-4/M-1 before/after with a 500-row session.
- [ ] **Commit** — `perf(db): covering index for per-turn llm_history reads`.

### Task 5.2 — One transaction per iteration for message writes

**Files:** `workflow.zig` (queued-message drain `:707-779`, `handle_tool` result loop), `insert_llm_histories.zig`.

- [ ] **Failing test** — a 5-tool-call iteration performs **one** commit, not 15.
- [ ] **Fix** — wrap the queued-message drain loop and the per-tool-call insert loop in a single `BEGIN IMMEDIATE` … `COMMIT`, with `ROLLBACK` on error. Keep SSE emission outside the transaction (SSE ordering is independent of the DB).
- [ ] **Caveat to test** — a failure mid-loop must roll back *all* rows for that iteration and the workflow must still save its error diagnostic (i.e. the diagnostic insert happens after the rollback, and is not swallowed).
- [ ] **Commit** — `perf(agentic-loop): batch per-iteration message writes into one transaction`.

### Task 5.3 — Stop re-reading what we just wrote

**Files:** `handle_tool.zig:418,801,808`, `insert_llm_histories.zig:252`, `session_skills.zig`.

- [ ] **Failing test** — one tool-calls iteration performs zero `getLatestMessage`-style read-backs and **one** `session_skills` read (today: one per row).
- [ ] **Fix** — pass the in-memory row into `sendSSEForLatestMessage` instead of re-SELECTing (LIMIT-1, 27 columns); hoist the `session_skills` read once per iteration and thread it into every insert/SSE. Cache `get_current_agent_by_session_id` between `workflow.zig:793` and `handle_tool.zig:386` (same iteration, same data).
- [ ] **Functional** — `pytest tests/functional/mcp_stdio_test.py tests/functional/background_command_completion_test.py -v`.
- [ ] **Commit** — `perf(agentic-loop): reuse in-memory rows; read session_skills once per turn`.

---

## Ordering & expected payoff

| Phase | Tasks | Risk | Payoff (measured) |
|---|---|---|---|
| 0 | 0.1–0.4 | none | none (enables everything) |
| 1 | 1.1–1.6 | low | M-4 −10 stmts; M-1 −5–15 %; removes a 150 KB/turn alloc |
| 2 | 2.1–2.5 | medium | **M-4 −80 stmts typ / −100 worst; ≈ −168 KB disk I/O per turn**; M-1 −30–50 % on workspace-bound sessions |
| 3 | 3.1–3.3 | medium-high | kills the O(H²)·turns term; M-2 −50 % on long sessions |
| 4 | 4.1–4.5 | medium | removes the stranding hazard + latent UB; M-2 −30–50 % on tool-heavy sessions |
| 5 | 5.1–5.3 | low | M-4 −5–15 stmts; fewer fsyncs |

Ship PR #1 after Phase 1 (cheap wins), PR #2 after Phase 2 (prompt), PR #3 after Phases 3–5. Each PR must carry the before/after `docs/bench/agentic-loop-baseline.md` table.

---

## Non-goals (explicitly rejected)

- **Rewriting the agent loop as an event-driven state machine.** The `while (true)` shape is load-bearing for compaction, queue draining, cancellation and `ActiveLoops`; a rewrite is a separate project.
- **Moving tool execution to a thread pool.** Not needed for the measured hotspots and it would break `ActiveLoops`/cancellation assumptions.
- **Changing prompt content or ordering.** Only *how many times* it is computed changes.
- **Caching anything across sessions in a process-global without a per-session key.** Every cache in this plan is either run-scoped (dies with the run) or keyed by session; no cross-session prompt cache.
- **A general-purpose KV cache / HTTP response cache for LLM calls.** Provider prefix-caching already handles the wire side; the win here is local.
- **Deleting the dead prompt helpers** (`prompts_make_skills_equiped_context.zig`, `prompts_make_activity_info_context.zig`, `BuildBackgroundProcessPrompt`, `BuildDynamicAgentContent`) — real clean-up, but it is behaviour-neutral churn that would obscure the perf diffs in review. File a separate card.

## Appendix A — Verification commands

```bash
# unit + static-contract (must be 0 fail, 0 leak)
cd /home/ginwa/ginwaaitoolbox && zig build test --summary all 2>&1 | tail -n 30

# end-to-end build (must be N/N steps succeeded)
zig build pabrik-desktop --summary all 2>&1 | tail -n 5

# functional wire tests for anything touching HTTP/SSE/tools
zig build install:linux 2>&1 | tail -n 3     # pabrik-desktop does NOT rebuild pabrikcore-linux-x86_64
PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 \
  python3 -m pytest tests/functional/command_tool_test.py \
                   tests/functional/mcp_stdio_test.py \
                   tests/functional/background_command_completion_test.py -v

# benchmark (Phases 0/1/2/3/4/5 before-and-after)
./scripts/bench_agentic_loop.sh | tee /tmp/bench-after.txt
```

## Appendix B — Evidence inventory (audit handles)

| Finding | Handle |
|---|---|
| Loop body | `src/ai_workflow/tui/agentic_loop/workflow.zig:588-1316` |
| History re-read (27 dupes/row, no LIMIT) | `src/ai_workflow/tui/agentic_loop/get_llm_histories.zig:27-119` |
| Prompt assembly | `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig:77-273` |
| `filteringTools` workspace query | `prompts_build_messages_for_agent_prompt.zig:1221-1226` |
| Workspace N+1 (2 queries × ≤20 siblings) | `src/ai_workflow/tui/agentic_loop/llm_history.zig:4170-4230`, `MAX_SIBLING_ITEMS` at `:4005` |
| Duplicate `getWorkspaceContext` impls | `prompts_make_workspace_context.zig:101`, `prompts_make_kanban_context.zig:175`, `llm_history.zig:4089` |
| Working-dir files double-opened | `prompts_make_working_directory_context.zig:29,39,47` |
| Skills read fully for a one-liner | `src/modules/.../skills.zig:302-323,541-580` |
| `equips()` dupe × 2 | `workflow.zig:1735-1736` → `tools_equipped.zig:65-117` |
| Heartbeat × 2, 5 statements each | `workflow.zig:594,781` → `update_worker.zig:42,72,100,105,112` |
| Double O(H) scan | `workflow.zig:998-1016` |
| 150 KB debug log formatted unconditionally | `workflow.zig:1041` → `src/modules/logger/Logger.zig:248-252,211` |
| Retry poll @50 ms | `retry_delay_ms.zig:114` |
| Arena semantics proof | `/usr/lib/zig/std/heap/ArenaAllocator.zig:51-62` (`deinit`), `:608-636` (`free`), `:507-530` (`alloc` node from child) |
| Per-iteration arena nesting / stranding hazard | `workflow.zig:413,590`; parent allocations in-loop at `:395,640,646` |
| Retry-detail cross-iteration escape | `workflow.zig:545,1065`, read at `:890,936,938` |
| Stream snapshot global spinlock + page_allocator + no evict | `stream_snapshot.zig:38-42,63,88-105` |
| `maybeCompactMessagesNew` no-op is O(1) ✅ | `workflow_compact_message.zig:887-895` |
| `generateSessionName` correctly gated ✅ | `workflow.zig:1018-1020` |
