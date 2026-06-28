# Workspace Item Task Pagination (Click-to-Load) — v2

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Supersedes:** `docs/plans/2026-06-06-workspace-item-task-pagination.md` (989 lines, never executed). This v2 is a fresh, condensed plan that:
> 1. Updates line numbers for the post-`WorkspaceItemTask.vue` refactor (commit `6cb63fe`, 2026-06-10).
> 2. Confirms `Sidebar.vue` is the parent that wires `loadMoreTasks` to the store (not `AppLayout.vue` as v1 guessed).
> 3. References v1 for verbose code blocks that have not changed (Zig `listWorkspaceItemTasks` body, full backend test bodies, etc.).

**Goal:** Add cursor-paginated "Load More" pagination to the task list shown inside each expanded `WorkspaceItem` in the desktop sidebar. The user **must click** a button to fetch the next page; there is no auto-load / infinite scroll. (This is the click-to-load behaviour the user asked for — not the lazy/auto-load pattern used elsewhere.)

**Architecture:** Extend `GET /api/workspaces/:workspace_id/items/:item_id/tasks` with `limit` + `cursor` query params and a `has_more` / `next_cursor` response shape (mirror the existing `getChatHistory` / `session_list.zig` pattern). Store the pagination state per-item in the existing `workspaces` Pinia store. Render a single "Load More" button at the bottom of the task list in `WorkspaceItem.vue` (the parent component, not the newly-extracted `WorkspaceItemTask.vue`). Each item's task list is independent — the button and pagination state live per-item.

**Tech Stack:** Zig 0.15 (backend handler + DB layer), TypeScript / Vue 3 / Pinia (frontend store + component), Vitest (frontend tests).

---

## Background — Why a v2 Plan?

The v1 plan from 2026-06-06 is structurally sound but stale:

| Change since v1 | Effect on the plan |
|---|---|
| 2026-06-10: extracted `WorkspaceItemTask.vue` from `WorkspaceItem.vue` (commit `6cb63fe`) | The Load More button is now added to a different `<div>` (post-`v-for` inside the `v-if` wrapper, after `<WorkspaceItemTask v-for>`). v1's line numbers (125-166) are wrong. |
| 2026-06-10: confirmed `Sidebar.vue` is the parent of `WorkspaceList` (not `AppLayout.vue` as v1 hedged) | Task 3.2's parent-update step is now concrete. |
| Last 4 days of work: ~31 commits, new skills (`sse-pagehide-cleanup`, `sseClient` wrapper) | v1's "Background" section is outdated. v2 reflects current state. |

The Zig code itself (DB function, response struct, handler) is **unchanged** in v2 because the backend state has not moved. v1's Task 1.1–1.4 are reused verbatim with a one-line cross-reference. The frontend work is **re-scoped** to account for the `WorkspaceItemTask` boundary.

---

## File Structure

### Backend (Zig) — unchanged from v1

- **Modify** `src/ai_workflow/tui/llm_history.zig:2356-2373` — add `listWorkspaceItemTasksWithCursor` (cursor = `created_at` of the last task from the previous page, `limit + 1` "peek" trick to compute `has_more`, same pattern as `getSessionListWithCursor`).
- **Modify** `src/ai_workflow/tui/http_handlers/http_response.zig:295-310` — add `has_more: bool = false` and `next_cursor: ?[]const u8 = null` to `WorkspaceItemTaskListResponse`; update `makeWorkspaceItemTaskListResponse` to accept the new fields.
- **Modify** `src/ai_workflow/tui/http_handlers/tasks_list.zig:8-43` — parse `limit` + `cursor` query params, call the new cursor function, return `has_more` / `next_cursor` in the response.
- **Create** `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` — integration-style tests. **Wire into `test_runner.zig:13`** next to the existing `_ = @import("http_handlers/tasks_update_test.zig");` line.

### Frontend (TypeScript / Vue) — updated for post-refactor state

- **Modify** `src/apps/desktop/src/api/index.ts:135-139` — extend `getTasks(workspaceId, itemId, limit?, cursor?)` to accept optional pagination params, parse `has_more` / `next_cursor` from the response.
- **Modify** `src/apps/desktop/src/stores/workspaces.ts:15, 169-180, 407-435, 460-489, 770+` — extend the `WorkspaceItem` interface with `hasMoreTasks?: boolean` + `tasksNextCursor?: string | null` + `isLoadingMoreTasks?: boolean`; add `loadMoreTasks(workspaceId, itemId)` action; update `init()` to seed those fields from the first page; export `loadMoreTasks` from the store.
- **Modify** `src/apps/desktop/src/components/WorkspaceItem.vue:23-35, 75-100, 189-204` — add `loadMoreTasks: [workspaceId, itemId]` to `defineEmits`; add `handleLoadMoreTasks` pass-through; add a "Load More" button at the bottom of the task-list `<div>` (after the `<WorkspaceItemTask v-for>`).
- **Modify** `src/apps/desktop/src/components/WorkspaceList.vue:23-35, 131-146, 262-274` — add `loadMoreTasks: [workspaceId, itemId]` to `defineEmits`; add a pass-through `handleLoadMoreTasks`; forward `@load-more-tasks` from `<WorkspaceItemComponent>` to the parent (`Sidebar`).
- **Modify** `src/apps/desktop/src/components/Sidebar.vue:7, 23-35, 306-321, 367-373, 450-464` — add `loadMoreTasks: [workspaceId, itemId]` to `defineEmits`; add `handleLoadMoreTasks(workspaceId, itemId)` that calls `workspacesStore.loadMoreTasks(workspaceId, itemId)`; wire `@load-more-tasks` from `<WorkspaceList>`.

