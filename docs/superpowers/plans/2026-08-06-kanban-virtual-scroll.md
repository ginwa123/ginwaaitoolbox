# Kanban VirtualScroller + URL Sort Defaults (2026-08-06)

## Summary

Three related changes to the kanban view that landed in the
`worktree/kanban-sort-by` branch:

1. **VirtualScroller integration.** Cards in each column now render
   through `<VirtualScroller>` (the same component used by ChatView)
   instead of plain `v-for`. With 100+ tasks on a column, the DOM
   stays at ~10-14 cards regardless of total. The user-reported
   "lazy load adds items in TOP not BOTTOM" bug is gone — that was
   plain-v-for visually displacing existing rows when a new page
   arrived.

2. **URL `?sorts=col_X:updated_at:desc,...` is the source of truth
   for sort.** When the user clicks a kanban workspace item in the
   sidebar, Sidebar writes a default `sorts` string for every column.
   The kanban column's existing per-column sort picker still works —
   picking a sort emits `sortChange`, KanbanView writes the URL,
   and `fetchKanbanTasksForAllColumns(sortBy, direction)` re-fetches
   with the new sort so the backend re-sorts.

3. **`api.getTasks` no-default sort params.** `sortBy` and
   `direction` default to `undefined`; only set on the URL when
   BOTH are explicitly provided. The backend's own default
   (`updated_at desc`) handles the no-sort case identically — same
   wire result, cleaner URL.

## Why now (vs the original kanban-sort-by plan)

The original plan kept the per-column sort picker client-side:
cardsInColumn applied a local sort after the backend returned
globally-sorted tasks. The user then iterated:
- "if limit 10, why not auto fetch" (the user wanted auto-fetch
  on a page that fits the viewport — fixed in the VirtualScroller
  integration with an `hasAutoFetched` watcher).
- "i remove that [client-side sort] and its become better" (the
  user removed the `.sort()` call in `cardsInColumn` — fixed by
  pointing the picker at the backend via the URL, and removing
  the unused `compareBySortMode` comparator).
- "no need set default when load task kanban" (the user wanted
  the API not to send silent sort defaults — fixed by removing
  the `sortBy: 'updated_at' = 'updated_at'` defaults on
  `api.getTasks`).

## Files

### New (3)

- `src/apps/desktop/src/__tests__/KanbanColumn.virtualScroller.spec.ts` (15 tests)
- `src/apps/desktop/src/__tests__/apiGetTasksSortParams.spec.ts` (6 tests)
- `src/apps/desktop/src/__tests__/sidebarKanbanSortUrl.spec.ts` (4 tests)

### Modified (8)

- `src/apps/desktop/src/api/index.ts` — drop defaults on `getTasks(sortBy, direction)`
- `src/apps/desktop/src/components/AppLayout.vue` — `handleNavigate(view, chatName?, taskId?, workspaceId?, itemId?, pageId?, sortsParam?)` — new 7th positional arg
- `src/apps/desktop/src/components/kanban/KanbanColumn.vue` — wrap cards in `<VirtualScroller>` + card gap `pb-1`; delete unused `compareBySortMode`; add auto-fetch watcher for short columns
- `src/apps/desktop/src/components/shell/Sidebar.vue` — `handleSelectItem` builds the `?sorts=col_X:updated_at:desc,...` string when the item is a kanban
- `src/apps/desktop/src/__tests__/AppLayout.urlPersist.spec.ts` — 3 new tests for `sortsParam`
- `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts` — reframe 1 test (no client-side sort)
- `src/apps/desktop/src/__tests__/KanbanView.sortByApi.spec.ts` — rewrite 1 test (URL → fetch mapping, not card order)
- `AGENTS.md` — changelog entry

### Deleted (1)

- `src/apps/desktop/src/__tests__/KanbanColumn.sortMenu.spec.ts` (12 tests)
  — per-column-sort UI is intact (the picker still works, the URL
  still writes) but the client-side comparator is gone. Replaced
  by the auto-fetch tests in `KanbanColumn.virtualScroller.spec.ts`.

## Behavioural contract

| User action                              | Result                                                |
| ---------------------------------------- | ----------------------------------------------------- |
| Click kanban item in sidebar              | `?sorts=col_X:updated_at:desc,...` written to URL     |
| Refresh                                  | Backend honors `?sorts=` per-column on initial fetch  |
| Open column ⋮ → "Sort tasks…" → pick a sort | URL updates, fetch fires with new sort, backend re-sorts |
| Scroll to bottom of column                | VirtualScroller @load-more → `loadMoreTasksForColumn`  |
| Short column that fits the viewport        | Auto-fetch watcher fires until scroller is scrollable |

## Verification

- `bun run build` — clean (vue-tsc passes)
- `bunx vitest run` — **2016 pass / 12 fail** (the 12 are pre-existing
  on main — banned static-contract tests in AppLayout.memoriesGate /
  DesignElement static + design-view regressions in
  DesignView.undoHidden / AppLayout.translateResize /
  DesignView.nudge). No new failures.

## Out of scope (deferred)

- Drag-to-reorder while a non-position sort is active: backend
  still writes `kanban_position` on drop; client renders the
  dragged card at its server-sorted position on the next
  reactive update. Same UX as before.
- LLM tool calls that drove the per-column picker UI: the picker
  is still in the template (`Sort tasks…` ⋮ menu entry), but
  the LLM-tool path that used to call it was removed in an
  earlier round. Re-add if requested.
