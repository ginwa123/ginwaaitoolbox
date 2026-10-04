# Kanban Task Detail — Single-Task Fetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Opening the kanban Task details dialog must fetch exactly ONE task (`GET /api/workspaces/:ws/items/:item/tasks/:task_id`) instead of refetching the whole task list with `limit=100`.

**Architecture:** Add a new single-task GET endpoint on the backend (new `tasks_get.zig` handler + a new `getWorkspaceItemTaskById` DB fn in `llm_history.zig` that reuses the exact SELECT/JOIN/row-mapping of the existing lister, scoped by `t.id = ?`), then switch the frontend `refreshTask` store action from `api.getTasks(ws, item, 100)` to the new `api.getTask(ws, item, taskId)`. The response reuses the existing `WorkspaceItemTaskResponse` shape wrapped in `{ task: {...} }`, so the dialog, normalization, and store-splice logic stay unchanged.

**Tech Stack:** Zig 0.16 backend (gserverz HTTP router, SQLite via `SqliteBackend`), Vue 3 + Pinia + TypeScript frontend, Vitest for frontend tests, static-contract Zig tests for the handler.

## Global Constraints

- **NEVER kill or bind port 8081** — the user's dev server lives there. Functional tests use the harness (ports 8080–8199).
- **User convention (2026-08-24):** test and impl code should live in ONE file — inline `test` blocks at the bottom of the implementation file. (Exception: `http_handlers/` has an established sibling `*_test.zig` convention with static-contract tests; follow the local convention there — new sibling `tasks_get_test.zig`, registered in `test_runner.zig`.)
- **Route-order shadowing:** `matchRoute` walks routes in registration order. The new literal route `GET .../tasks/:task_id` must be registered AFTER the existing `GET .../tasks` list route (it is — `:task_id` only appears in a longer path, and the list route `/tasks` is a strict prefix that only matches when the path ends there; verify with a static test).
- **Empty-slice-as-NULL binding:** `SqliteBackend.exec`/`query` bind `""` as SQL NULL. The `task_id` path param must be validated non-empty BEFORE any DB call (400 otherwise).
- **Per-request arena:** handlers allocate from `ctx.allocator` (arena) — do NOT `defer allocator.free` arena-backed strings; DO keep `defer rows.deinit()` for SQLite statement handles and `defer task.deinit(allocator)` for `WorkspaceItemTaskInfo`.
- **SSE:** no new SSE events in this plan — no wire-contract triple-check needed.
- **No comments above `logger.infoFmt(...)` calls.**
- **Frontend tests:** Teleport-based dialog tests need `attachTo: document.body` + `document.querySelector` (not relevant here — we test the store + api layer, not the dialog).
- **`zig build test --summary all` must stay green** (baseline: 2636 pass / 6 skip / 0 fail; known pre-existing failures are unrelated — see memory `mem_a1eabbc7daa573fa` for the current list if counts drift).
- **`bun run test:unit` must stay green** (baseline 2578 pass).

## Root Cause (verified 2026-08-24)

`KanbanView.vue:678 handleViewTaskDetail` → `workspacesStore.refreshTask(...)` → `workspaces.ts:3592`:

```ts
const { tasks: fresh } = await api.getTasks(workspaceId, itemId, 100)
const freshTask = fresh.map(normalizeTaskTags).find((t) => t.id === taskId)
```

Every dialog open downloads up to 100 full task rows (with routine JOINs, tags, image_urls base64 blobs, git-branch subprocess per row) to update ONE task. The store comment at `workspaces.ts:3573-3580` even documents this as a deliberate trade-off ("avoids adding a new GET /tasks/:id endpoint") — that trade-off no longer holds now that the board has 270+ tasks and `image_urls` carries base64 payloads.

There is no single-task GET endpoint today (`src/main.zig:441` only registers the list route).

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `src/ai_workflow/tui/agentic_loop/llm_history.zig` | EDIT | Add `pub fn getWorkspaceItemTaskById(...)` — single-row variant of `listWorkspaceItemTasksWithCursor` |
| `src/ai_workflow/tui/http_handlers/tasks_get.zig` | NEW | `tasksGetHandler` for `GET /api/workspaces/:ws/items/:item/tasks/:task_id` |
| `src/ai_workflow/tui/http_handlers/tasks_get_test.zig` | NEW | Static-contract tests (route registration, handler wiring, DB fn existence, non-empty task_id guard) |
| `src/ai_workflow/tui/http_handlers/mod.zig` | EDIT | Re-export `tasksGetHandler` |
| `src/ai_workflow/tui/test_runner.zig` | EDIT | Register `tasks_get_test.zig` |
| `src/main.zig` | EDIT | Register the GET `:task_id` route |
| `src/apps/desktop/src/api/index.ts` | EDIT | Add `getTask(workspaceId, itemId, taskId)` |
| `src/apps/desktop/src/stores/workspaces.ts` | EDIT | Rewrite `refreshTask` to call `getTask` |
| `src/apps/desktop/src/__tests__/workspacesStoreRefreshTask.spec.ts` | EDIT | Update mocks from list-shape to single-task shape; add "calls getTask not getTasks" assertion |
| `src/apps/desktop/src/__tests__/apiGetTask.spec.ts` | NEW | Wire-shape tests for `getTask` (URL, 404 → null) |