### Tests

- **Create** `src/apps/desktop/src/__tests__/workspacesStoreLoadMoreTasks.spec.ts` — store-level test for `loadMoreTasks` (appends + advances cursor, no-op when `hasMoreTasks === false`, no-op when in flight, leaves state intact on failure).
- **Create** `src/apps/desktop/src/__tests__/workspaceItemTaskLoadMore.spec.ts` — component test for the Load More button (renders when `hasMoreTasks`, hidden otherwise, click emits `loadMoreTasks`, spinner + disabled during load, `stopPropagation` works).

---

## Design Notes (read first)

1. **Click-to-load, NOT lazy/auto-load.** The user explicitly asked for click-to-load. The button is the ONLY trigger for fetching the next page. There is no scroll listener, no IntersectionObserver, no auto-fetch on expansion. The button is hidden when `hasMoreTasks === false` (i.e. we've reached the end).
2. **Default page size: 20.** Chosen to match the `loadMoreChats` pattern in `ChatsList.vue:164-189`. Reasonable for a sidebar task list — fits comfortably and rarely needs more than one or two loads per session.
3. **Cursor = `created_at` timestamp string of the last task from the previous page.** Same pattern as `getSessionListWithCursor` (`llm_history.zig:416` bug-fix entry). Tasks are ordered `created_at DESC`, so `WHERE created_at < ?` yields the next older page.
4. **Per-item state, not a global "all tasks" fetch.** Each `WorkspaceItem` has its own `hasMoreTasks` + `tasksNextCursor` + `isLoadingMoreTasks` because the task lists of different items are independent. The `init()` code that fans out per-item (`workspaces.ts:169-180`) already supports this shape — extend it to seed pagination fields.
5. **Existing patterns to copy:**
   - Handler: `src/ai_workflow/tui/http_handlers/session_list.zig:11-55` — the `limit` / `cursor` parsing + `has_more` computation. Mirror this exactly.
   - Frontend state: `src/apps/desktop/src/components/ChatsList.vue:121-183` (`loadMoreChats`) — the canonical click-to-load pattern in this codebase. `chatsHasMore` + `chatsNextCursor` + `chatsLoading` guard, append, then update both fields.
   - Frontend event wiring: `selectTask` / `deleteTask` / `renameTask` chain through `WorkspaceItem → WorkspaceList → Sidebar` (we just added these on 2026-06-10 in commit `6cb63fe`). Mirror that exact chain for `loadMoreTasks`.
6. **The Load More button lives in `WorkspaceItem.vue`, NOT `WorkspaceItemTask.vue`.** Reason: the button is a sibling of the per-task list (it appears once at the bottom of the entire task list for that item), not a property of any individual task. Putting it in `WorkspaceItemTask.vue` would render it once per task. The post-refactor (commit `6cb63fe`) `WorkspaceItem.vue` already owns the `<div v-if="isExpanded && item.tasks && item.tasks.length > 0" class="ml-8 mt-1 space-y-0.5">` wrapper, so the button goes right after the closing `</WorkspaceItemTask>` of the `v-for`.
7. **`unshift` for new tasks is preserved.** `addTask` (`workspaces.ts:407-435`) prepends new tasks to `item.tasks`. This still works with pagination because new tasks have the *latest* `created_at` and live in the "first page" zone. The cursor only advances as the user clicks "Load More" *downward* (older tasks).
8. **`addTask` and `deleteTask` are safe to leave as-is.** Adding a new task doesn't invalidate the cursor (it's still older than the cursor's `created_at` boundary). Deleting a task shrinks the current page but doesn't add new "has more" — the cursor still points to the same point in the timeline. Only `init()` and the new `loadMoreTasks` action touch the new fields.
9. **No changes to:** `createTask` / `updateTask` / `deleteTask` handlers, DB schema / migrations (the existing `idx_workspace_item_tasks_item_created` index from `migration.zig:644` already covers the cursor query), or the `addTask` action semantics.
10. **Verification commands** (always run before claiming done):
    - Backend: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 60 zig build 2>&1 | tail -n 20`
    - Backend tests: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test 2>&1 | tail -n 40` (uses `test_runner.zig`)
    - Frontend: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30` (TS check + build — per the mandatory rule, NOT `build-only`)
    - Frontend tests: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run test:unit --run 2>&1 | tail -n 50` (note: the package script is `test:unit`, not `test:run` as v1 had)

---

# Chunk 1: Backend Pagination

> **Reuses v1's Task 1.1–1.4 verbatim.** The Zig code in `llm_history.zig`, `http_response.zig`, `tasks_list.zig`, and the test pattern from `tasks_update_test.zig` have not changed since 2026-06-06. The executor should follow v1's tasks 1.1, 1.2, 1.3, 1.4 step-by-step.

**Reference:** `docs/plans/2026-06-06-workspace-item-task-pagination.md` lines 56-384.

**One adjustment for v2:** when wiring `tasks_list_test.zig` into `test_runner.zig`, insert the import at `src/ai_workflow/tui/test_runner.zig:13` (immediately after the existing `_ = @import("http_handlers/tasks_update_test.zig");`), not at line 14 or below. v1 didn't specify a line number.

## Task 1.1: Add cursor-based DB query function (per v1)

**Files:** Modify `src/ai_workflow/tui/llm_history.zig:2356-2373`

Add `listWorkspaceItemTasksWithCursor` directly below the existing `listWorkspaceItemTasks`. Signature + body: see v1 lines 65-138. Verify the SQLite API call pattern against the actual `db.query(allocator, sql, params)` signature used by `getSessionListWithCursor` in the same file — the skeleton in v1 was a draft, not a copy-paste.

## Task 1.2: Extend the response type to carry pagination fields (per v1)

**Files:** Modify `src/ai_workflow/tui/http_handlers/http_response.zig:295-310`

Add `has_more: bool = false` and `next_cursor: ?[]const u8 = null` to `WorkspaceItemTaskListResponse`; update `makeWorkspaceItemTaskListResponse` to accept and serialize the new fields. See v1 lines 158-202 for the exact struct + helper signatures.

## Task 1.3: Wire the handler to use cursor pagination (per v1)

**Files:** Modify `src/ai_workflow/tui/http_handlers/tasks_list.zig:8-43`

Parse `limit` (default 20, max 100) + `cursor` (null when absent) query params, call `listWorkspaceItemTasksWithCursor`, return `has_more` / `next_cursor`. See v1 lines 217-289. The 44-line file is short — the rewrite replaces the whole handler body. `next_cursor` should be the `created_at` of the last task in the current page when `has_more` is true, null otherwise.

## Task 1.4: Add integration tests for the handler (per v1, with wiring fix)

**Files:**
- Create `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` — see v1 lines 322-369 for the 6 test cases to cover (default limit, limit query param, cursor advance, end-of-pages, MAX_PAGE_SIZE clamp, missing item_id 400).
- Modify `src/ai_workflow/tui/test_runner.zig:13` — insert `_ = @import("http_handlers/tasks_list_test.zig");` on a new line immediately after the existing `tasks_update_test.zig` import. The test runner file has 18 lines; the existing 3 test imports live at lines 10-13.

Use the existing `tasks_update_test.zig` as the structural reference (DB setup, teardown, mock HTTP context pattern). The exact mocking pattern is project-specific — read `tasks_update_test.zig` first to match its style.

## Backend chunk acceptance criteria
- `zig build` is clean
- `zig build test` runs all 6 new `tasks_list_test.zig` tests + all existing tests
- `curl /api/workspaces/<ws>/items/<item>/tasks` returns `{ tasks, count, has_more, next_cursor }`
- `curl /api/workspaces/<ws>/items/<item>/tasks?limit=5&cursor=<created_at>` returns the next page

---

# Chunk 2: Frontend API + Store

## Task 2.1: Extend the frontend `getTasks` API helper

**Files:** Modify `src/apps/desktop/src/api/index.ts:135-139`

- [ ] **Step 1: Update `getTasks` to support pagination**

Replace the existing 5-line function with:

```typescript
/**
 * Fetch tasks for a workspace item, with optional cursor pagination.
 *
 * @param workspaceId  - owning workspace
 * @param itemId       - workspace item (e.g. a project folder)
 * @param limit        - page size (default 20; backend clamps at 100)
 * @param cursor       - the `created_at` of the last task from the previous
 *                       page; pass undefined for the first page
 * @returns `{ tasks, has_more, next_cursor }`. `next_cursor` is null when
 *          there are no more pages.
 */
export async function getTasks(
  workspaceId: string,
  itemId: string,
  limit = 20,
  cursor?: string,
): Promise<{
  tasks: Task[]
  has_more: boolean
  next_cursor: string | null
}> {
  const params = new URLSearchParams()
  params.set('limit', String(limit))
  if (cursor) {
    params.set('cursor', cursor)
  }
  const response = await fetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks?${params.toString()}`,
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const data = await response.json()
  return {
    tasks: data.tasks ?? [],
    has_more: data.has_more ?? false,
    next_cursor: data.next_cursor ?? null,
  }
}
```

**Behavior preserved:** all current callers that call `getTasks(workspaceId, itemId)` with no extra args get `{ tasks, has_more, next_cursor }` instead of `{ tasks }`. Update the one caller in `workspaces.ts:173` (in Task 2.2 below) to destructure the new fields. The shape is a superset — no other callers exist.

- [ ] **Step 2: Build the frontend to confirm types.** Run `bun run build`. Expected: clean (the one caller is updated in Task 2.2, not here).

- [ ] **Step 3: Commit.**
  ```bash
  git add src/apps/desktop/src/api/index.ts
  git commit -m "feat(frontend): extend getTasks API helper with limit and cursor"
  ```

## Task 2.2: Add per-item pagination state and `loadMoreTasks` action to the store

**Files:** Modify `src/apps/desktop/src/stores/workspaces.ts:15, 169-180, 407-435, 460-489, 770+`

- [ ] **Step 1: Extend the `WorkspaceItem` interface (line 15).** Add three optional fields:

  ```typescript
  export interface WorkspaceItem {
    id: string
    name: string
    item_type: string
    path?: string
    lastAccessed?: Date
    entries?: FolderEntry[]
    isLoaded?: boolean
    isLoading?: boolean
    expanded?: boolean
    tasks?: Task[]
    // Pagination state for the task list. Populated when tasks are first
    // fetched (in init()) and reset whenever tasks are reloaded. `null`
    // next_cursor means there are no more pages. `isLoadingMoreTasks` is
    // per-item and independent of `isLoading` (which is for the folder
    // entry fetch). See loadMoreTasks action below.
    hasMoreTasks?: boolean
    tasksNextCursor?: string | null
    isLoadingMoreTasks?: boolean
  }
  ```

- [ ] **Step 2: Seed the new fields in `init()` (lines 169-180).** Switch the per-item fan-out from the old `{ tasks }` shape to the new `{ tasks, has_more, next_cursor }` shape:

  ```typescript
  await Promise.all(
    (items || []).map(async (item: WorkspaceItem) => {
      try {
        const { tasks, has_more, next_cursor } = await api.getTasks(ws.id, item.id)
        tasksByItem.set(item.id, tasks)
        // Stash pagination state on the item object directly. The spread
        // below (~line 191) will copy these into the final item.
        item.hasMoreTasks = has_more
        item.tasksNextCursor = next_cursor
      } catch (err) {
        console.error(`Failed to fetch tasks for item ${item.id}:`, err)
      }
    }),
  )
  ```

  Don't change the final `.map((item) => ({ ...item, … }))` — the spread will pick up the new fields automatically. If the catch fires, `hasMoreTasks` / `tasksNextCursor` stay `undefined`, which the Load More button treats as "no more pages" (the template's `v-if="item.hasMoreTasks"` is falsy for `undefined`).

- [ ] **Step 3: Confirm `addTask` and `deleteTask` are safe to leave as-is.** Read the two actions:
  - `addTask` (lines 407-435) `unshift`s a new task. Pagination state is unchanged (cursor still points to the same boundary). **No change.**
  - `deleteTask` (lines 460-489) removes a task by id. Pagination state is unchanged. **No change.**

  (Both functions are also covered by the v1 plan's rationale in lines 508-516 — same logic applies in v2 because the surrounding code is the same.)

- [ ] **Step 4: Add the `loadMoreTasks` action.** Insert after the `deleteTask` action (around line 489), before any unrelated follow-on action:

  ```typescript
  // Load the next page of tasks for a workspace item. No-op if there are
  // no more pages, a load is already in progress for this item, or the
  // item / workspace can't be found. Mirrors the `loadMoreChats` pattern
  // in ChatsList.vue:121-183.
  async function loadMoreTasks(workspaceId: string, itemId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item) return
    if (item.isLoadingMoreTasks) return
    if (!item.hasMoreTasks) return
    if (!item.tasksNextCursor) return

    item.isLoadingMoreTasks = true
    try {
      const { tasks, has_more, next_cursor } = await api.getTasks(
        workspaceId,
        itemId,
        20, // PAGE_SIZE — keep in sync with the default in api/index.ts
        item.tasksNextCursor,
      )
      // Append the new page to the existing list. We push (not unshift)
      // because tasks are ordered newest-first, so older tasks go at the
      // end of the list.
      if (!item.tasks) item.tasks = []
      item.tasks.push(...tasks)
      item.hasMoreTasks = has_more
      item.tasksNextCursor = next_cursor
    } catch (err) {
      console.error(`Failed to load more tasks for item ${itemId}:`, err)
      // Leave hasMoreTasks/cursor as-is so the user can retry by clicking
      // the button again. Do not surface a toast — keep the failure mode
      // quiet (same pattern as addTask's catch block).
    } finally {
      item.isLoadingMoreTasks = false
    }
  }
  ```

- [ ] **Step 5: Export `loadMoreTasks` from the store (the return-object block at the bottom of the `defineStore` body).** Add `loadMoreTasks,` to the returned object alongside `deleteTask` and the other actions. (The exact line number depends on the order of exports — search for `deleteTask,` and add it right after, on its own line, with the same indentation.)

- [ ] **Step 6: Build the frontend to confirm types.** Run `bun run build`. Expected: clean.

- [ ] **Step 7: Commit.**
  ```bash
  git add src/apps/desktop/src/stores/workspaces.ts
  git commit -m "feat(frontend): add per-item pagination state and loadMoreTasks action"
  ```

## Task 2.3: Add a store-level test for `loadMoreTasks`

**Files:** Create `src/apps/desktop/src/__tests__/workspacesStoreLoadMoreTasks.spec.ts`

- [ ] **Step 1: Read `workspacesStoreInit.spec.ts` to learn the project's test setup pattern** (mocking style, Pinia setup, fixture creation). Use that file as a template for the new spec — the project has a specific mock-vi style we should match.

- [ ] **Step 2: Write the tests.** Cover 4 scenarios:
  | # | Scenario | Assertion |
  |---|---|---|
  | 1 | Initial fetch returned `has_more=true`, `next_cursor='C-time'`; second fetch returns `[D, E]`, `has_more=false` | After `loadMoreTasks`: `item.tasks === [A, B, C, D, E]`, `hasMoreTasks === false`, `tasksNextCursor === null`; `api.getTasks` was called with `'C-time'` as the cursor |
  | 2 | `hasMoreTasks === false` at start | `api.getTasks` is NOT called (no-op) |
  | 3 | `isLoadingMoreTasks === true` at start | `api.getTasks` is NOT called (no-op, prevents double-fire) |
  | 4 | `api.getTasks` rejects | `item.tasks` unchanged, `hasMoreTasks` still `true`, `tasksNextCursor` still set, `isLoadingMoreTasks === false` (state intact for retry) |

  Match the mocking style of `workspacesStoreInit.spec.ts` exactly — read it first to see whether the project uses `vi.mock('../api', ...)` with manual stubs, dependency injection via `provide`, or another pattern. The store reads `api.getTasks` via a top-level import, so `vi.mock` is the likely approach.

- [ ] **Step 3: Run the new spec in isolation.** `bun run test:unit --run -- workspacesStoreLoadMoreTasks 2>&1 | tail -n 30`. Expected: 4 tests pass.

- [ ] **Step 4: Commit.**
  ```bash
  git add src/apps/desktop/src/__tests__/workspacesStoreLoadMoreTasks.spec.ts
  git commit -m "test(frontend): add unit tests for workspaces store loadMoreTasks"
  ```

## Frontend store chunk acceptance criteria
- `bun run build` is clean
- 4 new `workspacesStoreLoadMoreTasks.spec.ts` tests pass
- All 150 existing tests still pass (sanity check before moving to Chunk 3)

---

# Chunk 3: Frontend UI

## Task 3.1: Add the "Load More" button to `WorkspaceItem.vue` (post-refactor line numbers)

**Files:** Modify `src/apps/desktop/src/components/WorkspaceItem.vue:23-35, 75-100, 189-204`

> **Note:** This is the v2 change with the biggest delta from v1. After commit `6cb63fe` (2026-06-10), `WorkspaceItem.vue` is 207 lines. The task-list `<div>` wrapper is at lines 193-204, and contains a single `<WorkspaceItemTask v-for="task in item.tasks" ... />` child (NOT an inline `<button v-for>` as in v1).

- [ ] **Step 1: Add `loadMoreTasks` to the `defineEmits` block (lines 23-35).** Insert one new entry in the existing `defineEmits` block:

  ```typescript
  const emit = defineEmits<{
    click: [item: WorkspaceItem]
    delete: [item: WorkspaceItem]
    addTask: [item: WorkspaceItem]
    selectTask: [taskId: string]
    deleteTask: [workspaceId: string, itemId: string, taskId: string]
    renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
    // The user must click to fetch the next page of tasks for this item.
    // WorkspaceList forwards the event to Sidebar, which calls
    // workspacesStore.loadMoreTasks. See Design Note 6 — the button
    // lives here (not in WorkspaceItemTask.vue) because it is a sibling
    // of the per-task list, not a property of any individual task.
    loadMoreTasks: [workspaceId: string, itemId: string]
  }>()
  ```

- [ ] **Step 2: Add the `handleLoadMoreTasks` pass-through (in the script block, around line 75-100, after `handleRenameTask`).** Mirror the pattern of `handleSelectTask` / `handleDeleteTask` / `handleRenameTask`:

  ```typescript
  const handleLoadMoreTasks = (event: Event) => {
    // Stop the click from bubbling up to the parent <button> (which
    // would toggle item expansion). The Load More button lives inside
    // the task-list <div>, which sits next to the main item row, so
    // bubbling isn't strictly necessary — but it's belt-and-braces
    // against a future refactor that moves this button.
    event.stopPropagation()
    emit('loadMoreTasks', props.workspaceId, props.item.id)
  }
  ```

- [ ] **Step 3: Add the button to the template (lines 193-204).** The current block is:

  ```vue
  <!-- Tasks List (shown when expanded - allows multiple). Per-task
       row lives in <WorkspaceItemTask> (extracted 2026-06-10);
       events bubble up via the pass-through handlers in the
       <script setup> block. -->
  <div v-if="isExpanded && item.tasks && item.tasks.length > 0" class="ml-8 mt-1 space-y-0.5">
    <WorkspaceItemTask
      v-for="task in item.tasks"
      :key="task.id"
      :task="task"
      :workspace-id="workspaceId"
      :item-id="item.id"
      @select-task="handleSelectTask"
      @delete-task="handleDeleteTask"
      @rename-task="handleRenameTask"
    />
  </div>
  ```

  Add the Load More button AFTER the `<WorkspaceItemTask v-for>` and BEFORE the closing `</div>`:

  ```vue
  <!-- Tasks List (shown when expanded - allows multiple). Per-task
       row lives in <WorkspaceItemTask> (extracted 2026-06-10);
       events bubble up via the pass-through handlers in the
       <script setup> block. -->
  <div v-if="isExpanded && item.tasks && item.tasks.length > 0" class="ml-8 mt-1 space-y-0.5">
    <WorkspaceItemTask
      v-for="task in item.tasks"
      :key="task.id"
      :task="task"
      :workspace-id="workspaceId"
      :item-id="item.id"
      @select-task="handleSelectTask"
      @delete-task="handleDeleteTask"
      @rename-task="handleRenameTask"
    />
    <!-- Load More: shown when the backend says there are more tasks
         for this item. Hidden during the load to prevent double-clicks.
         data-testid is used by workspaceItemTaskLoadMore.spec.ts. -->
    <button
      v-if="item.hasMoreTasks"
      data-testid="load-more-tasks"
      :disabled="item.isLoadingMoreTasks"
      @click="handleLoadMoreTasks"
      class="w-full flex items-center justify-center gap-1.5 px-3 py-1 rounded text-xs transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed hover:opacity-80"
      style="color: var(--semantic-text-dim);"
    >
      <span v-if="item.isLoadingMoreTasks" class="w-3 h-3">
        <div
          class="w-3 h-3 border-2 rounded-full animate-spin"
          style="border-color: var(--color-aqua); border-top-color: transparent"
        ></div>
      </span>
      <span>{{ item.isLoadingMoreTasks ? 'Loading…' : 'Load more' }}</span>
    </button>
  </div>
  ```

  Notes:
  - `v-if="item.hasMoreTasks"` is the gate. `undefined` (e.g. before the first page loads, or when init() failed) is falsy → button hidden.
  - `:disabled="item.isLoadingMoreTasks"` is belt-and-suspenders against double-clicks; the store's `if (item.isLoadingMoreTasks) return` guard is the primary defence.
  - `stopPropagation` in `handleLoadMoreTasks` prevents the click from bubbling up to the parent row's `handleClick` (which would toggle item expansion). The task list `<div>` is a sibling of the main row, not a child, so bubbling isn't strictly necessary today — but it's defensive against future layout changes.
  - The button is INSIDE the `v-if` wrapper, so it only renders when the item is expanded AND has at least one task. This matches the existing task rows' visibility rule.

- [ ] **Step 4: Build the frontend to confirm types.** Run `bun run build`. Expected: clean.

- [ ] **Step 5: Commit.**
  ```bash
  git add src/apps/desktop/src/components/WorkspaceItem.vue
  git commit -m "feat(frontend): add Load More button to WorkspaceItem task list"
  ```

## Task 3.2: Wire the new event through `WorkspaceList` to `Sidebar`

**Files:**
- Modify `src/apps/desktop/src/components/WorkspaceList.vue:23-35, 131-146, 262-274`
- Modify `src/apps/desktop/src/components/Sidebar.vue:23-35, 306-321, 450-464`

> **v2 fix:** v1 hedged that the parent of `WorkspaceList` was "likely `AppLayout.vue`" — it is in fact `Sidebar.vue`. The chain is `WorkspaceItem → WorkspaceList → Sidebar` (not `AppLayout`). This was confirmed on 2026-06-10 by reading `Sidebar.vue:7,450-464` directly.

- [ ] **Step 1: Add the emit to `WorkspaceList`'s `defineEmits` (lines 23-35).** Insert one new entry:

  ```typescript
  loadMoreTasks: [workspaceId: string, itemId: string]
  ```

- [ ] **Step 2: Add the pass-through handler in `WorkspaceList.vue` (around line 131-146, after the existing task-related handlers).** Mirror the `handleAddTask` / `handleSelectTask` / `handleDeleteTask` / `handleRenameTask` pattern:

  ```typescript
  const handleLoadMoreTasks = (workspaceId: string, itemId: string) => {
    emit('loadMoreTasks', workspaceId, itemId)
  }
  ```

- [ ] **Step 3: Forward the event in `<WorkspaceItemComponent>` (lines 262-274).** Add one new event binding next to the existing ones:

  ```vue
  <WorkspaceItemComponent
    v-for="item in workspace.items"
    :key="item.id"
    :item="item"
    :is-active="activeWorkspaceItemItemId === item.id"
    :workspace-id="workspace.id"
    @click="handleItemClick(workspace.id, $event.id)"
    @delete="handleDeleteItem(workspace.id, $event.id)"
    @add-task="handleAddTask(workspace.id, $event)"
    @select-task="handleSelectTask"
    @delete-task="handleDeleteTask"
    @rename-task="handleRenameTask"
    @load-more-tasks="handleLoadMoreTasks(workspace.id, $event[0], $event[1])"
  />
  ```

  > **Important:** The `@load-more-tasks` binding syntax depends on how `WorkspaceList`'s parent will invoke the handler. Read the existing patterns to match: `@select-task="handleSelectTask"` is a direct passthrough (single arg), `@add-task="handleAddTask(workspace.id, $event)"` passes the workspace.id and a single arg from the event. The `@load-more-tasks` emit carries two args (`workspaceId`, `itemId`), so the binding can either be `@load-more-tasks="(ws, item) => handleLoadMoreTasks(ws, item)"` (arrow function) or `@load-more-tasks="handleLoadMoreTasks(workspace.id, ...$event)"`. Confirm by reading how the existing two-arg event bindings work in this file (search for `@delete-task` and `@rename-task` to see the actual syntax used).

- [ ] **Step 4: Add the handler in `Sidebar.vue` (around line 306-321, after the existing task handlers).** Mirror the `handleDeleteTask` / `handleRenameTask` shape — both invoke a store action:

  ```typescript
  const handleLoadMoreTasks = (workspaceId: string, itemId: string) => {
    workspacesStore.loadMoreTasks(workspaceId, itemId)
  }
  ```

  (`workspacesStore` is already imported in `Sidebar.vue` via `useWorkspacesStore()`.)

- [ ] **Step 5: Add `loadMoreTasks` to `Sidebar.vue`'s `defineEmits` (lines 23-35).** Even though `Sidebar` invokes the store action directly (not re-emit), it must declare the event because it receives it from `<WorkspaceList>`:

  ```typescript
  const emit = defineEmits<{
    // ... existing entries ...
    loadMoreTasks: [workspaceId: string, itemId: string]
  }>()
  ```

  Actually — if `Sidebar` invokes the store action directly and does NOT re-emit, then `loadMoreTasks` does NOT need to be in `defineEmits`. Only include it if the parent of `Sidebar` needs to know. The existing pattern in `Sidebar.vue:23-35` is mixed: `selectTask` and `deleteTask` are re-emitted (the parent `AppLayout` consumes them), while `renameTask` and `addTask` invoke the store directly. Mirror whichever pattern matches `loadMoreTasks`'s actual usage — the handler calls the store, so no re-emit, so no entry in `defineEmits`. **Skip this step if `Sidebar` only consumes the event.**

- [ ] **Step 6: Wire `@load-more-tasks` on the `<WorkspaceList>` element in `Sidebar.vue` (line 450-464).** Add one new event binding next to the existing ones:

  ```vue
  <WorkspaceList
    :workspaces="workspaces"
    :active-workspace-item-id="activeWorkspaceItemId"
    @toggle-workspace="handleToggleWorkspace"
    @select-item="handleSelectItem"
    @delete-workspace="handleDeleteWorkspace"
    @rename-workspace="handleRenameWorkspace"
    @delete-item="handleDeleteItem"
    @request-add-item="handleRequestAddItem"
    @add-workspace="handleAddWorkspace"
    @add-task="handleAddTask"
    @select-task="handleSelectTask"
    @delete-task="handleDeleteTask"
    @rename-task="handleRenameTask"
    @load-more-tasks="handleLoadMoreTasks"
  />
  ```

  Adjust the handler-arg unpacking syntax based on what `WorkspaceList`'s emit looks like (single-arg, two-arg tuple, or two-arg passthrough). The simplest correct binding is `@load-more-tasks="(ws, item) => handleLoadMoreTasks(ws, item)"` if Vue delivers multi-arg emits as separate args, or `@load-more-tasks="handleLoadMoreTasks"` if `WorkspaceList` already pre-binds the workspace id (which it doesn't here).

- [ ] **Step 7: Build the frontend to confirm types.** Run `bun run build`. Expected: clean. If `vue-tsc` complains about the `@load-more-tasks` binding syntax, read the actual emit signature Vue generates (it depends on the `defineEmits` tuple form) and adjust.

- [ ] **Step 8: Commit.**
  ```bash
  git add src/apps/desktop/src/components/WorkspaceList.vue src/apps/desktop/src/components/Sidebar.vue
  git commit -m "feat(frontend): wire loadMoreTasks event from WorkspaceItem up to Sidebar"
  ```

## Task 3.3: Add a component test for the "Load More" button

**Files:** Create `src/apps/desktop/src/__tests__/workspaceItemTaskLoadMore.spec.ts`

- [ ] **Step 1: Read `workspaceItemTaskSpinner.spec.ts` to learn the project's test pattern for `WorkspaceItem.vue`.** Specifically: how `processingState` is provided via `global.provide`, how Pinia is set up, and how the `item` prop is constructed. Reuse that fixture style.

- [ ] **Step 2: Write the tests.** Cover 6 scenarios:
  | # | Scenario | Assertion |
  |---|---|---|
  | 1 | `hasMoreTasks: true`, `isLoadingMoreTasks: false` | `[data-testid="load-more-tasks"]` exists; button text is "Load more" (not "Loading…") |
  | 2 | `hasMoreTasks: false` | `[data-testid="load-more-tasks"]` does not exist |
  | 3 | `hasMoreTasks: true` + click | `wrapper.emitted('loadMoreTasks')` is `[['<wsId>', '<itemId>']]` |
  | 4 | `hasMoreTasks: true`, `isLoadingMoreTasks: true` | Button text is "Loading…"; spinner div is rendered |
  | 5 | `hasMoreTasks: true`, `isLoadingMoreTasks: true` | Button has `disabled` attribute |
  | 6 | `hasMoreTasks: true` + click on the Load More button | `selectTask` is NOT emitted (verifies `stopPropagation` works — no bubbling to the per-task rows) |

  Use the same mount fixture as `workspaceItemTaskSpinner.spec.ts:29-45`. The `processingState` provide is required because the new component still injects it (unchanged from the refactor).

- [ ] **Step 3: Run the new spec in isolation.** `bun run test:unit --run -- workspaceItemTaskLoadMore 2>&1 | tail -n 30`. Expected: 6 tests pass.

- [ ] **Step 4: Commit.**
  ```bash
  git add src/apps/desktop/src/__tests__/workspaceItemTaskLoadMore.spec.ts
  git commit -m "test(frontend): add component tests for Load More button in WorkspaceItem"
  ```

## Frontend UI chunk acceptance criteria
- `bun run build` is clean
- 6 new `workspaceItemTaskLoadMore.spec.ts` tests pass
- 4 new `workspacesStoreLoadMoreTasks.spec.ts` tests pass (from Chunk 2)
- All 150 existing tests still pass (sanity check)
- A new "Load more" button is visible in the dev server when `hasMoreTasks === true` (manual smoke test — see Final Verification)

---

# Final Verification

After all three chunks, run the full project verification (NOT just the changed pieces) to catch cross-cutting regressions.

## Run all checks

```bash
# Backend build
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 60 zig build 2>&1 | tail -n 20

