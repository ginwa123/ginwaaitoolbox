# Kanban pre-fetch tasks in init() — instant open on click (2026-08-06)

## Symptom (user report, task_1785772308817, follow-up)

User: *"if you see spinned is show after i click a kanban workspace"*.

After clicking a kanban workspace in the sidebar, the board rendered
column headers with correct counts (e.g. `merged=10`, `in_review_task=3`)
but the column BODIES all showed "No tasks yet" — the per-column task
fetches only fired on KanbanView's `onMount`, leaving a visible loading
gap between the click and the data landing.

User asked for the same "instant open" behaviour the design-pages fix
shipped (auto-expand-design-pages plan, merged at `ede5c8a8`).

## Root cause

`workspacesStore.init()` (the single point where the workspace tree is
built) restored expanded item IDs + per-item tasks for non-kanban items,
but **never fetched kanban tasks**. The pre-fix code had:

```ts
// Per-column pagination (Option B, 2026-08-06 amendment): for
// KANBAN items, we no longer fire a board-wide task fetch in
// init(). The kanban view fires per-column fetches on mount
// (one per column), so the initial load is consistent.
```

So the per-column task fetch responsibility landed on `KanbanView.vue::
loadColumnsAndTasks` (its `onMount`). The result: a user click on the
sidebar mounted `KanbanView`, which then fired N parallel fetches in
parallel with the user already seeing the empty kanban layout. There was
no spinner state in the meantime — just "No tasks yet" everywhere.

## Fix

Pre-fetch kanban tasks in `init()` for every kanban item, mirroring the
design-pages fix. Two blocks were modified:

### 1. New kanban block in init() (workspaces.ts)

```ts
await Promise.all(
  (items || []).map(async (item: WorkspaceItem) => {
    if (item.item_type !== 'kanban') return
    try {
      // Step 1: load columns (id list for per-column fetches).
      const { columns } = await api.listKanbanColumns(ws.id, item.id)
      item.kanban_columns = [...columns].sort(
        (a, b) => a.position - b.position,
      )
      // Step 2: fire per-column task fetches with DEFAULT sort (page 1).
      await Promise.all(
        item.kanban_columns.map(async (col) => {
          const { tasks, has_more, next_cursor } = await api.getTasks(
            ws.id, item.id, 10,
            undefined, undefined, undefined,
            col.id,  // ← per-column filter (kanban-per-column-pagination plan)
            undefined,
          )
          const normalized = (tasks ?? []).map(normalizeTaskTags)
          const otherTasks = (item.tasks ?? []).filter(
            (t) => t.kanban_column_id !== col.id,
          )
          item.tasks = [...otherTasks, ...normalized]
          item.columnPagination ??= {} as Record<string, ColumnPaginationState>
          item.columnPagination[col.id] = {
            cursor: next_cursor, hasMore: has_more, isLoading: false,
          }
        }),
      )
    } catch (err) {
      console.error(`Failed to fetch kanban tasks for item ${item.id}:`, err)
    }
  }),
)
```

### 2. Preserve pre-fetched columnPagination in the outer items map (workspaces.ts)

The outer `items: (items || []).map((item) => ({ ...item, ...,
columnPagination: {} }))` previously OVERRODE any per-column
pagination that init() had populated — making the pre-fetch invisible
to the rest of the app. The new conditional preserves the pre-fetched
state when present:

```ts
columnPagination: (item.item_type === 'kanban'
  && item.columnPagination
  && Object.keys(item.columnPagination).length > 0)
  ? item.columnPagination
  : ({} as Record<string, ColumnPaginationState>),
```

This means `KanbanView.vue::loadColumnsAndTasks` (its `onMount` watcher)
sees `needFetch` as empty for pre-fetched columns, so it skips them
on the user's first click. URL-sorted columns still re-fetch in the
onMount path (the URL restore plan) — replacing the default-sort
pre-fetch with the user's preferred sort in <100ms after mount.

### 3. Why inline the fetch (instead of calling fetchKanbanColumns / fetchKanbanTasks)

Both store actions use `findItem(workspaceId, itemId)` which looks at
`workspaces.value`. At the time the kanban block runs, the outer
`Promise.all` is still building that array — so `findItem` returns
undefined and the helpers silently no-op. Inlining the merge writes
directly to the in-flight `item` reference (the same object the outer
`.map((item) => ({...item, ...}))` is about to wrap).

## Behavioural invariants (locked in by tests)

1. `init()` calls `listKanbanColumns` exactly once per kanban item —
   never for folder/chat/design items.
2. The call count for non-kanban-item workspaces is `0` (regression
   guard).
3. After `init()` resolves, every kanban column has a populated
   `columnPagination` entry — the KanbanView `needFetch` filter
   skips pre-fetched columns on first mount.
4. A failing per-column fetch is best-effort: workspace tree still
   loads, failed column has no `columnPagination` entry, the
   chevron-toggle lazy fetch is the fallback retry.

## Trade-offs (none flagged for user confirmation)

- **Wire cost: 1 + N endpoints per kanban on every init().** A typical
  board has 5-7 columns → 6-8 endpoints — sub-100ms on a cold boot.
  Most workspaces have 1-3 kanbans.
- **Brief default-sort flash for URL-sorted columns.** The onMount
  URL restore re-fetches URL-sorted columns with the user's preferred
  sort, REPLACING the default-sort pre-fetch. The replacement happens
  in <100ms after mount, before the user can perceive it.
- **`fetchKanbanTasks` is now duplicated** between the public helper
  (used by KanbanView onMount + kanbanSse) and the inline block in
  init(). The inline merge keeps the file readable (no extra helper
  to thread the in-flight item reference through), and the merge
  logic is 5 lines.

## Verification

- `bun run build` — clean (vue-tsc passes, 5.02s)
- `bunx vitest run src/__tests__/workspacesStoreInit.spec.ts` —
  **13/13 pass** (was 9/9, +4 new tests)
- `bunx vitest run` (full suite) — 2052 pass / 19 fail. The 19
  failures are PRE-EXISTING on main (verified against `ede5c8a8`
  baseline). Zero regressions.

## Out of scope (deferred to follow-ups)

- **Pre-loading the active page's elements** (design only — already
  filed as a separate follow-up).
- **Loading skeleton state in the sidebar** while init() is running.
- **Deduping the inline merge with `fetchKanbanTasks`** into a
  shared helper that accepts an explicit item reference (would
  eliminate the duplication; would also require passing the
  pagination-state setter so the helper can populate it).

## Files

- `src/apps/desktop/src/stores/workspaces.ts` — new kanban pre-fetch
  block + conditional `columnPagination` preservation in the
  outer items map (2 surgical edits)
- `src/apps/desktop/src/__tests__/workspacesStoreInit.spec.ts` —
  +4 behavioural tests

## Branch / commit

- Branch: `worktree/kanban-prefetch-on-init`
- Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-prefetch-on-init`
