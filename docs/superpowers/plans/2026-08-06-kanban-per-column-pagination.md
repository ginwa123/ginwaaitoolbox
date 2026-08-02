# Kanban — Per-column pagination (Option A) Implementation Plan

**Goal:** Replace the single board-wide `hasMoreTasks` / `tasksNextCursor` with per-column pagination state so each kanban column scrolls + paginates independently, and the "Load more" / auto-load sentinel only fetches more tasks for its own column.

**Architecture:** Backend adds an optional `?column_id=<col>` filter to `GET /api/workspaces/:ws/items/:item/tasks` and scopes the cursor to a single column. The frontend store replaces the per-item `hasMoreTasks` / `tasksNextCursor` / `isLoadingMoreTasks` with a per-column `columnPagination: Record<columnId, { cursor, hasMore, isLoading }>` map. `fetchKanbanTasks` (initial load) still returns ALL columns' first page (no `column_id` filter — preserves the existing wire). `loadMoreTasksForColumn(ws, item, columnId)` fetches the next page for ONE column only. Each `KanbanColumn` reads its own `hasMore` from the per-column map and calls `loadMoreTasksForColumn` — the column's auto-load sentinel + manual "Load more" button become per-column.

**Tech Stack:** Zig 0.16 backend (`tasks_list.zig`, `llm_history.zig`), Vue 3 + TypeScript + Pinia frontend (`workspaces.ts`, `KanbanColumn.vue`, `KanbanView.vue`, `api/index.ts`).

## Global Constraints

- **Cross-platform:** Every change must compile on Linux + macOS + Windows. Cross-compile check after the backend + store changes.
- **Back-compat:** Live `nalar` on port 8081 must remain untouched. Use port 8080 for local smoke.
- **SSE parity:** SSE-driven refetch (the kanban SSE handler that re-fetches tasks when a remote mutation happens) must clear the per-column pagination state for the affected column and refetch from page 1.
- **Search parity:** `?q=` must still filter across all columns (server-side filter stays on the items endpoint).
- **Per-column sort parity:** Per-column sort still gets forwarded on `loadMoreTasksForColumn` (the cursor is tied to the sort order).
- **Tests:** Behavioural tests only (no static-contract tests). Mirror the existing pattern (`workspacesStoreLoadMoreTasks.spec.ts`, `KanbanColumn.spec.ts`).

## File Structure

| File | Role | Change |
|---|---|---|
| `src/ai_workflow/tui/llm_history.zig` | DB fn | Add `column_id: ?[]const u8` param to `listWorkspaceItemTasksWithCursor`; add column-filter to WHERE clause. |
| `src/ai_workflow/tui/http_handlers/tasks_list.zig` | HTTP handler | Pass `column_id` query param through to DB fn. |
| `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` | Backend tests | Add tests for column filter + per-column cursor. |
| `src/apps/desktop/src/api/index.ts` | API client | Add `column_id?: string` to `getTasks` signature. |
| `src/apps/desktop/src/stores/workspaces.ts` | Pinia store | Replace `hasMoreTasks` / `tasksNextCursor` / `isLoadingMoreTasks` with `columnPagination` map; add `loadMoreTasksForColumn`; update `fetchKanbanTasks` + SSE refetch. |
| `src/apps/desktop/src/types/workspaces.ts` (if exists) | Type defs | Update `WorkspaceItem` interface. |
| `src/apps/desktop/src/components/kanban/KanbanColumn.vue` | Column view | Replace `moreTasksAvailable` / `loadingMoreTasks` to read per-column from store; update `handleAutoLoad` / `handleManualLoadMore`. |
| `src/apps/desktop/src/components/kanban/KanbanView.vue` | Board view | No big change — auto-load is per-column now. |
| `src/apps/desktop/src/__tests__/workspacesStoreLoadMoreTasks.spec.ts` | Existing test | Rewrite to test per-column pagination. |
| `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts` | Existing test | Add per-column load-more tests. |
| `src/apps/desktop/src/__tests__/workspacesStorePerColumnPagination.spec.ts` | New test | New behavioural tests for the store's per-column state machine. |
| `docs/SPEC.md` | Docs | Add changelog entry under §10.2.1. |
| `AGENTS.md` | Docs | Add changelog note. |

## Tasks