---

## Task 1 — Backend: `getWorkspaceItemTaskById` DB function

**Files:**
- Edit: `src/ai_workflow/tui/agentic_loop/llm_history.zig`

**Context for the engineer:** `listWorkspaceItemTasksWithCursor` (llm_history.zig:4846) is the live lister. Its SELECT (line 5011) joins `kanban k`, `routines r`, `sessions s` and returns 25 columns (indices 0–24 documented at lines 5045–5067). The row-mapping block (lines 5068–5136) builds a `WorkspaceItemTaskInfo` (struct at ~line 4200, `deinit` at 4301). We extract NOTHING — we copy the SELECT + mapping into a new single-row function. Duplication is deliberate: the lister is cursor/pagination-entangled and refactoring it risks regressions across every kanban fetch site. (DRY exception justified: the two functions share the *schema contract*, not the *query shape*.)

**Steps:**

- [ ] Write the failing test first. Add an inline `test` block at the bottom of `llm_history.zig` (the file already has inline tests — see `test_runner.zig`-registered blocks; follow the existing pattern in that file, e.g. how `listWorkspaceItemTasksWithCursor` is contract-tested in `tasks_list_test.zig:200-216` via source grep). The test greps the source for:
  - `pub fn getWorkspaceItemTaskById(`
  - the signature params `(allocator, db, workspace_item_id, task_id)`
  - `WHERE t.workspace_item_id = ? AND t.id = ?` (both scoping binds present — task_id alone is NOT enough; the item scoping prevents cross-item task reads)
  - `LIMIT 1`
  - Assert it fails: `zig build test --summary all 2>&1 | head -n 30` → the new test fails with "does not define".
- [ ] Implement `getWorkspaceItemTaskById` directly above `listWorkspaceItemTasksWithCursor` (line ~4845):

```zig
/// Fetch ONE workspace item task by id, scoped to its parent item.
/// Returns null when no row matches (caller maps to 404).
/// SQL + row mapping mirror listWorkspaceItemTasksWithCursor
/// (same 25-column contract, indices 0-24) minus cursor/sort/
/// pagination — replaced by `WHERE t.id = ? ... LIMIT 1`.
/// Caller owns the returned task; free with `.deinit(allocator)`.
pub fn getWorkspaceItemTaskById(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    task_id: []const u8,
) !?WorkspaceItemTaskInfo {
```

  - SQL: copy the exact SELECT string from line 5011 (all 25 columns + the 3 LEFT JOINs), replace the WHERE tail: `WHERE t.workspace_item_id = ? AND t.id = ? LIMIT 1` (drop `{s}{s}{s} {s} LIMIT {s}` cursor/q/column/order/limit formatting).
  - Binds: `&.{workspace_item_id, task_id}` (order matters — matches the `?` order).
  - Row mapping: copy lines 5068–5133 verbatim (the `while (try rows.next())` body), but:
    - guard with `if (try rows.next()) |row| { ... return task; }` instead of a while loop,
    - `row.deinit(allocator)` before `return task`,
    - `return null` after the if (no row).
- [ ] Run: `zig build test --summary all 2>&1 | tail -n 5` → new test passes, no new failures.
- [ ] Commit: `git add -A && git commit -m "kanban: add getWorkspaceItemTaskById DB fn (single-task fetch)"`

---

## Task 2 — Backend: `tasks_get.zig` handler + route

**Files:**
- New: `src/ai_workflow/tui/http_handlers/tasks_get.zig`
- New: `src/ai_workflow/tui/http_handlers/tasks_get_test.zig`
- Edit: `src/ai_workflow/tui/http_handlers/mod.zig` (line ~88, next to `tasksListHandler`)
- Edit: `src/ai_workflow/tui/test_runner.zig` (line ~24, next to `tasks_list_test`)
- Edit: `src/main.zig` (line ~441, immediately AFTER the `tasksListHandler` GET route)

**Context:** Model the handler on `tasks_list.zig` (handler at :293, error mapping at :315-330). Response reuses `http_response.WorkspaceItemTaskResponse` (http_response.zig:479) — the SAME struct the list endpoint serializes, so the frontend's `Task` type needs zero changes. The git_branch computation (tasks_list.zig:160, 187-199: `fetchWorkspaceItemPath` fallback + `resolveGitBranch`) must be replicated — the dialog shows the branch badge.

