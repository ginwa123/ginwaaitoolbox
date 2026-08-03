# Auto-expand design pages in sidebar tree (2026-08-06)

## Symptom (user report, task_1785772308817)

User: *"see workspace design, when refresh its empty, but when i click it the header it show, can you make all of that instant open"*.

After a browser refresh (or any re-mount of `AppLayout`), the workspace sidebar
tree's expanded design item shows:

```
▼ design
  + Add Page
```

…instead of the populated `<DesignPageRow>` children (AI Chat View, Kanban Mode,
Chat View In Progress, Workspaces Sidebar, Task Dialog, + Add Page). Clicking
the design item's header (which triggers a chevron-toggle collapse-then-expand)
pops the pages in. The user wanted this to happen instantly on mount, with no
click.

## Root cause

`workspacesStore.init()` restored `expandedItemIds` from localStorage on every
boot (so the design item stayed expanded), but it **never fetched design
pages**. The `fetchDesignPages` action was only called lazily from
`WorkspaceItem.vue::handleChevronToggle` when the user clicked the chevron
(line 131, `void workspacesStore.fetchDesignPages(...)`).

The result: after a refresh, the sidebar tree's nested `<DesignPageRow>` block
(see `WorkspaceItem.vue:731-761`) renders, but `designPagesByItemId[itemId]`
is still `[]` because nothing fetched them. The empty state (`+ Add Page`) is
the only thing visible.

User workaround: click the chevron → `toggleExpandedItem` flips to
collapsed → click again → flips to expanded AND fires `fetchDesignPages` →
cache populates → sidebar re-renders with the page list.

## Fix (surgical, frontend-only)

Modify `workspacesStore.init()` to fire `fetchDesignPages(ws.id, item.id)` for
every design item in parallel with the existing tasks fetch. Awaiting the
fetch inside `init()` means the sidebar is fully populated by the time
`isLoading` flips to `false`. No changes to `WorkspaceItem.vue`, the chevron
handler, or the existing fetch flow.

### Files modified

| File | Change |
|------|--------|
| `src/apps/desktop/src/stores/workspaces.ts` | Added per-design-item `fetchDesignPages` block in `init()` (parallel to existing tasks fetch). Updated the `resetDesignPagesCache()` comment to reflect the eager init fetch. |
| `src/apps/desktop/src/__tests__/workspacesStoreInit.spec.ts` | Added 4 behavioural tests + 1 mock reset (mockClear in beforeEach so call-count assertions stay scoped). |

### Why also skip `getTasks` for design items

The per-item tasks fetch was already gated on `item_type !== 'kanban'`. Adding
`&& item_type !== 'design'` is a small optimization — design items don't have
a tasks list (the sidebar template at `WorkspaceItem.vue:620` excludes them per
the design-pages-in-workspace-tree plan, 2026-08-06). Without this skip, the
new init code path would fire an unused `api.getTasks` for every design item.

## Behavioural invariants (locked in by tests)

1. `init()` calls `listDesignPages` exactly once per design item — never for
   folder/chat/kanban items.
2. The call count for non-design-item workspaces is `0` (regression guard
   against accidentally broadening the filter to kanban/folder/chat).
3. The cache (`designPagesByItemId`) is populated before `init()` resolves —
   `isLoading === false` and `designPagesByItemId[itemId]` is non-empty at the
   same time.
4. A failing `listDesignPages` call is best-effort: workspace tree still
   loads, failing design item has no cache entry, chevron-toggle's lazy fetch
   is the fallback retry.

## Trade-offs (none flagged for user confirmation)

- **One extra HTTP call per design item on every init.** A typical workspace
  has 1-3 design items; this is sub-100ms of additional latency on a cold
  boot. The `fetchDesignPages` in-flight guard dedupes concurrent calls, so
  the chevron-click and the init fetch share the same promise.
- **`init()` blocks on `listDesignPages`.** Previously, init resolved as
  soon as the tasks fetch completed; design pages filled in later. Now init
  resolves only after both. For a workspace with 1-3 design items, this is
  imperceptible. If a workspace has 10+ design items, consider switching to
  fire-and-forget + reactive rendering.

## Why the user said "click it the header" (mechanism)

The user's mental model: clicking the design item header makes the pages show
up. The actual mechanism: clicking the design item's *chevron* collapses then
re-expands, with the second expansion firing the lazy fetch. The header click
itself calls `handleClick`, which for design items does NOT toggle expand
(see `WorkspaceItem.vue:105-107` — design items skip the toggle path because
they use the dedicated chevron handler). So if the user only clicked the row
body (not the chevron), they'd see no change.

Either way, the fix removes the need to click anything — the pages show on
mount.

## Verification

- `bun run build` clean (vue-tsc passes, 1.82s)
- `bunx vitest run src/__tests__/workspacesStoreInit.spec.ts` — **9/9 pass**
  (was 5/5, +4 new tests)
- `bunx vitest run src/__tests__/workspacesStoreDesignPages.spec.ts
  src/__tests__/DesignPageRow.spec.ts` — 11/11 pass (unchanged)
- `bunx vitest run` (full suite) — 2037 pass / 19 fail. The 19 failures are
  PRE-EXISTING on main (verified via direct run on main: 2033 pass / 19 fail).
  The +4 net new tests are the only delta.

## Out of scope (deferred to follow-ups)

- **Pre-load design ELEMENTS for the active design item.** This fix only
  pre-loads the page list. The active page's elements still fetch when
  DesignView mounts. The pre-fix bug was about the sidebar tree being empty
  — that's now fixed. A separate bug about the canvas going dark on the
  first design-page click is a different concern (would need a similar eager
  fetch in DesignView.onMounted).
- **Pre-load pages for ALL workspaces, not just the first.** `init()` already
  iterates every workspace; the fix follows the same per-workspace fan-out.
  No change needed for users with multiple workspaces.
- **Loading skeleton state in the sidebar.** A future polish could show a
  subtle spinner while `init()` is running. Today's behavior is the same as
  before for non-design items (no spinner during tasks fetch).

## Branch / commit

- Branch: `worktree/auto-expand-design-pages`
- Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/auto-expand-design-pages`
- Files: 2 modified (1 store + 1 test)
- Tests: +4 new behavioural tests