# Workspace Routines — Delete Per-Task, Replace With Workspace-Level (agent-mode sibling) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the per-task routines system entirely and replace it with workspace-level routines — a first-class `item_type='routine'` beside `agent`, each with its own instruction + cron schedule.

**Architecture:** One breaking Migration 084 does `UPDATE workspace_item_tasks SET task_type='standard' WHERE task_type='routine'` + `DROP TABLE IF EXISTS routines` + `CREATE TABLE workspace_routines` (`id == workspace_item_id`, D3 copy from `agents`). The fire pipeline is retargeted, not duplicated: `routines/cron.zig` (parser) is KEPT verbatim; `routines/model.zig` + `fire.zig` + `Scheduler.zig` are rewritten to the new table and the old per-task functions deleted. Old HTTP routes (`GET /api/routines`, `POST .../tasks/:tid/run`) and old task `routine` branches are removed; 4 new workspace-routine routes take their place. Frontend deletes `AddRoutineDialog`/`EditRoutineDialog` + `RoutineMeta` plumbing and adds `AddRoutineItemDialog` + `RoutineView`. No data carry-over — old per-task schedules are dropped by design (announced breaking change).

**Tech Stack:** Zig 0.16 + SQLite, `routines/cron.zig` parser (kept), `routines/Scheduler.zig` 5s tick (retargeted), Vue 3 + Pinia, python functional harness.

## Global Constraints

- Breaking change is intentional: no migration of old `routines` rows, no back-compat shim. `GET /api/routines` and per-task `POST .../tasks/:tid/run` are deleted, not deprecated. Call this out in `docs/SPEC.md` + release notes.
- `agents` mode stays untouched (Migration 078 table + `main.zig:452-477` routes + `AgentView`). Only the routine side is deleted/replaced.
- `task_type` column stays (used by `standard`/`memory` + many fixtures) — only the `'routine'` value stops being produced. Existing `'routine'` rows are normalized to `'standard'` inside Migration 084.
- New table is `workspace_routines`, never `routines` (avoids resurrection confusion with the dropped table).
- D3 identity copy: `workspace_routines.id == workspace_items.id`, `workspace_item_id TEXT NOT NULL UNIQUE`, `FK → workspace_items(id) ON DELETE CASCADE`.
- Cron errors → `400 InvalidSchedule` with offending expression; wrong item kind → `400 ItemNotRoutine`; missing → `404`; busy run → `409 Disabled|AlreadyRunning`.
- Per-request arena: no `defer free` on `ctx.allocator` memory; still `deinit()` SQLite stmts.
- No new SSE event in v1.
- Verification per task: `zig build test --summary all` + `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/workspace_routines_test.py -v` (new) + proof of deletion (old tests removed, old routes 404). Never live-server+curl, never port 8081.
- One commit per task, green tree.

## Deletion Inventory (everything below goes or is edited)

**Backend — delete files:** `http_handlers/routines_list.zig`, `http_handlers/routines_run.zig`, `models/routine.zig`, `routines/model_test.zig`, `routines/fire_test.zig`, `routines/scheduler_test.zig` (rewritten in Task 3 as workspace versions — delete-then-recreate, not edit), `migrations/migration_routines_test.zig` (Migration 044 historical tests — delete; 044 itself stays in history, 084 drops what it made).

**Backend — edit (strip routine branches):** `task_create.zig` (routine `task_type` + `routines INSERT`, ~13 hits), `task_delete.zig:147`, `tasks_get.zig:76,78` + `tasks_list.zig:168,169,175` (`RoutineMeta` mapping), `http_response.zig:474,495` (`RoutineMetaResponse`), `llm_history.zig:4288,4307,4878-5257` (`RoutineMeta` def + builders), `models/workspace_item_task.zig` (`"routine"` variant), `kanban_tasks_create.zig` (forced-standard guard now dead — simplify), `main.zig:538,541,553,155-164` (old routes + scheduler submit comments), `mod.zig:150,163`, `test_runner.zig` old test refs, `src/models/session.zig:5` comment.