### Task 1 — Backend: pipe `column_id` query param through tasks_list handler

**Files:** `src/ai_workflow/tui/http_handlers/tasks_list.zig`

**Steps:**
- [ ] Add `column_id` to `TasksListInput` struct (Zig field, optional `?[]const u8`).
- [ ] In `parseInput`, parse `query.get("column_id")` → null/empty → null, else forward the raw string.
- [ ] Add `column_id` to the `useCase` call signature.
- [ ] Run `zig build test --summary all` and confirm the existing `tasks_list_test.zig` tests still pass (back-compat — no column_id is null).

**Verification:** `zig build test --summary all` shows no regressions. `tasks_list_test.zig` count unchanged.

**Commit:** `feat(backend): tasks_list accepts ?column_id query param`

---

### Task 2 — Backend: `listWorkspaceItemTasksWithCursor` filters by column_id

**Files:** `src/ai_workflow/tui/llm_history.zig`

**Steps:**
- [ ] Add `column_id: ?[]const u8` parameter to `listWorkspaceItemTasksWithCursor` (after `q`).
- [ ] Build a `column_id_clause`:
  - If `column_id` is null or empty → `""` (no extra WHERE).
  - Else → `" AND (t.kanban_column_id = ? OR t.kanban_column_id IS NULL)"` — NULL match is required because the existing `kanban_column_id` column is nullable (some tasks have no column).
- [ ] Append the column_id to the `binds` ArrayList when non-null.
- [ ] Append `column_id_clause` to the SQL `{s}` slots (between `cursor_clause` and `q_clause`).
- [ ] Run `zig build test --summary all` — confirm no regressions.

**Verification:** Existing tests pass. The `hasMore` logic still works (the +1 trick).

**Commit:** `feat(backend): listWorkspaceItemTasksWithCursor accepts column_id filter`

---

### Task 3 — Backend: tests for column_id filter + per-column cursor

**Files:** `src/ai_workflow/tui/http_handlers/tasks_list_test.zig`

