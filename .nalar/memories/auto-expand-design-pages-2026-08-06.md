# Auto-expand design pages in sidebar tree (2026-08-06)

## Symptom (user report, task_1785772308817)

User: *"see workspace design, when refresh its empty, but when i click it the
header it show, can you make all of that instant open"*.

After a browser refresh, the workspace sidebar's expanded design item showed
only `+ Add Page` (empty state). Clicking the design item's chevron
(collapse-then-expand) made the pages appear. The user wanted pages to render
instantly on mount without any click.

## Root cause

`workspacesStore.init()` restored `expandedItemIds` from localStorage (so the
design item stayed expanded), but it **never fetched design pages**. The
`fetchDesignPages` action only fired lazily from `WorkspaceItem.vue::
handleChevronToggle` when the user clicked the chevron.

Pre-fix flow:
1. Refresh → init() loads workspaces + items + tasks
2. `expandedItemIds[designId] === true` (restored from localStorage)
3. `designPagesByItemId[designId] === undefined` (never fetched)
4. Sidebar template `v-if="isExpanded && item.item_type === 'design'"` renders
5. `designPages` computed returns `[]` (empty cache)
6. Only `+ Add Page` button renders
7. User clicks chevron → toggle (collapse) → click again → toggle (expand)
   + `fetchDesignPages` fires → cache populates → sidebar re-renders

## Fix

Modify `init()` to fire `fetchDesignPages(ws.id, item.id)` for every design
item in parallel with the existing tasks fetch. Awaiting the fetch inside
`init()` means the sidebar is fully populated when `isLoading` flips to
`false`.

```ts
// In init() step 2/3/4 fan-out:
await Promise.all(
  (items || []).map(async (item: WorkspaceItem) => {
    if (item.item_type !== 'design') return
    try {
      await fetchDesignPages(ws.id, item.id)
    } catch (err) {
      console.error(`Failed to fetch design pages for item ${item.id}:`, err)
    }
  }),
)
```

The `fetchDesignPages` in-flight guard (the store-action `Map<itemId, Promise>`)
dedupes concurrent calls, so chevron-click racing init() shares the same
promise instead of double-fetching.

## Bonus: skip getTasks for design items

The per-item tasks fetch was gated on `item_type !== 'kanban'`. Adding
`&& item_type !== 'design'` is a small optimization — design items don't have
a tasks list (the sidebar template at `WorkspaceItem.vue:620` excludes them
per the design-pages-in-workspace-tree plan, 2026-08-06). Without this skip,
init would fire an unused `api.getTasks` for every design item.

## Why this is the canonical pattern

`init()` is the single point where the workspace tree is built. ANY data the
sidebar tree renders for an item should be fetched here. The per-item tasks
fetch (already in init) handles standard tasks. The new per-design-item pages
fetch handles design pages. Future additions (e.g., pre-loading task counts
for folders, pre-loading kanban column counts) should follow the same pattern
— fan out within the per-workspace `Promise.all`, fail best-effort, await
inside init for `isLoading` semantics.

## Pitfall: vi.fn() call state persists across tests

When a test uses `vi.fn()` for tracking calls and asserts `toHaveBeenCalledTimes(0)`,
you need `mockClear()` in `beforeEach`. `vi.restoreAllMocks()` (in `afterEach`)
restores spy implementations but does NOT clear `vi.fn()` call history. Without
the `mockClear()`, the second test sees the first test's calls and the count
assertion flakes.

```ts
beforeEach(() => {
  vi.spyOn(api, 'listDesignPages').mockImplementation(listDesignPagesMock)
  listDesignPagesMock.mockClear() // ← required for toHaveBeenCalledTimes(0)
})
```

## Out of scope (deferred to follow-ups)

- **Pre-load design ELEMENTS for the active design item.** This fix only
  pre-loads the page list. The active page's elements still fetch when
  DesignView mounts. A separate bug about the canvas going dark on the
  first design-page click is a different concern.
- **Loading skeleton state in the sidebar.** A future polish could show a
  subtle spinner while `init()` is running.

## Verification

- `bun run build` clean (vue-tsc passes, 1.82s)
- `bunx vitest run src/__tests__/workspacesStoreInit.spec.ts` — 9/9 pass
  (was 5/5, +4 new tests)
- `bunx vitest run` (full suite) — 2037 pass / 19 fail. The 19 failures are
  PRE-EXISTING on main (verified via direct run on main: 2033 pass / 19 fail).
  Zero regressions.

## Files

- `src/apps/desktop/src/stores/workspaces.ts` — init() fan-out
- `src/apps/desktop/src/__tests__/workspacesStoreInit.spec.ts` — +4 behavioural tests
- `docs/superpowers/plans/2026-08-06-auto-expand-design-pages.md` — plan

## Branch / commit

- Branch: `worktree/auto-expand-design-pages`
- Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/auto-expand-design-pages`