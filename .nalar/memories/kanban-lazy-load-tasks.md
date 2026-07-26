# nalar — Kanban task list hidden pagination cap

## Symptom

The Kanban board (item_type='kanban') showed partial data without any "Load more" affordance:

- A column with > 20 tasks appeared truncated: badge said "16" but the user expected more.
- The frontend's "Load more" button (folder-list view, `WorkspaceItem.vue:537`) was NOT wired into the kanban view.
- `KanbanView.vue` only renders whatever's in `props.item.tasks ?? []` — no scroll trigger, no auto-load.

## Root cause

`workspacesStore.fetchKanbanTasks` (`stores/workspaces.ts:846-863`) called `api.getTasks(workspaceId, itemId)` with **no limit arg**. The backend handler `tasks_list.zig:24-27` defaults to `DEFAULT_PAGE_SIZE=20`:

```zig
const DEFAULT_PAGE_SIZE: u32 = 20;
const MAX_PAGE_SIZE: u32 = 100;
```

So the kanban always loaded the FIRST 20 tasks of the parent item (sorted by `is_pinned DESC, pinned_position DESC, updated_at DESC, id DESC` per `listWorkspaceItemTasksWithCursor`). Tasks beyond the 20-task ceiling were invisible to the kanban view entirely — no cursor advance, no second page, no UI hint that more existed.

## Fix (PR `feature/kanban-lazy-load-tasks`, 2 commits)

### Chunk 1 — bump initial fetch to `limit=100`

`stores/workspaces.ts` `fetchKanbanTasks` now passes `100` as the third arg to `api.getTasks`, matching the backend's `MAX_PAGE_SIZE`. Typical kanbans load in a single round-trip.

Regression tests added in `__tests__/workspacesStoreKanbanTasks.spec.ts`:
- Existing "replaces item.tasks" test updated to assert `expect(api.getTasks).toHaveBeenCalledWith(WS_ID, ITEM_ID, 100)`
- New: "passes limit=100 on initial fetch (matches backend MAX_PAGE_SIZE)" — pins the contract
- New: "does not pass a cursor on initial fetch" — guards against future refactors that thread the cursor through unconditionally

### Chunk 2 — per-column auto-load + Load more button

`components/kanban/KanbanColumn.vue` got two new pieces wired through the existing `workspacesStore.loadMoreTasks`:

1. **Scroll-triggered auto-load**: a 1px sentinel `<div ref="autoLoadSentinel">` placed at the bottom of the cards container. An `IntersectionObserver` with `rootMargin: '0px 0px 200px 0px'` (matches VirtualScroller's `loadMoreThreshold`) fires `loadMoreTasks` once when the sentinel enters the viewport. Debounced via `hasTriggeredAutoLoad` ref that resets when `cardsInColumn.value.length` changes (a new page arrived). Observer disconnects on `onUnmounted` and re-wires when the sentinel ref is recreated.

2. **Manual "Load more" button** at the bottom of each column when `item.hasMoreTasks` is true. Disabled during `isLoadingMoreTasks`. Catches keyboard-only users and short columns where the sentinel never enters the viewport.

Both routes reuse the existing `loadMoreTasks` store action (no new store changes) — the `isLoadingMoreTasks` guard + cursor advance + SSE reconcile all work without further wiring. The button's `data-testid="kanban-column-${column.id}-load-more"` mirrors the folder-list's `data-testid="load-more-tasks"` for consistency.

**Refactor**: inline `workspacesStore.workspaces.find(...).items.find(...)` lookups in the template became `moreTasksAvailable` + `loadingMoreTasks` computeds for cleaner template code.

## Why this matters

1. The bug was silent — `count: 16` on the merged column badge *looks* correct, but it's "16 of whatever loaded", not "16 of N". Users with > 20 tasks had no way to know more existed.
2. The pagination primitive already existed (`loadMoreTasks`) — only the kanban-side wiring was missing. Reusing it (not building a parallel system) means SSE reconciliation + cursor advance + double-click guarding all came for free.
3. `bun run build` is the only check that catches `vue-tsc` template errors that `bunx vitest run` misses — both must pass per `.nalar/memories/project-working-patterns.md`.

## When this bites (future agents)

- Adding a NEW kanban-like view (folder kanban, calendar view, etc.) — always check whether the new view wires `loadMoreTasks` (it might silently inherit the 20-task cap like the kanban did).
- Raising the backend's `DEFAULT_PAGE_SIZE` or `MAX_PAGE_SIZE` — the frontend's hardcoded `100` in `fetchKanbanTasks` would diverge from the backend cap and over-fetch (backend clamps silently). Keep them in sync — pin a comment in both files.
- Adding per-column pagination — DON'T. The backend cursor is per-item (joins routines + sessions), so a "per-column next page" would require backend changes (group-by + cursor on the JOIN side). Out of scope for this plan.

## Related

- `docs/SPEC.md` §3.7 (Frontend — Kanban, lazy-load tasks entry) — the full plan was consolidated into the spec
- `src/ai_workflow/tui/http_handlers/tasks_list.zig:24-27` — backend's `DEFAULT_PAGE_SIZE=20` and `MAX_PAGE_SIZE=100` (the source of truth for the cap)
- `src/apps/desktop/src/stores/workspaces.ts:846-863` — `fetchKanbanTasks` (the fix)
- `src/apps/desktop/src/stores/workspaces.ts:1420-1452` — `loadMoreTasks` (the existing primitive the kanban now reuses)
- `src/apps/desktop/src/components/kanban/KanbanColumn.vue` — auto-trigger + Load more button