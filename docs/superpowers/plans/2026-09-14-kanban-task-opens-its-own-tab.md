# Kanban task opens its OWN tab (in-app, browser-style)

> **Status: PLAN ONLY — not executed, and now SELF-CONTAINED.**
> Rev 2 (2026-09-14): the sibling card *"make KanbanChatdialog not a dialog, so
> refactore to KanbanChat"* is being **DROPPED**, so rev 1's hard dependency is
> gone. This plan therefore absorbs the one thing it needed from that work —
> kanban task chat must render as a **view** (a tab needs a view body, not a
> Teleport modal) — and does everything itself. No external prerequisite.
> Awaiting the go-ahead at `in_review_planning`.

> **For agentic workers:** this is a *planning* artefact. Before implementing, use
> subagent-driven-development / executing-plans. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** Clicking a kanban task card opens that task's chat in **its own tab** in
the tab strip, activated, with the board tab left open beside it — instead of the
chat appearing as a modal dialog today.

Generated 2026-09-14 against `main` @ `63f92209`.

---

## 1. Decisions (locked)

| Decision | Value | Why |
|---|---|---|
| "New tab" means | **In-app browser-style tab strip** (`docs/tabs.md`, PR #476) | User confirmed. The attached screenshot shows the strip with a chat tab (`💬 execution-order-priority-t…`) — the target look. |
| The board tab stays open | **Yes** — a card click *adds* a tab, it does not replace the board tab | "open a new tab" next to the board is the whole point. |
| The `KanbanChatDialog` **modal is deleted** | Yes, in both tab-on and tab-off modes | A modal cannot be a tab body, and the user explicitly said "instead of open a new dialog". Keeping a second code path for tab-off would double the surface for the legacy mode. |
| Design items | **Out of scope** — `DesignChatDialog` stays a modal | The user asked for kanban; the design chat is opened by a canvas header button + an FK-driven auto-open, not a per-card click. |
| `Ctrl/Cmd+click` / middle-click background open | **Out of scope** — follow-up (§7) | User narrowed the goal to the plain click. Fully specified in §7 so it can be picked up later without re-research. |
| Closing a chat tab when it is the LAST tab | **Browser-like**: `tabs.close()` already falls back to a fresh home tab | User's answer: "browser like maybe". No bespoke logic. |
| Sidebar task rows for a kanban item | **Behave identically** | They go through the same `Sidebar.handleSelectTask`, so they inherit the behaviour for free. Consistent by construction. |
| In-chat header (task name + ✕) | **Shown** (`ChatView :show-header="true"`) | Gives a close affordance in both modes. See §11 Q1 for the alternative. |

### 1.1 This deliberately reverses commit `03780fe2`

`fix(tabs): one tab per kanban/design item — task-chat identity is item-type
aware` introduced the rule we are now removing, on the rationale *"kanban/design
open it as a dialog inside the item's view (one tab, however many cards you
open)"*. That rationale is now obsolete for kanban: the user **wants** one tab
per card. Design keeps it. The regression test that locks the old rule
(`AppLayout.tabs.spec.ts:249-292`) must be rewritten, not deleted — it becomes
the test for the new rule.

### 1.2 Degraded rollback (be aware)

`docs/tabs.md:190-195` claims the *Settings → General → Browser-style tabs* toggle
is "a complete rollback". After this plan that claim weakens: with tabs **off**
the kanban chat no longer appears as a modal — it replaces the board, exactly
like an agent/folder task chat does today (still one view, still no strip). The
toggle still removes the strip; it no longer restores the modal. Rollback of the
modal itself is `git revert`. Task 4 updates that doc paragraph.

---

## 2. Why the modal must become a view (self-contained work)

A tab is a body in the `<main>` render chain. Today the kanban chat is a
`<Teleport to="body">` modal that sits *above* the chain:

