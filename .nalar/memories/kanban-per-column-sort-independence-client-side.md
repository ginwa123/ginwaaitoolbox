# Kanban per-column sort independence — fetch only the changed column

## Symptom

User picks "Name (Z→A)" in one column's ⋮ menu → Sort tasks…
modal. DevTools Network panel shows ALL columns receiving
`sort_by=name&direction=desc` in parallel. Every column's
endpoint gets hit; the user only wanted column A's wire to change.

User feedback (task_1785730557641, take 2):
- *"when sort happen its should independece not all column use
  same sort by value, fix that code above"*
- *"just make sure if i sort column a, only column a endpoint that
  called, other column a should not call endpoint"*

## Root cause (two parts)

1. **Wire shape: `fetchKanbanTasksForAllColumns` fans out the
   SAME sort to every column.** The backend's
   `listWorkspaceItemTasksWithCursor`
   (`src/ai_workflow/tui/llm_history.zig:3933-4006`) accepts ONE
   `sort_field` + `sort_direction` per request. `fetchKanbanTasks`
   takes one set of sort params per call. The helper
   `fetchKanbanTasksForAllColumns` (workspaces.ts:1302) loops over
   every column and calls `fetchKanbanTasks(col, sortBy, direction)`
   — same `sortBy` / `direction` for all. Visual order is
   `name Z→A` everywhere.

2. **The `columnSorts` watcher in KanbanView took only the LATEST
   changed sort and applied it to ALL columns.** Picking "Name
   (Z→A)" in column A caused column B (Manual) to also be
   re-fetched with `sortBy=name&direction=desc`. The
   `watch(columnSorts, ...)` at KanbanView.vue:427 took the last
   entry from `Object.values(columnSorts.value)` and used it
   globally.

## Fix (per-column fetch)

**`handleColumnSortChange` in KanbanView.vue** now fires
`fetchKanbanTasks` for ONLY the column the user picked, with
THAT column's own sortBy/direction:

```ts
const handleColumnSortChange = (
  columnId: string,
  payload: { sortBy: SortField; direction: SortDirection },
) => {
  // 1. Update columnSorts → watcher writes the URL.
  columnSorts.value = { ...columnSorts.value, [columnId]: { ...payload } }

  // 2. Fire fetch for ONLY this column.
  if (payload.sortBy === 'position' && payload.direction === 'asc') {
    void workspacesStore.fetchKanbanTasks(ws, item, columnId, 10)
  } else {
    const apiSortBy = payload.sortBy === 'position'
      ? undefined
      : payload.sortBy as 'created_at' | 'updated_at' | 'name'
    void workspacesStore.fetchKanbanTasks(
      ws, item, columnId, 10,
      undefined, // cursor
      undefined, // q
      apiSortBy,
      payload.direction,
    )
  }
}
```

**The `columnSorts` watcher is now URL-only** (no fetch):

```ts
watch(columnSorts, (next) => {
  const encoded = encodeSortsParam(Object.values(next))
  // router.replace writes the URL — no fetch
})
```

No more debounce needed (per-column fetch is already minimal —
one endpoint per click).

**`KanbanColumn.cardsInColumn` is now a thin filter** (no client-
side sort). The wire data arrives already in the column's own
sort order; we just filter by `kanban_column_id`.

**`handleSortModalSelect` always emits `sortChange`**, even when
the user picked the SAME sort (Manual after Manual). The previous
watcher-based emit only fired on value CHANGE — silent on idempotent
picks. The explicit emit on every menu click guarantees the
parent's per-column fetch always fires on user action.

**`setSortMode` does NOT emit.** The URL restore path uses it
to update local refs; the onMount loop fires the per-column
fetch directly (one call per entry, default sort is `continue`d).
Avoiding the emit prevents double-fetch during URL restore.

## What you DON'T change

- `fetchKanbanTasksForAllColumns` — kept as-is. Still used by
  KanbanView's `loadColumnsAndTasks` (initial mount-time fetch
  with no sort params) and the SSE handler. The helper remains
  the right abstraction for "fetch all columns with the same
  sort". Per-column sort goes through `fetchKanbanTasks`
  directly instead.
- Backend — no changes. `listWorkspaceItemTasksWithCursor`
  already supports all 4 fields × 2 directions.
- `loadMoreTasksForColumn` — unchanged. Already uses per-column
  sort via `activeSortBy` / `activeSortDirection` maps in the
  store.

