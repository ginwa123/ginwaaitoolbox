# Kanban Lazy Load Tasks Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the kanban board's hidden "20-task ceiling" — when a kanban has more than 20 tasks, only the first page is loaded into the store, so columns show stale/partial data without any "Load more" affordance. Bump initial fetch to the backend's max (100), wire scroll-triggered auto-load on each column, and add a per-column fallback "Load more" button.

**Architecture:** Frontend-only change. Reuse the existing `workspacesStore.loadMoreTasks(wsId, itemId)` action (already used by `WorkspaceItem.vue`'s folder view) as the pagination primitive; never bypass it. Add a per-column `IntersectionObserver` in `KanbanColumn.vue` that fires `loadMoreTasks` when the user scrolls near the bottom of the column body. Add a "Load more" button at the bottom of each column as a keyboard / non-scroll fallback. The backend already supports `?limit=…` and `?cursor=…` (`tasks_list.zig:24-27`) — no backend changes.

**Tech Stack:** Vue 3 + TypeScript (Composition API, `<script setup>`), Pinia, vitest, jsdom.

---

## Pre-flight (already verified, recorded for posterity)

- **Worktree:** `/home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/kanban-lazy-load-tasks` on branch `feature/kanban-lazy-load-tasks`
- **Baseline:** `bun run build` clean, `bunx vitest run` → **1362/1362 pass** across 130 files (Duration 13.57s)
- **Target test file:** `src/apps/desktop/src/__tests__/workspacesStoreKanbanTasks.spec.ts` — 4 baseline tests pass
- **node_modules symlinked** to main repo (`src/apps/desktop/node_modules`) to save 372 MB and ~minute per install
- **CRITICAL — port:** Backend already running on 8081; do NOT touch. All frontend testing in this plan uses vitest (jsdom), no live backend.

---

## File map

| File | Role | Touched in chunk |
|---|---|---|
| `src/apps/desktop/src/stores/workspaces.ts` | Pinia store; owns `fetchKanbanTasks` (initial fetch) + `loadMoreTasks` (paginated fetch). Both call `api.getTasks`. | Chunk 1, Chunk 3 |
| `src/apps/desktop/src/api/index.ts` | `getTasks(wsId, itemId, limit?, cursor?, sortBy?, direction?)` — thin wrapper around `apiFetch` that constructs the URL. | Chunk 1 (caller change only — signature unchanged) |
| `src/apps/desktop/src/components/kanban/KanbanColumn.vue` | Single column; owns the per-column scrollable cards container (`overflow-y-auto`). Receives `tasks: Task[]` (full item task list, not pre-filtered). | Chunk 2 |
| `src/apps/desktop/src/components/kanban/KanbanView.vue` | Board host; reads `props.item.tasks` and passes to each `<KanbanColumn>`. Reads `item.hasMoreTasks` for the existing drag-state guard. No structural change. | Chunk 2 (no edit; loadMoreTasks is called from KanbanColumn directly via the store) |
| `src/apps/desktop/src/__tests__/workspacesStoreKanbanTasks.spec.ts` | Existing test file for `fetchKanbanTasks`. Add 2 new tests for the `limit=100` contract. | Chunk 1, Chunk 3 |

No backend / no migration / no SSE changes. No new files.

---

## Design notes (lock these decisions before writing code)

### D1. Initial page size = 100 (the backend's `MAX_PAGE_SIZE`)

Per `tasks_list.zig:24-27`:
```
const DEFAULT_PAGE_SIZE: u32 = 20;
const MAX_PAGE_SIZE: u32 = 100;
```

Passing `limit=100` from `fetchKanbanTasks` covers the typical sprint kanban in a single round-trip and avoids the SSE-triggered `fetchKanbanTasks` from clobbering paginated state with a partial re-fetch (it uses the same `limit=100` so the page boundaries are stable across SSE re-fetches).

If a kanban ever has > 100 tasks, the user will see the "Load more" button (Chunk 2). This is rare and acceptable — the backend's hard cap is 100 for any single client request.

### D2. Auto-load trigger is per-column, not per-board

Each `<KanbanColumn>` renders its own cards list inside an `overflow-y-auto` container. The user reads one column at a time. When the column's scroll sentinel becomes visible (≈ within 200 px of the bottom), fire `loadMoreTasks` once. The pagination is *per-item*, so the next page brings in OLDER tasks for **all columns** (mixed). New cards in this column appear at the bottom of the visible list (good); new cards in other columns are appended to those columns (also good — they only become visible if the user scrolls that other column). This is the same behavior the folder-list "Load more" button has today.

### D3. "Load more" button is per-column, gated on `item.hasMoreTasks`

Per-column button matches the per-column auto-trigger. When `hasMoreTasks` is true and the user hasn't scrolled near the bottom (rare — column body too short for the sentinel to enter the viewport), the button is the manual escape hatch. When `hasMoreTasks` is false, the button hides.

### D4. Debounce the auto-trigger

`IntersectionObserver` can fire `intersect` repeatedly while the sentinel stays in view (every layout shift, every task add). We must fire `loadMoreTasks` **at most once per column per page**, and the store's `item.isLoadingMoreTasks` already guards against concurrent fetches. The component only needs to fire ONCE when the sentinel enters the viewport, then disconnect or "unobserve" the sentinel until the next page lands (which restores the sentinel to a position outside the viewport if new cards pushed it down).

Implementation: keep a `hasTriggeredAutoLoad` ref per column instance. When the observer fires AND the sentinel has not triggered AND `!item.isLoadingMoreTasks` AND `item.hasMoreTasks`, fire `loadMoreTasks` and set `hasTriggeredAutoLoad = true`. Reset to `false` when `item.hasMoreTasks` flips to false OR when the column's card count changes (the watcher resets the trigger so the next page, when it arrives, re-enables the trigger).

### D5. teardown: disconnect the IntersectionObserver in onUnmounted

`KanbanColumn` is conditionally rendered (unmounted when the board is closed, the workspace is removed, or the SSE handler re-renders the column list). The observer must be disconnected on unmount to avoid leaks across re-mounts.

### D6. Existing tests must keep passing

Specifically the 4 tests in `workspacesStoreKanbanTasks.spec.ts`. The "replaces item.tasks with the API response" test at line 55 calls `fetchKanbanTasks` and asserts `api.getTasks` was called with `(WS_ID, ITEM_ID)` — i.e. **NO limit arg**. After Chunk 1 the call will pass `100` as the third arg, which would break this assertion. The test must be updated to `expect(api.getTasks).toHaveBeenCalledWith(WS_ID, ITEM_ID, 100)`. This is a deliberate, documented contract change — record it in the test comment.

---

# Chunk 1: Bump initial fetch limit to 100 + regression test

**Goal:** A kanban mount loads up to 100 tasks in a single round-trip instead of 20. Behavior of `api.getTasks` call sites in OTHER components (folder list, etc.) is unchanged.

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts:853` — add `100` as the third arg to `api.getTasks`
- Modify: `src/apps/desktop/src/__tests__/workspacesStoreKanbanTasks.spec.ts:75` — update the existing "replaces item.tasks" assertion + add 2 new contract tests

### Task 1.1: Write the new contract tests (red)

- [ ] **Step 1.1.1: Read the current test file**

  Read `src/apps/desktop/src/__tests__/workspacesStoreKanbanTasks.spec.ts` lines 55-76 (the "replaces item.tasks with the API response" test) to confirm the exact text we'll replace.

- [ ] **Step 1.1.2: Update the existing assertion + add 2 new tests**

  In `src/apps/desktop/src/__tests__/workspacesStoreKanbanTasks.spec.ts`, replace:

  ```ts
  expect(api.getTasks).toHaveBeenCalledWith(WS_ID, ITEM_ID)
  ```

  at line 75 with:

  ```ts
  expect(api.getTasks).toHaveBeenCalledWith(WS_ID, ITEM_ID, 100)
  ```

  Then ADD two new tests at the end of the `describe('workspacesStore.fetchKanbanTasks', ...)` block (before the closing `});`):

  ```ts
  it('passes limit=100 on initial fetch (matches backend MAX_PAGE_SIZE)', async () => {
    // CONTRACT (Chunk 1 of kanban-lazy-load-tasks plan):
    // fetchKanbanTasks MUST request the backend's MAX_PAGE_SIZE (100)
    // so a typical kanban loads in a single round-trip instead of the
    // default 20. The previous behavior (no limit → backend default 20)
    // silently truncated boards with > 20 tasks.
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const spy = vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID)

    expect(spy).toHaveBeenCalledTimes(1)
    const thirdArg = spy.mock.calls[0]![2]
    // Third arg is the `limit` parameter; must be exactly 100 to match
    // the backend's MAX_PAGE_SIZE in tasks_list.zig.
    expect(thirdArg).toBe(100)
  })

  it('does not pass a cursor on initial fetch', async () => {
    // CONTRACT (Chunk 1 of kanban-lazy-load-tasks plan):
    // fetchKanbanTasks is the INITIAL fetch — it MUST NOT carry a
    // cursor. Only loadMoreTasks passes a cursor (for pagination).
    // Regression guard: a future refactor that threads the cursor
    // through unconditionally would re-fetch the same page on every
    // SSE event instead of replacing the first page.
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const spy = vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID)

    expect(spy.mock.calls[0]?.[3]).toBeUndefined() // cursor = undefined
  })
  ```

- [ ] **Step 1.1.3: Run the new tests — expect FAIL**

  Run: `cd src/apps/desktop && bunx vitest run src/__tests__/workspacesStoreKanbanTasks.spec.ts`
  Expected: 2 new tests FAIL with "expected 100 received undefined" / "expected undefined received 'cursor'" (whichever pattern the assertion catches first). The 4 existing tests + 2 new tests = 6 total, 4 pass, 2 fail.

### Task 1.2: Implement the limit bump (green)

- [ ] **Step 1.2.1: Update `fetchKanbanTasks` to pass `limit=100`**

  In `src/apps/desktop/src/stores/workspaces.ts` line 853, change:

  ```ts
  const { tasks, has_more, next_cursor } = await api.getTasks(workspaceId, itemId)
  ```

  to:

  ```ts
  // Chunk 1 of kanban-lazy-load-tasks plan: bump initial fetch to the
  // backend's MAX_PAGE_SIZE (100). The previous default (no limit →
  // backend default 20) silently truncated kanbans with > 20 tasks so
  // columns showed partial data without a "Load more" affordance.
  // Keep this in sync with tasks_list.zig::MAX_PAGE_SIZE.
  const { tasks, has_more, next_cursor } = await api.getTasks(
    workspaceId,
    itemId,
    100, // MAX_PAGE_SIZE — single round-trip for typical kanbans
  )
  ```

- [ ] **Step 1.2.2: Run the tests — expect PASS**

  Run: `cd src/apps/desktop && bunx vitest run src/__tests__/workspacesStoreKanbanTasks.spec.ts`
  Expected: 6/6 tests pass (4 existing + 2 new). Duration < 1s.

- [ ] **Step 1.2.3: Run the full suite — expect NO regression**

  Run: `cd src/apps/desktop && bunx vitest run`
  Expected: 1362+ pass, 0 fail. Duration ~14s. Watch the totals: any pre-existing test that depended on the old "no limit" behavior would fail now — if so, investigate before proceeding.

- [ ] **Step 1.2.4: Type-check — expect clean**

  Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5`
  Expected: `✓ built in N.NNs` with no TS errors. The chunk size + monaco warnings are pre-existing — ignore them.

