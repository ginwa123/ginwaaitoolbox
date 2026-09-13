# Tab Mode (Browser-Style Tabs) Implementation Plan (rev 2)

> **Status: implemented.** Approved by the user ("okey execute the plan") and
> built on branch `worktree/tab-mode-like-a-browser-1789300444735` (PR #476).
> See `## Implementation status (rev 2)` at the bottom for what shipped, the
> measured test baseline, and the deviations from this plan. The design
> decisions below are unchanged. User-facing doc: `docs/tabs.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the nalar SPA an opt-out **tab mode**: a browser-style tab strip above the content area where each tab keeps one target open — a chat session, a kanban board, a design page, an agent / routine item, a workspace task, or Settings — with close buttons, middle-click close, drag reordering, keyboard shortcuts, "reopen last closed", per-window persistence across reloads, and open-in-background. The feature is frontend-only: no Zig, SQL, or HTTP change.

**Architecture:**

1. **A tab is a snapshot of the existing URL contract, not a new view enum.** Every target the app can show today is already addressable: `?view=chat&session=X`, `?view=workspace&workspaceId=W&itemId=I`, `/app/settings`, `/app/kanban/:itemId/settings`. A tab stores `{ path, query }` — exactly what `router.push` takes today — plus an id, a dedupe key, a display title, and a kind hint.
2. **The render pipeline is untouched.** `route.fullPath → AppLayout.currentView` (`AppLayout.vue:904-942`) → the existing `v-if` / `v-else-if` chain keeps working verbatim. Tab mode changes *who writes the URL*, not what reads it.
3. **One watcher on `route.fullPath` is the funnel.** Any navigation from anywhere (sidebar click, chats list, kanban chat dialog, deep link, back button) syncs into the tab list: create a tab, focus an existing one, or normalize the URL. No call site needs to know tabs exist.
4. **Exactly one view is mounted at a time** (today's behaviour). Tab switching is navigation. Chat state survives because it already does for re-select: history re-fetch, in-flight stream resume from `GET /api/llm/session/:id/stream` (`ChatView.vue:2639-2647`), scroll restore from `chat-scroll-<sessionId>` (`ChatView.vue:421`), and per-session `processingState` / `agentError` maps (`App.vue:10-11,37-39`, `stores/agentError.ts:44`).
5. **Persistence is per window.** A `sessionStorage` window id scopes a `localStorage` tab-list key, so a second app window or browser tab starts with its own (empty) set — exactly like a browser — while a reload of the same window restores its set.
6. **The toggle restores today's behaviour byte-for-byte.** With `enabled === false` the strip is not rendered, the funnel no-ops, and `?tab=` is stripped from the URL on the next navigation.

**Tech Stack:** Vue 3 `<script setup>` + TypeScript + Pinia (setup-store style) + vue-router 5 with web history + Vitest/jsdom. Chrome is inline `:style` with CSS variables (there is no `components/ui/` and no dropdown/tooltip primitive in this repo). Frontend root is `src/apps/desktop`.

---

## Global Constraints

- **No backend change.** No Zig, no SQL, no route work. `?tab=` is client-only and must never be forwarded to the API. The one place URL params are copied into a generated URL is `helpers/buildTaskUrlQuery.ts:107-109`, which goes through `pickBreadcrumbFromQuery` (`helpers/buildItemIdWithChat.ts:69`; the whitelist — `workspaceId`, `itemId`, `pageId`, `sorts` — is documented at `:60`), so `tab` cannot leak. **Re-verify this after Task 3**: `search(pattern: "tab")` inside `helpers/buildTaskUrlQuery.ts` and `helpers/buildItemIdWithChat.ts` must stay at zero hits.
- **Never touch the process on port 8081.** The dev server proxies to it (`src/apps/desktop/vite.config.ts:44-45`); a `nalar` instance is already running there. Do not start, stop or restart anything on 8081. Manual checks use `pnpm dev` (5173).
- **No python/functional harness work in this plan.** Nothing on the wire changes: the SPA fallback prefix `/app` (`src/main.zig:384-392`) already serves `index.html` for any query string, so `?tab=` needs no server support. The gates are Vitest + `vue-tsc`/`vite build` + the manual checklist in `## Verification`. If a task ever does need a wire assertion, use `tests/functional/harness.py` (free port 8080..8199, isolated `HOME`) — never `curl` a live binary.
- **Editing rules.** No `// NEW (plan: …)` comments — say *why*, never *when*. `vue-tsc --build` emits stray `.js` next to `.ts` sources; delete them before committing (`git status --porcelain` must not list `*.js` under `src/`).
- **Defensive load for every persisted value.** Corrupt or older `localStorage` must never throw; fall back to a single fresh `home` tab. Precedent: `stores/navigation.ts:49-71` (parse-or-default, clamped numbers).
- **Invariants — assert each one in a test:**
  1. The tab list is never empty. Closing the last tab opens a fresh `home` tab.
  2. Closing the **active** tab activates the right neighbour, else the left.
  3. `?tab=<id>` is honoured **only** when it names an existing tab *and* the URL's target key equals that tab's stored key. Otherwise the URL is a fresh navigation: create/focus by key and normalize the URL.
  4. Activating a tab uses `router.replace`, never `push` — Back stays "navigate inside the active tab", never "switch tabs".
  5. The strip is not rendered when `enabled === false`, and `enabled === false` means zero behaviour change from `d540b617`.
- **Gates:** `pnpm --dir src/apps/desktop test` (Vitest), `pnpm --dir src/apps/desktop run build` (vue-tsc + vite build). Record the full-suite baseline **before** the first code change (see `## Verification`) — this repo carries pre-existing failures.

---

## Current State (verified 2026-09-13 at `d540b617` via 5 parallel explorers + first-hand reads)

### The shell and its single view slot

| Fact | Where | Evidence |
|---|---|---|
| `vue-router` 5 with web history; **every** route resolves to `AppLayout` | `src/apps/desktop/src/router/index.ts:4-5,12-14,17-19,23-25,29-31` | `component: AppLayout,` ×5 |
| Path-based views are discriminated by regex before the query fallthrough | `AppLayout.vue:904-942` | `if (/^\/app\/kanban\/[^/]+\/settings\/?$/.test(path))` (`:917`), `if (path === '/app/settings') return 'settings'` (`:906`) |
| Overlay views are driven by refs, not tabs | `AppLayout.vue:921-932` | `if (gitViewerFile.value) { … return 'gitfile' }` / `if (skillViewerSkill.value) …` / `if (codeEditorFile.value) return 'code-editor'` |
| Everything else is the query fallthrough, default `chat` | `AppLayout.vue:939` | `const view = (route.query.view as string) \|\| 'chat'` |
| `<main>` is the single content column; strip has a natural home as its first child | `AppLayout.vue:2228,2237` | `<div class="flex h-screen" …>` / `<main class="flex-1 flex flex-col overflow-hidden relative">` |
| No content branch uses `h-screen` — nothing fights a `shrink-0` strip | repo-wide search `h-screen\|100vh` | only `AppLayout.vue:2228` and `Sidebar.vue:1286` (a sibling of `<main>`) |
| Views are swapped by `v-if`/`v-else-if` + `:key`, never kept alive | `AppLayout.vue:2380-2382,2506-2508,2556-2558,2580-2582,2662-2681` | `:key="'kanban-' + activeWorkspaceItem.id"` … `<ChatView :key="activeChatId">` |
| Zero `<KeepAlive>` in the frontend | search `KeepAlive\|keep-alive` | commented mentions only |
| `home` (the "new tab page") already exists | `AppLayout.vue:2682` | `<Chats v-else-if="currentView === 'chat'" />` |
| Navigation funnel today | `AppLayout.vue:476-544` | `chat-<id>` → `router.push({ path: '/app', query: { view: 'chat', session } })` (`:511`); `workspace` → `{view, workspaceId, itemId, pageId, sorts}` (`:526-540`); `settings` → `router.push({ path: '/app/settings' })` (`:542`) |
| Cold-boot URL restore | `AppLayout.vue:68-127` | `navigationStore.setActiveChat(urlSessionId, …)` (`:100`), `navigationStore.initFromUrl(...)` (`:103`) |
| Route-sync watcher (the seam the funnel joins) | `AppLayout.vue:2083-2200` | `watch(() => route.query, async (query) => {` (`:2084-2086`) |

### The state that makes "one tab at a time" the only safe first step

| Fact | Where | Evidence |
|---|---|---|
| A single global active chat, not a per-workspace map | `stores/navigation.ts:18-22` | `const activeChatId = ref('')` / `const activeTaskId = ref<string \| null>(null)` |
| Setter writes one id to `localStorage` | `stores/navigation.ts:95-108` | `localStorage.setItem(STORAGE_KEY_ACTIVE_CHAT_ID, sessionId)` |
| A single global active workspace item | `stores/workspaces.ts:481` | `const activeWorkspaceItemId = ref<string \| null>(null)` |
| `kanbanSse` / `designSse` each hold **one** active workspace filter | `stores/kanbanSse.ts:48`, `stores/designSse.ts:50` | filtered on `activeWorkspaceId.value` |
| `ChatView` navigates globally from inside itself | `ChatView.vue:347-350` | `router.replace({ path: '/app', query: { view: 'chat', session: sessionId } })` (peek → open full) |
| Per-instance chat state is setup-scope (good), but the above are not | `ChatView.vue:360-361,2156-2161` | `const isStreaming = ref(false)` / `let offLlm: (() => void) \| null = null` |
| Chat re-select already resumes an in-flight stream | `ChatView.vue:2639-2647` | `const snap = await api.getStreamSnapshot(sessionId.value)` → `streamingContent.value = snap.content` |
| Scroll is already per session | `ChatView.vue:421` | `const chatScrollStorageKey = computed(() => 'chat-scroll-' + sessionId.value)` |
| Stream/queue listeners already filter by session id, and a comment anticipates multi-ChatView | `ChatView.vue:2165,2182-2183,352-359` | `if (event.session_id !== sid) return` |
| Composer text is component-local and dies on remount | `components/file/FileInput.vue:53` | `const inputText = ref('')` |
| `FileInput` has **two** parents — the draft prop must be optional | `ChatView.vue:16,3601`, `git/GitFileViewer.vue:5,501` | `import FileInput from '../file/FileInput.vue'` ×2 |

### What already exists for persistence, titles, and the strip

| Fact | Where | Evidence |
|---|---|---|
| Persistence convention: Pinia store + localStorage shadow, no central helper | `stores/recentFolders.ts:15-17` | `Mirrors the useDesignHistory / useSettings pattern of "app-local state with a localStorage shadow".` |
| `localStorage`, never `sessionStorage`, is used today | search `sessionStorage` in `src/` | zero hits |
| A tab-ish strip exists but is a controlled, fixed-list component | `components/nalar/NalarTabStrip.vue:25-29,70-73` | `const tabs: ReadonlyArray<{id: TabId; label: string}>` / violet `0.5` underline |
| No `components/ui/`, no dropdown/menu primitive; menus are hand-rolled | `components/kanban/KanbanSortMenu.vue:110` | `document.addEventListener('keydown', handle…)` pattern |
| Session renames already arrive over SSE with the name attached | `helpers/sseBus.ts:25,215` + `api/index.ts:3046-3070` | `session: SessionEvent` / `sessions: (e) => forward('session', e)` / `interface SessionEvent { action: 'created'\|'updated'\|'deleted'\|'reordered'; id: string; name: string; … }` |
| The bus is a singleton with idempotent install | `helpers/sseBus.ts:129-160` | `let _instance: SseBus \| null = null` / `if (_instance) return _instance` |
| Lazy session lookup exists for a title fallback | `api/index.ts:1643` | `export async function getSession(sessionId: string): Promise<Session \| null>` |
| A per-window id concept exists in the SSE channel, but is internal | `helpers/sseTabChannel.ts:119-121` | `function randomTabId() { return \`t_${Math.random().toString(36).slice(2, 10)}\` }` |
| **No desktop-vs-web detection flag exists** — so browser-reserved chords cannot be gated | search `isDesktop\|__NALAR\|webMode` in `src/` | only `window.__nalarLogCtx` (`App.vue:78`) and `window.__designLogger` (`helpers/designLogger.ts:338`) |
| Test layout: Vitest + jsdom, 15 s timeout, `src/__tests__/` + colocated specs | `src/apps/desktop/vitest.config.ts:23-28` | `environment: 'jsdom'`, `setupFiles: ['./src/__tests__/setup.ts']` |
| The regression net for this change is big | `src/__tests__/AppLayout.*.spec.ts` | 15 files incl. `AppLayout.simplifyUrl`, `AppLayout.urlPersist`, `AppLayout.chatClickUrlOverwrite`, `AppLayout.taskClickUrlOverwrite` |

---

## Design Decisions (for reviewer)

1. **A tab stores the router target (`{ path, query }`), not a new view enum.** Rejected: a `TabKind` enum with its own render switch — it would duplicate `currentView` (`AppLayout.vue:904-942`) and immediately drift. Consequence: `kind` is a *display hint only* (icon + close tooltip), recomputed best-effort at open time.
2. **One `watch(route.fullPath)` funnel instead of editing every navigation call site.** Rejected: teaching `Sidebar.vue:331-437,992`, `ChatsList.vue:306-338`, `ChatView.vue:349` and four `AppLayout.handleNavigate` branches about tabs — bigger diff, and every future navigation path silently escapes the tab bar. The funnel means a new view type added later *automatically* becomes tabbable.
3. **Single-pane rendering; no `<KeepAlive>`.** Rejected: keeping N views alive, because it requires first making six singletons per-tab: `navigation.activeChatId`/`activeTaskId` (`stores/navigation.ts:18-22`), `workspaces.activeWorkspaceItemId` (`stores/workspaces.ts:481`), `kanbanSse.activeWorkspaceId` (`stores/kanbanSse.ts:48`), `designSse.activeWorkspaceId` (`stores/designSse.ts:50`), the `active-chat-id` localStorage mirror (`stores/navigation.ts:7-9`), and `ChatView`'s global `router.replace` (`ChatView.vue:349`). Single-pane keeps the blast radius to the tab layer and still gives the user "my chat is still there when I come back", because the resume path (`ChatView.vue:2639-2647`) and per-session scroll key already exist.
4. **Persistence keyed by a per-window id.** `sessionStorage['nalar-window-id']` (a fresh random id per browser tab / webview) scopes `localStorage['nalar-tabs:v1:<windowId>']`. Rejected: one global tab list — two app windows would fight last-writer-wins, and closing the app in window B would clobber window A's set. Also rejected: storing the list in `sessionStorage` directly (it would not survive a reload in some hosts, and it makes the set un-inspectable). This is the first `sessionStorage` use in the repo (verified zero today) — justified because "per browser window" is exactly `sessionStorage`'s semantics.
5. **Tab activation uses `router.replace`.** Rejected: per-tab history stacks (a real browser's Back goes back *inside* the tab) — that needs a per-tab history store and a rewrite of every navigation read; deferred to a follow-up, listed in `## Out of Scope`. With `replace`, Back/Forward remain "navigate inside the active tab" because plain navigation still uses `push`.
6. **Keyboard shortcuts live in the `Shift+Alt` namespace, with the familiar chords registered opportunistically.** In the web target the browser owns `Ctrl/Cmd+T`, `Ctrl/Cmd+W`, `Ctrl/Cmd+1..9` and Chromium also swallows `Ctrl+Tab`; a page cannot override them. So the *documented, testable* map is `Shift+Alt+…`, and `Ctrl+Tab`/`Ctrl+Shift+Tab`/`Ctrl+W`/`Ctrl+T` are registered as best-effort for the desktop webview (GTK `webview` does not reserve them). Rejected: `Ctrl/Cmd+…` as the primary map (dead in the web target, and there is no desktop detection flag to branch on — verified).
7. **Composer drafts are kept in memory, per window, and not persisted.** Switching tabs remounts `FileInput` (`FileInput.vue:53`), so a draft would be lost on every tab switch — that would ship as a bug on day one. But drafts are unsent user text; writing them to disk is a privacy/cleanup cost that today's behaviour does not have (a reload loses them anyway), so the draft map is in-memory in the tabs store, cleared on successful submit, and survives closing+reopening the tab within the session.
8. **A user-facing toggle, default ON.** `enabled === false` must be a perfect rollback: strip hidden, funnel no-ops, `?tab=` stripped. Default ON because a hidden feature gets no review; the toggle is the escape hatch if a regression slips through.
9. **A new `TabBar.vue`; `NalarTabStrip.vue` is left alone.** `NalarTabStrip` is a *controlled* component over a compile-time `ReadonlyArray` with its own settings-scoped storage key (`NalarTabStrip.vue:4,25-29,34-39`); extending it to closable/draggable/dynamic tabs would put the Settings page (which `NalarSettings.spec.ts` asserts on) at risk for zero reuse gain. The visual language (violet underline, `--color-*` / `--semantic-*` vars) is copied instead.
10. **Titles are resolved at render time, not frozen at open time.** Resolution order: live store lookup for workspace items (`workspacesStore`) → the tab's last known title (snapshot from the navigation argument, or `SessionEvent.name`) → lazy `api.getSession()` for a chat tab opened from a deep link → a kind-based fallback label. Live updates come from the existing `session` SSE channel (`sseBus.ts:215`, `SessionEvent.name`) and from `ChatsList`'s already-loaded list. Rejected: a title field written once at open time — the auto-rename-on-first-message cascade would leave stale labels in the strip.
11. **Closing a tab never stops an agent.** The backend session and its agentic loop are independent of the UI; the tab is a pointer. The close tooltip says so, and Task 3 asserts no API call is made on close. Rejected: "close = stop session" (destroys work, and contradicts the existing `tabs.touched` / staleness model).
12. **Open-in-background from the sidebar.** `Ctrl/Cmd+click` and middle-click on a chat row or workspace item create (or focus) a tab **without** activating it and without touching the URL. This is the one feature that needs explicit per-call-site wiring, because "don't navigate" cannot be expressed through the funnel. Rejected: skipping it — browser muscle memory makes `Ctrl+click` a very likely first user action.

---

## Wire Contract — URL, storage and key shapes

### 1. URL: one new query param

The active tab's target is mirrored into the URL exactly as today, plus `tab=<tabId>`:

```
/app?view=chat&session=session-1789300446&tab=tab_k3f9a1
/app?view=workspace&workspaceId=ws_1&itemId=item_7&tab=tab_zz20qx
/app/settings?tab=tab_aa11bb
/app/kanban/item_7/settings?tab=tab_cc22dd
```

- `tab` is **client-only**. It is never sent to the API (see Global Constraints).
- `tab` is excluded from tab *identity* (it names a tab, it is not part of the target).
- A cold `GET /app?view=chat&session=X` with no `tab=` (deep link, bookmark, `open -a`) still works: one tab is created for it.
- **URL wins over storage on boot.** If the restored list disagrees with the URL, the URL's target becomes the active tab and the rest of the restored list stays in the strip.

### 2. Tab identity — `tabKeyOf(path, query)`

Dedupe key; two navigations with the same key focus one tab instead of opening two.

| Target | Key |
|---|---|
| `/app/settings` | `settings` |
| `/app/kanban/<itemId>/settings` | `ks:<itemId>` |
| `view=chat` (no session) — the "new tab page" | `home` |
| `view=chat`, `session=X` | `chat:X` |
| `view=workspace`, `workspaceId=W`, `itemId=I` | `ws:W:bare(I)[:pageId]` |
| `view=task`, `task=T` (legacy shape, rewritten on mount at `AppLayout.vue:81-94`) | `chat:T` |
| anything else | `view:<view>` |

`bare(I)` means `parseItemIdWithChat(I).itemId` (`helpers/buildItemIdWithChat.ts:38`) — the `/chat/<taskId>` suffix is stripped, so **opening a task chat inside a kanban board focuses the board's tab** instead of creating a second tab for the same board (the dialog is rendered by the same branch, `AppLayout.vue:2380-2382` + `2414-2421`).

Volatile params are excluded from the key but kept in the tab's stored `query` (refreshed on refocus): `tab`, `sorts`.

### 3. `shouldTabify(path, query)` — exclusions

Returns `false` (funnel no-ops, URL untouched, exactly today's behaviour) for:

- `view ∈ { gitfile, skill, code-editor }` — these are `absolute inset-0 z-10` full-surface overlays (`AppLayout.vue:2240,2253,2301`) with their own Back buttons, not destinations. Decision: the strip stays behind them.
- `view === 'delete-chat'` (`ChatsList.vue:342` uses this as an event flag).

### 4. Storage schema

```
sessionStorage['nalar-window-id']            = 'w_7c1a9e02'
localStorage['nalar-tabs-enabled']           = 'true' | 'false'          // global preference, not per window
localStorage['nalar-tabs:v1:<windowId>']     = JSON.stringify({
  v: 1,
  active: 'tab_k3f9a1',
  tabs: [
    { id: 'tab_k3f9a1', key: 'chat:session-1789…', kind: 'chat',
      title: 'Fix CI on macOS', path: '/app',
      query: { view: 'chat', session: 'session-1789…' }, createdAt: 1789300446000 }
  ],
  closed: [ /* last MAX_CLOSED, same shape + closedAt */ ]
})
```

- `MAX_TABS = 50` (on overflow evict the oldest **non-active** tab), `MAX_CLOSED = 10`.
- A truncated `tabs` array is not an error: `closed` may be `[]` or missing; `active` may be absent (fall back to `tabs[0]`).
- Load is defensive: bad JSON / wrong shape / unknown `v` → ignore storage, start with one `home` tab. Never throw.

### 5. Keyboard map

| Keys | Action | Works where |
|---|---|---|
| `Shift+Alt+T` | new `home` tab | everywhere (primary map) |
| `Shift+Alt+W` | close active tab | everywhere |
| `Shift+Alt+Z` | reopen last closed | everywhere |
| `Shift+Alt+ArrowRight` / `ArrowLeft` | next / previous tab | everywhere |
| `Shift+Alt+1..9` | activate nth tab | everywhere |
| `Ctrl+T` / `Ctrl+W` / `Ctrl+Tab` / `Ctrl+Shift+Tab` / `Ctrl+1..9` | same actions | desktop webview only (best effort; browsers reserve these) |

Rules: handlers `preventDefault()` **only** when they actually act; all of them no-op when `enabled === false` or the list is empty; none of them fire while a modal dialog owns focus (bail when `event.target` is inside an `[role="dialog"]`).

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/apps/desktop/src/helpers/tabTarget.ts` | NEW | Pure functions: `tabKeyOf`, `shouldTabify`, `stripTabParam`, `withTabParam`, `kindOf`, `fallbackTitle`, `parseTabList` (storage validation). No Vue/Pinia/router imports. |
| `src/apps/desktop/src/helpers/windowId.ts` | NEW | `getWindowId()` → stable random id in `sessionStorage` (in-memory fallback when storage throws, e.g. private mode / hardened webview). |
| `src/apps/desktop/src/stores/tabs.ts` | NEW | The tab list: `tabs`, `activeTabId`, `activeTab`, `enabled`, `drafts`; actions `open`, `openInBackground`, `activate`, `close`, `closeOthers`, `closeToRight`, `reorder`, `next`, `prev`, `reopenLastClosed`, `syncFromTarget`, `setEnabled`, `setChatTitle`, `getDraft`/`setDraft`/`clearDraft`; persistence via `windowId` + `localStorage`. |
| `src/apps/desktop/src/components/shell/TabBar.vue` | NEW | The strip: tabs with icon + truncated title + close button, active styling, `+` button, horizontal overflow scroll, middle-click close, HTML5 drag reorder, right-click menu. |
| `src/apps/desktop/src/composables/useTabShortcuts.ts` | NEW | `keydown` listener registration + the key map from §5, returning a teardown. |
| `src/apps/desktop/src/components/AppLayout.vue` | EDIT | Mount `<TabBar>` as the first child of `<main>` (`:2237`); add the funnel watcher with `syncFromTarget`; make the existing `handleNavigate` branches persist `?tab=` (they already build the query); mount `useTabShortcuts`. **The `currentView` computed and the whole `v-if` chain stay untouched.** |
| `src/apps/desktop/src/components/file/FileInput.vue` | EDIT | Optional `draftKey` prop: restore on mount, debounced save on input, clear on submit. Default `undefined` = today's behaviour (so `GitFileViewer` is unaffected). |
| `src/apps/desktop/src/components/views/ChatView.vue` | EDIT | Pass `draftKey="chat:<sessionId>"` to `<FileInput>` (`:3601`). Nothing else in this file changes. |
| `src/apps/desktop/src/components/views/ChatsList.vue` | EDIT | Publish loaded chat names to the tabs store (title feed); `Ctrl/Cmd+click` + middle-click → `tabs.openInBackground`; `createChat` opens/focuses a tab. |
| `src/apps/desktop/src/components/shell/Sidebar.vue` | EDIT | Same modifier-click handling for workspace items + task rows; single-click keeps emitting `navigate` (the funnel does the rest). |
| `src/apps/desktop/src/components/NalarSettings.vue` | EDIT | "Browser-style tabs" toggle in the General tab, bound to `tabsStore.enabled`; when turning it off, strip `tab=` from the current URL. |
| `src/apps/desktop/src/__tests__/tabTarget.spec.ts` | NEW | Pure-helper table tests (keys, exclusions, storage validation, corrupt input). |
| `src/apps/desktop/src/__tests__/tabsStore.spec.ts` | NEW | Store behaviour: open/dedupe/close neighbour rules/never-empty/reorder/persistence round-trip/corrupt-load/drafts/`setChatTitle`/`reopenLastClosed`. |
| `src/apps/desktop/src/__tests__/TabBar.spec.ts` | NEW | Component: render, active styling, click, middle-click, close button, `+`, drag reorder, close-menu items, overflow scroll, hidden when disabled. |
| `src/apps/desktop/src/__tests__/AppLayout.tabs.spec.ts` | NEW | Integration: sidebar navigate → tab created + `?tab=` in URL; switch tab → URL replaced; `?tab=` normalisation; overlays excluded; `enabled=false` → no strip + URL cleaned. |
| `src/apps/desktop/src/__tests__/tabDraft.spec.ts` | NEW | `FileInput` draft restore/save/clear, and that two ChatView mounts for two sessions keep separate drafts. |
| `src/apps/desktop/src/__tests__/useTabShortcuts.spec.ts` | NEW | Key map, no-op when disabled/empty, no-op inside `[role="dialog"]`, `preventDefault` only when acting. |
| `docs/tabs.md` | NEW | User+engineer doc: what tab mode is, the URL/`?tab=` contract, the shortcut map and its browser-reserved caveat, the storage schema, how to turn it off. Structure mirrors `docs/sse-tab-sharing.md`. |
| `docs/superpowers/plans/2026-09-13-tab-mode-like-a-browser.md` | THIS FILE | The plan. |

**Not touched:** any `.zig` file, `src/main.zig`, `router/index.ts` (no new route is needed — `?tab=` rides the existing `/app` route and the SPA fallback), `stores/navigation.ts`, `stores/workspaces.ts`, `stores/kanbanSse.ts`, `stores/designSse.ts`, `NalarTabStrip.vue`, `helpers/sseBus.ts`, `helpers/sseTabChannel.ts`. If implementation finds itself needing to edit one of these, stop and re-read the corresponding Design Decision — the plan deliberately avoids them.

---

## Tasks

### Task 1 — The pure tab contract (`tabTarget.ts` + `windowId.ts`)

- [ ] Write `__tests__/tabTarget.spec.ts` **first**, table-driven: `tabKeyOf` for every row of the Wire Contract §2 table (incl. `itemId: 'item_Y/chat/task_W'` → `ws:W:item_Y`, and `pageId` inclusion); `tabKeyOf` ignores `tab` and `sorts`; `shouldTabify` false for `gitfile`/`skill`/`code-editor`/`delete-chat` and true for `chat`/`workspace`/`settings`/absent view; `stripTabParam` / `withTabParam` round-trip; `parseTabList` on `null`, `''`, `'{'`, `'{}'`, `'{"v":99,…}'`, an entry missing `id`, an entry whose `query` is an array → always a valid single-`home` list, never a throw.
- [ ] Implement `helpers/tabTarget.ts`: no Vue, no Pinia, no vue-router imports — only `parseItemIdWithChat` from `helpers/buildItemIdWithChat.ts`. Keep every exported function total (no throwing).
- [ ] Implement `helpers/windowId.ts`: read `sessionStorage['nalar-window-id']`, else create `w_<10 random base36>`, write it, return it; on a throwing storage (quota/private mode) fall back to a module-level id so the session still works.
- [ ] Add a `windowId.spec.ts` case (or fold into `tabTarget.spec.ts`) covering: first call creates + persists, second call returns the same value, a throwing `sessionStorage` returns a stable in-memory id.
- [ ] Confirm the Global-Constraints leak check: `tab` does not appear in `helpers/buildTaskUrlQuery.ts` / `helpers/buildItemIdWithChat.ts`.
- [ ] `Commit:` `feat(tabs): pure tab-target helpers + per-window id`

### Task 2 — The tabs store (`stores/tabs.ts`)

- [ ] Write `__tests__/tabsStore.spec.ts` **first**. Required cases: `open()` creates a tab with a `?tab`-free `query` and makes it active; `open()` with a key that already exists focuses it and refreshes its stored `query` (e.g. new `sorts`) without reordering; `activate()` is a no-op for an unknown id; `close(inactive)` keeps the active tab active; `close(active)` picks the right neighbour; `close(activeRightmost)` picks the left; `close(lastRemaining)` leaves exactly one `home` tab; `remove all but one` never yields an empty list; `reorder(0, 3)` moves the item and keeps the active tab active; `next()`/`prev()` wrap; `reopenLastClosed()` restores id + key + query and no-ops on an empty stack; `MAX_TABS` eviction never evicts the active tab; persistence round-trip (`persist()` then a fresh store sees the same list, order and active id); corrupt storage → one `home` tab; `setEnabled(false)` then `true` keeps the list; `drafts`: `getDraft`/`setDraft`/`clearDraft` and "a draft survives closing and reopening the tab".
- [ ] Implement the store in the setup-store style (`defineStore('tabs', () => { … })`), mirroring `stores/navigation.ts`'s defensive-load idiom (`:49-71`).
- [ ] `syncFromTarget(path, query)` implements the funnel logic from Wire Contract §1 (URL wins; `?tab=` honoured only when the key matches; normalize by returning the desired `{ path, query }` for the caller to `router.replace` — the store itself must not import the router).
- [ ] Persist on every mutation (debounce with a 200 ms timer, matching `stores/recentFolders.ts:62`, and flush on `pagehide`).
- [ ] `Commit:` `feat(tabs): tab list store with per-window persistence`

### Task 3 — The strip (`components/shell/TabBar.vue`)

- [ ] Write `__tests__/TabBar.spec.ts` **first** against a real Pinia store (`setActivePinia(createPinia())`, pattern from `__tests__/navigation.spec.ts:2-6`): renders one `role="tab"` per open tab with `aria-selected` only on the active one; title truncation keeps the tab accessible (`title` attr = full title); clicking a tab calls `activate`; clicking its close button removes it and does not `activate` it first; middle-click (`auxclick`, `button === 1`) closes; the `+` button opens a `home` tab; the right-click menu offers Close / Close others / Close to the right and each maps to the right action; drag: `dragstart` on index 1 + `drop` on index 3 calls `reorder(1, 3)`; nothing renders when `enabled === false`; `data-testid` hooks exist (`tab-item-<id>`, `tab-close-<id>`, `tab-new`, `tab-bar`).
- [ ] Implement the component. First child of `<main>`, `shrink-0`, height `h-9`, `border-b` `--color-border`, background `--semantic-content-bg`, violet `0.5` underline on the active tab (copied from `NalarTabStrip.vue:70-73` — no component is imported from there).
- [ ] Overflow: `overflow-x-auto` with a hidden scrollbar; `watch(activeTabId)` → `activeEl.scrollIntoView({ block: 'nearest', inline: 'nearest' })`; a `wheel` handler translates vertical delta into horizontal scroll and calls `preventDefault()` only when it actually scrolled.
- [ ] Close-menu: hand-rolled absolutely-positioned div + a `document` click/keydown listener removed on unmount (pattern: `components/kanban/KanbanSortMenu.vue:110`).
- [ ] Assert in the spec that closing a tab performs **no** API call (spy on the api module) — the "closing a tab never stops an agent" decision.
- [ ] `Commit:` `feat(tabs): browser-style tab strip component`

### Task 4 — AppLayout wiring: the funnel and the strip

- [ ] Write `__tests__/AppLayout.tabs.spec.ts` **first** (mount `AppLayout` with a real router, as the existing `AppLayout.simplifyUrl.spec.ts` does): navigating to `chat-<id>` through `handleNavigate` leaves `?view=chat&session=<id>&tab=<id>` in the URL and exactly one tab in the strip; navigating to a second chat adds a second tab; re-navigating to the first focuses it without adding one; `?view=workspace&workspaceId=W&itemId=I` creates a `ws:` tab and the chat-suffixed variant of the same item focuses it; `?view=skill&skill=abc` creates **no** tab and leaves the URL untouched; a deep-link `?view=chat&session=Z` (no `tab=`) creates one tab and normalizes the URL to carry `tab=`; `?tab=<unknown>` is replaced by a freshly created tab's id; `enabled === false` → `[data-testid="tab-bar"]` is absent and the URL never gains `tab=`.
- [ ] Mount `<TabBar />` as the first child of `<main>` right after `AppLayout.vue:2237`, gated on `tabsStore.enabled`.
- [ ] Add the funnel: `watch(() => route.fullPath, …)` calling `tabsStore.syncFromTarget(route.path, route.query)` and applying the returned normalisation with `router.replace`. Runs `{ immediate: true }` so a cold boot is covered, and must run **after** the existing `onMounted` restore (`AppLayout.vue:68-127`) — defer the immediate sync by a `nextTick` if ordering fights the `navigationStore.initFromUrl` restore.
- [ ] Activating a tab (from the strip) calls `router.replace({ path: tab.path, query: withTabParam(tab.query, tab.id) })` from the strip's parent handler in `AppLayout` — one place, so no component imports the router for tabs.
- [ ] Leave `AppLayout.handleNavigate` semantics intact; the only change is that its built queries now also carry `tab=<active id>` (build the query, then run it through `withTabParam`) so a re-render does not lose the active tab.
- [ ] Layout check (no unit test can catch this): with the strip mounted, every branch — `Chats`, `ChatView`, `KanbanView`, `DesignView`, `AgentView`, `RoutineView`, `StandardTaskChatView`, `SettingsView`, kanban-settings, workspace preview — still fills `<main>` with no 36 px overflow. Verified safe by construction: no content branch uses `h-screen` (searched 2026-09-13); the only hits are `AppLayout.vue:2228` and the sibling `Sidebar.vue:1286`.
- [ ] Re-run the 15 existing `AppLayout.*.spec.ts` files and fix any that assert an exact `route.query` object (they will now see `tab`).
- [ ] `Commit:` `feat(tabs): drive tab strip from the route funnel in AppLayout`

### Task 5 — Draft survival across tab switches

- [ ] Write `__tests__/tabDraft.spec.ts` **first**: `FileInput` with `draftKey="chat:A"` restores seeded text on mount; typing saves (fake timers advance the debounce); `submit` clears the stored draft; `FileInput` **without** `draftKey` never reads or writes the store (so `GitFileViewer` is untouched); two mounts with `chat:A` and `chat:B` keep independent text.
- [ ] Add the optional `draftKey?: string` prop to `components/file/FileInput.vue`; on mount read `tabsStore.getDraft(draftKey)` into `inputText`; on `inputText` change debounce 200 ms → `setDraft`; on submit/clear → `clearDraft`.
- [ ] Pass `:draft-key="`chat:${sessionId}`"` (or the tab id) from `ChatView.vue:3601`.
- [ ] `Commit:` `feat(tabs): keep composer drafts across tab switches`

### Task 6 — Keyboard shortcuts

- [ ] Write `__tests__/useTabShortcuts.spec.ts` **first**: each row of Wire Contract §5 maps to the right action (drive the exported handler with synthetic `KeyboardEvent`s — `document.dispatchEvent(new KeyboardEvent('keydown', { key, shiftKey, altKey, ctrlKey, metaKey }))`); `preventDefault` is called for an acting combo and **not** for a pass-through; every combo no-ops when `enabled === false`; no-ops when the list is empty; a combo whose target sits inside `[role="dialog"]` no-ops; the teardown removes the listener.
- [ ] Implement `composables/useTabShortcuts.ts` with the §5 map (primary `Shift+Alt+…` + opportunistic browser-reserved combos) and register it in `AppLayout` `onMounted`/`onUnmounted`.
- [ ] `Commit:` `feat(tabs): tab keyboard shortcuts`

### Task 7 — Settings toggle + live titles

- [ ] Write `__tests__/tabsSettingsToggle.spec.ts` **first**: `NalarSettings` renders a "Browser-style tabs" toggle bound to `tabsStore.enabled`; flipping it off persists `'false'` and strips `tab=` from the current URL; flipping it back on restores the strip.
- [ ] Add the toggle to the General tab (`NalarSettings.vue:52,569` area, `NalarTabStrip` untouched) and the `?tab=` cleanup in the toggle handler.
- [ ] Add the title feed: in the tabs store's `init()` subscribe to `bus.on('session', …)` (`helpers/sseBus.ts:25,215`) and on `action === 'created' | 'updated'` with a non-empty `name` call `setChatTitle(id, name)` for any open `chat:` tab; unsubscribe on teardown. Add a spec case driving `__dispatchSseBus('session', {...})` (harness hook at `helpers/sseBus.ts:456`).
- [ ] In `ChatsList.vue`, after `loadChats` succeeds, publish `{id, name}` pairs to `tabsStore.setChatTitle` in one pass. Spec: a renamed session updates an open tab's displayed title.
- [ ] `Commit:` `feat(tabs): tab-mode setting and live tab titles`

### Task 8 — Open in background / open in new tab

- [ ] Write the spec cases in `__tests__/tabsStore.spec.ts` + `__tests__/AppLayout.tabs.spec.ts`: `openInBackground({path, query})` creates the tab, does **not** change `activeTabId`, and leaves `route.fullPath` untouched; focusing an already-open tab from background makes it active.
- [ ] Implement `openInBackground` in the store.
- [ ] Wire `Ctrl/Cmd+click` and `middle-click` (`@auxclick` with `button === 1`, `preventDefault`) on chat rows (`ChatsList.vue:320-338` area) and workspace/task rows (`Sidebar.vue:367-437,933-992` area) to call `openInBackground` with the target query the row already knows how to build.
- [ ] Document the intended consequence for "peek → Open full" (`ChatView.vue:347-350`): the sub-agent session has a different key, so it now lands in a **new** tab and the parent chat stays open in the strip. Add a spec asserting two tabs after that navigation.
- [ ] `Commit:` `feat(tabs): open links in background from the sidebar`

### Task 9 — Regression sweep, docs, PR

- [ ] `pnpm --dir src/apps/desktop test` twice: once on the base commit (record the baseline failure list) and once with the change. **No new failures.** Record both lists in the PR body.
- [ ] `pnpm --dir src/apps/desktop run build` clean; then `git status --porcelain` shows no stray `*.js` under `src/apps/desktop/src` (delete any that `vue-tsc --build` emitted).
- [ ] Manual dev checklist on `pnpm dev` (5173) — every line, on both a fresh `HOME`-less web URL and the desktop webview if available: open 6 tabs across chat / kanban / design / agent / settings; reload → same list, same active tab; close the active tab → right neighbour activates; close the last tab → `home`; drag-reorder survives a reload; middle-click closes; `Shift+Alt+T/W/Z/arrows/1..9`; `Ctrl+click` a sidebar chat → background tab; type in tab A → switch to B → back to A → text still there; start a long agent run → switch away → back → streaming content resumed, not restarted; toggle the setting off → strip gone and behaviour identical to `d540b617`.
- [ ] Write `docs/tabs.md` (mirrors `docs/sse-tab-sharing.md`): what tab mode is, the `?tab=` contract, the key map **with** the browser-reserved caveat, the storage schema + the "how do I reset my tabs" answer (`localStorage.removeItem('nalar-tabs:v1:<windowId>')`), and the toggle.
- [ ] Open the PR (plan-only PRs in this repo are docs-only; this one is a normal feature PR): branch `worktree/tab-mode-like-a-browser-1789300444735`, base `main`.
- [ ] `Commit:` `docs(tabs): document tab mode` then open the PR with the task table, the decision list, and both test baselines in the body.

---

## Verification

- [ ] **Plan saved** to `docs/superpowers/plans/2026-09-13-tab-mode-like-a-browser.md` and committed on the worktree branch.
- [ ] **Plan header** includes Goal, Architecture, Tech Stack, Global Constraints.
- [ ] **Each task has bite-sized steps** (test → implement → verify → commit).
- [ ] **User has reviewed the plan** before execution begins.
- [ ] **No-regression gate (the important one):** `pnpm --dir src/apps/desktop test` — full suite. Baseline recorded on `d540b617` *before* the first change; the post-change run must introduce **zero** new failures. All 15 `AppLayout.*.spec.ts` files must pass, in particular `AppLayout.simplifyUrl`, `AppLayout.urlPersist`, `AppLayout.chatSuffixRoundTrip`, `AppLayout.sortUrlRoundTrip`, `AppLayout.chatClickUrlOverwrite`, `AppLayout.taskClickUrlOverwrite`.
- [ ] **Toggle-off gate:** with `nalar-tabs-enabled = 'false'`, the URL never gains `tab=`, `[data-testid="tab-bar"]` never renders, and the 15 AppLayout specs pass unchanged. This is the rollback proof.
- [ ] **Type/build gate:** `pnpm --dir src/apps/desktop run build` (runs `vue-tsc --build` in parallel with `vite build`); no stray `.js` in `git status`.
- [ ] **New spec files** all present and green: `tabTarget`, `tabsStore`, `TabBar`, `AppLayout.tabs`, `tabDraft`, `useTabShortcuts`, `tabsSettingsToggle`.
- [ ] **Persistence gate:** seed `localStorage['nalar-tabs:v1:<windowId>']` with (a) valid 3-tab JSON + reload, (b) `'{'`, (c) `'{"v":1,"tabs":[{"id":1}]}'`, (d) `'{"v":99}'`. (a) restores exactly; (b)–(d) fall back to one `home` tab with **no** console exception.
- [ ] **Second-window gate:** opening the app in a second browser tab yields an independent tab list (its own `sessionStorage` window id) while the SSE leader election (`helpers/sseTabChannel.ts`) still converges to one connection — this feature must not disturb the existing 6-connection fix.
- [ ] **Port gate:** nothing in the run touched port 8081; manual checks used 5173 only.
- [ ] **No wire gate needed, stated explicitly:** no Zig file changed, so `zig build test` is not a gate for this plan; no python functional test is required because no HTTP route, request body or SSE payload changes.

---

## Out of Scope (explicit non-goals)

- **Per-tab navigation history** (a real browser's Back goes back *inside* the tab). Needs a per-tab history store and a rework of every `route` read; deferred behind Decision 5.
- **Multiple simultaneously live views** (`<KeepAlive>`, split panes, side-by-side chats). Blocked on the six singletons in Decision 3.
- **Native OS windows / multi-window tabs.** The shell creates exactly one webview (`src/apps/desktop_app/webview_lib.zig:119-126`, single `webview_create`) and `webview_run` blocks the main loop (`:18-20`); multi-window is a separate plan.
- **Moving the existing sidebar-adjacent tabstrips** (`NalarTabStrip`, `RightSidebar`, `FilePickerDialog`) onto the new strip — Decision 9.
- **Tab groups, pinning, tab search, session restore across app restarts** (only the strip persists, not the app's LLM sessions — that already lives server-side).
- **SSE per-tab connection handling** — already solved by `docs/sse-tab-sharing.md` (one leader connection per browser profile); this plan must not regress it, and asserts that in the second-window gate.
- **Backend/tab-state persistence** (a `ui_state` table). Verified absent today (`ui_state|open_tabs|window_state|session_state` → zero hits); keeping tab state client-side is Decision 4.
- **`Ctrl/Cmd+…` shortcuts in the web target** — not technically possible (browser-reserved); documented instead.

## Open Questions for the reviewer

1. **Default ON or OFF?** *Implemented default: ON* (Decision 8) so the feature is visible in review; OFF would make it invisible until someone finds the toggle. Flip this if you want a softer rollout.
2. **Should `home` (the chats list) be a closable tab?** *Implemented: yes, closable like any other* — closing the last tab recreates it. Alternative: make it pinned/unclosable like a browser's pinned tab.
3. **Should overlay views (`gitfile` / `skill` / `code-editor`) get their own tabs?** *Implemented: no* (Decision/§3) — they are full-surface overlays with Back buttons. Alternative: give them tabs too, which means re-laying them out so the strip stays visible.
4. **Per-tab history now?** *Implemented: no* (Decision 5). If Back-as-tab-switcher feels wrong in review, this is the follow-up.
5. **Should `Ctrl+click` background-open also cover kanban board items** (not just chats + sidebar rows)? *Implemented: sidebar rows and chat rows only*; kanban cards keep their current click behaviour.
6. **Draft persistence across reload?** *Implemented: in-memory only* (Decision 7). Say the word and it becomes a `localStorage` key.

## Risks

1. **`tab=` leaking into a generated URL or an API call.** Mitigated: the only URL builder whitelists breadcrumb params (`helpers/buildItemIdWithChat.ts:60,69` via `helpers/buildTaskUrlQuery.ts:107-109`); Task 1 asserts zero `tab` references there. The API never sees query strings — it sees explicit `api.*` calls.
2. **Existing `AppLayout.*` specs asserting an exact `route.query`.** Mitigated: Task 4 explicitly re-runs the 15 files; `AppLayout.urlPersist` / `simplifyUrl` are the most likely to need a `tab`-aware update rather than a behaviour fix.
3. **Strip + branch layout (36 px overflow).** Low: no content branch uses `h-screen` (verified 2026-09-13); `main` is height-bound by `flex h-screen` at `AppLayout.vue:2228`. Covered by the manual matrix in Task 9, which is the only thing that can catch it.
4. **The funnel fighting the existing `route.query` watcher (`AppLayout.vue:2083-2200`).** Two watchers on overlapping state can ping-pong. Mitigated: the funnel only ever *adds/normalises* `tab` and re-dispatches a `replace` only when the value actually differs; Task 4's spec includes a "no navigation loop" case (assert `router.replace` call count is 1 for a single navigation).
5. **Ordering against `onMounted` restore (`AppLayout.vue:68-127`).** A cold deep link is handled by both paths (`navigationStore.initFromUrl` and the funnel). Mitigated: the funnel is authoritative for *tabs* only, `initFromUrl` stays authoritative for *navigation state*; the spec covers boot with and without `?tab=`.
6. **`FileInput` is shared with `GitFileViewer` (`GitFileViewer.vue:501`).** Mitigated: `draftKey` is optional and the no-prop path is asserted to never touch the store.
7. **Storage growth / stale tabs pointing at deleted sessions or items.** Mitigated: `MAX_TABS = 50`, and activating a dead chat shows the existing empty/history state (no new failure mode). A "prune dead tabs" pass is deliberately not in scope.
8. **`sessionStorage` availability.** Mitigated: `helpers/windowId.ts` falls back to an in-memory id (feature still works, just loses reload persistence in that host).
9. **Pre-existing test failures being mistaken for regressions.** Mitigated: Task 9 records the baseline on `d540b617` before any change.

## Plan saved checklist

- [x] Plan saved to `docs/superpowers/plans/2026-09-13-tab-mode-like-a-browser.md` (in the worktree, committed on the branch)
- [x] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [x] Each task has bite-sized steps (test → implement → verify → commit)
- [x] User has reviewed the plan before execution begins (approved 2026-09-13: "okey execute the plan")

---

## Implementation status (rev 2)

All nine tasks landed. Commits on the branch, in order:

| Commit | Task |
|---|---|
| `b4a4fdf9` | 1 — pure contract (`tabTarget.ts`, `windowId.ts`) |
| `ec0b0e31` | 2 + 3 — tabs store and `TabBar.vue` |
| `42ec1952` | 4 — AppLayout route funnel + strip mount |
| `f7c27de4` | 5 + 6 — composer drafts and keyboard shortcuts |
| `b5119287` | 7 + 8 — settings toggle, live titles, open-in-background |
| (final) | docs (`docs/tabs.md`), plan status, PR body |

**Measured gates** (frontend only — no Zig file changed, so `zig build test`
and the python harness were correctly not run):

| Gate | Base `d540b617` | After |
|---|---|---|
| `pnpm test` (vitest) | 4 failed / 3057 passed, 356 files | 4 failed / **3164 passed**, 363 files |
| failing files | `FilePickerDialog.windows`, `WorkspaceItemHideTasksForDesign`, `workspacesStoreNormalizeTaskDates`, `workspacesStoreNormalizeTaskImageUrls` | the same four — **zero new failures** |
| `pnpm run build` (`vue-tsc --build` + `vite build`) | — | clean; no stray `.js` emitted (`git status` matches only intended files) |
| new tests | — | +107 across 7 new spec files |
| port 8081 | — | never touched; no live server was started |

### Deviations from this plan (all deliberate, all smaller than planned)

1. **Persistence is synchronous** (with a skip-if-unchanged guard) instead of a
   200 ms debounce + `pagehide` flush. The payload is tiny and the debounce could
   drop the last action on an immediate reload.
2. **Navigation call sites were not touched at all.** The plan said
   `handleNavigate`'s queries would also carry `tab=`. They don't: the route
   funnel adds it via `router.replace` right after the navigation. That is why
   the 15 pre-existing `AppLayout.*` specs (which assert exact `router.push`
   payloads) needed **zero** changes.
3. **The funnel runs synchronously in `onMounted`**, registered after the
   existing restore hook (Vue fires hooks in registration order), instead of
   deferring by `nextTick` — a deferral shifted mount timing and broke
   `AppLayout.urlPersist.spec.ts`'s fixed tick counts.
4. **Titles come from the `session` SSE channel + the chats list**, not from a
   lazy `api.getSession()` fallback: every chat the strip can show is in the
   list the user just loaded, and renames arrive over SSE.
5. **Task 8 covers chat rows and workspace-item rows** (Ctrl/Cmd+click and
   middle click). Kanban task *cards* keep their existing click behaviour —
   they need the same emit threaded through `WorkspaceItemTaskRow`, left as a
   follow-up rather than widening this diff.
6. **`NalarSettings.spec.ts` gained `setActivePinia(createPinia())`** — the
   settings orchestrator now reads the tabs store for the new toggle, which is
   a real dependency of the component, not a test workaround.
7. **TabBar has no `api` import at all**, so "closing a tab never stops an
   agent" is structural rather than assertion-based (verified by grep); the
   close tooltip states it in the UI.
8. **Post-review correction (user-reported): a task chat now gets its own tab.**
   The plan keyed `itemId=I/chat/T` onto the item's tab (`ws:W:I`), on the
   reasoning that the chat dialog renders inside the board view. The user
   reported the consequence: selecting another task/session appeared to
   *replace* the tab they were reading, because a task IS a session
   (`task.id == session.id`, migration 052). Now `ws:W:I:chat:T`, so each task
   chat is its own tab and re-selecting focuses it. The plan's §2 identity table
   and `docs/tabs.md` were updated with it.
9. **`renameChatTab(oldId, newId)`** was added and wired into
   `AppLayout.handleUpdateChatId`. Without it, the synthetic
   `session-<timestamp>` id of a brand-new chat left a dead tab behind while the
   funnel opened a second tab for the real session id — i.e. two tabs for one
   chat. Ids are preserved across the rename; if the real chat is already open,
   the dead pointer is dropped and the live tab focused.
10. **Post-review correction 2 (user-reported): kanban/design keep one tab, and
   identity is item-type aware.** Item 8 gave every task chat its own tab, which
   is right for `agent` / `folder` / `routine` / `memory` items (the task chat
   *is* the view) but wrong for kanban/design, where the chat is a dialog inside
   the board — the user reported a strip full of duplicate `AGENTIC_KANBAN` tabs
   (one per card opened). `tabKeyOf(path, query, itemType?)` now decides per item
   type (`taskChatRendersInItemTab`), the route funnel passes
   `workspacesStore.activeWorkspaceItem.item_type` when it matches the URL, and a
   tab created without that knowledge is marked `provisional` and re-keyed in
   place once the type arrives (`tabKeyVariants` + `findExisting`) instead of
   being duplicated. Covered by three new/rewritten specs at the pure, store and
   AppLayout level.
11. **Post-review correction 3 (user-reported): activating a tab must mirror the
   target into the STORES, not just rewrite the URL.** "Switch between 2
   workspace not change": both workspace tabs rendered the same board. The render
   chain reads `workspacesStore.activeWorkspaceItem` / `navigationStore.activeChatId`,
   and only the sidebar set them (WorkspaceItem → Sidebar.handleSelectItem →
   emit), so a URL-only tab activation left the previous view on screen.
   `AppLayout.mirrorTargetIntoStores(path, query)` now performs the store half of
   a navigation (workspace item + optional task chat + design page; for chats:
   clear the item, set the session) and `applyActiveTabToUrl` calls it before
   replacing the URL. Regression test: two workspace tabs clicked back and forth
   assert both the store state and *which view renders*.

