# Simplify URL browser — collapse `view=task` into the workspace URL

> Date: 2026-08-15
> Owner: session_1786740781061
> Status: **Draft — awaiting user approval before implementation**

## Problem (user-reported, task_1786740781061)

Two URL shapes carry the same context today:

```
workspace (no chat): ?view=workspace&workspaceId=ws_X&itemId=item_Y[&pageId=page_Z]
chat dialog open  : ?view=task&task=task_W&workspaceId=ws_X&itemId=item_Y[&pageId=page_Z]
```

Three redundancies:

1. `view=task` and `view=workspace` are mutually exclusive values that
   point at the same `(workspaceId, itemId)` pair.
2. `task=task_W` is the only payload of `view=task`; the rest is a
   copy of the workspace URL.
3. The "chat dialog open" state is a sub-state of "workspace item
   active", but the URL doesn't reflect that — it pretends the chat
   is its own top-level view.

The user wants the chat-open URL to look like:

```
?view=workspace&workspaceId=ws_X&itemId=item_Y/chat/task_W
```

i.e., one URL shape, with the chat-open state encoded as a path-style
suffix on the `itemId` value. No `view=task`, no separate `task=` param
at the top level.

## Goal

A **single URL shape** for workspace items (kanban / design / folder):

| State | URL |
|---|---|
| Workspace item visible (no chat) | `?view=workspace&workspaceId=X&itemId=Y[&pageId=Z][&sorts=…]` |
| Workspace item visible + chat dialog open | `?view=workspace&workspaceId=X&itemId=Y/chat/task_W[&pageId=Z][&sorts=…]` |

`view=task&task=X` is **gone**. The chat task id lives in the
`itemId` value's `/chat/<id>` suffix.

## Wire shape (final)

The `itemId` query parameter value carries one of two shapes:

- **Bare item id** — no chat dialog open. `itemId=item_Y`.
- **Item id + chat suffix** — chat dialog open. `itemId=item_Y/chat/task_W`.

Parsing:

```ts
function parseItemId(raw: string): { itemId: string; chatTaskId: string | null } {
  const idx = raw.indexOf('/chat/')
  if (idx === -1) return { itemId: raw, chatTaskId: null }
  return {
    itemId: raw.slice(0, idx),
    chatTaskId: raw.slice(idx + '/chat/'.length),
  }
}

function buildItemId(itemId: string, chatTaskId: string | null): string {
  return chatTaskId ? `${itemId}/chat/${chatTaskId}` : itemId
}
```

The slash is a literal `"/chat/"` separator. Item ids never contain
`/chat/` (the backend uses ULIDs / UUID-like strings — no slashes),
so parsing is unambiguous.

Other URL params behave the same as today:

- `pageId` — design-page id; present iff the active item is a design
  and a page is selected.
- `sorts` — kanban per-column sort state; preserved on the workspace
  → chat round-trip via the existing `savedSortsParam` mechanism.

## Mental model (URL is source of truth)

```
URL                                                         → exactly one view
───────────────────────────────────────────────────────────────────────────────
?view=workspace&workspaceId=X&itemId=Y                       → workspace item Y, no chat
?view=workspace&workspaceId=X&itemId=Y/chat/task_W          → workspace item Y, chat W open
?view=chat&session=X                                        → standalone chat X
?view=chat                                                  → chat list (welcome)
?view=settings, ?view=gitfile, etc.                         → overlay views
```

`useCurrentMainView` returns:

```ts
type CurrentMainView =
  | { kind: 'chat'; sessionId: string }
  | { kind: 'workspace'; workspaceId?: string; itemId: string; pageId?: string; chatTaskId?: string }
  | { kind: 'none' }
```

No `kind: 'task'` anymore — the workspace view now carries the
optional `chatTaskId`, and the chat dialog is rendered on top of it.

## Design

### 1. `useCurrentMainView` — add `chatTaskId`, drop `task`

The composable (`src/apps/desktop/src/composables/useCurrentMainView.ts`)
gains a single new field on the `workspace` variant and loses the
`task` variant entirely:

```ts
| { kind: 'workspace'; workspaceId?: string; itemId: string; pageId?: string; chatTaskId?: string }
```

The `itemId` value is **the wire shape** (with the `/chat/task_X`
suffix if present). The composable parses it once via
`parseItemId` and exposes both the bare `itemId` and the optional
`chatTaskId`. Consumers that need only the bare item id should use
the parsed `itemId` field, not the raw `route.query.itemId`.