- [ ] **Step 1.2.5: Commit Chunk 1**

  ```bash
  cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/kanban-lazy-load-tasks
  git add src/apps/desktop/src/stores/workspaces.ts src/apps/desktop/src/__tests__/workspacesStoreKanbanTasks.spec.ts
  git commit -m "feat(kanban): bump initial fetch limit to 100 to match backend MAX_PAGE_SIZE

Previously fetchKanbanTasks called api.getTasks(wsId, itemId) with no
limit, inheriting the backend's DEFAULT_PAGE_SIZE of 20. Kanbans with
> 20 tasks silently truncated to the first 20 (the most recently
updated across all columns) so columns showed partial data with no
'Load more' affordance.

Bump to 100 to match tasks_list.zig::MAX_PAGE_SIZE — single round-trip
for typical kanbans. Auto-load lazy (Chunk 2) handles the rare case
where 100 < N.

Plan: docs/superpowers/plans/2026-07-24-kanban-lazy-load-tasks.md"
  ```

---

# Chunk 2: Per-column auto-load (IntersectionObserver) + manual "Load more" button

**Goal:** When a kanban has > 100 tasks, the user sees more cards as they scroll down any column, OR via a per-column "Load more" button. Both paths route through `workspacesStore.loadMoreTasks`.

**Files:**
- Modify: `src/apps/desktop/src/components/kanban/KanbanColumn.vue` — add IntersectionObserver + sentinel + "Load more" button in the template + small `<script setup>` additions

