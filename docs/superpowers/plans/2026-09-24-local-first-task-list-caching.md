# Local-first task-list caching implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every task-list fetch paint cached tasks immediately and revalidate the existing backend page by merging rows by task id.

**Architecture:** Add a `TaskEngineDb` child of `BaseSyncEngine` and an IndexedDB `tasks` store. The store uses one cache context per workspace/item/column/query/sort shape, paints cached rows first, and then calls the existing `getTasks()` API without changing the backend contract. Older-page pagination remains network-only and writes through to the cache.

**Tech Stack:** Vue 3 + Pinia, TypeScript, Vitest, `idb`/IndexedDB, Python functional harness.

## Global Constraints

- Do not stop or use port 8081; functional tests must use an isolated port in 8080–8199.
- Keep the backend and `getTasks()` URL contract unchanged.
- Keep `ColumnPaginationState.cursor` independent from cache ordering.
- Cache rows must retain the complete server task object and use the wire `updated_at` value as the local sort key.
- Network failure must not erase a painted cache.
- Search, sort, column, and workspace/item contexts must not leak rows into one another.
- Do not add `// NEW (plan: ...)` source comments.
- Use TDD: add the focused regression test before the corresponding implementation.
- Commit each completed task with a focused message.

## File map

### Create

- `src/apps/desktop/src/sync/TaskEngineDb.ts` — task-row mapping, context keys, cache-first orchestration, and cache write/evict helpers.
- `src/apps/desktop/src/sync/__tests__/TaskEngineDb.spec.ts` — task engine mapping, merge, fallback, and context-isolation tests.
- `tests/functional/task_list_cache_contract_test.py` — existing HTTP task-list wire contract used while validating the frontend-only change.

### Modify

- `src/apps/desktop/src/sync/IndexedDbStore.ts` — add the `tasks` store and bump the IndexedDB schema version while preserving existing stores.
- `src/apps/desktop/src/stores/workspaces.ts` — use the task engine for all first-page/refresh paths, write through older pages, and keep mutations cache-coherent.
- `src/apps/desktop/src/stores/kanbanSse.ts` — preserve the existing SSE refresh and human-touch behavior while using the store's cache-first path.
- `src/apps/desktop/src/__tests__/workspacesStoreInit.spec.ts` — verify non-kanban and per-column initialization use cached rows and revalidate.
- `src/apps/desktop/src/__tests__/workspacesStorePerColumnPagination.spec.ts` — verify older pages write through without replacing the first page.
- `src/apps/desktop/src/__tests__/apiTasks.spec.ts` — assert the existing API URL contract remains unchanged.

## Task 1: Frontend-only task engine contract

**Files:** `src/apps/desktop/src/sync/__tests__/TaskEngineDb.spec.ts`

- [ ] Write a failing test fixture with a wire-shaped task and assert `toTaskRow` retains the complete `raw` object and maps `updated_at` to `sortKey`.
- [ ] Write failing context-key tests showing workspace, item, column, query, and sort changes produce distinct keys.
- [ ] Write failing tests for cold first-page revalidation, warm cache paint, same-id replacement, failed revalidation, and cache write-through.
- [ ] Run the focused Vitest file and confirm the failures are limited to the not-yet-implemented engine.

## Task 2: Implement `TaskEngineDb` and IndexedDB storage

**Files:** `src/apps/desktop/src/sync/TaskEngineDb.ts`, `src/apps/desktop/src/sync/IndexedDbStore.ts`

- [ ] Add the `tasks` object store to the known-store list and bump the database version without deleting existing message/session stores.
- [ ] Implement the task row type and `toTaskRow` mapping with a safe `updated_at` fallback.
- [ ] Implement deterministic context serialization and a context-specific in-memory/IndexedDB store.
- [ ] Implement cache-first revalidation using the existing `getTasks()` function, same-id replacement, and stable newest-row ordering.
- [ ] Implement `putLocal`, `removeLocal`, `clear`, and `removeTask` helpers.
- [ ] Run the focused engine tests and existing `SyncEngine`, `SessionEngineDb`, and `ChatEngineDb` tests.

## Task 3: Preserve and test the existing API contract

**Files:** `src/apps/desktop/src/api/index.ts`, `src/apps/desktop/src/__tests__/apiTasks.spec.ts`

- [ ] Add a regression test that `getTasks()` still emits only the existing parameters and response envelope.
- [ ] Add a test that the first-page request shape is unchanged for non-kanban and per-column calls.
- [ ] Run the focused API tests and the existing sort-parameter tests.