Consumers that need the raw wire value (e.g. when building a new URL
that should preserve the suffix) use `route.query.itemId` directly.

### 2. New helper — `helpers/buildItemIdWithChat.ts`

Pure function (no Vue / Pinia / vue-router) — sibling to
`buildTaskUrlQuery`. Exports:

```ts
export function buildItemIdWithChat(itemId: string, chatTaskId: string | null): string
export function parseItemIdWithChat(raw: string): { itemId: string; chatTaskId: string | null }
export const CHAT_SUFFIX = '/chat/'  // exported for tests
```

Used by every call site that builds the `itemId` value for a task
URL (Sidebar.handleSelectTask, Sidebar.handleAddTaskPick,
Sidebar.handleRunRoutine, AppLayout.handleNavigate('task'),
closeGitViewer / closeSkillViewer / closeCodeEditor's task-else branch,
and the URL sync watcher in AppLayout.vue).

### 3. `buildTaskUrlQuery` — return item-id-with-suffix

The existing helper (`helpers/buildTaskUrlQuery.ts`) currently emits:

```ts
{ view: 'task', task: '...', workspaceId, itemId, pageId?, sorts?, session? }
```

After this change it emits:

```ts
{ view: 'workspace', workspaceId, itemId: '<itemId>/chat/<taskId>', pageId?, sorts?, session? }
```

It stops emitting `view` and `task` (the caller always knows
`view=workspace` is implied; the task id is in the itemId suffix).
The `session` param is **dropped** — under the new wire shape, the
session id is always equal to the chat task id (the
`task.id == session_id` convention) and is fully recoverable from the
`itemId` suffix. See "Drop `session` query param" in the migration
section below.

### 4. `Sidebar.handleSelectTask` — emit `/chat/<taskId>` suffix

The change:

```diff
- await router.push({ path: '/app', query: buildTaskUrlQuery({ taskId, ... }) })
+ await router.push({
+   path: '/app',
+   query: buildTaskUrlQuery({
+     taskId,
+     activeWorkspaceId,
+     activeWorkspaceItemId,
+     activeDesignPageId,
+     activeItemType,
+     currentQuery: route.query,
+   }),
+ })
```

The helper internally appends `/chat/<taskId>` to the `itemId` value
and emits `view: 'workspace'` instead of `view: 'task'`. The call
site doesn't need to know the wire shape — it just calls the helper.

