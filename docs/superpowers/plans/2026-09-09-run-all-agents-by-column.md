# Run All Agents by Column Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Run all agents" action to each kanban column header `...` menu that starts agents on every idle task in that column, including tasks not yet loaded by pagination.

**Architecture:** New backend bulk endpoint `POST .../kanban/columns/:column_id/run_all_agents` that SELECTs all task ids for the column server-side and loops the existing single-task `startAgentUseCase` per id (keeping its 404/409 guards); frontend menu calls it once and surfaces the `{started, skipped, failed}` summary. No new SSE event, no migration.

**Tech Stack:** Zig backend (`src/ai_workflow/tui/http_handlers/run_all_agents.zig`, `src/main.zig` route, `src/ai_workflow/tui/http_handlers/mod.zig`), Vue 3 (`KanbanColumn.vue`, `KanbanView.vue`), Pinia `workspaces.ts`, existing `processingState` SSE map, vitest + Zig static-contract tests + python functional harness.

## Global Constraints

- No new SSE `event_type` (reuse `worker_created/updated/deleted` → `processingState` in `src/apps/desktop/src/App.vue:10-43`).
- No migration / schema change (bulk reads existing `workspace_item_tasks` + `worker` rows).
- `task.id == session_id`; `processingState[task.id]===true` is the running signal on the frontend.
- Backend per-task guards stay source of truth: 404 via `getWorkspaceItemTask`, 409 via `isTaskRunning (llm_history.zig:2803-2812 SELECT 1 FROM worker)`.
- Route MUST NOT collide with the `/tasks/:task_id` family: `matchRoute` walks in registration order (`src/modules/custom_http_server/src/router.zig:182`), so a literal like `/tasks/run_all` registered after `GET .../tasks/:task_id (main.zig:503)` would be captured with `task_id="run_all"`. Nesting under `kanban/columns/:column_id/run_all_agents` avoids the family entirely.
- Mandatory verification: `zig build test --summary all` + `pnpm test:unit` + `vue-tsc --noEmit` + functional harness on port != 8081 (never 8081, never live-server curl).

## Current state (verified file:line)

- Menu: `src/apps/desktop/src/components/kanban/KanbanColumn.vue:641-699` (`toggleMenu 341-343`, `handleMenuRename 354-357`, `handleMenuSort 362-365`, `handleMenuDelete 367-370`).
- Column list: `KanbanView.vue:361-365 sortedColumns`, render `1216-1218`, pass-through emits `338-339` + wiring `1229-1230`.
- Pagination (why bulk must be server-side): `fetchKanbanTasks(ws, item, columnId, limit=10, cursor?) workspaces.ts:1563-1652` → `api.getTasks 621-673` returns `{tasks, has_more, next_cursor}` (no total); `columnPagination[col] workspaces.ts:1619-1624`; `loadMoreTasksForColumn 3270-3335`; `cardsInColumn KanbanColumn.vue:159-163` is loaded-only.
- Single run: `KanbanTaskDetailDialog.vue:1671-1691` → `KanbanView.vue:746-760 handleStartAgent` (`startAgentBusy 681`) → `workspaces.ts:2851-2862 startAgentOnTask` → `api/index.ts:1157-1166 POST .../tasks/:taskId/start_agent` (200 triggered / 404 / 409).
- Backend single: `src/main.zig:532` route → `start_agent.zig:105-175 useCase` (404 `L115`, 409 `L122-124`), `190-250 handler` (400/500/200/404/409 mapping), `Outcome L73-77`; `emit_run_agent root.zig:120-231` with `skip_initial_queue_message=true L161-172`; workflow `workflow.zig:523-583`; `ActiveLoops ActiveLoops.zig:3-37`.
- Existing column routes: `main.zig:490-493` (`GET/POST /kanban/columns`, `PATCH/DELETE /kanban/columns/:column_id`).

## Open decisions (need human before execution)

1. **Confirm dialog: yes/no?** Recommended yes — `Run all agents in '<column>'?` with server-provided counts (`N total, M already running will be skipped`). Each run is LLM spend.
2. **Scope vs search filter:** bulk runs ALL tasks in the column (`WHERE kanban_column_id=?`), ignoring the active search `q`/sort. If you want "all matches only", say so — the endpoint would need `q` passthrough.
3. **Menu label:** recommended `Run all agents` with count once known, disabled while a bulk run for that column is in flight.
4. **Summary UX:** recommended banner/toast `Started X, skipped Y (already running), failed Z` + existing per-card spinners via SSE. Per-task id lists in response (capped?) vs counts only — recommended ids (frontend can highlight), tasks table ids are small.
5. **Concurrency inside bulk:** recommended sequential loop reusing `startAgentUseCase` (avoids thundering herd on `emit_run_agent` + sqlite `worker` writes; each iteration is independent so one failure never aborts the rest).

---

## Tasks

### Task 1 — Backend: `run_all_agents` useCase + handler (TDD)

