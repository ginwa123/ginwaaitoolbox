# Better URL browser — APPEND on task click, not REPLACE (2026-08-06)

## What landed (PR #178, commit `bb2b9bd4`)

`Sidebar.handleSelectTask` now APPENDS the current URL context to
the new task URL instead of REPLACING it. The user reported
*"when click task in kanban, no need replace url, but append the
url browser"* — clicking a kanban task used to write a lean
`?view=task&task=X&itemId=Y` URL via `router.replace`, dropping the
workspace + per-column sort context and clobbering the browser
history.

## The pattern (URL is breadcrumb, not just identifier)

When the user navigates between views, the URL should preserve the
breadcrumb context (workspaceId, itemId, pageId, sorts) so:

1. **Browser back works** — use `router.push` not `router.replace`
2. **Refresh preserves context** — the URL carries enough info to
   rehydrate the prior workspace state on reload
3. **No orphan context injection** — deep-link URLs without
   breadcrumb stay lean (don't inject workspaceId if none was there)

## Implementation pattern

```ts
// Pre-fix (REPLACE — clobbers history, drops context):
router.replace({
  path: '/app',
  query: { view: 'task', task: taskId, itemId: parentItemId },
})

// Post-fix (APPEND — preserves context, history intact):
const query: Record<string, string> = {
  ...pickBreadcrumbFromQuery(route.query),
  view: 'task',
  task: taskId,
  itemId: parentItemId,
}
router.push({ path: '/app', query })
```

`pickBreadcrumbFromQuery` extracts only the string-typed scalars
from vue-router's `LocationQuery` (which can also be `null |
(string|null)[]`):

```ts
const pickBreadcrumbFromQuery = (
  query: Record<string, unknown>,
): Record<string, string> => {
  const out: Record<string, string> = {}
  for (const key of ['workspaceId', 'itemId', 'pageId', 'sorts']) {
    const v = query[key]
    if (typeof v === 'string' && v.length > 0) out[key] = v
  }
  return out
}
```

## The mental model

The URL is not just an identifier of the current view — it's a
**breadcrumb** that lets the user:
- Go back (browser back button)
- Reload (URL → store → view rehydration)
- Share the link (paste to another tab, give to a teammate)
- Inspect what they're looking at (URL bar is the "where am I" UX)

`router.replace` is for "rewriting the current state" (e.g. closing
a dialog). `router.push` is for "navigating somewhere new" (e.g.
opening a task from a kanban — the kanban stays in history).

## Pitfalls (the non-obvious traps)

- **The `LocationQuery` type is `string | null | (string|null)[]`**,
  not `string`. Always narrow with `typeof v === 'string' &&
  v.length > 0` before spreading. Vue-router accepts null arrays for
  repeated query keys (`?foo=bar&foo=baz`).
- **The override order matters.** Spread the breadcrumb first, then
  override `view`/`task`/`itemId` — the new nav params always win
  over any stale URL value.
- **Deep-link round-trips stay lean.** When `route.query` has no
  breadcrumb fields (e.g. user bookmarked `?view=task&task=X`),
  `pickBreadcrumbFromQuery` returns `{}` and the resulting URL is
  just `{ view: 'task', task: X, itemId: Y }` — no orphan
  workspaceId is injected.
- **Don't delete the `savedSortsParam` snapshot mechanism.** It
  remains the close-restore fallback for AppLayout.handleCloseTaskView
  when the URL doesn't carry the kanban context (older URL patterns
  or stale reactive state). URL is the primary path; snapshot is the
  safety net.
- **Don't use `router.back()` for the close handler.** It would be
  more "browser-back-button-natural" but riskier — the user might
  have navigated away from the kanban between clicking the task and
  closing it; back would go to an unexpected page. The minimal
  change preserves the existing `router.replace` behavior on close.

## Where to look

- `src/apps/desktop/src/components/shell/Sidebar.vue::handleSelectTask` — the surgical change
- `src/apps/desktop/src/components/shell/Sidebar.vue::pickBreadcrumbFromQuery` — the new helper
- `src/apps/desktop/src/__tests__/sidebarHandleSelectTaskUrl.spec.ts` — 5 behavioural tests
- `docs/superpowers/plans/2026-08-06-better-url-browser.md` — plan
- `src/apps/desktop/src/__tests__/AppLayout.sortUrlRoundTrip.spec.ts` — round-trip contract still holds
- `src/apps/desktop/src/components/AppLayout.vue::handleCloseTaskView` — unchanged (still uses router.replace for close)

## Branch / PR / commit

- Branch: `worktree/better-url-browser`
- Commit: `bb2b9bd4`
- PR: #178
- Plan: `docs/superpowers/plans/2026-08-06-better-url-browser.md`