The `workspacesStore.isNavigatingToTask` flag stays (it's still the
right primitive for closing the URL-sync watcher's race window), but
its semantic shifts from "navigating to a task URL" to "navigating to
the chat-open state of the workspace URL". The flag's name is
preserved to minimise churn; a comment in the store explains the
broadened meaning.

### 5. `AppLayout.handleNavigate('task')` — drop the branch

The dead-code `view === 'task'` branch at
`AppLayout.vue:447-465` (covered by the
`add-workspace-id-params` plan for future re-enable) is **deleted**.
No remaining caller passes `view: 'task'` to `handleNavigate`, since
the URL helper never emits it. The `view` parameter in the function
signature becomes effectively `'workspace' | 'chat' | 'settings'`;
it's still kept in the type for back-compat with any caller that
might pass it (the branch was a no-op today anyway).

### 6. `AppLayout.handleCloseTaskView` — strip the `/chat/` suffix

Currently navigates to `?view=workspace&workspaceId=X&itemId=Y`. After
this change it does the same — the item id passed to `router.replace`
is the **bare** item id (suffix stripped). This is automatic if we
just use `workspacesStore.activeWorkspaceItemId` instead of `route.query.itemId`
in the URL builder.

### 7. `currentView` computed — drop `'task'` arm

`AppLayout.vue:827-847` (`currentView`) currently returns `'task'`
when `route.query.view === 'task'`. After this change, `route.query.view`
is always `'workspace'` for chat-open URLs, so the `'task'` arm
becomes dead code and is removed.

The `<ChatView v-else-if="currentView === 'task' && activeTask">`
mount at line 1954 is **deleted**. Under the new scheme:

- Kanban chat dialog → `KanbanChatDialog` mount (gated on
  `activeWorkspaceItem.item_type === 'kanban' && activeTask && activeTaskWorkspaceItemId === activeWorkspaceItem.id`)
  — unchanged.
- Design chat dialog → `DesignChatDialog` mount (gated on
  `item_type === 'design' && activeDesignChatTaskId`)
  — unchanged.
- The legacy "task view for non-kanban parents" `<ChatView>` branch
  is unreachable (the URL never says `view=task` anymore, and any
  pre-fix `view=task` URL becomes `view=workspace` on first navigation).
  It is removed.

### 8. URL restoration on mount (`pendingUrlRestore`)

`AppLayout.vue:163-178` builds `pendingUrlRestore` from
`route.query`. After this change it uses the **parsed** item id
(stripping the `/chat/` suffix) so the store's `activeWorkspaceItemId`
ends up set to the bare id. The chat task id is restored separately
in the `onMounted` block:

```ts
const parsed = parseItemIdWithChat(rawItemId)
const urlChatTaskId = parsed.chatTaskId
// … existing pendingUrlRestore uses parsed.itemId …

if (urlChatTaskId) {
  workspacesStore.setActiveTask(urlChatTaskId)
}
```

### 9. `useCurrentMainView` consumers — update task-row highlight

`WorkspaceItemTaskRow.vue:56-58` currently checks
`currentMainView.value.kind === 'task' && currentMainView.value.taskId === task.id`.

After this change:

```ts
currentMainView.value.kind === 'workspace' &&
currentMainView.value.itemId === bareItemIdOfParent &&
currentMainView.value.chatTaskId === task.id
```

`WorkspaceItem.vue:92-95` (workspace item row highlight) keeps the
`kind === 'workspace'` check but uses `currentMainView.value.itemId`
(the parsed bare id) instead of `route.query.itemId`.

### 10. URL-sync watcher — preserve `/chat/` suffix on item-write

The watcher at `AppLayout.vue:242-326` that mirrors
`activeWorkspaceItemId` / `activeDesignPageId` back to the URL
currently writes:

```ts
const query: Record<string, string> = { view: 'workspace' }
query.itemId = itemId
query.workspaceId = wsId
if (pageId) query.pageId = pageId
```

After this change, when `route.query.itemId` already carries a
`/chat/<taskId>` suffix (the chat dialog is open), the watcher MUST
preserve it:

```ts
const existingItemId = (route.query.itemId as string) ?? ''
const parsed = parseItemIdWithChat(existingItemId)
// … write query.itemId = buildItemIdWithChat(itemId, parsed.chatTaskId)
```

This keeps the URL stable across the item-id mutation that
`setActiveTask` fires (it sets `activeWorkspaceItemId` to the task's
parent item; the watcher must mirror that change WITHOUT clobbering
the chat task id suffix already in the URL).

### 11. Tests

#### New tests

| File | Test |
|---|---|
| `src/apps/desktop/src/helpers/__tests__/buildItemIdWithChat.spec.ts` | `buildItemIdWithChat(itemId, null) === itemId`, `buildItemIdWithChat(itemId, 'task_X') === 'item_Y/chat/task_X'`; `parseItemIdWithChat` round-trips; `parseItemIdWithChat('item_Y')` returns `{chatTaskId: null}`; idempotent (`parse(build(x)) === x`); rejects item ids containing `/chat/` substring (throws) |
| `src/apps/desktop/src/__tests__/AppLayout.simplifyUrl.spec.ts` | Mounting with `?view=workspace&workspaceId=X&itemId=Y/chat/task_W` restores `activeWorkspaceItemId === Y` and `activeTaskId === task_W`; mounting with `?view=workspace&workspaceId=X&itemId=Y` leaves `activeTaskId === null` |
| `src/apps/desktop/src/__tests__/AppLayout.chatSuffixRoundTrip.spec.ts` | Click a kanban task → URL becomes `?view=workspace&…&itemId=Y/chat/task_W` (NOT `view=task`); close the chat → URL becomes `?view=workspace&…&itemId=Y` (suffix stripped); browser back button restores the open-chat URL |

#### Modified tests

The change touches a lot of test files because `view=task&task=X` URLs
appear in many places. The mass-rewrite:

| Pattern in old test | Replace with |
|---|---|
| `fullPath: '/app?view=task&task=X'` | `fullPath: '/app?view=workspace&workspaceId=W&itemId=item_Y/chat/task_X'` (with appropriate workspaceId / itemId context) |
| `route.query.view === 'task'` | `route.query.view === 'workspace' && parseItemIdWithChat(route.query.itemId).chatTaskId === 'task_X'` |
| `pushArg.query.view === 'task'`, `pushArg.query.task === 'X'` | `pushArg.query.view === 'workspace'`, `pushArg.query.itemId === 'item_Y/chat/task_X'` |
| `useCurrentMainView().value.kind === 'task'` | `useCurrentMainView().value.kind === 'workspace' && useCurrentMainView().value.chatTaskId === 'task_X'` |

Affected test files (estimated from search results — every
`?view=task&task=X` reference must be rewritten):

- `useCurrentMainView.spec.ts` — rewrite the `task` test cases into
  `workspace+chatTaskId` cases.
- `AppLayout.urlPersist.spec.ts` — every `view=task` URL in test setup.
- `AppLayout.sortUrlRoundTrip.spec.ts` — the close-restore test
  asserts the URL round-trips correctly.
- `AppLayout.taskClickUrlOverwrite.spec.ts` — the task-click URL is
  rewritten to the new shape.
- `AppLayout.kanbanChatDialog.spec.ts` — assert the dialog mount is
  driven by the new URL suffix.
- `AppLayout.kanban.spec.ts` — assert the legacy `view=task&task=X`
  URL becomes `view=workspace&itemId=Y/chat/task_X`.
- `sidebarHandleSelectTaskUrl.spec.ts` — every assertion of `view=task`
  / `task=X` is rewritten to `view=workspace` / `itemId=Y/chat/task_X`.
- `helpers/__tests__/buildTaskUrlQuery.spec.ts` — rewrite the helper's
  expected output shape (drops `view`, `task`; adds `/chat/<taskId>`
  to `itemId`; drops `session`).
- `workspaceItemTask.spec.ts` — task row's active styling uses
  `kind: 'workspace' + chatTaskId` instead of `kind: 'task'`.
- `workspaceItemTaskCard.spec.ts` — same.
- `DesignPageRow.spec.ts` — no change (design page highlight is
  unaffected by this refactor; verify in the diff).
- `DesignPageRow.activeFromUrl.spec.ts` — verify no change.
- `WorkspaceItem.activeFromUrl.spec.ts` — uses `kind: 'workspace'`
  with parsed `itemId`.
- `ChatsList.activeFromUrl.spec.ts` — no change (chat row is still
  `kind: 'chat'`).
- `AppLayout.chatview.spec.ts` — covered by the new
  `AppLayout.simplifyUrl.spec.ts`.
- `AppLayout.designChatDialog.spec.ts` — assert design chat dialog
  mount is driven by the new URL suffix.

## Drop `session` query param (incidental cleanup)

The `buildTaskUrlQuery` helper currently emits `session=<taskId>`
(redundant with `task=<taskId>` per the `task.id == session_id`
convention). With the new wire shape the task id lives in the
`itemId` suffix — there's no separate `task=` to be parallel to, so
`session` becomes redundant and is dropped from the URL.

This is incidental to the main change — there are no callers that
read `session` from the URL today (`useRoute().query.session` is read
only in the legacy `view=chat&session=X` path, which is unrelated).
Dropping it makes the URL strictly smaller.

## Wire shape — edge cases

1. **Stale URL with old `view=task` shape.** On mount, the URL
   restoration logic detects `view === 'task' || route.query.task` and
   rewrites the URL to `view=workspace&itemId=Y/chat/task_W` via
   `router.replace` (silent — no history entry). After this one-time
   rewrite, the URL is in the new shape. This handles bookmarks /
   shared links from before this change.

2. **Item id containing `/chat/` substring.** Defensive: the backend
   uses ULIDs / UUID-like strings for `id` columns and we have no
   precedent for item ids containing slashes. The helper throws if
   it sees an item id that contains the suffix separator, so a
   future regression can't silently corrupt a URL. (The test
   `buildItemIdWithChat rejects item ids containing /chat/` pins
   this.)