## Task 4: Integrate cache-first first-page reads in the workspace store

**Files:** `src/apps/desktop/src/stores/workspaces.ts`, `src/apps/desktop/src/__tests__/workspacesStoreInit.spec.ts`

- [ ] Add a store helper that maps a task request shape to a `TaskEngineDb` context and applies cached rows to a workspace item before awaiting the network.
- [ ] Route non-kanban initialization through the helper and preserve best-effort error behavior.
- [ ] Route kanban initialization through the helper for every column while preserving independent `columnPagination` state.
- [ ] Ensure the cache paint does not erase tasks belonging to other columns and the network merge preserves the existing one-copy-per-column invariant.
- [ ] Add store tests for immediate cache paint, non-kanban cache use, per-column isolation, and network fallback.
- [ ] Run the focused workspace initialization tests.

## Task 5: Integrate refresh, search, sort, SSE, and older-page paths

**Files:** `src/apps/desktop/src/stores/workspaces.ts`, `src/apps/desktop/src/stores/kanbanSse.ts`, `src/apps/desktop/src/__tests__/workspacesStorePerColumnPagination.spec.ts`

- [ ] Make `fetchKanbanTasks` use the cache-first path for initial loads and refreshes, while keeping active query/sort metadata per item.
- [ ] Make SSE-triggered refreshes go through the same path; retain the local human-touch patch without a list request.
- [ ] Keep `loadMoreTasksForColumn` network-only, append deduplicated rows, update only the existing per-column pagination cursor, and write rows through to the task cache.
- [ ] Add tests for warm refresh, search/sort context isolation, SSE refresh behavior, and older-page write-through behavior.
- [ ] Run the focused kanban/store/SSE tests.

## Task 6: Make task mutations cache-coherent

**Files:** `src/apps/desktop/src/stores/workspaces.ts`, `src/apps/desktop/src/stores/kanbanSse.ts`

- [ ] Mirror successful create/update/pin/move responses into the relevant cache contexts.
- [ ] Evict deleted tasks and remove stale source-column copies after moves.
- [ ] Keep optimistic local updates and rollback behavior unchanged when the API fails.
- [ ] Add focused tests for create, update, delete, move, pin, and review-state cache behavior.

## Task 7: Functional and frontend verification

**Files:** `tests/functional/task_list_cache_contract_test.py` and all changed frontend files

- [ ] Add a functional contract test for the existing task-list HTTP URL and response envelope; do not add backend delta-query coverage.
- [ ] Run focused Vitest suites for the engine, API, workspace store, pagination, and SSE.
- [ ] Run the frontend type-check and lint checks; remove generated JS artifacts if `vue-tsc` emits them.
- [ ] Run the isolated functional test without touching port 8081.
- [ ] Inspect `git diff --check`, `git status`, and the complete diff for unrelated changes or forbidden plan-tag comments.
- [ ] Request a code review and address any findings.
- [ ] Commit the implementation, move the kanban task to `in_review_task`, and leave it there for human review.

## Execution notes (2026-09-24)

- Implemented frontend-only. No backend changes; the existing task-list
  endpoint shape is unchanged (covered by `task_lifecycle_test.py` and
  `kanban_task_get_test.py`, so no new functional test was added).
- Mutation coherence (`stores/workspaces.ts`): `addTask`,
  `moveTaskToColumn`, `pinTask`, `reorderPinnedTasks`, `toggleTask`,
  `renameTask`, `updateTaskDetails`, `refreshTask`, `deleteKanbanColumn`,
  `fetchTaskMedia`, `fetchTasksMedia`, and the session SSE
  `updated`/`deleted` handlers all write through or evict via
  `cacheTaskMutation` / `removeTaskFromCache` (column + board contexts).
  The sync SSE mirrors (`mirrorKanbanTaskMove`, `applyHumanTouched`)
  write through fire-and-forget so their sync signatures are unchanged.
- Complete-page reconcile: `TaskEngineDb.loadDelta` evicts context rows
  a complete (`has_more=false`) first page omits, and the three paint
  sites drop cached-only rows for complete pages instead of merging them
  back (remote delete / move-out no longer resurrect offline rows).
  Partial pages (`has_more=true`) still merge; `loadMoreTasksForColumn`
  appends via `putLocal` with no reconcile.
- Verification: new `workspacesStoreTaskCache.spec.ts` (6 tests) +
  extended `TaskEngineDb.spec.ts` (4 new) pass; `vue-tsc` clean;
  related suites 92/92; full-suite failures (35) are byte-identical on
  the clean base commit — no regressions introduced.