# Backend tests (uses test_runner.zig)
timeout 120 zig build test 2>&1 | tail -n 40

# Frontend build (MUST be `bun run build`, not `build-only` — see project rules)
cd src/apps/desktop
timeout 90 bun run build 2>&1 | tail -n 30

# Frontend tests (note: package script is `test:unit`, not `test:run`)
timeout 120 bun run test:unit --run 2>&1 | tail -n 50
```

## Manual smoke test (start the desktop app, NOT the nalar process)

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
bun run dev  # or whatever `dev` script is in package.json (it is `vite`)
```

In the running desktop app:

1. Create a workspace + add an item (project folder).
2. **Trick to seed >20 tasks:** temporarily lower the default page size in `api/index.ts:135` from `20` to `3`, then click "Add Task" 5 times via the UI, then revert. Alternatively, insert tasks directly into the dev SQLite DB.
3. Open the sidebar, expand the workspace, expand the item.
4. Confirm: only the first 3 (or 20) tasks are visible, and a "Load more" button appears at the bottom.
5. Click "Load more". Confirm: the next page appears, the button is replaced by another "Load more" (if more pages) or disappears (if last page).
6. Re-collapse and re-expand the item. Confirm: tasks are still loaded (no re-fetch), the "Load more" state is preserved.
7. Delete a task from the middle of the list. Confirm: pagination state is preserved (no spurious re-fetch, button visibility unchanged).
8. Reload the page. Confirm: the workspace reinitializes via `init()`, the first page loads, and "Load more" is shown again if applicable.

