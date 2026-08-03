# Kanban — per-column sort fetch (only the changed column's endpoint)

## Symptom (user report, task_1785730557641 — take 2)

After the previous fix (`worktree/kanban-sort-independence` @ `911e6647`) restored per-column visual independence, the user reported the wire shape was still wrong. The Network panel showed every column receiving the same `sort_by` URL params on every sort change.

User feedback:
- *"when sort happen its should independece not all column use same sort by value, fix that code above"*
- *"just make sure if i sort column a, only column a endpoint that called, other column a should not call endpoint"*

The user's mental model:
> Wire volume matters. Picking a sort in one column should only hit ONE endpoint. Other columns are not affected by the click.

## Root cause

Two layers:

1. **`KanbanView.vue:427 watch(columnSorts, ...)`** took only the LATEST changed sort from `Object.values(columnSorts.value)` and applied it globally. The `watch` was debounced (300ms) and called `fetchKanbanTasksForAllColumns` with the single latest sort.

2. **`fetchKanbanTasksForAllColumns` (workspaces.ts:1302)** loops over every column and calls `fetchKanbanTasks(col, sortBy, direction)` with the SAME `sortBy` / `direction`. The backend's `listWorkspaceItemTasksWithCursor` accepts ONE sort per request, so this fan-out is the only way to keep the wire in sync — but the fan-out is the wrong primitive for per-column sort changes.

The previous fix (commit `911e6647`) addressed visual independence via a client-side `compareBySortMode` in `KanbanColumn.cardsInColumn`. The wire shape was unchanged — the comparator was a workaround for the global `ORDER BY`. The user is now asking for the wire shape itself to be per-column.

## Fix (surgical)

### 1. `handleColumnSortChange` in KanbanView fires per-column fetch

The handler now calls `fetchKanbanTasks` for ONLY the changed column, with that column's own sortBy/direction. Other columns' data is untouched.

```ts
const handleColumnSortChange = (
  columnId: string,
  payload: { sortBy: SortField; direction: SortDirection },
) => {
  // 1. Update columnSorts → watcher writes the URL.
  columnSorts.value = {
    ...columnSorts.value,
    [columnId]: { columnId, sortBy: payload.sortBy, direction: payload.direction },
  }

  // 2. Fire fetch for ONLY this column with its own sort.
  if (payload.sortBy === 'position' && payload.direction === 'asc') {
    // Default sort — no sortBy param, backend default ORDER BY.
    void workspacesStore.fetchKanbanTasks(
      props.workspaceId,
      effectiveItemId.value,
      columnId,
      10,
    )
  } else {
    const apiSortBy = payload.sortBy === 'position'
      ? undefined
      : payload.sortBy as 'created_at' | 'updated_at' | 'name'
    void workspacesStore.fetchKanbanTasks(
      props.workspaceId,
      effectiveItemId.value,
      columnId,
      10,
      undefined, // cursor
      undefined, // q
      apiSortBy,
      payload.direction,
    )
  }
}
```

### 2. `watch(columnSorts, ...)` is URL-only (no fetch)

The debounce is removed. Per-column fetch is already minimal — one endpoint per click.

```ts
watch(columnSorts, (next) => {
  const encoded = encodeSortsParam(Object.values(next))
  const query: Record<string, string> = { view: 'workspace' }
  if (props.workspaceId) query.workspaceId = props.workspaceId
  if (effectiveItemId.value) query.itemId = effectiveItemId.value
  if (encoded) query.sorts = encoded
  router.replace({ path: '/app', query })
})
```

### 3. URL restore onMount fires per-column fetches

```ts
if (entries.length > 0) {
  for (const entry of entries) {
    if (entry.sortBy === 'position' && entry.direction === 'asc') {
      // Default sort — already loaded with default, no extra fetch.
      continue
    }
    const apiSortBy = entry.sortBy === 'position'
      ? undefined
      : entry.sortBy as 'created_at' | 'updated_at' | 'name'
    void workspacesStore.fetchKanbanTasks(
      props.workspaceId,
      effectiveItemId.value,
      entry.columnId,
      10,
      undefined, // cursor
      undefined, // q
      apiSortBy,
      entry.direction,
    )
  }
}
```

### 4. KanbanColumn.cardsInColumn — back to plain filter

The client-side `compareBySortMode` from the previous fix is removed. The wire data is already in the column's own sort order — the column just filters.

```ts
const cardsInColumn = computed<Task[]>(() => {
  return props.tasks
    .filter((t) => t.kanban_column_id === props.column.id)
    .slice()
})
```

### 5. KanbanColumn emits on every menu click (not just value changes)

The previous `watch([sortBy, direction], ...)` only fired on value CHANGE — silent on idempotent picks (Manual after Manual). The fix moves the emit to `handleSortModalSelect`, which fires on every menu click:

```ts
const handleSortModalSelect = () => {
  sortModalOpen.value = false
  emit('sortChange', { sortBy: sortBy.value, direction: direction.value })
}
```

### 6. setSortMode is a pure ref-mutator (no emit)