| Fact | Where |
|---|---|
| `KanbanChatDialog` is a `<Teleport to="body">` modal with a backdrop | `components/kanban/KanbanChatDialog.vue:105,119,132-137` |
| Mounted standalone (`v-if`, **not** `v-else-if`) so it overlays the board | `AppLayout.vue:2562-2576` |
| `show` driven by an `activeTask` watcher | `AppLayout.vue:976-983` |

So this plan includes converting it to a `v-else-if` branch in the chain. The
result is exactly what the two tabs need:

| URL | Render chain result | Tab |
|---|---|---|
| `?view=workspace&itemId=item_7` | `KanbanView` (board) | `ws:…:item_7` |
| `?view=workspace&itemId=item_7/chat/task_9` | the chat view | `ws:…:item_7:chat:task_9` |

**Critical chain detail (learned the hard way):** the new branch **must** be
`v-else-if` and placed **before** the `KanbanView` branch (`AppLayout.vue:2528`).
A standalone `v-if` starts a *new* chain and would render the board **and** the
chat stacked — the board on top, the chat squeezed underneath.

**Optional reference, not a dependency:** branch
`worktree/make-kanbanchatdialog-not-a-dialog-so-refactore-to-1789299728209`
(commit `5f516224`) contains a working version of this conversion, including a
`components/kanban/KanbanChat.vue` wrapper with a dedicated header. This plan does
**not** require it (that card is being dropped, and the branch may disappear).
Task 2 uses the smaller in-place approach; if the visual review rejects it, lift
the wrapper from `5f516224` before the branch is pruned.

---

## 3. Current behaviour (verified 2026-09-14 at `63f92209`, main)

### 3.1 The click chain (one path, many pass-through layers)

`WorkspaceItemTaskCard.vue:324` `@click="handleSelectTask"` (root `<button>`)
→ `composables/useTaskActions.ts:114-116` `emit('selectTask', props.task.id)`
→ `KanbanCard.vue:100` → `KanbanColumn.vue:816` → `KanbanView.vue:1305`
→ `AppLayout.vue:2541` `handleKanbanSelectTask` (`:1811-1813`)
→ `sidebarRef.selectTask` (`Sidebar.vue:1288` → `:939`).

`Sidebar.handleSelectTask` (`Sidebar.vue:939-1018`) is where the work happens:

```ts
workspacesStore.isNavigatingToTask = true          // :953  race guard
workspacesStore.setActiveTask(taskId)              // :955  store: activeTaskId
const query = buildTaskUrlQuery({ … })             // :1000 breadcrumb-preserving
await router.push({ path: '/app', query })         // :1014 PUSH (not replace)
```

`buildTaskUrlQuery` (`helpers/buildTaskUrlQuery.ts:94-137`) produces
`?view=workspace&workspaceId=…&itemId=<item>/chat/<task>[&sorts=…]`.

**Consequence that makes this plan cheap:** the click is already a plain
`router.push`, so it already flows through the tab funnel
(`AppLayout.vue:2292-2302` → `stores/tabs.ts:424-468`). The click path needs
**zero** new JavaScript — only the identity change in Task 1.

### 3.2 Why it is one tab today

`helpers/tabTarget.ts:156-182` `tabKeyOf` builds `ws:<ws>:<item>[:<page>]` and
appends `:chat:<taskId>` **conditionally**:

```ts
if (parsed.chatTaskId && !taskChatRendersInItemTab(itemType)) {   // :176
  parts.push(`chat:${parsed.chatTaskId}`)
}
```

`taskChatRendersInItemTab` (`:191-193`) is a whitelist:

```ts
const DIALOG_ITEM_TYPES = ['kanban', 'design', 'kanban-settings']   // :189
```

So for a kanban item the key stays `ws:ws_1:item_7` and three different cards
collapse into one tab. `AppLayout.tabs.spec.ts:249-292`
(*"keeps one tab when opening task chats inside a kanban item"*) locks that in,
and `docs/tabs.md:114,121-125` documents it as a contract.