## Acceptance criteria (all must be true)

- [ ] Backend returns `{ tasks, count, has_more, next_cursor }` from `GET /api/workspaces/:workspace_id/items/:item_id/tasks`.
- [ ] Frontend fetches the first page on workspace init, populates per-item pagination state (`hasMoreTasks`, `tasksNextCursor`).
- [ ] "Load more" button appears at the bottom of an item's task list when more pages exist.
- [ ] Clicking "Load more" appends the next page, advances the cursor, and updates the button visibility.
- [ ] Button is hidden when no more pages exist (`hasMoreTasks === false`).
- [ ] Button shows a spinner and disables itself during a load (no double-click).
- [ ] No regression in `addTask` / `deleteTask` / `updateTask` flow.
- [ ] `zig build` and `bun run build` are clean.
- [ ] All tests pass: 6 backend `tasks_list_test.zig` + 4 store `workspacesStoreLoadMoreTasks.spec.ts` + 6 component `workspaceItemTaskLoadMore.spec.ts` + 150 existing.

---

# Rollback plan

If a chunk fails or breaks cross-cutting tests:

- **Chunk 1 (backend):** `git revert <commit>`. The frontend will still call the old `{ tasks: Task[] }` shape and the backend will serve it. Reverts cleanly.
- **Chunk 2 (frontend API + store):** `git revert <commit>`. The store's `loadMoreTasks` action will be gone; the component will still render the button (which won't appear in the UI if `hasMoreTasks` stays `undefined`); no other consumers are affected.
- **Chunk 3 (frontend UI):** `git revert <commit>`. Removes the button and the event wiring. `Sidebar` no longer needs `handleLoadMoreTasks`. The store's `loadMoreTasks` is still defined but never called.

The whole refactor touches 7 files (4 backend, 3 frontend source, 2 test files). Rollback is one `git revert` per chunk = 3 reverts in the worst case.