3. **Refresh while chat is open.** The URL contains the chat task id
   in the suffix; on reload, `AppLayout.onMounted` reads it, calls
   `setActiveTask`, the watcher opens the dialog. Identical UX to
   today.

4. **Refresh while chat is open but task was deleted.** The store's
   `setActiveTask` walks workspaces looking for the task
   (`workspaces.ts:3234-3273`). If the task no longer exists, the
   store leaves `activeTaskId = null`; the URL keeps the suffix but
   the dialog doesn't open. The URL gets cleaned up on the next
   navigation. (Same behavior as the pre-fix
   `?view=task&task=deleted_id` URL — preserved.)

5. **Browser back from a chat-open URL.** The chat-open URL is a
   `router.push` (not `replace`) — same as today's task URL. Back
   button returns to the bare workspace URL naturally.

## Out of scope (deferred)

- **URL path-segment form** (`/app/workspace/ws_X/item_Y/chat/task_W`).
  The query-param form is preserved for back-compat with the existing
  routes (`/app`, `/app/settings`). A future PR can introduce the
  path-segment form alongside; the helper functions in
  `buildItemIdWithChat.ts` are designed to be reusable.
- **Removing the `view=task` legacy route.** Not strictly needed —
  the router already has a catch-all `/app/task/:taskId` route but
  `AppLayout` ignores it. We could delete it for cleanliness, but
  that's a separate PR.