`TabBar.titleOf` (`TabBar.vue:73-99`) already contains the *other* half of the
rule: `if (chatTaskId && !taskChatRendersInItemTab(item.item_type)) return task.name`
(`:91-94`) — i.e. the label logic already knows how to name a per-task chat tab;
it just never runs for kanban because `taskChatRendersInItemTab('kanban')` is
`true`. **Labelling needs no code.**

### 3.3 Closing today, and why it must change

`AppLayout.handleCloseTaskView` (`:1460-1515`) is a **shared** handler — wired
from four places, so it cannot simply be deleted or repurposed:

| Caller | Line |
|---|---|
| `KanbanChatDialog @close` | `AppLayout.vue:2575` |
| `DesignChatDialog @close` | `AppLayout.vue:2603` |
| `AgentChatView @close` | `AppLayout.vue:2690` |
| `KanbanView @close-chat` | `AppLayout.vue:2547` |

It does:

```ts
workspacesStore.setActiveTask(null)      // :1471
navigationStore.clearActiveChat()        // :1472
…
router.replace({ path: '/app', query })  // :1514  back to the bare board URL
```

Under tab mode that `router.replace` is **wrong** for the new shape: it rewrites
the *chat tab's* target to the bare board key, the funnel then finds the existing
board tab (`findExisting` → `tabs.ts:216-227`), re-keys + activates it, and
leaves the chat tab behind as an orphaned stale pointer. Task 3 adds an
item-type-guarded early branch so kanban closes the tab instead.

**Adjacent pre-existing bug (out of scope, flag it):** agent items already give
their task chat its own tab key (`'agent'` is not in `DIALOG_ITEM_TYPES`), and
`AgentChatView`'s ✕ already goes through this same `router.replace` — so the
orphan-tab behaviour is live for agent items today. Fixing it is a two-line
generalisation of Task 3, but it is **not** this card's scope. Note it in the PR
description as a follow-up rather than changing agent behaviour silently.

### 3.4 The funnel (unchanged by this plan, listed for orientation)

| Step | Where |
|---|---|
| `watch(() => route.fullPath)` → `syncFromRoute` | `AppLayout.vue:2357-2362`, `:2292-2302` |
| item type resolved only when it describes the URL's item | `AppLayout.vue:2297-2299` |
| `tabsStore.syncFromTarget(path, query, itemType)` | `stores/tabs.ts:424-468` |
| `?tab=` adoption → `findExisting` → `open()` (create + `insertAfterActive` + activate) | `tabs.ts:447-467`, `:244-263`, `:163-172` |
| URL normalisation with `tab=<id>` | `AppLayout.vue:2301` |
| store mirror for a tab click | `mirrorTargetIntoStores` `:2252-2271`, `applyActiveTabToUrl` `:2274-2281` |
| tab strip × → `tabsStore.close` + `applyActiveTabToUrl` | `TabBar.vue`, `AppLayout.vue:2328-2331` |

Note that **the tab strip's × already closes a chat tab correctly today**:
`applyActiveTabToUrl` → `mirrorTargetIntoStores` re-reads the new active tab's
`itemId` and calls `setActiveTask(parsed.chatTaskId)` (`:2259`), which clears
`activeTask` for the bare board URL and re-renders `KanbanView`. Task 3 only adds
the *in-chat* ✕ path.

---

## 4. Target behaviour

| Action | Result |
|---|---|
| Click a kanban card | The task's chat gets **its own tab**, inserted right after the board tab, and is activated. The board tab stays open. |
| Click the board tab | Board (`KanbanView`). |
| Click the chat tab | Chat, history + in-flight stream resumed. |
| ✕ in the chat header, or the strip's × | That chat tab **closes**; the strip activates the board tab (its left neighbour). |
| Reload with the chat tab active | Both tabs restored; the chat tab re-renders the chat. |
| Open two cards | Two chat tabs, one per task. |
| Tab mode off | The chat replaces the board (one view), still with its header + ✕. No modal anywhere. |