**Backend — retarget (keep file, rewrite body):** `routines/cron.zig` KEEP verbatim (+ `cron_test.zig` 10 tests KEEP); `routines/model.zig`, `routines/fire.zig`, `routines/Scheduler.zig` rewritten to `workspace_routines` (old per-task fns deleted).

**Frontend — delete files:** `dialogs/AddRoutineDialog.vue` + `EditRoutineDialog.vue`, `__tests__/AddRoutineDialog.spec.ts`, `EditRoutineDialog.spec.ts`, `apiRunRoutine.spec.ts`, `workspaceItemTaskRoutine.spec.ts`.

**Frontend — edit (strip plumbing):** `api/index.ts` (`RoutineMeta:369`, `routine?:387`, create/update/run wrappers ~21 hits), `stores/workspaces.ts` (~32 hits), `composables/useTaskActions.ts` (`isRoutine`, statusColor, emits), `components/workspace/WorkspaceItemTaskRow.vue` (clock icon + status dot + Run-Now + tooltips), `Sidebar.vue` (`editRoutineTarget`), `AppLayout.vue` (`@edit-routine/@run-routine`), `helpers/buildTaskUrlQuery.ts:67` (back-compat).

**Tests — delete/retire:** `task_lifecycle_test.py` Tests 8, 9, 14, 15 (the 4 routine tests — delete; other 17 stay); all Zig + frontend specs above.

## Schema (Migration 084 — drop + create in one migration)

```sql
-- 1. normalize leftovers, 2. drop old, 3. create new. Order matters (FK).
UPDATE workspace_item_tasks SET task_type = 'standard' WHERE task_type = 'routine';
DROP TABLE IF EXISTS routines;
DROP INDEX IF EXISTS idx_routines_enabled_next_run;
DROP INDEX IF EXISTS idx_routines_last_status;

CREATE TABLE IF NOT EXISTS workspace_routines (
    id TEXT PRIMARY KEY,                        -- == workspace_item_id (D3 copy from agents)
    workspace_item_id TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    instruction TEXT NOT NULL DEFAULT '',       -- the agent prompt fired each tick
    schedule TEXT NOT NULL DEFAULT '',          -- 5-field cron, '' = manual-run only
    enabled INTEGER NOT NULL DEFAULT 1,
    last_run_at DATETIME NULL,
    next_run_at DATETIME NULL,                  -- NULL when schedule='' or enabled=0
    last_status TEXT NOT NULL DEFAULT 'idle',   -- idle|firing|running|failed
    last_error TEXT NOT NULL DEFAULT '',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_workspace_routines_workspace_item_id ON workspace_routines(workspace_item_id);
CREATE INDEX IF NOT EXISTS idx_workspace_routines_enabled_next_run ON workspace_routines(enabled, next_run_at);
```

v1 is ONE root table. Knowledge/tools/system_prompt children for routines are v2 (reuse vs `routine_*` mirror — deferred, not this plan).

## Endpoints (delete 2, add 4)

Delete: `GET /api/routines` → 404 after Task 2 (assert in tests). `POST /api/workspaces/:w/items/:i/tasks/:tid/run` → 404 after Task 2 (assert in tests).

| # | Method + Path | Mirrors | Notes |
|---|---------------|---------|-------|
| 1 | `POST /api/workspaces/:ws/items/routine` `{name, path, instruction?, schedule?, enabled?}` → `201 {item, routine}` | `POST .../items/agent` | `name`+`path` REQUIRED; non-empty `schedule` validated via kept `cron.zig`, `next_run_at` computed; seed default tools in-txn |
| 2 | `GET /api/workspaces/:ws/items/:item/routine` → `{routine}` | `agentsGetHandler` | `400 ItemNotRoutine` / `404` / `404 NotConfigured` |
| 3 | `PATCH /api/workspaces/:ws/items/:item/routine` `{description?, instruction?, schedule?, enabled?}` | `agentsUpdateHandler` + `task_update.zig` recompute | schedule change recomputes `next_run_at`; `''`→NULL; disable→NULL |
| 4 | `POST /api/workspaces/:ws/items/:item/routines/:routine_id/run` → `{success, session_id, status}` | old `routinesRunHandler` semantics | `404 NotARoutine` / `409 Disabled\|AlreadyRunning` |