- **Removing `view=chat&session=X` URL.** Standalone chats
  (sidebar-chats, not kanban/design tasks) keep their own URL shape.
  This PR only collapses `view=task` (kanban/design chat) into the
  workspace URL.
- **Cleanup of `currentView` computed's many arms.** The
  `gitfile` / `skill` / `code-editor` arms stay as-is.

## Files touched (estimate)

- **Modified (production)**:
  - `src/apps/desktop/src/composables/useCurrentMainView.ts` (drop
    `task` variant, add `chatTaskId` to `workspace` variant, parse
    the `itemId` value).
  - `src/apps/desktop/src/helpers/buildTaskUrlQuery.ts` (drop
    `view: 'task'` / `task` / `session`; append `/chat/<taskId>` to
    `itemId`; emit `view: 'workspace'`).
  - `src/apps/desktop/src/components/shell/Sidebar.vue`
    (`handleSelectTask`, `handleAddTaskPick`, `handleRunRoutine`
    — call sites adapt automatically because the helper changes).
  - `src/apps/desktop/src/components/AppLayout.vue`:
    - `handleNavigate` — drop the `'task'` arm.
    - `handleCloseTaskView` — strip suffix when writing the
      bare-workspace URL.
    - `currentView` computed — drop the `'task'` arm.
    - Template — delete the `<ChatView v-else-if="currentView === 'task'">`
      mount.
    - `pendingUrlRestore` — use the parsed item id; restore chat task
      id in `onMounted`.
    - URL-sync watcher — preserve `/chat/<taskId>` suffix on
      item-id writes.
    - `closeGitViewer` / `closeSkillViewer` / `closeCodeEditor` —
      their `else if (activeTask.value)` branches use the new helper
      output.
  - `src/apps/desktop/src/components/workspace/WorkspaceItemTaskRow.vue`
    — task row's `active` highlight reads
    `kind: 'workspace' + chatTaskId`.
  - `src/apps/desktop/src/components/workspace/WorkspaceItem.vue` —
    workspace item row's `active` highlight uses the parsed `itemId`.

- **New (production)**:
  - `src/apps/desktop/src/helpers/buildItemIdWithChat.ts`.

- **Modified (tests)**:
  - 11 test files listed above.

- **New (tests)**:
  - `src/apps/desktop/src/helpers/__tests__/buildItemIdWithChat.spec.ts`
  - `src/apps/desktop/src/__tests__/AppLayout.simplifyUrl.spec.ts`
  - `src/apps/desktop/src/__tests__/AppLayout.chatSuffixRoundTrip.spec.ts`

## Risk / verification

- **Risk**: The wire shape mixes path-style separators (`/chat/`)
  into a query value, which is unusual. Vue Router doesn't decode
  path separators in query values — `route.query.itemId` returns
  the raw string `"item_Y/chat/task_X"` — but anyone reading
  `route.query.itemId` directly (instead of going through
  `useCurrentMainView`) will get the wire value, not the bare id.
  Mitigation: `useCurrentMainView` is the canonical reader; add a
  code-comment near every direct `route.query.itemId` read pointing
  to the helper.
- **Risk**: Mass-test rewrite may miss a spot. Mitigation: the new
  `AppLayout.chatSuffixRoundTrip.spec.ts` exercises the click → URL →
  back-button round-trip end-to-end and would fail loudly if any
  intermediate component still expects the old `view=task` shape.
- **Verification**: `bun run build` (vue-tsc clean) + `bunx vitest run`
  for the new + updated tests, plus full-suite check that no
  pre-existing tests regress.

## Plan / spec

- Spec: this document.
- Plan: `docs/superpowers/plans/2026-08-15-simplify-url-browser.md`
  (written next, after spec approval).