---

## 5. Global constraints

- **Never touch port 8081.** A `nalar` instance already runs there
  (`src/apps/desktop/vite.config.ts:44-45` proxies to it). Manual checks use
  `pnpm dev` (5173) or the Vitest/jsdom suite. Never `nohup` a binary + `curl`.
- **No backend change.** No Zig, no SQL, no HTTP route, no wire payload. `tab` is
  client-only. Therefore **no python functional harness work** is warranted — the
  gates are Vitest + `pnpm run build` (vue-tsc) + lint + the manual checklist.
- **Do not touch design or agent branches** beyond deleting the kanban modal
  mount. `DesignChatDialog` and `AgentChatView` keep their current wiring.
- **`handleCloseTaskView` stays shared.** Any new branch inside it must be
  item-type-guarded so design + agent are unaffected.
- **Esc-to-close disappears** with the modal (the modal owned that key handler at
  `KanbanChatDialog.vue:82-87,123`). Esc is not a tab-strip idiom; nothing
  replaces it. Note it as a deliberate, documented loss.
- **No `// NEW (plan: …)` comments.** Explain *why*, never *when*.
- `vue-tsc` can emit stray `.js` next to `.ts`; delete before committing.
- **Baseline first.** Record `pnpm --dir src/apps/desktop test` output before the
  first edit (this repo carries pre-existing failures).

---

## 6. Tasks

### Task 1 — Tab identity: a kanban task chat gets its own key

The headline change. One line of behaviour.

- [ ] **1.1** In `src/apps/desktop/src/helpers/tabTarget.ts`:
  - drop `'kanban'` from `DIALOG_ITEM_TYPES` (`:189`) → `['design', 'kanban-settings']`
  - rewrite the comments at `:148-155`, `:173-178` and the
    `taskChatRendersInItemTab` doc at `:184-188`: kanban renders its chat as its
    own view, so the chat URL is its own tab; design still renders a dialog
    inside the canvas view and keeps one tab.
- [ ] **1.2** Verify `tabKeyVariants` (`:202-214`). With kanban out of the
  whitelist, a kanban chat URL keys as `…:chat:<taskId>` **regardless of the
  known item type**, so the known/unknown pair collapses to one variant. Add an
  explicit unit test (no duplicate on cold boot).
- [ ] **1.3** Confirm `TabBar.titleOf` (`:73-99`) now names the tab after the
  task. No code change expected — add a test rather than assume.
- [ ] **1.4** Do **not** rename `DIALOG_ITEM_TYPES` here (the `'kanban-settings'`
  member is inert because the function is only called with item types) — note it
  as optional cleanup so the diff stays reviewable.

**Acceptance:** `tabKeyOf('/app', {view:'workspace',workspaceId:'ws_1',itemId:'item_7/chat/task_9'}, 'kanban') === 'ws:ws_1:item_7:chat:task_9'`, and the bare board URL still keys `ws:ws_1:item_7`.

### Task 2 — Convert the kanban chat from modal to a render-chain view

The absorbed work from the dropped card (§2). Without this, Task 1 produces a tab
whose body is an empty board.