**Steps:**

- [ ] Write failing static-contract tests in `tasks_get_test.zig` (follow `tasks_list_test.zig` style — source-grep contracts):
  1. `tasks_get.zig` calls `getWorkspaceItemTaskById`
  2. `tasks_get.zig` guards empty task_id → 400 (`task_id required`)
  3. `mod.zig` re-exports `tasksGetHandler`
  4. `main.zig` registers `GET /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id` → `tasksGetHandler`, and the registration line appears AFTER the `tasksListHandler` line (route-order shadowing guard)
  5. `llm_history.zig` exposes `pub fn getWorkspaceItemTaskById(`
  Run `zig build test --summary all 2>&1 | tail -n 5` → 5 new tests fail.
- [ ] Implement `tasks_get.zig`:

```zig
//! GET /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id
//!
//! Single-task fetch for the kanban Task details dialog. Returns
//! `{ task: {...} }` using the same WorkspaceItemTaskResponse shape
//! as the list endpoint (GET .../tasks) so the frontend Task type is
//! unchanged. 404 when the task does not exist under the item.
```

  - Handler: extract `item_id` + `task_id` from `req.params`; 400 when either is empty (`"item_id required"` / `"task_id required"`).
  - UseCase: call `ai_mod.llm_history.getWorkspaceItemTaskById(allocator, db, item_id, task_id) catch return error.QueryFailed`; `defer if (task) |t| t.deinit(allocator)`.
  - `null` result → 404 `makeErrorResponse(allocator, .{ .@"error" = "task not found" })`.
  - Found → compute `item_path` + `git_branch` exactly like tasks_list.zig:160-199 (copy the two helpers or import them — they're file-private in tasks_list.zig, so COPY `fetchWorkspaceItemPath` + `resolveGitBranch` into tasks_get.zig; ~60 lines, documented duplication).
  - Serialize: build one `WorkspaceItemTaskResponse` (field-for-field identical to tasks_list.zig:201-253) and wrap: `try std.fmt.allocPrint(allocator, "{{\"task\":{s}}}", .{task_json})` — or simpler, use `std.json.Stringify` on a wrapper struct `.{ .task = resp }`. Return 200.
- [ ] Wire `mod.zig` re-export + `test_runner.zig` import + `main.zig` route (AFTER the list route, with a comment pointing at this plan).
- [ ] Run: `zig build test --summary all 2>&1 | tail -n 5` → all green.
- [ ] **Functional test (MANDATORY per workspace rule — HTTP route):** add `tests/functional/kanban_task_get_test.py` using `tests/functional/harness.py`:
  1. create workspace + kanban item + task (POST `/api/workspaces/:ws/items/:item/kanban/tasks` mode default),
  2. `GET /api/workspaces/:ws/items/:item/tasks/:task_id` → 200, body has `task.id == task_id`, `task.name`, `task.is_auto_retry_until_stop` key present,
  3. wrong item id in path → 404,
  4. unknown task_id → 404,
  5. `GET .../tasks?limit=100` still works (list route unshadowed).
  Run: `PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/kanban_task_get_test.py -v`
- [ ] Commit: `git add -A && git commit -m "kanban: GET /tasks/:task_id single-task endpoint + functional test"`

---

## Task 3 — Frontend: `api.getTask()` + `refreshTask` rewrite

**Files:**
- Edit: `src/apps/desktop/src/api/index.ts` (add `getTask` right after `getTasks`, ~line 620)
- Edit: `src/apps/desktop/src/stores/workspaces.ts` (`refreshTask`, lines 3565-3615)
- Edit: `src/apps/desktop/src/__tests__/workspacesStoreRefreshTask.spec.ts`
- New: `src/apps/desktop/src/__tests__/apiGetTask.spec.ts`

**Context:** `refreshTask`'s job is unchanged — fetch server-truth for one task and splice it into `item.tasks` in place (the dialog re-derives its form from the watcher). Only the transport changes. Keep the best-effort semantics (catch → `console.warn`, never block the dialog). Keep `normalizeTaskTags` (it also folds in `normalizeTaskImageUrlsInPlace`, workspaces.ts:244-249).

**Steps:**

- [ ] Write failing test `apiGetTask.spec.ts` (mock `fetch` via `vi.fn()` returning `{ ok, status, json }` per the project's api-test pattern — see `apiTasks.spec.ts`):
  1. `getTask('ws_1', 'item_1', 'task_9')` issues `GET /api/workspaces/ws_1/items/item_1/tasks/task_9` (assert exact URL),
  2. 200 `{ task: {...} }` → resolves to the task object,
  3. 404 → resolves to `null` (NOT a throw — the store treats missing as no-op),
  4. network error → throws (store catches).
  Run `bun run test:unit -- apiGetTask` → fails (function doesn't exist).
- [ ] Implement in `api/index.ts` after `getTasks`:

```ts
/**
 * Fetch ONE workspace item task by id (kanban Task details dialog).
 * GET /api/workspaces/:ws/items/:item/tasks/:task_id → { task } | 404.
 * Resolves to the Task, or null on 404 (task deleted / wrong item).
 * Replaces the old refreshTask list-refetch (limit=100) — one row
 * on the wire instead of the whole board.
 */
export async function getTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<Task | null> {
  const data = await apiFetch<{ task: Task | null }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/items/${encodeURIComponent(itemId)}/tasks/${encodeURIComponent(taskId)}`,
  )
  return data.task ?? null
}
```

  (Check how `apiFetch` handles 404 — read its implementation first; if it throws on non-2xx, wrap in try/catch on `status === 404` and `return null`.)
- [ ] Update `workspacesStoreRefreshTask.spec.ts`: mocks change from `{ tasks: [...], has_more: false, next_cursor: null }` to `{ task: {...} }`; spy on `api.getTask` instead of `api.getTasks`. Add one new assertion: **`api.getTasks` is NOT called** by `refreshTask` (this is the regression this whole plan exists for).
- [ ] Rewrite `refreshTask` (workspaces.ts:3586-3615):

```ts
async function refreshTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<void> {
  try {
    const freshTask = await api.getTask(workspaceId, itemId, taskId)
    if (!freshTask) return
    const normalized = normalizeTaskTags(freshTask)
    for (const ws of workspaces.value) {
      if (ws.id !== workspaceId) continue
      for (const item of ws.items) {
        if (item.id !== itemId) continue
        if (!item.tasks) continue
        const idx = item.tasks.findIndex((t) => t.id === taskId)
        if (idx === -1) continue
        item.tasks.splice(idx, 1, normalized)
        return
      }
    }
  } catch (err) {
    console.warn('Failed to refresh task before dialog open:', err)
  }
}
```

  Also update the stale comment block above it (lines 3565-3585): the "re-fetch the WHOLE task list" rationale is gone — now reads "fetch the single task via GET /tasks/:task_id (plan: 2026-08-24-kanban-task-detail-single-fetch.md)".
- [ ] Run: `bun run test:unit` → all green (watch `kanbanSse.spec.ts` and `workspacesStoreInit.spec.ts` — they mock `getTasks` for OTHER call sites, untouched).
- [ ] Commit: `git add -A && git commit -m "kanban: task detail dialog fetches one task instead of limit=100 list"`

---

## Task 4 — Verification + changelog

- [ ] Full backend: `zig build test --summary all 2>&1 | tail -n 5` → 0 fail, 0 new leaks.
- [ ] Full frontend: `bun run test:unit 2>&1 | tail -n 5` → all pass.
- [ ] Functional: `PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/kanban_task_get_test.py -v` → 5/5 pass.
- [ ] Manual smoke (user's dev flow, port 8080 — NEVER 8081): open kanban with 270+ tasks, click a card → DevTools Network shows ONE `tasks/task_xxx` request, NO `tasks?limit=100` request. Dialog still shows live unattended toggle + tags + images + branch badge.
- [ ] Add AGENTS.md changelog entry (follow the existing "What landed / Wire / Files / Plan" format).
- [ ] Commit: `git add -A && git commit -m "docs: changelog for kanban single-task fetch"`

## Pitfalls

- **Route shadowing check is not paranoia:** `matchRoute` is order-sensitive (see router.zig:182 note in workspace rules). The static test in Task 2 asserting registration order is the guard.
- **Don't "fix" the dead lister:** `listWorkspaceItemTasks` (non-cursor, llm_history.zig:4729) has no production callers. Leave it alone.
- **`apiFetch` 404 semantics:** verify before writing `getTask` — if `apiFetch` throws on 404, `getTask` must catch and return `null`, or `refreshTask`'s best-effort catch handles it (but then the store can't distinguish "deleted" from "network down" — prefer null-on-404 in the api layer).
- **image_urls base64 bloat is the point:** the single-task response still carries the task's own images (needed by the dialog gallery) — that's correct. The win is not carrying 99 OTHER tasks' images.
- **`encodeURIComponent` on path segments:** the existing `getTasks` does NOT encode (line 614); ids are server-generated (`task_<ts>_<n>`) so it's cosmetic — but encode in the new function anyway, it's free.

## Verification

- [ ] Plan saved to `docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md`
- [ ] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task has bite-sized steps (test → implement → verify → commit)
- [ ] User has reviewed the plan before execution begins