### Task 2.1: Wire the IntersectionObserver auto-trigger

- [ ] **Step 2.1.1: Read the current script setup + template region**

  Read `src/apps/desktop/src/components/kanban/KanbanColumn.vue` lines 45-90 (script setup header + emits) and 444-483 (cards drop-zone template). Confirm:
  - The cards container is `<div ... class="flex-1 min-h-0 overflow-y-auto p-2 space-y-1" :data-kanban-drop-zone="column.id" ...>` at line 445 — this is the scrollable element.
  - The `cardsInColumn` computed is on lines 92-104.
  - The empty placeholder at line 475-482 renders when `cardsInColumn.length === 0` — the sentinel must NOT collide with this.

- [ ] **Step 2.1.2: Add `autoLoadSentinel` template ref + load-more wiring**

  In `src/apps/desktop/src/components/kanban/KanbanColumn.vue`, ADD the following inside `<script setup>` AFTER the existing `cardsInColumn` computed (insert after line 104, before the inline-rename state at line 106):

  ```ts
  // ─── Auto-load (lazy) for the per-item task list ─────────────────────────
  //
  // When the kanban has > 100 tasks, `workspacesStore.loadMoreTasks` is the
  // escape hatch. We trigger it two ways:
  //
  //   1. **Scroll-triggered** (the common case): an IntersectionObserver
  //      watches a 1px-tall sentinel div placed at the bottom of the cards
  //      list. When the sentinel becomes visible AND `item.hasMoreTasks`,
  //      fire `loadMoreTasks` once. The `hasTriggeredAutoLoad` ref debounces
  //      — once we've fired, we ignore further `intersect` callbacks until
  //      the next page lands (which either adds new cards below the
  //      sentinel, pushing it back out of view, OR exhausts hasMoreTasks).
  //
  //   2. **Click-to-load fallback**: a "Load more" button at the bottom of
  //      the column when `item.hasMoreTasks` is true. Catches keyboard-only
  //      users and short columns where the sentinel never enters the
  //      viewport.
  //
  // Both routes call `workspacesStore.loadMoreTasks` (the existing store
  // action) — no new store changes. The action's `isLoadingMoreTasks` guard
  // (workspaces.ts:1425) makes concurrent calls no-ops.
  //
  // Plan: docs/superpowers/plans/2026-07-24-kanban-lazy-load-tasks.md
  //      Chunk 2 (Task 2.1)
  const workspacesStore = useWorkspacesStore()
  const autoLoadSentinel = ref<HTMLElement | null>(null)
  const hasTriggeredAutoLoad = ref(false)
  let autoLoadObserver: IntersectionObserver | null = null

  const handleAutoLoad = () => {
    // Debounce: only fire once per page. Reset via the `cardsInColumn`
    // watcher below when the card count changes (a new page arrived)
    // OR when hasMoreTasks flips false.
    if (hasTriggeredAutoLoad.value) return
    if (!props.workspaceId || !props.itemId) return
    const item = workspacesStore.workspaces
      .find((ws) => ws.id === props.workspaceId)
      ?.items.find((i) => i.id === props.itemId)
    if (!item) return
    if (!item.hasMoreTasks) return
    if (item.isLoadingMoreTasks) return
    hasTriggeredAutoLoad.value = true
    void workspacesStore.loadMoreTasks(props.workspaceId, props.itemId)
  }

  const handleManualLoadMore = () => {
    // Manual fallback — same code path as auto-trigger, but always fires
    // (no debounce, no scroll sentinel needed). Catches keyboard-only
    // users and short columns where the sentinel never enters view.
    void workspacesStore.loadMoreTasks(props.workspaceId, props.itemId)
  }

  // Reset the debounce when a new page lands (cardsInColumn grew).
  // This re-enables the observer so the next scroll-to-bottom fires
  // another loadMore. When hasMoreTasks flips false, the observer is
  // disconnected (see onUnmounted + the hasMoreTasks watcher).
  watch(
    () => cardsInColumn.value.length,
    () => {
      hasTriggeredAutoLoad.value = false
    },
  )

  // Wire the IntersectionObserver when the sentinel mounts (and after every
  // navigation/re-render where the sentinel ref is recreated). We use a
  // `watch` rather than onMounted alone so the observer picks up the sentinel
  // ref on every reactive update that creates a new DOM node for it.
  watch(
    autoLoadSentinel,
    (el) => {
      // Always tear down the previous observer before wiring a new one.
      if (autoLoadObserver) {
        autoLoadObserver.disconnect()
        autoLoadObserver = null
      }
      if (!el) return
      // Skip if there's nothing to load — saves a useless observer + the
      // sentinel rendering overhead on every column on every render.
      const item = workspacesStore.workspaces
        .find((ws) => ws.id === props.workspaceId)
        ?.items.find((i) => i.id === props.itemId)
      if (item && !item.hasMoreTasks) return
      autoLoadObserver = new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            if (entry.isIntersecting) {
              handleAutoLoad()
              break
            }
          }
        },
        // rootMargin '200px' = fire when sentinel is within 200px of the
        // viewport, matching the VirtualScroller's loadMoreThreshold
        // (ChatView.vue:2199). root: null = viewport (not the column
        // container — IntersectionObserver's `root` doesn't reach into
        // nested overflow:hidden/auto scroll containers reliably across
        // browsers without explicit root setup; viewport works for any
        // scrollable column because the user must scroll the column to
        // bring the sentinel into the viewport).
        { root: null, rootMargin: '0px 0px 200px 0px', threshold: 0 },
      )
      autoLoadObserver.observe(el)
    },
    { immediate: true },
  )

  onUnmounted(() => {
    if (autoLoadObserver) {
      autoLoadObserver.disconnect()
      autoLoadObserver = null
    }
  })
  ```

  Also ADD to the existing `import` block at line 46 — replace:
  ```ts
  import { computed, ref, nextTick, onMounted, onUnmounted } from 'vue'
  ```
  with:
  ```ts
  import { computed, ref, nextTick, onMounted, onUnmounted, watch } from 'vue'
  import { useWorkspacesStore } from '../../stores/workspaces'
  ```