**Steps:**
- [ ] Add test: `column_id=col_a` returns ONLY tasks in col_a (use 3+ tasks across 2 columns, request col_a, assert 1-2 results, all match `column_id=col_a`).
- [ ] Add test: `column_id=col_a` returns the correct cursor (the `next_cursor` in the response, when decoded, belongs to col_a's last row).
- [ ] Add test: `column_id=col_a` + `cursor=X` returns the NEXT page of col_a (not cols b/c).
- [ ] Add test: `column_id=col_a` + `q=foo` returns col_a rows matching "foo" (search + column filter combine).
- [ ] Add test: `column_id=` (empty) behaves like no filter (returns all columns).
- [ ] Add test: `column_id=nonexistent` returns 0 tasks + `has_more=false`.
- [ ] Run `zig build test --summary all` — all new tests pass.

**Verification:** `tasks_list_test.zig` count grows by 6+. Existing tests untouched.

**Commit:** `test(backend): lock in column_id filter for tasks_list`

---

### Task 4 — Frontend: API signature carries column_id

**Files:** `src/apps/desktop/src/api/index.ts`

**Steps:**
- [ ] Find `getTasks` (or `listWorkspaceItemTasks` — search for the source-of-truth API method name).
- [ ] Add `column_id?: string` as the 7th or 8th positional argument (after `q`).
- [ ] When `column_id` is non-empty, append `&column_id=<encoded>` to the URL.
- [ ] Run `bun run build` — type-check passes.

**Verification:** `bun run build` clean. No behavioural tests for this signature change (it's plumbing).

**Commit:** `feat(frontend): api.getTasks accepts column_id`

---

### Task 5 — Frontend store: per-column pagination state

**Files:** `src/apps/desktop/src/stores/workspaces.ts`

**Steps:**
- [ ] Add `ColumnPaginationState` interface: `{ cursor: string | null; hasMore: boolean; isLoading: boolean }`.
- [ ] Add `columnPagination: Record<columnId, ColumnPaginationState>` to `WorkspaceItem` interface.
- [ ] Replace `hasMoreTasks`, `tasksNextCursor`, `isLoadingMoreTasks` reads with a helper `getColumnPagination(itemId, columnId)` that returns the per-column state (or a default `{ cursor: null, hasMore: false, isLoading: false }`).
- [ ] In `fetchKanbanTasks` (initial / full-board page-1):
  - After receiving the response, populate `columnPagination` for ALL columns that have tasks in the response:
    - For each column id present in the returned tasks, set `{ cursor: next_cursor if hasMore else null, hasMore: hasMore, isLoading: false }`.
  - **Critical:** Each column's `hasMore` is NOT the global `has_more` — derive it from the response per-column. The simplest correct heuristic for the FIRST page: only mark `hasMore: true` for a column if that column has at least `limit` tasks in the response (server returns next page only when more rows exist). Better: when the board `has_more` is true AND the column has at least `limit` tasks in this page, set `hasMore: true` for that column. (Edge case: a sparse column with 2 tasks when limit=10 — backend may still have more, but we don't know until we paginate.)
  - **Initial implementation:** Set `hasMore: true` for every column that has any task in the page-1 response IF the global `has_more` is true. (The user can always click "Load more" to discover. Auto-load will fire only when sentinel is in view, and we can refine the heuristic later.)
- [ ] Remove the now-unused `hasMoreTasks`, `tasksNextCursor`, `isLoadingMoreTasks` fields (or keep them as deprecated back-compat for `KanbanColumn`'s old code path until Task 6 migrates).
- [ ] Update `kanbanSse.ts` (if it reads `hasMoreTasks` / `tasksNextCursor`) to clear `columnPagination` for the affected column on SSE event.
- [ ] Add new action `loadMoreTasksForColumn(workspaceId, itemId, columnId)`:
  - Read `columnPagination[columnId]`; if `!hasMore || isLoading` → return.
  - Set `isLoading = true`.
  - Read `activeSortBy` / `activeSortDirection` / `activeSearchQueries` (same as existing `loadMoreTasks`).
  - Call `api.getTasks(..., columnId, cursor, sortBy, direction, q)`.
  - Append returned tasks to `item.tasks` (or filter to only those in this column for safety).
  - Update `columnPagination[columnId] = { cursor: next_cursor, hasMore: has_more, isLoading: false }`.
  - On error: log + leave state as-is (same pattern as existing `loadMoreTasks`).
- [ ] Keep `loadMoreTasks(workspaceId, itemId)` for back-compat OR delete it. **Recommendation: delete it** — only `KanbanColumn` calls it, and Task 6 migrates that.
- [ ] Run `bun run build` + `bunx vitest run src/__tests__/workspacesStoreLoadMoreTasks.spec.ts` — type-check passes; existing tests likely FAIL (they test the old API). That's expected — Task 8 rewrites them.

**Verification:** `bun run build` clean. Existing loadMoreTasks tests fail (expected — Task 8 fixes).

**Commit:** `feat(frontend): per-column pagination state in workspacesStore`

---

### Task 6 — Frontend column: read per-column pagination state

**Files:** `src/apps/desktop/src/components/kanban/KanbanColumn.vue`

**Steps:**
- [ ] Replace `moreTasksAvailable` computed to read from `columnPagination[props.columnId]?.hasMore ?? false`.
- [ ] Replace `loadingMoreTasks` computed to read from `columnPagination[props.columnId]?.isLoading ?? false`.
- [ ] Replace `parentItem` is still used for `columnPagination` accessor.
- [ ] Update `handleAutoLoad` to call `workspacesStore.loadMoreTasksForColumn(props.workspaceId, props.itemId, props.columnId)`.
- [ ] Update `handleManualLoadMore` to call the same.
- [ ] The `loadMorePageSize` const stays — same usage.
- [ ] The auto-load sentinel + IntersectionObserver stay — they read per-column hasMore now.
- [ ] Run `bun run build` — type-check passes.

**Verification:** `bun run build` clean. Existing column tests may break (they asserted the old API call).

**Commit:** `feat(frontend): KanbanColumn paginates per-column`

---

### Task 7 — Frontend KanbanView: nothing to change (verify)

**Files:** `src/apps/desktop/src/components/kanban/KanbanView.vue`

**Steps:**
- [ ] Verify `KanbanView` does not read `item.hasMoreTasks` / `item.tasksNextCursor` / `item.isLoadingMoreTasks` directly. Search for those names.
- [ ] If any read exists, migrate to `columnPagination`.
- [ ] Run `bun run build` — clean.

**Verification:** `bun run build` clean. No grep hits for the old field names in `KanbanView.vue`.

**Commit:** `chore(frontend): no KanbanView changes needed for per-column pagination` (or skip — empty commit).

---

### Task 8 — Tests: behavioural coverage for per-column pagination

**Files:** `src/apps/desktop/src/__tests__/workspacesStorePerColumnPagination.spec.ts` (new), `src/apps/desktop/src/__tests__/workspacesStoreLoadMoreTasks.spec.ts` (rewrite), `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts` (add tests)

**Steps (new spec file):**
- [ ] `fetchKanbanTasks` populates `columnPagination` for each column with tasks in the response.
- [ ] `fetchKanbanTasks` with `has_more=true` sets `hasMore: true` for every column that has tasks in the page.
- [ ] `fetchKanbanTasks` with `has_more=false` sets `hasMore: false` for every column.
- [ ] `loadMoreTasksForColumn(ws, item, col_a)` calls `api.getTasks` with `column_id='col_a'`.
- [ ] `loadMoreTasksForColumn` appends returned tasks to `item.tasks`.
- [ ] `loadMoreTasksForColumn` updates `columnPagination[col_a].cursor` + `.hasMore`.
- [ ] `loadMoreTasksForColumn` on a column with `hasMore: false` is a no-op.
- [ ] `loadMoreTasksForColumn` while `isLoading: true` is a no-op (no double-click).
- [ ] `loadMoreTasksForColumn` forwards the active sort (sortBy + direction) on the API call.
- [ ] `loadMoreTasksForColumn` forwards the active `q` (search query) on the API call.
- [ ] `loadMoreTasksForColumn` on error: leaves `hasMore` + `cursor` untouched (retry-by-click still works).
- [ ] `fetchKanbanTasks` resets `columnPagination` to a fresh map (no stale cursors from a previous query).

**Steps (rewrite existing file):**
- [ ] Replace the old `loadMoreTasks` tests with `loadMoreTasksForColumn` tests (the old fn no longer exists).
- [ ] Keep the `fetchKanbanTasks` tests intact.

**Steps (KanbanColumn.spec.ts):**
- [ ] "Load more" button is hidden when `columnPagination[col].hasMore: false`.
- [ ] "Load more" button is hidden when `cardsInColumn.length === 0`.
- [ ] "Load more" button is visible when `hasMore: true` AND there are cards.
- [ ] Click "Load more" calls `loadMoreTasksForColumn(ws, itemId, col)`.
- [ ] Auto-load sentinel in viewport calls `loadMoreTasksForColumn` (mock IntersectionObserver).
- [ ] Auto-load sentinel does NOT call when `hasMore: false` (disconnected observer).
- [ ] Initial fetch with `has_more: true` returns tasks for col_a — column's `columnPagination[col_a].hasMore: true`.

**Verification:** `bunx vitest run` shows the new tests pass; old `loadMoreTasks` tests are deleted.

**Commit:** `test(frontend): per-column pagination coverage`

---

### Task 9 — SSE refetch: clear per-column pagination on remote event

**Files:** `src/apps/desktop/src/stores/kanbanSse.ts`

**Steps:**
- [ ] Find the SSE handler that refetches tasks on remote events (e.g., task moved, task created in a column, task deleted).
- [ ] The handler currently calls `fetchKanbanTasks(ws, item, ...)`. After this change, it must also clear `columnPagination` for the affected column (or reset the whole map — the next fetch will repopulate).
- [ ] Simplest: at the top of the SSE handler, set `item.columnPagination = {}` so the next `fetchKanbanTasks` repopulates from scratch.
- [ ] Run `kanbanSse.spec.ts` to verify no regressions.

**Verification:** `bunx vitest run src/__tests__/kanbanSse.spec.ts` passes.

**Commit:** `fix(frontend): kanbanSse refetch clears per-column pagination`

---

### Task 10 — Cross-platform compile check

**Steps:**
- [ ] `zig build test --summary all` — Linux Zig pass.
- [ ] `zig build install:linux:system` — Linux build.
- [ ] `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig` — Windows target.
- [ ] `zig build-obj -fno-emit-bin -target aarch64-macos -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig` — macOS target.
- [ ] `bun run build` — frontend type-check.
- [ ] `bunx vitest run` — full test suite.

**Verification:** All 6 steps clean.

**Commit:** `chore: cross-platform compile + test pass for per-column pagination`

---

### Task 11 — Live smoke on port 8080

**Steps:**
- [ ] Build the backend: `zig build install:linux:system`.
- [ ] Run the live binary on port 8080 with a fresh `$HOME` under `/tmp/`.
- [ ] Create a kanban with 25 tasks split across 2 columns (e.g. 15 in col_a, 10 in col_b). Page sizes: limit=10.
- [ ] Reload page-1 (no column_id) — expect 10 tasks back (mix of cols based on sort).
- [ ] Wait — page-1 of the board is mixed. The per-column pagination only kicks in on subsequent fetches. This is a known limitation: the FIRST page still shows a mix; the user's mental model is "scroll column X → click load more → see column X's next 10".
- [ ] For column_a: click "Load more" twice — expect 15 tasks in col_a (3 + 10 + 2, since page-1 may have included 3 col_a tasks).
- [ ] For column_b: click "Load more" once — expect 10 tasks in col_b.
- [ ] Verify the URL does NOT change (no `cursor` param persisted; just refresh resets to page 1).

**Verification:** Manual smoke. Capture a screenshot if possible.

**Commit:** `chore: live smoke for per-column pagination` (skip if no live traces to commit).

---

### Task 12 — Docs: AGENTS.md + SPEC.md changelog

**Files:** `AGENTS.md`, `docs/SPEC.md`

**Steps:**
- [ ] Append a `### 2026-08-06: Kanban per-column pagination` block to `AGENTS.md` (in the established format — see existing entries).
- [ ] Update `docs/SPEC.md` §10.2.1 PR index with the new entry.
- [ ] Update `docs/SPEC.md` §3 (plans by domain) — link the new plan.

**Verification:** Docs render correctly (markdown lints clean).

**Commit:** `docs: per-column pagination changelog + SPEC.md`

---

## Pitfalls

- **`hasMore` heuristic for first page is purposely imprecise.** When `fetchKanbanTasks` returns a mix of col_a + col_b tasks and `has_more: true`, we mark BOTH columns as `hasMore: true` even if one column's tasks were sparse. The auto-load will fire and immediately get `hasMore: false` from the backend on the next page. This is acceptable — the alternative (asking the backend for a per-column COUNT) is a separate endpoint. Document this in code.
- **The cursor encoding must include the column_id.** Currently the cursor is `"<sort_value>|<id>"`. With per-column pagination, the cursor must be `"<column_id>|<sort_value>|<id>"` so the backend can disambiguate (or the backend can just trust the `column_id` query param + the cursor, since they're always sent together). Simplest: the cursor stays `<sort_value>|<id>`, and the `column_id` query param is the column context. This is what the user-facing API will look like.
- **`fetchKanbanTasks` (initial) returns ALL columns mixed.** This is by design — the first page must be board-wide so the columns can populate. The per-column pagination only kicks in on page 2+.
- **The `kanbanSse` refetch path must clear per-column pagination.** Otherwise an old `cursor` from a previous query will be reused on the next fetch, causing 400 errors.
- **`KanbanView` does not need to know about column pagination.** Each column reads its own slice from the store. Don't add a `columnPagination` prop to `KanbanColumn` — let it walk the store directly (same pattern as `parentItem`).
- **The `hasMoreTasks` global fallback must be removed cleanly.** If any code path still reads `item.hasMoreTasks`, the auto-load will fire on stale state. Search for `hasMoreTasks` / `tasksNextCursor` / `isLoadingMoreTasks` across the codebase and migrate all reads.
- **No static-contract tests.** This is a hard project rule (2026-07-29). All new tests must be behavioural.

## Verification (final)

- [ ] `zig build test --summary all` — no regressions
- [ ] `zig build install:linux:system` — Linux build clean
- [ ] `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` + `-target aarch64-macos` — cross-compile clean
- [ ] `bun run build` — frontend type-check clean
- [ ] `bunx vitest run` — all tests pass (or only the documented pre-existing failures)
- [ ] Live smoke on port 8080 — per-column scroll + load more works
- [ ] AGENTS.md + SPEC.md updated
- [ ] No `hasMoreTasks` / `tasksNextCursor` / `isLoadingMoreTasks` reads anywhere in the codebase
- [ ] PR opened for review
</content>
</invoke>