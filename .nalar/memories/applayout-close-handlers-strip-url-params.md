# AppLayout close handlers strip URL params — recurring bug class

## Symptom

Closing a sidebar overlay (chatview ✕, git file viewer ✕, skill viewer ✕,
code editor ✕) silently strips `pageId` from the URL when the user was
on a design item. A page reload then restores the design item but lands
on the FIRST design page instead of the page the user had been editing.

Repro: open design item with multiple pages → click page B → open chat
panel → close chat (✕) → notice URL is now `?view=workspace&workspaceId=X&itemId=Y`
(no `pageId`) → reload → land on page A (the first one).

## Root cause

`AppLayout.vue` has FOUR close handlers that all call
`router.replace({ path: '/app', query: { view: 'workspace', workspaceId, itemId } })`:

| Handler | Line | Trigger |
|---|---|---|
| `handleCloseTaskView` | 712 | ChatView ✕ button |
| `closeGitViewer` | 391 | GitFileViewer ✕ button |
| `closeSkillViewer` | 458 | SkillDetail ✕ button |
| `closeCodeEditor` | 554 | CodeEditor ✕ button |

ALL FOUR read `activeWorkspaceItemId` and `activeWorkspaceId` from the
store but NOT `activeDesignPageId`. So the URL is missing `pageId` after
close.

The reverse-sync watcher at `AppLayout.vue:236-263` watches
`[activeWorkspaceItemId, activeDesignPageId]` and mirrors them back to
the URL — but it ONLY fires when EITHER value changes. Closing chat/git/
skill/code doesn't change either value, so the watcher doesn't run to
restore the pageId either. The result: pageId is silently gone.

The forward sync (`handleNavigate('workspace', …, wsId, itemId)`) has
the same gap — it sets `workspaceId + itemId` but not `pageId`. But
the watcher catches that because `setActiveWorkspaceItem(itemId)` does
change `activeWorkspaceItemId`, which triggers the watcher to write
pageId to the URL.

## Fix

In all 4 close handlers, also read `activeDesignPageId` from the store
and include `pageId` in the `router.replace` query when set:

```js
const pageId = workspacesStore.activeDesignPageId
const query: Record<string, string> = {
  view: 'workspace',
  workspaceId: wsId,
  itemId,
}
if (pageId) query.pageId = pageId
router.replace({ path: '/app', query })
```

`pageId` is design-item-scoped and empty for kanban/folder items, so
the URL stays clean for non-design items (omit when empty).

## Why this bites (3 reasons)

1. **The reverse-sync watcher hides the bug for SOME flows** but not
   for close flows. Testing by setting `activeWorkspaceItem` directly
   works fine because the watcher fires; testing by calling close
   handlers shows the pageId drop because the watcher doesn't fire.
2. **TypeScript / vue-tsc don't catch it** — the template compiles
   cleanly with the missing param.
3. **Static contract tests don't catch it** — they grep for handler
   existence, not for the full URL contract.

## When this bites

- Any new "close overlay" handler that navigates back to a workspace
  view. ALWAYS include the pageId (when set) in the URL query.
- Any new "open overlay" handler that changes the view from workspace
  to a child view. ALSO save the previous URL params so close can
  restore them. (The git/skill/code openers use `setActiveWorkspaceItem`
  side-effect-free and rely on the store's `activeWorkspaceItemId`
  being already populated — they don't need to save it explicitly.)
- A refactor that changes `activeWorkspaceItemId` reset semantics —
  if close ever does clear `activeWorkspaceItemId`, the watcher would
  fire and re-mirror pageId back to the URL, but it'd mirror the wrong
  itemId. Always audit.

## Detection recipe

```bash
# Find every router.replace call in AppLayout.vue and check the query
rg -n "router.replace" src/apps/desktop/src/components/AppLayout.vue

# Find every place that reads activeWorkspaceItemId (should always
# consider pageId in the same scope)
rg -n "activeWorkspaceItemId" src/apps/desktop/src/components/AppLayout.vue
```

For each match, ask: "does this URL contract include ALL the
forward-sync params?" If not, add the missing ones.

## Verification recipe

```bash
cd src/apps/desktop
timeout 60 bunx vitest run src/__tests__/AppLayout.urlPersist.spec.ts
# 19/19 pass (was 16 before fix)

timeout 180 bunx vitest run   # 1522/1522 pass
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build   # clean
timeout 180 bun run build   # vue-tsc + vite clean
```

## Tests (AppLayout.urlPersist.spec.ts)

- `handleCloseTaskView preserves workspaceId + itemId when the active
  task belongs to a design` — UPDATED to also assert `pageId` is in
  the URL after close.
- `handleCloseTaskView omits pageId when no design page is active` —
  NEW: covers kanban item case (no pageId in URL after close).
- `closeGitViewer preserves workspaceId + itemId + pageId when on a
  design item` — UPDATED, renamed from "+ itemId".
- `closeSkillViewer preserves workspaceId + itemId + pageId when on a
  design item` — UPDATED, renamed.
- `closeCodeEditor preserves workspaceId + itemId + pageId when on a
  design item` — UPDATED, renamed.

## Related

- `vue-tsc-build-emits-js-files.md` — vue-tsc --build emits .js files
  next to .ts source files; delete them before committing (project
  convention, not enforced by tooling).
- `zig-0.16-stdlib-changes.md` §"Function parameter with matching
  return type is implicitly const" — same "narrow surface, wide blast
  radius" bug pattern. Fixes look trivial but the bug is invisible
  to type-check alone.
- Branch: `worktree/close-chatview-keep-pageid`
- Commit: `e5897530`
- Plan: `docs/plans/2026-07-28-close-chatview-keep-pageid.md`
  (deleted — content rolled into commit message and this memory).