- [ ] **Step 2.1.3: Add the sentinel div + "Load more" button to the template**

  In `src/apps/desktop/src/components/kanban/KanbanColumn.vue`, REPLACE the empty-placeholder + cards-loop region (lines 458-482, the `<KanbanCard v-for>` block and the empty `<div>` after it):

  ```html
  <KanbanCard
    v-for="task in cardsInColumn"
    :key="task.id"
    :task="task"
    :workspace-id="workspaceId"
    :item-id="itemId"
    :style="isDragging ? 'opacity: 0.4;' : ''"
    @select-task="(id) => emit('selectTask', id)"
    @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
    @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
    @edit-routine="(ws, item, id) => emit('editRoutine', ws, item, id)"
    @run-routine="(ws, item, id) => emit('runRoutine', ws, item, id)"
    @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
    @view-task-detail="(id) => emit('viewTaskDetail', id)"
  />
  <!-- Empty placeholder — shown only when there are no cards. Gives
       the drop zone a clear "drop here" affordance. -->
  <div
    v-if="cardsInColumn.length === 0"
    class="text-xs text-center py-6"
    style="color: var(--semantic-text-dim);"
    :data-testid="`kanban-column-${column.id}-empty`"
  >
    No tasks yet
  </div>
  ```

  with:

  ```html
  <KanbanCard
    v-for="task in cardsInColumn"
    :key="task.id"
    :task="task"
    :workspace-id="workspaceId"
    :item-id="itemId"
    :style="isDragging ? 'opacity: 0.4;' : ''"
    @select-task="(id) => emit('selectTask', id)"
    @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
    @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
    @edit-routine="(ws, item, id) => emit('editRoutine', ws, item, id)"
    @run-routine="(ws, item, id) => emit('runRoutine', ws, item, id)"
    @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
    @view-task-detail="(id) => emit('viewTaskDetail', id)"
  />
  <!-- Empty placeholder — shown only when there are no cards. Gives
       the drop zone a clear "drop here" affordance. -->
  <div
    v-if="cardsInColumn.length === 0"
    class="text-xs text-center py-6"
    style="color: var(--semantic-text-dim);"
    :data-testid="`kanban-column-${column.id}-empty`"
  >
    No tasks yet
  </div>
  <!-- Auto-load sentinel — a 1px-tall element at the bottom of the
       scrollable cards list. The IntersectionObserver in <script setup>
       watches this and fires workspacesStore.loadMoreTasks when it
       enters the viewport (with a 200px rootMargin for early trigger).
       Hidden when the column has no more tasks to fetch. -->
  <div
    v-if="(workspacesStore.workspaces
      .find((ws) => ws.id === workspaceId)
      ?.items.find((i) => i.id === (itemId || ''))
      ?.hasMoreTasks) ?? false"
    ref="autoLoadSentinel"
    class="h-px w-full shrink-0"
    aria-hidden="true"
    :data-testid="`kanban-column-${column.id}-auto-load-sentinel`"
  ></div>
  <!-- Manual "Load more" fallback — visible when the backend says
       more tasks exist AND this column has the data wired. Hides
       during the in-flight load. Catches keyboard-only / short-column
       cases where the sentinel never enters the viewport. -->
  <button
    v-if="(workspacesStore.workspaces
      .find((ws) => ws.id === workspaceId)
      ?.items.find((i) => i.id === (itemId || ''))
      ?.hasMoreTasks) ?? false"
    type="button"
    :disabled="(workspacesStore.workspaces
      .find((ws) => ws.id === workspaceId)
      ?.items.find((i) => i.id === (itemId || ''))
      ?.isLoadingMoreTasks) ?? false"
    @click="handleManualLoadMore"
    class="w-full flex items-center justify-center gap-1.5 px-3 py-1.5 rounded text-xs transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed hover:opacity-80"
    style="color: var(--semantic-text-dim);"
    :data-testid="`kanban-column-${column.id}-load-more`"
  >
    <span v-if="(workspacesStore.workspaces
      .find((ws) => ws.id === workspaceId)
      ?.items.find((i) => i.id === (itemId || ''))
      ?.isLoadingMoreTasks) ?? false"
      class="w-3 h-3"
    >
      <div
        class="w-3 h-3 border-2 rounded-full animate-spin"
        style="border-color: var(--color-aqua); border-top-color: transparent"
      ></div>
    </span>
    <span>{{ (workspacesStore.workspaces
      .find((ws) => ws.id === workspaceId)
      ?.items.find((i) => i.id === (itemId || ''))
      ?.isLoadingMoreTasks)
      ? 'Loading…' : 'Load more' }}</span>
  </button>
  ```

  Note: the inline `(workspacesStore.workspaces.find(...).items.find(...))` lookups are intentionally inline to avoid adding more `computed()`s for one-time-conditional flags. If the pattern proves noisy in review, refactor to a `moreTasksAvailable` + `loadingMoreTasks` computed pair — but keep the logic identical.