## Tasks

### Task 1 — Migration 084 (drop old + create new) + model

- [ ] Read `migration.zig` Migration 044 block (`:764-807`: `CREATE TABLE routines`, indexes) + Migration 078 block (`:3292-3434`: `agents` DDL + comment) + `allMigrations` tail (`:1955-1972`, latest 083) + `src/models/agent.zig` + `src/models/routine.zig`.
- [ ] Write failing inline tests: `workspace_routines` has all 12 columns; `workspace_item_id UNIQUE` rejects dup; FK cascade wipes root on `workspace_items` delete; hot-path index exists; `up` idempotent; registered in `allMigrations`; **deletion proofs**: `routines` table gone after `up`, `task_type='routine'` rows normalized to `'standard'`.
- [ ] Run tests, confirm fail.
- [ ] Implement `Migration084ReplaceRoutinesWithWorkspaceRoutines` (`version=84`): SQL from Schema section in order. Add `src/models/workspace_routine.zig` (copy `agent.zig` + new fields). Do NOT touch Migration 044 (history stays; 084 undoes its objects).
- [ ] Run `zig build test --summary all` green.
- [ ] Commit.

### Task 2 — Delete old backend surface + add new CRUD routes

- [ ] Read `routines_list.zig` + `routines_run.zig` (full) + `task_create.zig` routine branch (`:200-220,306,390`) + `tasks_get.zig:76,78` + `tasks_list.zig:168-175` + `http_response.zig:474,495` + `llm_history.zig:4288,4307` + `main.zig:538-553` + `mod.zig:150,163` + `workspace_items_create_agent.zig:99-176` (txn template) + `agents_get/update.zig` + `cron.zig` validate + `task_update.zig:372,443` recompute.
- [ ] Write failing `tests/functional/workspace_routines_test.py`: **deletion proofs** — `GET /api/routines` → 404; `POST .../tasks/:tid/run` → 404; create task with `task_type='routine'` rejected (400); **new proofs** — `POST .../items/routine` → `201 {item:{item_type:'routine'}, routine}`; bad cron → `400 InvalidSchedule`; empty name/path → 400; GET bundle; PATCH recompute/`''`→NULL/disable→NULL; wrong-kind GET → `400 ItemNotRoutine`.
- [ ] Run, confirm fail.
- [ ] Implement: DELETE `routines_list.zig` + `routines_run.zig` + `models/routine.zig`; strip all routine branches listed in Deletion Inventory; remove old routes from `main.zig`/`mod.zig`/`test_runner.zig`; NEW `workspace_items_create_routine.zig` + `workspace_routines_get.zig` + `workspace_routines_update.zig`; register 3 new routes; re-export; wire tests.
- [ ] Run new functional file + `zig build test --summary all` green.
- [ ] Commit.

### Task 3 — Retarget fire pipeline (model/fire/Scheduler) + new run endpoint