The URL restore path uses `setSortMode` to apply the restored sort to the column's local refs. It does NOT emit — the onMount loop fires the per-column fetch directly. Avoiding the emit prevents double-fetch (one from the emit, one from the loop).

```ts
const setSortMode = (newSortBy: SortField, newDirection: SortDirection) => {
  sortBy.value = newSortBy
  direction.value = newDirection
  // No emit — the caller fires the fetch.
}
```

## What you DON'T change

- **`fetchKanbanTasksForAllColumns`** — kept as-is. Still used by:
  - KanbanView's `loadColumnsAndTasks` (initial mount-time fetch, no sort params — all columns, default sort)
  - The SSE handler (kanbanSse.ts) for re-fetch on remote mutation
  - The search-input watcher (all columns, same q)
  - The helper remains the right abstraction for "fetch all columns with the same sort". Per-column sort goes through `fetchKanbanTasks` directly.

- **Backend** — no changes. `listWorkspaceItemTasksWithCursor` already supports all 4 sort fields × 2 directions.

- **`loadMoreTasksForColumn`** — unchanged. Already uses per-column sort via `activeSortBy` / `activeSortDirection` maps in the store.

## Files

### Modified
- `src/apps/desktop/src/components/kanban/KanbanColumn.vue` — removed client-side sort + comparator. `handleSortModalSelect` always emits. `setSortMode` is a pure ref-mutator. Updated doc comments on `cardsInColumn` + the `sortChange` emit + the per-column sort state section.
- `src/apps/desktop/src/components/kanban/KanbanView.vue` — `handleColumnSortChange` fires per-column fetch. Watcher is URL-only. URL restore fires per-column fetches.
- `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts` — restored "renders cards in input order" assertion.
- `src/apps/desktop/src/__tests__/KanbanView.sortByApi.spec.ts` — 7 new behavioural tests (3 click handler + 1 URL persistence + 3 URL restore). The critical regression test: *"picking Created (oldest) on column A fires fetchKanbanTasks for col_a only (col_b is NOT called)"*.

### Deleted
- `src/apps/desktop/src/__tests__/KanbanColumn.sortIndependence.spec.ts` — the client-side comparator it tested is gone.

## Verification

- `bun run build` — vue-tsc clean.
- `bunx vitest run src/__tests__/KanbanView.sortByApi.spec.ts` — 7/7 pass.
- `bunx vitest run src/__tests__/KanbanColumn.spec.ts` — 19/19 pass.
- `bunx vitest run src/__tests__/KanbanView/` — 53/53 pass.
- `bunx vitest run` (full suite) — 2027 pass / 12 fail. The 12 failures are PRE-EXISTING on main (5 DesignView.undoHidden, 1 DesignElement static contract, 1 DesignView.nudge clamp, 1 AppLayout.translateResize, 4 AppLayout.memoriesGate). Zero regressions from this fix.

## Pitfalls

- **`watch([sortBy, direction], ...)` was wrong** — Vue's `watch` only fires on value CHANGE. Same-value picks (Manual after Manual) are silent. The fix moves the emit to `handleSortModalSelect` (called on every menu click, regardless of value change).
- **`setSortMode` should NOT emit** — the URL restore path uses it to apply the restored sort, then the onMount loop fires the fetch directly. A double emit causes a double fetch.
- **Don't fan out per-column sorts in a helper** — the previous attempt added a `perColumnSorts` parameter to `fetchKanbanTasksForAllColumns` and called it from the watcher. This still fires N parallel fetches on every change, which the user explicitly rejected. Use `fetchKanbanTasks` directly.
- **Pre-populate `columnPagination` in tests** — KanbanView's `loadColumnsAndTasks` fires `fetchKanbanTasks` for every column whose `columnPagination` is empty. To assert "only the changed column was called", the test fixture must have `columnPagination` populated for the OTHER columns so the initial mount fetch skips them.

## Out of scope

- Per-column COUNT endpoint (no user request).
- URL persistence of cursors (transient, no user request).
- Per-column search (search stays board-wide).
- Animation when switching columns.

## Branch / commits

- Branch: `worktree/per-column-sort-watcher`
- Plan doc: `docs/superpowers/plans/2026-08-06-kanban-sort-independence.md`

## Lessons

- **Network panel = wire shape, not behavior.** The user's initial complaint was about the Network panel showing the same `sort_by` on every column. The first take (per-column-sorts-map) fixed the wire shape but still fired N parallel fetches. The user pushed back: they don't want OTHER columns' endpoints called at all. The take-2 fix removes the fan-out entirely.
- **Per-column fetch is the right primitive.** The store already has `fetchKanbanTasks(columnId, sortBy, direction)`. Use it directly; the `fetchKanbanTasksForAllColumns` helper is for "all columns with the SAME sort" (initial mount, search, SSE) — not for per-column sort changes.
- **Idempotent user actions should always emit.** The watcher-based emit only fired on value CHANGE. The menu click handler emits unconditionally — even when the user picks the same sort twice. Same sort twice should still refetch.
- **`setSortMode` is a seam, not a side-effect channel.** It mutates refs but doesn't emit. The URL restore path uses it to set local state, then the onMount loop fires the fetch. Keeping the seam pure prevents double-fetch.