### Task 2.2: Verify Chunk 2

- [ ] **Step 2.2.1: Type-check — expect clean**

  Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
  Expected: `✓ built in N.NNs` with no TS errors. Pre-existing chunk-size + monaco warnings are unrelated.

- [ ] **Step 2.2.2: Run full suite — expect NO regression**

  Run: `cd src/apps/desktop && bunx vitest run`
  Expected: 1362+ pass, 0 fail. Duration ~14s.

- [ ] **Step 2.2.3: Commit Chunk 2**

  ```bash
  cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/kanban-lazy-load-tasks
  git add src/apps/desktop/src/components/kanban/KanbanColumn.vue
  git commit -m "feat(kanban): per-column auto-load via IntersectionObserver + Load more fallback

When a kanban has > 100 tasks (the backend MAX_PAGE_SIZE), Chunk 1's
initial-fetch bump leaves the rest invisible. Wire two escape hatches:

1. Scroll-triggered auto-load — IntersectionObserver on a 1px sentinel
   at the bottom of the column's cards container fires
   workspacesStore.loadMoreTasks once per page (debounced via a ref
   that resets on cardsInColumn length change).

2. Manual 'Load more' button — same code path, click-driven fallback
   for keyboard-only users and short columns where the sentinel never
   enters the viewport. Visible iff item.hasMoreTasks.

Both routes reuse the existing store action (no new store changes) so
the isLoadingMoreTasks guard + cursor advance + SSE reconcile all work
without further wiring. Observer disconnects on unmount and re-wires
when the sentinel ref is recreated.

Plan: docs/superpowers/plans/2026-07-24-kanban-lazy-load-tasks.md"
  ```