- [ ] Write failing Zig tests in `src/ai_workflow/tui/http_handlers/run_all_agents_test.zig`: empty `column_id` → error; unknown column → `column_not_found`; column with [idle-A, running-B (seed `worker` row), idle-C] → `{started:[A,C], skipped:[B], failed:[]}`; useCase never throws on single-task failure (collects into `failed`).
- [ ] Run them, confirm they fail (no such file/symbols).
- [ ] Implement `src/ai_workflow/tui/http_handlers/run_all_agents.zig`:
  - `RunAllAgentsOutcome { started: []const []const u8, skipped: []const []const u8, failed: []const []const u8 }` (or struct with per-id lists; empty-slice-as-NULL rule: never bind `""` ids).
  - `runAllAgentsUseCase(allocator, db, di, column_id)`: validate non-empty; `SELECT id FROM workspace_item_tasks WHERE kanban_column_id=?` (item scoping via join if schema requires — check `getWorkspaceItemTask` at `llm_history.zig:4650` for the scoping pattern); for each id call the existing single-task `startAgentUseCase` (reuse, don't copy its guards); map `triggered→started`, `worker_already_running→skipped`, `task_not_found/other→failed`.
  - `runAllAgentsHandler(ctx,req,res)`: `column_id` from `req.params`, empty → 400; `getSingleton` fail → 500; useCase error → 500; success → 200 `{success:true, column_id, started, skipped, failed}`; unknown column → 404.
  - Re-export in `http_handlers/mod.zig` next to `startAgentHandler (mod.zig:156,161)`.
- [ ] Run new tests, confirm pass.
- [ ] Commit.

### Task 2 — Backend: route registration + static contract

- [ ] Add static-contract test asserting the route string exists in `main.zig` and is NOT shadowed: `POST /api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id/run_all_agents` nests under the columns family (`main.zig:490-493` area), never under `/tasks/:task_id` (`main.zig:503,526-533,540`).
- [ ] Run it, confirm fail (route absent).
- [ ] Register in `src/main.zig` next to the column routes (`~L490-493`): `try gs.router.post(".../kanban/columns/:column_id/run_all_agents", ai_mod.http_handlers.runAllAgentsHandler);`
- [ ] Run contract test + `zig build test --summary all`, confirm green.
- [ ] Commit.

### Task 3 — Frontend: column menu item + pass-through

- [ ] Write failing vitest for `KanbanColumn.vue`: menu contains 4th item `data-testid="kanban-column-<id>-menu-run-all"`, click emits `requestRunAllAgents` with `column.id`, menu closes.
- [ ] Run it, confirm fail.
- [ ] Implement in `KanbanColumn.vue`: new `<li><button>` after Delete (`L688-698`, before `</ul> L699`), `handleMenuRunAll()` next to `L367-370`, emit decl next to `L74/L77`; accept a `runAllDisabled`/`runAllBusy` prop for the in-flight state.
- [ ] Write failing spec for `KanbanView.vue`: `@request-run-all-agents` routes to `handleRunAllAgents(columnId)` with per-column re-entrancy guard (mirror `startAgentBusy:681`).
- [ ] Run it, confirm fail; implement decl near `L338-339`, wiring near `L1229-1230`, handler delegating to the store action (Task 4).
- [ ] Run specs + `vue-tsc --noEmit`, confirm pass.
- [ ] Commit.

### Task 4 — Frontend: store action + confirm + summary

- [ ] Write failing vitest for `stores/workspaces.ts runAllAgentsInColumn`: mocked `api.runAllAgentsInColumn` returning `{started:2, skipped:1, failed:0}` resolves to the same summary; API throw → `{started:[], skipped:[], failed:[]}` + error surfaced, no unhandled rejection.
- [ ] Run it, confirm fail.
- [ ] Implement: `api/index.ts runAllAgentsInColumn(ws, item, columnId)` → `POST .../kanban/columns/:columnId/run_all_agents`; `workspaces.ts runAllAgentsInColumn` thin wrapper (no client-side task iteration — server owns the list, so pagination is irrelevant).
- [ ] Implement `KanbanView.handleRunAllAgents`: per-column busy guard, `confirm()` gate (decision 1), call store action, show summary banner/toast (decision 4); leave run-state visuals to existing `processingState`/`SessionSlider` SSE flow.
- [ ] Run specs + type-check, confirm pass.
- [ ] Commit.

### Task 5 — Regression + functional wire proof

- [ ] `pnpm test:unit` full — no regressions in `KanbanColumn`, `KanbanView`, `workspaces` specs.
- [ ] Write python functional test (harness, port != 8081): seed workspace → kanban → column with 3 tasks (2 idle + 1 with worker running via direct `start_agent` 200 first); `POST .../kanban/columns/:col/run_all_agents` → 200 with `started==2 (or 1 + 409-skip semantics)`, `skipped` contains the running id; second identical POST is safe (all-skipped or all-started, no 500); unknown column → 404; also assert `GET .../tasks/:task_id` single route is NOT shadowed by the new route.
- [ ] Run with `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/<new>_test.py -v`; confirm pass.
- [ ] `zig build test --summary all` sanity, confirm green.
- [ ] Commit.

## Out of scope / follow-ups

- "Run all matches only" (search-filtered bulk) — needs `q`/`sortBy` passthrough + cursor-paging parity with `fetchKanbanTasks`.
- Progress bar / cancel-mid-bulk; per-task error card reuse (`stores/agentError.ts:44`).
- Frontend loop fallback (old v1 plan) — deleted in favor of this endpoint; do not implement both.

## Verification

- [ ] Plan saved here (`docs/superpowers/plans/2026-09-09-run-all-agents-by-column.md`)
- [ ] Header has Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task is test → implement → verify → commit, one action per step
- [ ] Human reviewed before execution (card stays in `in_review_planning`)