## Why NOT the per-column-sorts-map approach (the previous take)

A previous iteration added a 7th parameter
`perColumnSorts?: Record<columnId, SortEntry>` to
`fetchKanbanTasksForAllColumns` and passed `columnSorts.value`
from the watcher. This was the right SHAPE but the wrong
PHILOSOPHY — the helper was still firing N parallel fetches
(1 per column) on every sort change, even when only one column
changed. The user explicitly rejected this: *"only column a
endpoint that called, other column should not call endpoint"*.

The take-2 fix removes the fan-out entirely. One click = one
endpoint. Other columns are untouched (their local data still
matches their own last sort, which is what the per-column fetch
maintains).

## Files

- `src/apps/desktop/src/components/kanban/KanbanColumn.vue`
  - Removed `compareBySortMode` function + the client-side
    `.sort()` in `cardsInColumn` (back to plain filter).
  - `handleSortModalSelect` now emits `sortChange`
    unconditionally on every menu click.
  - `setSortMode` is a pure ref-mutator (no emit).
  - Updated doc comment blocks on `cardsInColumn` + the
    `sortChange` emit.
- `src/apps/desktop/src/components/kanban/KanbanView.vue`
  - `handleColumnSortChange` fires `fetchKanbanTasks` for
    ONLY the clicked column (with that column's own sort).
  - `watch(columnSorts, ...)` is URL-only (no fetch, no
    debounce).
  - URL restore onMount loops over entries and fires
    per-column `fetchKanbanTasks` (default sort is `continue`d).
- `src/apps/desktop/src/__tests__/KanbanView.sortByApi.spec.ts`
  - 7 new behavioural tests (3 click handler + 1 URL
    persistence + 3 URL restore). The critical regression test
    is "picking Created (oldest) on column A fires
    fetchKanbanTasks for col_a only (col_b is NOT called)".
- `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts`
  - Restored the "renders cards in input order" assertion
    (client-side sort is gone, wire order is what the user
    sees).
- `src/apps/desktop/src/__tests__/KanbanColumn.sortIndependence.spec.ts`
  - DELETED. The client-side comparator it tested is gone.
    The per-column independence is now verified by the
    KanbanView.sortByApi.spec.ts URL-restore tests.

## Verification

- `bun run build` — vue-tsc clean.
- `bunx vitest run src/__tests__/KanbanView.sortByApi.spec.ts`
  — 7/7 pass.
- `bunx vitest run src/__tests__/KanbanColumn.spec.ts` —
  19/19 pass.
- `bunx vitest run src/__tests__/KanbanView/` — 53/53 pass.
- `bunx vitest run` (full suite) — 2027 pass / 12 fail. The
  12 failures are PRE-EXISTING on main (5 DesignView.undoHidden,
  1 DesignElement static contract, 1 DesignView.nudge clamp,
  1 AppLayout.translateResize, 4 AppLayout.memoriesGate).
  Zero regressions from this fix.

## Branch / commit

- Branch: `worktree/per-column-sort-watcher`
- Plan doc: `docs/superpowers/plans/2026-08-06-kanban-sort-independence.md`

## Lessons

- **Network panel = wire shape, not behavior.** The user's
  initial complaint was about the Network panel showing the
  same `sort_by` on every column. We initially tried to fix
  this by adding per-column sorts to the wire (the
  per-column-sorts-map approach). The user pushed back: they
  don't want OTHER columns' endpoints called at ALL when
  one column's sort changes. The wire shape is secondary; the
  network volume is the primary concern.
- **Per-column fetch is the right primitive.** The store
  already has `fetchKanbanTasks(columnId, sortBy, direction)`
  that does ONE column's fetch with the column's own sort. The
  `fetchKanbanTasksForAllColumns` helper was the wrong tool for
  per-column sort changes — use the per-column primitive
  directly.
- **Idempotent user actions should always emit.** The watcher-
  based emit only fired on value CHANGE. The menu click
  handler emits unconditionally — even when the user picks
  the same sort twice. Same sort twice should still refetch
  (the user might be clicking to refresh).
- **`setSortMode` is a seam, not a side-effect channel.** It
  mutates refs but doesn't emit — the URL restore path uses
  it to set local state, then the onMount loop fires the
  fetch. The previous design let `setSortMode` emit, which
  caused a double fetch (one from the emit, one from the
  loop). Keep the seam pure.