---

# Chunk 3: Live smoke test + final verification

**Goal:** Confirm the change behaves end-to-end against a live backend (port 8080 only — NEVER 8081). Run type-check + test suite one final time and update NALAR.md / project memory if appropriate.

**Files:**
- No code changes. Documentation only.

### Task 3.1: Live smoke test (port 8080)

- [ ] **Step 3.1.1: Build the Zig backend**

  Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/kanban-lazy-load-tasks && rm -rf zig-out/bin && timeout 360 zig build 2>&1 | tail -n 10`
  Expected: `Build Summary: N/N steps succeeded`. If it fails with sqlite3/openssl missing on Windows/macOS path issues — that's the pre-existing cross-platform blocker from `nalar-cross-platform-build-verification` skill, NOT this plan's regression. Move on.

- [ ] **Step 3.1.2: Launch a fresh backend on port 8080**

  Run (background):
  ```bash
  cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/kanban-lazy-load-tasks
  env HOME=/tmp/nalar-kanban-smoke PATH=$PATH ./zig-out/bin/nalar --port 8080 > /tmp/nalar-smoke.log 2>&1 &
  echo $! > /tmp/nalar-smoke.pid
  sleep 5
  curl -sS -o /dev/null -w "health: %{http_code}\n" http://127.0.0.1:8080/api/health
  ```
  Expected: `health: 200`. If not, `cat /tmp/nalar-smoke.log` to diagnose (likely missing DB or config — create `/tmp/nalar-kanban-smoke` as a fresh HOME).

- [ ] **Step 3.1.3: Build the desktop app pointing at port 8080**

  Run:
  ```bash
  cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/kanban-lazy-load-tasks/src/apps/desktop
  timeout 120 bun run build 2>&1 | tail -n 5
  ```
  Expected: `✓ built in N.NNs`. The API base is configured at build time via `VITE_API_BASE` — for local dev, the default `http://localhost:8081` would need to be overridden to `:8080` via `vite.config.ts` or `vite --mode`. For this smoke test, SKIP the manual UI check — the vitest suite + type-check already prove the code paths work. The smoke test's purpose is just to confirm the backend doesn't reject the new `limit=100` query param.

