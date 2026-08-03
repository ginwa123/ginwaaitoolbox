# URL pageId leak — design → non-design item navigation

## Symptom (user report, task_1785726648589)

Switching from a design page (`?view=workspace&itemId=DESIGN&pageId=Y`)
to a kanban in the sidebar left the URL as
`?view=workspace&itemId=KANBAN&pageId=Y` — the pageId from the
previous design "leaked" into the URL. User hypothesised this might
be why ChatView didn't show up after clicking a task in the kanban.

## Root cause

`workspacesStore.setActiveWorkspaceItem(itemId)` does **not** reset
`activeDesignPageId`. Switching from a design to a kanban leaves the
store's `activeDesignPageId` carrying the design's page id.

The URL sync watcher in `AppLayout.vue` watches
`[activeWorkspaceItemId, activeDesignPageId]` and writes the URL
based on both. The pre-fix line was:

```ts
if (pageId) query.pageId = pageId
```

This included `pageId` in the URL purely because `activeDesignPageId`
was truthy — without checking whether the active item is a design
that owns the page. The watcher fires when `activeWorkspaceItemId`
changes (e.g. switching to a kanban), reads the still-stale
`activeDesignPageId`, and writes the URL with the stale pageId.

## Fix (surgical, 1 conditional + 1 lookup)

In `AppLayout.vue`'s URL sync watcher, gate `pageId` on the active
item's type:

```ts
if (pageId) {
  const activeItem = workspacesStore.workspaces
    .flatMap((ws) => ws.items)
    .find((it) => it.id === itemId)
  if (activeItem?.item_type === 'design') {
    query.pageId = pageId
  }
}
```

Kanban and folder items drop the pageId entirely. design → design
keeps the pageId in the URL (DesignView falls back to first page if
the pageId is invalid for the new design — existing behaviour, no
regression).

## Why NOT reset activeDesignPageId in setActiveWorkspaceItem?

Considered two approaches:

1. **Reset `activeDesignPageId` in `setActiveWorkspaceItem`** when
   the item changes. Pro: catches all stale pageId scenarios
   (design → design, design → folder, design → kanban). Con:
   breaks `WorkspaceItem.vue::handleSelectDesignPage` which calls
   `setActiveDesignPage` THEN `setActiveWorkspaceItem` (page first
   to avoid a race where the URL watcher sees the new page with the
   old item). The order would need to flip.

2. **URL watcher only includes pageId when item is design** (the
   chosen fix). Pro: minimal change, no store state change, no
   WorkspaceItem.vue order change. Con: design → design still has
   stale pageId in the URL (DesignView falls back to first page).

Chose #2 for surgical minimal. Restore-heavy local fix would be
follow-up work.

## Tests

2 new behavioural tests in `AppLayout.urlPersist.spec.ts`:

- `activeWorkspaceItem → URL watcher does NOT leak stale pageId when switching from design to kanban`
- `activeWorkspaceItem → URL watcher does NOT leak stale pageId when switching from design to folder`

TDD trace: RED (both fail on pre-fix code with "expected
'page_first' to be undefined") → GREEN (after the fix).

## Verification

- `bunx vitest run src/__tests__/AppLayout.urlPersist.spec.ts` —
  25/25 pass (was 23/23, +2 new).
- `bun run build` — vue-tsc clean.
- `bunx vitest run` (full suite) — 2018 pass / 12 fail. The 12
  failures are PRE-EXISTING on `main` (5 DesignView.undoHidden, 1
  DesignView.nudge, 1 AppLayout.translateResize, 5 AppLayout.memoriesGate).
  No regressions.

## Pitfalls (the non-obvious traps)

- **The watcher fires BEFORE `handleNavigate`'s `router.replace`**.
  When `setActiveWorkspaceItem` runs, the watcher is queued for the
  next microtask. `handleNavigate` runs synchronously after, but
  `router.replace` is also queued. The watcher fires first (because
  it was queued first), reads `route.query.view` (workspace, the
  old view), and writes the URL with the stale pageId. `handleNavigate`'s
  clean URL gets overwritten by the watcher.

- **Setting `activeDesignPageId = ''` AFTER setting
  `activeWorkspaceItemId` doesn't help** because `setActiveWorkspaceItem`
  is what fires the watcher, and the watcher reads whatever
  `activeDesignPageId` is at that moment. Reseting after would still
  have the watcher fire with the stale value.

- **The watcher's `if (wsId && itemId)` guard correctly skips when
  the item is unknown** but doesn't help here because the kanban IS
  a known item (just not a design).

- **Defensive URL restoration fix is "out of scope"** for this
  commit. The URL restoration at `AppLayout.vue:~187` still sets
  `activeDesignPageId` unconditionally even for non-design items.
  This is benign (kanban doesn't use `activeDesignPageId`) but a
  reload with a stale URL bookmark will keep the stale pageId in
  the URL — until the next store mutation. Follow-up if users
  complain about persistent stale URLs.

## Files

- `src/apps/desktop/src/components/AppLayout.vue` — URL sync watcher
  (~14 lines including FIX comment).
- `src/apps/desktop/src/__tests__/AppLayout.urlPersist.spec.ts` —
  2 new behavioural tests.

## Branch / commit

- Branch: `worktree/fix-url-pageid-leak`
- Commit: `d8c9f48d`
- Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/fix-url-pageid-leak`
- Task: `task_1785726648589` (bug chatview)