- [ ] **2.1** In `AppLayout.vue`, add a `v-else-if` branch **immediately before**
  the `KanbanView` branch (`:2528`) — before, or the board wins the chain:

  ```vue
  <ChatView
    v-else-if="
      activeWorkspaceItem &&
      activeWorkspaceItem.item_type === 'kanban' &&
      activeTask &&
      activeTaskWorkspaceItemId === activeWorkspaceItem.id
    "
    :key="'kanban-chat-' + activeTask.id"
    :chat-id="activeTask.id"
    :chat-name="activeTask.name"
    :type="'task'"
    :cwd="effectiveChatCwd"
    :show-header="true"
    @update-chat-id="handleUpdateChatId"
    @close="handleCloseTaskView"
  />
  ```
  - `:key` forces a fresh mount per task → preserves `useChatScrollRestore`'s
    per-session scroll contract when switching cards (same pattern the modal used,
    `KanbanChatDialog.vue:247`).
  - `:chat-id="activeTask.id"` matches the modal (`KanbanChatDialog.vue:248`).
    Migration 052 invariant: `task.id == session.id`. `ChatView` strips a leading
    `chat-` anyway (`ChatView.vue:2739`), so either form works — stay with the
    modal's form to keep behaviour identical.
  - `effectiveChatCwd` is the resolved cwd (`AppLayout.vue:2040-2060`) — the same
    source the modal used.
  - `:show-header="true"` renders `ChatView`'s compact header (`ChatView.vue:3017-3044`):
    chat name + a ✕ that emits `close`. Without it there is **no close affordance
    when tab mode is off**.
- [ ] **2.2** Delete the modal mount (`AppLayout.vue:2549-2576`, the whole
  `<KanbanChatDialog …>` block and its explanatory comment).
- [ ] **2.3** Delete the now-dead open-state machinery: the `kanbanChatDialogOpen`
  ref + its `watch(activeTask)` (`AppLayout.vue:965-983`) and the
  `KanbanChatDialog` import (`:16`).
- [ ] **2.4** Delete `src/apps/desktop/src/components/kanban/KanbanChatDialog.vue`
  and its spec `src/apps/desktop/src/__tests__/KanbanChatDialog.spec.ts`
  (the component no longer exists; do not keep a dead file).
- [ ] **2.5** Update the stale comments that reference the dialog as the kanban
  chat mount: `AppLayout.vue:2544-2560, 2586-2604, 2665-2700`,
  `KanbanView.vue:92-99, 291-300, 1104-1110`, `StandardTaskChatView.vue:11-12`,
  `helpers/tabTarget.ts:184-188`, `MoveToPageDialog.vue`, `DesignChatDialog.vue`
  (comment-only). Grep `KanbanChatDialog` under `src/` must come back empty.
- [ ] **2.6** `AppLayout.createElement.spec.ts` stubs the dialog — update the
  stub to `ChatView` (or drop the stub if the branch is only exercised elsewhere).

**Acceptance:** with `?view=workspace&itemId=item_7/chat/task_9`, the chat renders
as the `<main>` body with **no** board above or below it; with
`itemId=item_7` the board renders. `rg KanbanChatDialog src/` → no hits.

### Task 3 — Close semantics: the in-chat ✕ closes the tab

- [ ] **3.1** In `AppLayout.handleCloseTaskView` (`:1460`), add an early branch
  **before** everything else, guarded so design + agent cannot take it:

  ```ts
  const closing = tabsStore.activeTab
  const closingChatTaskId = closing
    ? parseItemIdWithChat(closing.query.itemId ?? '').chatTaskId
    : null
  if (
    tabsStore.enabled &&
    activeWorkspaceItem?.item_type === 'kanban' &&   // kanban only
    closing?.kind === 'workspace' &&
    closingChatTaskId
  ) {
    workspacesStore.setActiveTask(null)
    navigationStore.clearActiveChat()
    tabsStore.close(closing.id)   // activates the right neighbour, else the left
    applyActiveTabToUrl()         // mirrors the new active tab into stores + URL
    return
  }
  ```
  `close()` already picks the right neighbour else the left (`stores/tabs.ts:306-335`)
  and the chat tab is inserted immediately after the board tab
  (`insertAfterActive`, `:163-172`), so the user lands back on the board with no
  bespoke "go back to the board" logic.
- [ ] **3.2** Leave the legacy path below untouched — it is still the design +
  agent + tab-mode-off path (§3.3).
- [ ] **3.3** Last-tab case: **nothing to do**. If the chat tab is the only tab
  (deep link straight to `/chat/<task>`), the existing `close()` invariant opens
  a fresh `home` tab (`stores/tabs.ts:306-335`). Document it as intended.