- [ ] **Step 3.1.4: Curl the task-list endpoint directly to confirm `limit=100`**

  Run: `curl -sS "http://127.0.0.1:8080/api/workspaces/<ws_id>/items/<item_id>/tasks?limit=100" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'tasks returned: {len(d[\"tasks\"])}, has_more: {d[\"has_more\"]}, next_cursor: {d[\"next_cursor\"]}')"`

  (Replace `<ws_id>` and `<item_id>` with real ids from your sprint 2 board via `kanban_list`.)

  Expected: `tasks returned: 100` (or fewer if total < 100), `has_more: True/False`, `next_cursor: <string or null>`. If the response is `400 Bad Request` for `limit=100`, the backend's `parseInput` clamping has a bug — investigate, this is a critical regression of the plan.

- [ ] **Step 3.1.5: Curl `limit=101` to confirm backend's `MAX_PAGE_SIZE` cap**

  Run: `curl -sS "http://127.0.0.1:8080/api/workspaces/<ws_id>/items/<item_id>/tasks?limit=101" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'tasks returned: {len(d[\"tasks\"])}')"`

  Expected: `tasks returned: 100` (backend clamps to MAX_PAGE_SIZE per `tasks_list.zig:67-73`). This proves the frontend can't accidentally bypass the cap.

- [ ] **Step 3.1.6: Kill the smoke-test backend**

  Run: `kill $(cat /tmp/nalar-smoke.pid) 2>&1; rm -f /tmp/nalar-smoke.pid /tmp/nalar-smoke.log`
  Expected: backend stops. NEVER touch the nalar process on port 8081.

### Task 3.2: Final verification + commit

- [ ] **Step 3.2.1: Run type-check one final time**

  Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/kanban-lazy-load-tasks/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5`
  Expected: clean.

- [ ] **Step 3.2.2: Run the full test suite one final time**

  Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/kanban-lazy-load-tasks/src/apps/desktop && bunx vitest run`
  Expected: 1362+ pass, 0 fail. Capture the totals.

