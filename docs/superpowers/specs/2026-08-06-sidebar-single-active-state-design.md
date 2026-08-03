# Sidebar: single active state driven by main content view

> Date: 2026-08-06
> Owner: session_1785793620170
> Status: **Draft — awaiting user approval before implementation**

## Problem (user-reported)

Sidebar shows multiple rows styled as "active" at once, so the user
cannot tell which one the main content area is actually showing.

Screenshot evidence: while viewing `?view=workspace&workspaceId=…
&itemId=DESIGN&pageId=TASK_DIALOG`, the sidebar shows THREE rows
with the same `--semantic-active-bg` background:

| Row | Why it has the active bg |
|---|---|
| `session-1785791654156` (CHATS section) | `navigationStore.sessionId` still points at it from a previous click |
| `agentic coding` (WORKSPACES section header) | `workspace.expanded === true` — only because the user opened it, not because it's active |
| `Task Dialog` (design page list) | `activeDesignPageId === TASK_DIALOG` — actually active |

The actual active workspace item (`design`) has the active bg too, but
its color matches the expanded workspace above, so visually they
blend. Result: zero clear "this is what you're looking at" indicator.

## User's mental model (verbatim)

> "i just want only one active on sidebar, if active that mean the
> main content is related with the active"

## Goal

**At most one row in the sidebar is ever styled as "active" at a
time, and that row always corresponds to what the main content area
is currently showing.**

## Mental model (URL is source of truth)

The URL is the only source of truth for "what is in the main content
area right now". The sidebar derives its `active` state from the URL,
not from a separate Pinia store flag that can drift.

```
URL                                      → exactly one row is "active"
─────────────────────────────────────────────────────────────────
?view=chat&session=X                     → the chat row whose id === X
?view=task&task=X                        → the task row whose id === X
?view=workspace&itemId=Y                 → the workspace item row whose id === Y
?view=workspace&itemId=Y&pageId=Z        → the workspace item + the design page row whose id === Z
?view=workspace&workspaceId=W            → no row active (folder view, just the workspace is "open")
?view=settings, ?view=gitfile, etc.      → no row active (other views)
```

When the URL changes (router push/replace, refresh, deep link), the
sidebar re-derives the active row. No store mutation needed for the
sidebar's own active styling — the URL is enough.

## Design

### 1. URL-derived `currentMainView` computed (one place)

Add a single computed `currentMainView` to the workspaces store (or
a small composable) that returns one of:

```ts
type CurrentMainView =
  | { kind: 'chat';     sessionId: string }
  | { kind: 'task';     taskId: string; workspaceId?: string; itemId?: string }
  | { kind: 'workspace'; itemId: string; pageId?: string; workspaceId?: string }
  | { kind: 'none' }
```

Reads from `useRoute().query` (vue-router). All sidebar active-state
decisions consume this computed.

### 2. Each sidebar component asks "am I the current view?"

| Component | Active condition (NEW) |
|---|---|
| `ChatsList.vue` chat row | `currentMainView.kind === 'chat' && currentMainView.sessionId === item.id` |
| `WorkspaceItemTaskRow.vue` task row | `currentMainView.kind === 'task' && currentMainView.taskId === task.id` |
| `WorkspaceItem.vue` item row | `currentMainView.kind === 'workspace' && currentMainView.itemId === item.id` |
| `DesignPageRow.vue` page row | `currentMainView.kind === 'workspace' && currentMainView.pageId === page.id` |

Replace the existing store-derived active checks with these URL-derived checks. The store's `activeTaskId` / `activeWorkspaceItemId` / `activeDesignPageId` flags are kept (other AppLayout code consumes them) but stop driving sidebar highlighting.

### 3. Expanded workspace ≠ active workspace

WorkspaceList's "expanded workspace" loses its `--semantic-active-bg`
background. New styling for expanded workspaces:

- Chevron rotated 90° (same as today)
- **No background** — expanded is a UI state, not a content relationship
- Item count badge unchanged

The active WORKSPACE ITEM keeps the active bg. With the expanded
workspace no longer using that bg, the active item now stands out
from its expanded parent.

