# Tab mode — browser-style tabs

Tab mode keeps several destinations open at once in a strip above the
content area: chat sessions, kanban boards, design pages, agent / routine
items, workspace tasks, kanban settings and Settings. It is modelled on a
browser's tab strip, including the gestures and shortcuts.

Frontend-only feature. No backend, database or API change: a tab is a
snapshot of the router target the app already used, plus one extra query
param.

---

## Using it

| Gesture | Result |
|---|---|
| Click a chat / workspace item / task | Opens it in a tab (or focuses the tab that already shows it) |
| `Ctrl/Cmd+click`, middle click | Opens it in a **background** tab — you stay where you are |
| `+` (end of the strip) | Opens the chats list ("new tab page"); focuses it if it is already open |
| Click a tab | Switches to it |
| Click `×` on a tab, or middle-click a tab | Closes it |
| Right-click a tab | Close tab / Close other tabs / Close tabs to the right |
| Drag a tab | Reorders; the order is saved |
| Wheel over the strip | Scrolls the strip sideways |

Closing a tab **never stops a running agent**. The session lives on the
server and the tab is only a pointer to it; reopening the chat shows the
in-flight stream resumed (`GET /api/llm/session/:id/stream`) rather than
restarted.

Switching tabs re-mounts the view (one view is live at a time — see
"Rendering model" below). Chat history, scroll position, in-flight stream
content, queued messages and your unsent composer text all survive that.

## Shortcuts

The guaranteed map is the `Shift+Alt` namespace, because a page cannot
override the chords a browser reserves:

| Keys | Action |
|---|---|
| `Shift+Alt+T` | New tab |
| `Shift+Alt+W` | Close the active tab |
| `Shift+Alt+Z` | Reopen the last closed tab (stack of 10) |
| `Shift+Alt+→` / `Shift+Alt+←` | Next / previous tab (wraps) |
| `Shift+Alt+1…9` | Jump to the nth tab |

`Ctrl/Cmd+T`, `Ctrl/Cmd+W`, `Ctrl/Cmd+1…9` and `Ctrl+Tab` /
`Ctrl+Shift+Tab` are registered **opportunistically**. In the desktop
webview they work; in a browser the browser keeps them (Chromium does not
deliver `Ctrl+Tab` to the page at all, and `Ctrl+Shift+T` — the browser's
"reopen closed tab" — is deliberately left alone). There is no
desktop-vs-web detection flag in this repo, so the chords are registered
and simply never fire where the engine swallows them.

Shortcuts are inert when a modal dialog is open, and while tab mode is off.

## The URL contract

A tab remembers `{ path, query }` — exactly what `router.push` takes. The
active tab's target is mirrored into the URL as before, plus one param:

```
/app?view=chat&session=session-1789300446&tab=tab_k3f9a1
/app?view=workspace&workspaceId=ws_1&itemId=item_7&tab=tab_zz20qx
/app/settings?tab=tab_aa11bb
/app/kanban/item_7/settings?tab=tab_cc22dd
```

`tab` is **client-only** and is never sent to the API. It is also excluded
from tab identity, as is `sorts` (per-column kanban sorting changes
without the user going anywhere).

Rules worth knowing:

* **Nothing in the render chain changed.** `route.fullPath →
  AppLayout.currentView` → the existing `v-if` / `v-else-if` chain still
  decides what renders. Activating a tab is a navigation.
* **A cold deep link still works.** `?view=chat&session=X` with no `tab=`
  opens one tab for it and normalises the URL; the rest of the restored
  tab list stays in the strip.
* **URL wins over storage** on boot when the two disagree.
* **`?tab=` is honoured only when it names a tab whose target matches the
  URL.** A stale or hand-edited value is treated as a fresh navigation and
  rewritten.
* **Switching tabs uses `router.replace`, never `push`**, so the window's
  Back button stays "go back inside the active tab" instead of becoming a
  tab switcher. Plain navigation still pushes, so Back/Forward keep
  working for real navigation. Per-tab history stacks are *not*
  implemented.
* Overlay views (`view=gitfile`, `view=skill`, `view=code-editor`) are
  full-surface overlays with their own Back buttons. They never become
  tabs, they do not touch the strip, and their URLs are left exactly as
  they are.

### Identity — what dedupes

Two navigations that mean the same target focus one tab:

| Target | Key |
|---|---|
| `/app/settings` | `settings` |
| `/app/kanban/<itemId>/settings` | `ks:<itemId>` |
| `view=chat` with no session (the chats list) | `home` |
| `view=chat&session=X` | `chat:X` |
| `view=workspace&workspaceId=W&itemId=I[&pageId=P]` | `ws:W:<bare I>[:P]` |
| `view=workspace&itemId=I/chat/T` — a task chat on a **kanban / design** item | `ws:W:<bare I>[:P]` (the item's tab — the chat is a dialog *inside* that view) |
| `view=workspace&itemId=I/chat/T` — a task chat on any other item type | `ws:W:<bare I>:chat:T` (its own tab) |
| legacy `view=task&task=T` | `chat:T` |

**A task is a session** (`task.id == session.id`, migration 052), but where it
renders decides its tab:

* **kanban / design** open the chat as a dialog **inside** the item's view
  (`KanbanChatDialog` / `DesignChatDialog`), so the item keeps **one** tab no
  matter how many cards you open — otherwise every card click would spawn a tab.
* **agent / folder / routine / memory / chat** items render the task chat as its
  own view (`StandardTaskChatView`), so each task session gets its own tab.

When the item type is not known yet (a cold-boot deep link, before the workspace
tree has loaded), the tab is created **provisionally** and re-keyed in place the
moment the type arrives — so the strip never ends up with two tabs for one
target.

A brand-new chat starts life with a synthetic `session-<timestamp>` id and
receives the backend's real id on the first message. The tab follows that change
**in place** (same tab id, same position, new key) — it is never left behind as a
dead pointer, and no duplicate tab appears.

### Tab labels

Labels are **resolved live from the stores**, not frozen when the tab opens:
the route funnel only ever receives a bare target (a click, a deep link, a
reload), so there is no name to store at that moment, and the workspace tree
only lands after the API answers.

* workspace item → the item's name (`AGENTIC BASIC`, not "Workspace"), with the
  glyph following the item type (▦ kanban, 🎨 design, 🤖 agent, ⏱ routine, 📁
  folder, 🧠 memory)
* workspace item with a `/chat/task_X` suffix → that task's name
* chat → the name published by the chats list and the `session` SSE channel
  (renames included)
* chats list / settings / kanban settings → "Chats" / "Settings" / "Kanban
  settings"
* anything still unknown → a kind fallback ("Workspace", "Chat")

The resolved label is written back to the tab, so a reload (before the tree has
loaded) shows the real name instead of the fallback. The fallback is only ever
visible for the moment before the data arrives.

## Storage

```
sessionStorage['nalar-window-id']        = 'w_7c1a9e02'
localStorage['nalar-tabs-enabled']       = 'true' | 'false'
localStorage['nalar-tabs:v1:<windowId>'] = { v, active, tabs[], closed[] }
```

* **Per window.** `sessionStorage` is per browser tab / webview window, so
  a second window starts with its own empty strip while a reload of the
  same window restores its set — exactly like a browser. (Known quirk:
  duplicating a tab copies `sessionStorage`, so a duplicate shares its
  source's tab list. Benign, not defended against.)
* Bounds: 50 tabs (the oldest non-active tab is evicted), 10 closed tabs
  kept for "reopen".
* Load is defensive: corrupt JSON, an older version, or hand-edited
  entries never throw — the strip falls back to a single chats tab.
* Drafts (unsent composer text) are **in memory only**, per window, keyed
  by chat session. They are deliberately not written to disk. They survive
  closing and reopening a tab inside the session but not a reload.

### Resetting the strip

Close the tabs you do not want, or clear the storage key:

```js
localStorage.removeItem('nalar-tabs:v1:' + sessionStorage.getItem('nalar-window-id'))
```

## Turning it off

Settings → General → **Browser-style tabs**. Off is a complete rollback:
the strip is not rendered, the route funnel stops creating or normalising
tabs, and the `?tab=` param is dropped from the URL. The tab list is kept,
so switching it back on restores the strip.

## Rendering model (and why it is not `KeepAlive`)

Exactly one view is mounted at a time; switching tabs is navigation. The
alternative — keeping every open view alive — would first require making
six pieces of global state per-tab: `navigation.activeChatId` /
`activeTaskId`, `workspaces.activeWorkspaceItemId`,
`kanbanSse.activeWorkspaceId`, `designSse.activeWorkspaceId`, the
`active-chat-id` localStorage mirror, and `ChatView`'s own
`router.replace`. Single-pane keeps the blast radius in the tab layer, and
nothing is lost visually because re-selecting a chat was already handled:
history re-fetch, stream resume from the snapshot endpoint, per-session
scroll restore, per-session `processingState` / `agentError` maps, and now
per-session composer drafts.

## Files

| File | Role |
|---|---|
| `src/apps/desktop/src/helpers/tabTarget.ts` | Pure contract: identity, exclusions, storage validation, background-open detection |
| `src/apps/desktop/src/helpers/windowId.ts` | Per-window id (with an in-memory fallback when storage is denied) |
| `src/apps/desktop/src/stores/tabs.ts` | The list: open / activate / close / reorder / reopen / persist / drafts / `syncFromTarget` |
| `src/apps/desktop/src/components/shell/TabBar.vue` | The strip |
| `src/apps/desktop/src/composables/useTabShortcuts.ts` | The key map + listener |
| `src/apps/desktop/src/components/AppLayout.vue` | Mounts the strip, owns the route funnel and the router calls |
| `src/apps/desktop/src/components/file/FileInput.vue` | Optional `draftKey` — drafts survive the remount a tab switch causes |

Tests: `__tests__/tabTarget.spec.ts`, `tabsStore.spec.ts`, `TabBar.spec.ts`,
`AppLayout.tabs.spec.ts`, `tabDraft.spec.ts`, `useTabShortcuts.spec.ts`,
`tabsSettingsToggle.spec.ts`.