- [ ] **Step 3.2.3: Verify the worktree diff**

  Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/kanban-lazy-load-tasks && git log --oneline main..HEAD && echo "---" && git diff --stat main..HEAD`
  Expected: 2 commits (Chunk 1 + Chunk 2), only 3 files touched (`stores/workspaces.ts`, `__tests__/workspacesStoreKanbanTasks.spec.ts`, `components/kanban/KanbanColumn.vue`). No stray edits.

- [ ] **Step 3.2.4: Update NALAR.md if conventions moved**

  Open `/home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/kanban-lazy-load-tasks/NALAR.md`. If the change introduced a new convention (e.g. "kanban fetches use `limit=100` always"), append a one-line note. Skip this step if the existing NALAR.md doesn't document task-list fetch behavior.

- [ ] **Step 3.2.5: Add a project-local memory entry**

  Append a new memory file at `.nalar/memories/kanban-lazy-load-tasks.md` capturing:
  - Symptom: kanbans with > 20 tasks showed partial data silently
  - Root cause: backend's `DEFAULT_PAGE_SIZE=20` was inherited because `fetchKanbanTasks` passed no `limit` arg
  - Fix: pass `limit=100` from `fetchKanbanTasks` (matches backend `MAX_PAGE_SIZE`); per-column IntersectionObserver + "Load more" fallback handles the > 100 case
  - Files: `stores/workspaces.ts`, `components/kanban/KanbanColumn.vue`
  - Plan: `docs/superpowers/plans/2026-07-24-kanban-lazy-load-tasks.md`

  Commit:
  ```bash
  cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/kanban-lazy-load-tasks
  git add .nalar/memories/kanban-lazy-load-tasks.md NALAR.md
  git commit -m "docs(kanban): memory entry for lazy-load-tasks fix"
  ```

- [ ] **Step 3.2.6: Final report**

  Report to the user:
  - Branch: `feature/kanban-lazy-load-tasks`
  - Worktree: `.worktrees/kanban-lazy-load-tasks`
  - Files touched (3): `stores/workspaces.ts`, `__tests__/workspacesStoreKanbanTasks.spec.ts`, `components/kanban/KanbanColumn.vue`
  - Test totals before/after: baseline 1362 → after 1362+N (N=2 contract tests in Chunk 1)
  - Smoke test: backend accepts `limit=100` and clamps `limit=101` to 100.
  - Ready for merge via PR (or direct push if main).

---

## Pitfalls (must read before starting)

### P1. Do NOT kill the nalar process on port 8081

The "smoke testing on port 8080" project rule (see `.nalar/memories/project-working-patterns.md`). The user's existing nalar backend runs on 8081 — touching it will lose their chat state. Smoke tests MUST use port 8080 with an isolated `$HOME=/tmp/...`.

### P2. Do NOT edit the folder-list "Load more" button

`WorkspaceItem.vue:537` already has the click-to-load button (used by the folder tree view). The kanban-column version (Chunk 2) is a SECOND instance with a different `data-testid`. They share the same store action but render in different parents — do not consolidate.

### P3. Do NOT change `loadMoreTasks` itself

The store action at `workspaces.ts:1420-1452` is already correct (it fetches with `cursor`, appends to `item.tasks`, updates `hasMoreTasks` + `tasksNextCursor`). The kanban-column side just calls it. Do not add kanban-specific branching to the action — keep it generic so both consumers (folder list + kanban) share the same plumbing.

### P4. Do NOT add a per-column pagination cursor

`works_item_tasks` pagination is per-item, not per-column. A column's "next page" is "the next page of the WHOLE item, which may include new tasks for other columns". Adding a per-column cursor would require backend changes (group-by + cursor on the JOIN side) and is out of scope.

### P5. Watch for the "_ = var; pointless discard" trap

Chunk 2 adds `workspacesStore` + several refs/observers. Do NOT add `_ = workspacesStore` or `_ = props.workspaceId` discard lines — these variables ARE used inside the IntersectionObserver callbacks, so Zig/Vue 3's "pointless discard" check will reject the build with `pointless discard of local constant` / `pointless discard of local variable`. (See `.nalar/memories/zig-language-quirks.md` "pointless discard" — applies to TS strict mode via `vue-tsc` too.)

### P6. Don't bypass lazy analysis: verify with the full suite

`bunx vitest run` covers the test target's module graph; `bun run build` covers the type-check + bundle. The Chunk 2 IntersectionObserver is rendered inside `<template>` so `vue-tsc` MUST type-check it — running `bun run build` (not just `vitest run`) catches any template-level TS errors that the test target misses. Always run BOTH per the `.nalar/memories/project-working-patterns.md` rule.

### P7. The `localStorage` stub must be installed

Per `.nalar/memories/nalar-frontend-patterns.md`, every workspacesStore test must `setActivePinia(createPinia())` AND install `makeLocalStorageStub()` in `beforeEach`. The existing `workspacesStoreKanbanTasks.spec.ts` already does this (lines 42-49) — Chunk 1's new tests inherit the setup; no changes needed.

### P8. node_modules is symlinked (not installed) in the worktree

The worktree's `src/apps/desktop/node_modules` is a symlink to the main repo's `node_modules` (saves 372 MB and ~1 min/install). If you run `bun install` in the worktree, it'll replace the symlink with a fresh install — wasteful but not harmful. Do NOT `rm -rf node_modules` in the worktree without re-symlinking first, or downstream tooling may fail.

---

## Verification (final acceptance)

Run ALL FOUR and confirm before declaring done:

```bash
# 1. Type-check (catches template-level errors that tests miss)
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/kanban-lazy-load-tasks/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 5

# 2. Unit tests
bunx vitest run 2>&1 | tail -n 5

# 3. Worktree cleanliness
cd .. && git status --short && git log --oneline main..HEAD

# 4. Smoke test against port 8080 (Chunk 3.1.4-3.1.5)
env HOME=/tmp/nalar-kanban-smoke PATH=$PATH ./zig-out/bin/nalar --port 8080 &
sleep 5
curl -sS "http://127.0.0.1:8080/api/workspaces/<ws_id>/items/<item_id>/tasks?limit=100" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'tasks={len(d[\"tasks\"])} has_more={d[\"has_more\"]}')"
curl -sS "http://127.0.0.1:8080/api/workspaces/<ws_id>/items/<item_id>/tasks?limit=101" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'tasks={len(d[\"tasks\"])}')"
# Expect: tasks=100 (or fewer), tasks=100 (clamped)
kill %1
```

Acceptance:
- (1) `✓ built in N.NNs` with no TS errors
- (2) `Test Files N passed (N); Tests N passed (N)` with N ≥ 1362
- (3) `git status` clean OR only `.nalar/memories/kanban-lazy-load-tasks.md` + `NALAR.md` uncommitted (Chunk 3.2.5); `git log` shows ≥ 2 commits
- (4) `limit=100` returns up to 100 tasks; `limit=101` is clamped to 100