- [ ] **3.4** Code-comment that `savedSortsParam` (`:1500-1513`) is not
  load-bearing in tab mode (the board tab's stored `query` keeps its `sorts`), but
  leave it for the legacy path.

**Acceptance:** in tab mode, the in-chat ✕ (and the strip's ×) both leave exactly
the board tab active with the bare board URL; no orphan tab remains. Design and
agent closes are byte-for-byte unchanged.

### Task 4 — Documentation

- [ ] **4.1** `docs/tabs.md`
  - identity table `:107-117`: the kanban/design rows split — a kanban task chat
    is now its **own** tab key; design keeps the item's tab.
  - **"A task is a session"** (`:118-130`): rewrite — kanban cards each get a tab;
    design is the only remaining dialog-inside-item type.
  - **"Turning it off"** (`:190-195`): correct the "complete rollback" claim per
    §1.2 — the toggle removes the strip, it no longer restores the modal.
  - re-check the `Files` table (`:211-225`): `KanbanChatDialog.vue` must come out.
- [ ] **4.2** `docs/SPEC.md`
  - `:263` plan table row + `§3.7.7` (`:441-483`): mark the dialog section
    superseded (three-step history: side-by-side pane → modal → own tab) rather
    than rewriting it; add the new behaviour and the removed Esc/backdrop/✕
    affordance table.
- [ ] **4.3** `docs/superpowers/specs/2026-08-06-kanban-chat-as-dialog-design.md`:
  add a `> **Superseded by** …` header pointing at this plan. Do not delete the
  rationale.
- [ ] **4.4** Append an `## Implementation status` section to this plan when the
  work lands (house style — see `2026-09-13-tab-mode-like-a-browser.md:3-7`).

### Task 5 — Tests and gates

- [ ] **5.1** `tabTarget.spec.ts`:
  - `'keys a task chat by its item type, not unconditionally'` (`:59-75`) —
    kanban now yields the **suffixed** key; design/agent/folder unchanged; the
    variant pair collapses for kanban.
  - `'reports which item types keep a task chat inside the item tab'` (`:77-84`)
    — kanban flips `true → false`.
  - `'rebuilds a missing key…'` (`:236-256`) — re-check the kanban case.
- [ ] **5.2** Rewrite `AppLayout.tabs.spec.ts:249-292` from *"keeps one tab when
  opening task chats inside a kanban item"* to *"gives each kanban task chat its
  own tab and returns to the board tab on close"*: three cards → three chat tabs
  + the board tab; in-chat ✕ → board tab active, URL bare.
- [ ] **5.3** Rename `AppLayout.kanbanChatDialog.spec.ts` →
  `AppLayout.kanbanChatTab.spec.ts` and rewrite: the chat is a `<main>` body (not
  teleported), no backdrop, gate still requires
  `activeTaskWorkspaceItemId === activeWorkspaceItem.id`, header shows the task
  name, and the board does not render alongside it (the `v-else-if` chain
  regression guard).
- [ ] **5.4** New: board tab body vs chat tab body (`KanbanView` vs chat) and the
  reload/restore round trip (`?tab=tab_x` naming the chat tab).
- [ ] **5.5** `TabBar.spec.ts`: label for a kanban chat tab is the **task name**
  (glyph stays `▦`).
- [ ] **5.6** Regression sweep — re-run and adjust where they asserted the old
  modal/one-tab rule: `AppLayout.kanban.spec.ts`,
  `AppLayout.standardTaskChat.spec.ts:269` (kanban must still NOT use
  `StandardTaskChatView`), `AppLayout.sortUrlRoundTrip.spec.ts`,
  `AppLayout.chatSuffixRoundTrip.spec.ts`,
  `AppLayout.chatClickUrlOverwrite.spec.ts`, `AppLayout.urlPersist.spec.ts`,
  `AppLayout.designChatDialog.spec.ts`, `AppLayout.simplifyUrl.spec.ts`,
  `AppLayout.chatview.spec.ts`, `tabsStore.spec.ts`, `KanbanCard.spec.ts`,
  `StandardTaskChatView.spec.ts`, `DesignChatDialog.spec.ts`.
- [ ] **5.7** Gates: `pnpm --dir src/apps/desktop test`, `pnpm --dir src/apps/desktop run build`, lint.

---

## 7. Follow-up (explicitly NOT in this plan): `Ctrl/Cmd+click` background open

Still fully specified, so it can be picked up later without re-research.

- `useTaskActions.handleSelectTask` takes **no** argument (`useTaskActions.ts:114-116`),
  which is why a modifier is dropped today. Emit a second payload arg:
  `emit('selectTask', props.task.id, isBackgroundOpenEvent(event))`, with
  `handleSelectTask(event?: MouseEvent)`, and `WorkspaceItemTaskCard.vue:324`
  becomes `@click="handleSelectTask($event)"`.
- Update the pass-through re-emits: `KanbanCard.vue:100`, `KanbanColumn.vue:816`
  (`:103` declaration), `KanbanView.vue:1305` (`:324-325` declaration),
  `AppLayout.vue:2541` + `handleKanbanSelectTask` (`:1811-1813`),
  `Sidebar.vue:1288`/`:1408`.
- Middle click: a `<button>` fires `auxclick` (not `click`) for `button === 1` in
  Chromium. Add `@auxclick.prevent` plus `@mousedown.middle.prevent` to suppress
  the autoscroll cursor.
- `Sidebar.handleSelectTask(taskId, background = false)`: when
  `background && tabsStore.enabled`, call
  `tabsStore.openInBackground({ path: '/app', query, itemType: 'kanban' })` and
  **return** — no `setActiveTask`, no `isNavigatingToTask`, no `router.push`.
  `openInBackground` (`tabs.ts:265-284`) deliberately leaves the URL and
  `activeTabId` alone.
  - Side effect being skipped: `setActiveTask` also fires `markTaskHumanTouched`
    (`stores/workspaces.ts:3399-3406`), clearing the card's notification dot.
    Background open should **not** mark the task human-touched.
  - With `enabled === false`, ignore the flag and run the foreground path.
- Sidebar row variant for consistency: `WorkspaceItemTaskRow.vue:123`.
- `isBackgroundOpenEvent` already exists: `helpers/tabTarget.ts:220-226`.
- **Also here:** generalise the Task 3 close branch from `item_type === 'kanban'`
  to every item type that gives its task chat its own tab, which fixes the
  pre-existing agent orphan-tab bug (§3.3).

---

## 8. Edge cases (each needs a test)

| # | Case | Expected | Covered by |
|---|---|---|---|
| 1 | Card clicked twice | Funnel focuses the existing chat tab (`syncFromTarget:456-463`), no duplicate | 5.2 |
| 2 | Two different cards | Two chat tabs | 5.2 |
| 3 | Deep link straight to `/chat/<task>` (no board tab) | One tab, labelled by the task; closing it opens a fresh home tab | 5.4 |
| 4 | Cold boot, item type unknown | key is already suffixed, so no provisional adoption needed; no duplicate | 5.1 |
| 5 | `?sorts=` present when clicking a card | Sorts ride the chat tab's query; the board tab keeps its own; identity ignores `sorts` (`tabKeyOf` never reads it) | 5.6 |
| 6 | `?tab=` stale / hand-edited | Treated as a fresh navigation and rewritten (`tabs.ts:447-454`) | existing |
| 7 | 50-tab cap | `enforceLimit` evicts oldest non-active (`tabs.ts:154-161`) | existing |
| 8 | **Tab mode off** | Chat replaces the board, header + ✕ present, no strip | 5.3 |
| 9 | Overlay views (`gitfile`/`skill`/`code-editor`) | untouched — `shouldTabify` returns `false` (`tabTarget.ts:229-237`) | existing |
| 10 | Back button after a card click | Card click `push`es, then the funnel `replace`s with `tab=`; Back → board URL → funnel focuses the board tab. No duplicate. | 5.2 |
| 11 | Notification dot on the card | `setActiveTask` still fires → `markTaskHumanTouched`, unchanged | 5.6 |
| 12 | Design item task chat | Unchanged — still a `DesignChatDialog` modal, still one tab | 5.6 |
| 13 | Agent item task chat | Unchanged — its own tab, but its ✕ still uses the legacy URL path (orphan bug noted) | 5.6 |
| 14 | `kanban-settings` page | Unchanged (`ks:<itemId>` key) | existing |
| 15 | Board rendered *with* the chat (chain regression) | Never — the new branch is `v-else-if` before `KanbanView` | 5.3 |
| 16 | Sidebar task row for a kanban item | Same as a card click (shared handler) | 5.6 |

---

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| The new branch is written as `v-if` or placed after `KanbanView` | Board + chat render stacked | Explicit note in §2; regression test 5.3 |
| Deleting the modal removes Esc/backdrop close | Users who learned Esc lose it | Documented in §5 and Task 4; the tab strip's × and the in-chat ✕ remain |
| `handleCloseTaskView` is shared by design + agent | A careless guard changes their behaviour | Guard is item-type-scoped to `kanban` (3.1); 5.6 explicitly re-runs the design + agent specs |
| `AppLayout.createElement.spec.ts` stubs the dialog | Silent test breakage | Called out in 2.6 |
| Tab spam (the concern behind `03780fe2`) | Many chat tabs | Accepted product decision (§1.1); the 50-tab cap + `×` + close-others already bound it |
| Tab-mode-off users lose the modal | Behaviour change without the toggle protecting them | §1.2 documents it; the trade-off is one code path instead of two |
| Test churn in ~14 spec files | Time sink | 5.6 enumerates them up front; the identity flip is one line, most failures will be expectation strings |

---

## 10. Rollback

- **Toggle:** Settings → General → *Browser-style tabs* off removes the strip, but
  the kanban chat then replaces the board instead of opening a modal (§1.2).
- **Commit level:** three independent pieces — the one-line identity change in
  `tabTarget.ts`, the render-chain branch in `AppLayout.vue`, and the close
  branch in `handleCloseTaskView`. Reverting the identity line alone restores the
  one-tab rule; reverting the render-chain branch requires restoring
  `KanbanChatDialog.vue` (a pure `git revert` of Task 2's commits).

---

## 11. Verification (manual, after implementation)

Run `pnpm --dir src/apps/desktop dev` (port **5173** — never 8081), tab mode on:

- [ ] Board tab open → click a card → a **new tab** appears right of the board,
      labelled with the task name, and is active; the board tab is still there.
- [ ] Click the board tab → the board renders; click the chat tab → the chat
      renders with history + stream resume.
- [ ] ✕ in the chat header → the tab closes and the board tab becomes active with
      a bare `?view=workspace&itemId=…` URL.
- [ ] The strip's × on the chat tab → same result.
- [ ] Reload → both tabs restored, chat tab still renders the chat.
- [ ] Click two cards → two chat tabs.
- [ ] Board and chat are never on screen at the same time (chain regression).
- [ ] Settings → General → tabs **off** → clicking a card shows the chat in place
      of the board, with its header + working ✕, and no strip.
- [ ] Design canvas chat and agent chat behave exactly as before this plan.

### Open question for the reviewer (cosmetic, does not block)
**Q1 — the in-chat header.** Default is `ChatView :show-header="true"`, which
shows a second header bar (task name + ✕) directly under the tab strip — mildly
redundant with the tab label, but it is the only close affordance when tab mode is
off. The alternative is `:show-header="false"` (matching `StandardTaskChatView`)
and relying on the tab strip's ×, at the cost of a dead end in tab-off mode. Say
the word and Task 2/3 adjust; the rest of the plan is unaffected.
