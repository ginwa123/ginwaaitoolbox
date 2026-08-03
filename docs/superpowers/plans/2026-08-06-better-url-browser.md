# Better URL browser — preserve kanban context when clicking a task (2026-08-06)

## Symptom (user report, task_1785771871817)

> *"when click task in kanban, no need replace url, but append the url
> browser"*

Clicking a task card in the kanban rewrote the URL via `router.replace`
from the kanban URL (which carries `?workspaceId=…&itemId=…&sorts=col_X:…`)
to a lean `?view=task&task=X&itemId=Y`. Two side effects the user
noticed:

1. **URL lost context** — the kanban's per-column sort state
   (`?sorts=col_X:updated_at:desc,…`) was silently dropped from the
   URL. A refresh of the task URL landed without the sort, even though
   Sidebar.handleSelectTask snapshots it into `savedSortsParam` for
   close-restore.
2. **Browser back button skipped the kanban** — `router.replace`
   clobbered the kanban URL from the history stack, so the back
   button jumped to whatever was before the kanban (often the
   workspace sidebar or a chat).

## Pre-fix URL shape

Before:
```
/app?view=workspace&workspaceId=ws_X&itemId=kanban_Y&sorts=col_a:updated_at:desc,…
```
Click task →
```
/app?view=task&task=task_Z&itemId=kanban_Y
```

## Post-fix URL shape

After:
```
/app?view=workspace&workspaceId=ws_X&itemId=kanban_Y&sorts=col_a:updated_at:desc,…
```
Click task →
```
/app?view=task&task=task_Z&itemId=kanban_Y&workspaceId=ws_X&sorts=col_a:updated_at:desc,…
```

The task URL **appends** the kanban context instead of replacing it:
- `view` and `task` are the new params (overridden on the spread)
- `workspaceId`, `itemId`, `sorts`, `pageId` are preserved from the
  previous URL
- `router.push` keeps the kanban URL in the browser history so the
  back button returns naturally

## What landed

**1 surgical change to `Sidebar.handleSelectTask`** (`src/apps/desktop/src/components/shell/Sidebar.vue`):
- Spreads the current `route.query`'s breadcrumb fields
  (`workspaceId`, `itemId`, `pageId`, `sorts`) into the new query
- Overrides `view: 'task'`, `task: taskId`, `itemId: parentItemId` on
  the spread
- Uses `router.push` instead of `router.replace`
- New helper `pickBreadcrumbFromQuery` extracts only the string-typed
  scalars (vue-router's `LocationQuery` values are
  `string | null | (string|null)[]`; arrays/nulls are dropped)

**5 new behavioural tests** in
`src/apps/desktop/src/__tests__/sidebarHandleSelectTaskUrl.spec.ts`:

1. From a kanban URL, the task URL preserves `workspaceId`, `itemId`,
   `sorts` (the bug repro — RED without the fix).
2. From any URL, the click uses `router.push` (not
   `router.replace`).
3. From a design URL, `pageId` is preserved in the task URL.
4. From a deep-link task URL (no `workspaceId` in query), the new
   URL does NOT inject orphan workspace context — deep-link
   round-trips stay lean.
5. The `savedSortsParam` snapshot is STILL taken on click — it's
   the close-restore fallback the AppLayout.handleCloseTaskView
   reads when an older URL pattern lands on task without kanban
   context.

## Behavioural matrix

| Pre-click URL                                    | Post-click URL (push)                                                                                             |
|--------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| `?view=workspace&workspaceId=W&itemId=K&sorts=S` | `?view=task&task=T&itemId=K&workspaceId=W&sorts=S`                                                                |
| `?view=workspace&workspaceId=W&itemId=D&pageId=P`| `?view=task&task=T&itemId=D&workspaceId=W&pageId=P`                                                               |
| `?view=chat`                                     | `?view=task&task=T&itemId=K` (no kanban context to preserve — clean deep-link style)                              |
| `?view=task&task=A&itemId=K` (deep link)         | `?view=task&task=T&itemId=K` (no workspaceId was in URL — no orphan context injected)                              |
| `?view=task&task=A&itemId=K&workspaceId=W&sorts=S` (from a previous push + manual URL hack) | `?view=task&task=T&itemId=K&workspaceId=W&sorts=S` (preserves the prior context) |

## Why NOT also touch `handleCloseTaskView`?

`AppLayout.handleCloseTaskView` reads `activeWorkspaceId`,
`activeWorkspaceItemId`, `activeDesignPageId` from the store and
`workspacesStore.savedSortsParam` from the snapshot. After my fix:

- The store mirrors the URL (workspaceId, itemId, pageId all set).
- The `savedSortsParam` snapshot is still populated.
- The handle writes the same `?view=workspace&workspaceId=…&itemId=…`
  URL back. The user's mental model of "close the task → return to
  the kanban" is preserved.

A `router.back()` would be more "browser-back-button-natural" but
riskier (the user might have navigated away from the kanban between
clicking the task and closing it; back would go to an unexpected
page). The minimal change preserves the existing `router.replace`
behavior.

## Why not delete `savedSortsParam`?

It remains the close-restore fallback for:
- Older URL patterns that land on task without kanban context
- Stale `route.query` reads (e.g. reactive race between click handler
  and close handler — the snapshot is the canonical copy)

After my fix, the URL is the primary path; the snapshot is the
safety net. Both should coexist.

## Files

- `src/apps/desktop/src/components/shell/Sidebar.vue`
  (`handleSelectTask` + new `pickBreadcrumbFromQuery` helper)
- `src/apps/desktop/src/__tests__/sidebarHandleSelectTaskUrl.spec.ts`
  (new, 5 behavioural tests)

## Verification

- `bunx vitest run src/__tests__/sidebarHandleSelectTaskUrl.spec.ts`
  — 5/5 pass.
- `bunx vitest run src/__tests__/AppLayout.sortUrlRoundTrip.spec.ts`
  — 2/2 pass (existing round-trip contract intact).
- `bunx vitest run` — 2038 pass / 19 fail. The 19 failures are
  pre-existing on `main` (verified by `git stash` + re-run on the
  parent commit `b7993b52` — same 19 failures, same files:
  `DesignView.undoHidden ×5`, `DesignView.nudge clamp ×1`,
  `DesignElement static contract ×1`, `AppLayout.translateResize ×1`,
  `AppLayout.urlPersist ×7`, `AppLayout.memoriesGate ×4`).
- `bun run build` — vue-tsc clean.

## Out of scope (deferred)

- `router.back()` for the task-close button — would be more
  intuitive but risks breadcrumb surprises (see above).
- Reactively syncing the URL on store mutations not covered by the
  existing watcher at `AppLayout.vue:239-281` — not needed for this
  fix.
- A "compact URL" mode for clean URLs (`/task/T` instead of
  `?view=task&task=T`) — would require router config changes,
  separate plan.
- Same `push` treatment for chat-row clicks — chat URLs are
  differently scoped (per-session, not per-task) and don't share
  the kanban breadcrumb shape.

## Branch / commit

- Branch: `worktree/better-url-browser`
- Commit: TBD (pending)