- [ ] Read `routines/model.zig` + `fire.zig` + `Scheduler.zig` (full — claim/mark/emit/tick) + old `fire_test.zig`/`model_test.zig`/`scheduler_test.zig` (patterns to copy, then delete).
- [ ] Extend functional test: `POST .../routines/:rid/run` → `200 {success, session_id}`; immediate second run → `409 AlreadyRunning`; disabled → `409 Disabled`; unknown → `404`; due-scan: insert past-`next_run_at` row, tick, assert status flips + `next_run_at` advances.
- [ ] Run, confirm fail.
- [ ] Implement: rewrite `model.zig` → `listDueWorkspaceRoutineIds`/`claimWorkspaceRoutine`/`markWorkspaceRoutineSuccess|Failed` (delete per-task fns); `fire.zig` → `fireWorkspaceRoutine` (message prefix `"This is an automated workspace-routine fire…"`, delete `fireRoutine`); `Scheduler.zig` tick reads new table (delete old scan); NEW `workspace_routines_run.zig` + route; delete old `*_test.zig`, add workspace equivalents (round-trip, due-filter, atomic claim, mark success/failed, `resetStuckRunning`, `recomputeDueNextRunAt`).
- [ ] Run functional file + `zig build test --summary all` green.
- [ ] Commit.

### Task 4 — Frontend: delete old routine UI, add Routine item UI

- [ ] Read `AddRoutineDialog.vue` + `EditRoutineDialog.vue` + `api/index.ts:369-387,737-811,1115-1152` + `stores/workspaces.ts` routine wrappers + `useTaskActions.ts:111-137` + `WorkspaceItemTaskRow.vue` routine bits + `AddAgentDialog.vue` + `AgentView.vue` + `api/index.ts:4021-4120` + `stores/workspaces.ts:1422-1455` + `WorkspaceList.vue:753-766` + `Sidebar.vue:556-568`.
- [ ] Delete: both dialog components + 4 spec files; strip `RoutineMeta`/`routine?`/`taskType:'routine'`/create/update/run wrappers/status-dot/Run-Now/`editRoutineTarget`/`@edit-routine`/`buildTaskUrlQuery` back-compat. Write failing NEW specs: `AddRoutineItemDialog.spec.ts` + `RoutineView.spec.ts` (instruction/schedule/enabled/run-now/invalid-cron inline error).
- [ ] Run `pnpm test:unit`, confirm old specs gone + new specs fail.
- [ ] Implement: `api/index.ts` `createRoutineItem/getRoutineItem/updateRoutineItem/runRoutineItem`; `AddRoutineItemDialog.vue` (NEW, copy agent dialog); `RoutineView.vue` (NEW: description + instruction + schedule + enabled + run-now + last-run line); `Add Routine` dropdown + `store.addRoutineItem()`; mount on `item_type==='routine'`. Assert old task-row routine affordances are gone (no clock icon, no status dot).
- [ ] Run `pnpm test:unit` + `vue-tsc --noEmit` green.
- [ ] Commit.

### Task 5 — Retire old tests + docs + final verification

- [ ] Delete `task_lifecycle_test.py` Tests 8, 9, 14, 15 (4 routine tests; other 17 stay) + `migration_routines_test.zig` (5 tests) — assert `search routine` in `src/` returns only `workspace_routines`/`cron.zig`/`HandlerRoutine` (Win32 false-positive) hits.
- [ ] Update `docs/SPEC.md` (routines section: per-task deleted, workspace-level table + 4 endpoints + breaking-change note; tree entry stays, body rewritten) + release-note entry (old schedules dropped, no auto-migration).
- [ ] Extend functional test: cascade (delete `workspace_items` row wipes `workspace_routines`); `schedule:''` never auto-fires; `last_error` surfaces failure; `GET /api/routines` still 404 (no resurrection).
- [ ] Run FULL: `zig build test --summary all` + `pnpm test:unit` + `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/workspace_routines_test.py tests/functional/task_lifecycle_test.py tests/functional/agent_kanbans_test.py -v`.
- [ ] Commit. Mark plan complete.

## Verification (global)

- [ ] Plan saved to `docs/superpowers/plans/2026-09-10-workspace-items-routines.md`
- [ ] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task has bite-sized steps (test → implement → verify → commit)
- [ ] User has reviewed the plan before execution begins

## Explicitly out of scope (v2)

- Knowledge / system-prompt / tools children for routines.
- Any auto-migration of dropped per-task `routines` rows.
- New SSE event types, retry/backoff policy.