### 4. Active item gets a left accent bar

Add a 2px violet (`--color-violet`) left accent bar to the active
workspace item row. This is in addition to the bg, so the active
item is visually unambiguous even when its parent workspace is also
expanded. Implementation: `box-shadow: inset 2px 0 0 0 var(--color-violet)` on the active row.

Same accent bar treatment on the active chat row and the active
design page row (for visual consistency — "active" means the same
thing everywhere).

### 5. Side navigation does not propagate "active"

When user clicks a chat row, no longer set `workspacesStore.setActiveWorkspaceItem(null)` — the URL update handles it. The store's `activeWorkspaceItemId` only changes when the user clicks a workspace item (other AppLayout code paths still depend on it).

Same for the other direction: clicking a workspace item does NOT need to clear `navigationStore.sessionId`. The URL is the source of truth.

The store still tracks these flags for AppLayout's view routing
(beyond sidebar highlighting), but the sidebar no longer trusts
them for its own active state.

### 6. Tests (behavioural)

| File | New test |
|---|---|
| `ChatsList.activeFromUrl.spec.ts` | chat row's `active` flag is true ONLY when `route.query.view === 'chat' && route.query.session === row.id`; false in all other URL states |
| `WorkspaceItem.activeFromUrl.spec.ts` | item row gets `--semantic-active-bg` ONLY when `route.query.view === 'workspace' && route.query.itemId === item.id` |
| `DesignPageRow.activeFromUrl.spec.ts` | page row gets `--semantic-active-bg` ONLY when `route.query.view === 'workspace' && route.query.pageId === page.id` |
| `WorkspaceList.expandedNoLongerActiveBg.spec.ts` | expanded workspace row does NOT have `--semantic-active-bg` in its inline style |
| `sidebarSingleActive.spec.ts` (new) | mounts the full `<AppLayout>` with three pre-active fixtures (a chat, a workspace item, a design page all "currently active" in the store), then asserts that the URL state picks exactly one — and only one — row to render as active in the sidebar |

Pre-existing tests that assert the old behaviour must be updated to
the new contract:

| Existing test | Change |
|---|---|
| `workspaceItemTask.spec.ts:121` ("applies active styling when activeTaskId === task.id") | Update assertion: drive `currentMainView` via mock route, not via `ws.activeTaskId = task.id` |
| `workspaceItemTask.spec.ts:128-129` (asserts `--semantic-active-bg` + `--color-aqua` on active task row) | Update to set the URL via the router mock + assert the same inline style values |
| Any test that asserts the expanded workspace has `--semantic-active-bg` | Update to assert NO active bg on expanded workspace (only the active item keeps it) |

## Out of scope (deferred)

- The store's `activeTaskId` / `activeWorkspaceItemId` /
  `activeDesignPageId` flags are kept — they still drive AppLayout
  routing decisions. They just don't drive sidebar highlighting
  anymore. (Removing them would be a much larger refactor across
  AppLayout + SSE handlers + workspace store actions.)
- "Currently processing" spinners stay exactly as they are
  (yellow ring, leftmost slot). They are independent of "active".
- The collapsed-mode sidebar tile styling is unchanged.

## Files touched (estimate)

- Modified: `Sidebar.vue`, `ChatsList.vue`, `WorkspaceList.vue`,
  `WorkspaceItem.vue`, `WorkspaceItemTaskRow.vue`, `DesignPageRow.vue`,
  `AppLayout.vue` (only the URL-sync watcher if needed).
- New: `src/composables/useCurrentMainView.ts` (the computed).
- New tests: 5 files as above.
- Updated tests: ~2-3 existing files.

## Risk / verification

- **Risk**: SSE handlers / store mutations that currently rely on
  the sidebar reading `activeWorkspaceItemId` etc. could lose
  reactive updates. Mitigation: keep the store flags; only stop
  using them for sidebar highlighting.
- **Verification**: `bun run build` (vue-tsc clean) + `bunx vitest run`
  for the new + updated tests, plus full-suite check that no
  pre-existing tests regress.
