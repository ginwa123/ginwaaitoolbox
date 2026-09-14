# Kanban task opens its OWN tab (in-app, browser-style)

> **Status: APPROVED IN PRINCIPLE — plan only, not executed.** The user confirmed
> the in-app browser-style tab strip (not an OS window) and narrowed the goal to
> one sentence: *"when click the kanban task, it will open a new tab, in app"*.
> Everything optional has been cut from this revision.
> Awaiting the go-ahead at `in_review_planning`.

> **For agentic workers:** this is a *planning* artefact. Before implementing, use
> subagent-driven-development / executing-plans. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** Clicking a kanban task card opens that task's chat in **its own tab** in
the tab strip, activated, with the board tab left open beside it — instead of the
chat appearing as a modal dialog today, and instead of the chat *replacing* the
board inside the board's single tab (the state of the in-flight sibling PR).

Generated 2026-09-14 against `main` @ `63f92209`.

---

## 1. Decisions (locked)

| Decision | Value | Why |
|---|---|---|
| "New tab" means | **In-app browser-style tab strip** (`docs/tabs.md`, PR #476) | User confirmed. The screenshot the user attached shows the strip with a chat tab (`💬 execution-order-priority-t…`) — the target look. |
| The board tab stays open | **Yes** — a card click *adds* a tab, it does not replace the board tab | "open a new tab" next to the board is the whole point. |
| Design items | **Out of scope** — `DesignChatDialog` stays | The user asked for kanban; the design chat is opened by a canvas header button + an FK-driven auto-open, not a per-card click. Different plan. |
| `Ctrl/Cmd+click` / middle-click background open | **Out of scope** — follow-up (see §7) | User narrowed the goal to the plain click. Fully specified in §7 so it can be picked up later without re-research. |
| Closing a chat tab when it is the LAST tab | **Browser-like**: `tabs.close()` already falls back to a fresh home tab | User's answer: "browser like maybe". No bespoke fallback logic. |
| Sidebar task rows for a kanban item | **Behave identically** — not special-cased | They go through the same `Sidebar.handleSelectTask`, so they inherit the behaviour for free. Consistent by construction. |

### 1.1 This deliberately reverses commit `03780fe2`

`fix(tabs): one tab per kanban/design item — task-chat identity is item-type
aware` introduced the rule we are now removing, on the rationale *"kanban/design
open it as a dialog inside the item's view (one tab, however many cards you
open)"*. That rationale is now obsolete for kanban: the user **wants** the one
tab per card. Design keeps it. The regression test that locks the old rule
(`AppLayout.tabs.spec.ts:249-292`) must be rewritten, not deleted — it becomes
the test for the new rule.

---

## 2. Hard dependency: the sibling PR must land first

The chat body has to be a *view* before it can be a tab. On `main` today the
kanban task chat is still a Teleport modal:

| Fact | Where |
|---|---|
| `KanbanChatDialog` is a `<Teleport to="body">` modal with a backdrop | `components/kanban/KanbanChatDialog.vue:105,119,132-137` |
| Mounted standalone (`v-if`, **not** `v-else-if`) so it overlays the board | `AppLayout.vue:2562-2576` |
| `show` driven by an `activeTask` watcher | `AppLayout.vue:976-983` |

A modal cannot be the body of a tab. The sibling card
**`task_1789299739085_0` — "make KanbanChatdialog not a dialog, so refactore to
KanbanChat"** (branch
`worktree/make-kanbanchatdialog-not-a-dialog-so-refactore-to-1789299728209`,
commit `5f516224`, currently `in_review_task`) already deletes the modal and
adds an inline `components/kanban/KanbanChat.vue`, mounted **`v-else-if` before
`KanbanView`** in the `<main>` render chain.

**That is exactly the shape this plan needs:**

| URL | Render chain result | Tab |
|---|---|---|
| `?view=workspace&itemId=item_7` | `KanbanView` (board) | `ws:…:item_7` |
| `?view=workspace&itemId=item_7/chat/task_9` | `KanbanChat` (task chat) | `ws:…:item_7:chat:task_9` |

Two tabs, two different bodies, both driven by the same `activeTask` gate the
sibling PR already wired.

**Sequencing rule:** this plan is **stacked on `5f516224`**. Implement it on a
branch based on that commit (or rebase onto `main` once the sibling PR merges).
Verify first with:
```bash
git log --oneline main..worktree/make-kanbanchatdialog-not-a-dialog-so-refactore-to-1789299728209
git show worktree/make-kanbanchatdialog-not-a-dialog-so-refactore-to-1789299728209:src/apps/desktop/src/components/kanban/KanbanChat.vue | head -n 40
```
If the sibling PR is rejected or lands with a different architecture, **stop and
re-plan** — do not resurrect the modal.

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
(`AppLayout.vue:2292-2302` → `stores/tabs.ts:424-468`). The foreground "open a
new tab" behaviour needs **zero** new JavaScript on the click path — only the
identity change in Task 1.

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

### 3.3 Close semantics today

`AppLayout.handleCloseTaskView` (`:1460-1515`) runs on ✕ / backdrop / Esc:

```ts
workspacesStore.setActiveTask(null)      // :1471
navigationStore.clearActiveChat()        // :1472
…
router.replace({ path: '/app', query })  // :1514  back to the bare board URL
```

Under tab mode this is **wrong** for the new shape: `router.replace` rewrites the
*chat tab's* target to the bare board key, and the funnel then finds the existing
board tab (`findExisting` → `tabs.ts:216-227`), re-keys/activates it and leaves
the chat tab orphaned as a stale pointer. This is the single real bug this plan
must fix (Task 3).

### 3.4 The funnel (unchanged by this plan, listed for orientation)

| Step | Where |
|---|---|
| `watch(() => route.fullPath)` → `syncFromRoute` | `AppLayout.vue:2357-2362`, `:2292-2302` |
| item type resolved only when it describes the URL's item | `AppLayout.vue:2297-2299` |
| `tabsStore.syncFromTarget(path, query, itemType)` | `stores/tabs.ts:424-468` |
| `?tab=` adoption → `findExisting` → `open()` (create + `insertAfterActive` + activate) | `tabs.ts:447-467`, `:244-263`, `:163-172` |
| URL normalisation with `tab=<id>` | `AppLayout.vue:2301` |
| store mirror for a tab click | `mirrorTargetIntoStores` `:2252-2271`, `applyActiveTabToUrl` `:2274-2281` |

---

## 4. Target behaviour

| Action | Result |
|---|---|
| Click a kanban card | The task's chat gets **its own tab**, inserted right after the board tab, and is activated. The board tab stays open. |
| Click the board tab | Board (`KanbanView`). |
| Click the chat tab | Chat (`KanbanChat`), history + stream resumed. |
| Click ✕ in `KanbanChat`'s header | That chat tab **closes**; the strip activates the board tab (its left neighbour). |
| Reload with the chat tab active | Both tabs restored; the chat tab re-renders the chat. |
| Open two cards | Two chat tabs, one per task. |
| Tab mode off (Settings → General) | Unchanged: the inline chat replaces the board in the single view (post sibling PR). |

---

## 5. Global constraints

- **Never touch port 8081.** A `nalar` instance already runs there
  (`src/apps/desktop/vite.config.ts:44-45` proxies to it). Manual checks use
  `pnpm dev` (5173) or the Vitest/jsdom suite. Never `nohup` a binary + `curl`.
- **No backend change.** No Zig, no SQL, no HTTP route, no wire payload. `tab` is
  client-only. Therefore **no python functional harness work** is warranted — the
  gates are Vitest + `pnpm run build` (vue-tsc) + lint + the manual checklist.
- **`enabled === false` must stay a byte-for-byte rollback.** Every new branch
  reads `tabsStore.enabled` and falls through to today's code path.
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
  - rewrite the comment block at `:148-155` and `:173-178` and the
    `taskChatRendersInItemTab` doc at `:184-188`: kanban renders its chat as its
    own view, so the chat URL is its own tab; design still renders a dialog
    inside the canvas view and keeps one tab.
- [ ] **1.2** Verify `tabKeyVariants` (`:202-214`) still behaves. With kanban out
  of the whitelist, a kanban chat URL keys as `…:chat:<taskId>` **regardless of
  the known item type**, so the known/unknown pair collapses to a single variant.
  Add an explicit unit test for that (no duplicate on cold boot).
- [ ] **1.3** Confirm `TabBar.titleOf` (`:73-99`) now names the tab after the
  task. No code change expected — add a test rather than assume.
- [ ] **1.4** Do **not** rename `DIALOG_ITEM_TYPES` in this plan (the
  `'kanban-settings'` member is inert because the function is only ever called
  with item types) — note it as optional cleanup so the diff stays reviewable.

**Acceptance:** `tabKeyOf('/app', {view:'workspace',workspaceId:'ws_1',itemId:'item_7/chat/task_9'}, 'kanban') === 'ws:ws_1:item_7:chat:task_9'`, and the bare board URL still keys `ws:ws_1:item_7`.

### Task 2 — Render chain: two tabs, two bodies

- [ ] **2.1** Rebase/stack onto the sibling commit (§2). Confirm the
  `KanbanChat` branch is `v-else-if` and **before** `KanbanView`
  (`AppLayout.vue`, `main` chain around `:2528`).
- [ ] **2.2** No production change expected — the gate
  (`item_type === 'kanban' && activeTask && activeTaskWorkspaceItemId === activeWorkspaceItem.id`)
  already distinguishes "chat tab" (URL carries `/chat/<task>`, so `activeTask`
  is set by `mirrorTargetIntoStores:2259`) from "board tab" (no suffix, so
  `setActiveTask(undefined)` clears it at `:2259`).
- [ ] **2.3** Test: with tabs on, navigate board URL → chat URL; assert
  `tabs.tabCount === 3` (home + board + chat), `activeTab.key === 'ws:ws_1:item_7:chat:task_9'`,
  `KanbanChat` rendered; then `tabs.activate(boardTabId)` + `applyActiveTabToUrl`
  and assert `KanbanView` is rendered and `KanbanChat` is not.

**Acceptance:** activating either tab renders exactly the right body, and neither
action creates a third tab.

### Task 3 — Close semantics: closing the chat closes its tab (the real bug fix)

- [ ] **3.1** In `AppLayout.handleCloseTaskView` (`:1460-1515`), add an early
  branch **before** the existing `router.replace`:

  ```ts
  const closing = tabsStore.activeTab
  const closingChatTaskId = closing
    ? parseItemIdWithChat(closing.query.itemId ?? '').chatTaskId
    : null
  if (tabsStore.enabled && closing && closing.kind === 'workspace' && closingChatTaskId) {
    workspacesStore.setActiveTask(null)
    navigationStore.clearActiveChat()
    tabsStore.close(closing.id)      // activates the right neighbour, else the left
    applyActiveTabToUrl()            // mirrors the new active tab into stores + URL
    return
  }
  ```
  `close()` already picks the right neighbour else the left (`stores/tabs.ts:306-335`)
  and the chat tab is inserted immediately after the board tab
  (`insertAfterActive`, `:163-172`), so the user lands back on the board — the
  intended outcome, with no bespoke "go back to the board" logic.
- [ ] **3.2** Keep the legacy path below untouched for `enabled === false`.
- [ ] **3.3** Last-tab case: **nothing to do** — if the chat tab is the only tab
  (deep link straight to `/chat/<task>` with no board tab open), the existing
  `close()` invariant opens a fresh `home` tab (`stores/tabs.ts:306-335`).
  Document it in the code comment as the intended browser-like fallback.
- [ ] **3.4** Note in the code comment that `savedSortsParam` (`:1500-1513`) is no
  longer load-bearing in tab mode (the board tab's stored `query` keeps its
  `sorts`), but leave it for the non-tab path.

**Acceptance:** in tab mode, ✕ on a chat tab leaves exactly the board tab active
with the bare board URL; no orphan tab remains.

### Task 4 — Documentation

- [ ] **4.1** `docs/tabs.md`
  - identity table `:107-117`: the kanban/design rows split — a kanban task chat
    is now its **own** tab key; design keeps the item's tab.
  - **"A task is a session"** (`:118-130`): rewrite — kanban cards each get a
    tab; design is the only remaining dialog-inside-item type.
  - re-check the `Files` table (`:211-225`) — no new files expected.
- [ ] **4.2** `docs/SPEC.md`
  - `:263` plan table row + `§3.7.7` (`:441-483`): mark the dialog section
    superseded (two-step history: modal → inline view → own tab) rather than
    rewriting it; add the new behaviour.
- [ ] **4.3** `docs/superpowers/specs/2026-08-06-kanban-chat-as-dialog-design.md`:
  add a one-line `> **Superseded by** …` header pointing at this plan and the
  sibling `KanbanChat` refactor. Do not delete the rationale.
- [ ] **4.4** Append an `## Implementation status` section to this plan when the
  work lands (house style — see `2026-09-13-tab-mode-like-a-browser.md:3-7`).

### Task 5 — Tests and gates

- [ ] **5.1** Update `src/apps/desktop/src/__tests__/tabTarget.spec.ts`:
  - `'keys a task chat by its item type, not unconditionally'` (`:59-75`) —
    kanban now yields the **suffixed** key; design unchanged; agent/folder
    unchanged; the variant pair collapses for kanban.
  - `'reports which item types keep a task chat inside the item tab'` (`:77-84`)
    — kanban flips `true → false`.
  - `'rebuilds a missing key…'` (`:236-256`) — re-check the kanban case.
- [ ] **5.2** Rewrite `AppLayout.tabs.spec.ts:249-292` from *"keeps one tab when
  opening task chats inside a kanban item"* to *"gives each kanban task chat its
  own tab and returns to the board tab on close"*: three cards → three chat tabs
  + the board tab; ✕ on a chat tab → board tab active, URL bare.
- [ ] **5.3** New spec `AppLayout.kanbanTaskTab.spec.ts` (or fold into 5.2):
  board tab body vs chat tab body (`KanbanView` vs `KanbanChat`), and the
  reload/restore round trip (`?tab=tab_x` naming the chat tab).
- [ ] **5.4** `TabBar.spec.ts`: label for a kanban chat tab is the **task name**
  (and the glyph stays `▦`).
- [ ] **5.5** Regression sweep — these existing specs touch the changed gate and
  must be re-run and adjusted where they asserted the old rule:
  `AppLayout.kanbanChat.spec.ts` (the renamed sibling spec),
  `AppLayout.standardTaskChat.spec.ts:269` (kanban must still NOT use
  `StandardTaskChatView` — it uses `KanbanChat`),
  `AppLayout.sortUrlRoundTrip.spec.ts`, `AppLayout.chatSuffixRoundTrip.spec.ts`,
  `AppLayout.chatClickUrlOverwrite.spec.ts`, `AppLayout.urlPersist.spec.ts`,
  `AppLayout.designChatDialog.spec.ts`, `AppLayout.simplifyUrl.spec.ts`,
  `tabsStore.spec.ts`, `KanbanCard.spec.ts`.
  (`AppLayout.kanban.spec.ts:222-510` is already stale w.r.t. the dialog per the
  sibling PR — do not "fix" it beyond what the sibling PR did.)
- [ ] **5.6** Gates: `pnpm --dir src/apps/desktop test`, `pnpm --dir src/apps/desktop run build`, lint.

---

## 7. Follow-up (explicitly NOT in this plan): `Ctrl/Cmd+click` background open

Still fully specified, so it can be picked up later without re-research. It is
separable because the headline feature (§6) works without it.

- `useTaskActions.handleSelectTask` currently takes **no** argument
  (`useTaskActions.ts:114-116`), which is why a modifier is dropped today. Emit a
  second payload arg: `emit('selectTask', props.task.id, isBackgroundOpenEvent(event))`,
  with `handleSelectTask(event?: MouseEvent)`, and
  `WorkspaceItemTaskCard.vue:324` becomes `@click="handleSelectTask($event)"`.
- Update the four pass-through re-emits: `KanbanCard.vue:100`,
  `KanbanColumn.vue:816` (`:103` declaration), `KanbanView.vue:1305`
  (`:324-325` declaration), `AppLayout.vue:2541` + `handleKanbanSelectTask`
  (`:1811-1813`), `Sidebar.vue:1288`/`:1408`.
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

---

## 8. Edge cases (each needs a test)

| # | Case | Expected | Covered by |
|---|---|---|---|
| 1 | Card clicked twice | Funnel focuses the existing chat tab (`syncFromTarget:456-463`), no duplicate | 5.2 |
| 2 | Two different cards | Two chat tabs | 5.2 |
| 3 | Deep link straight to `/chat/<task>` (no board tab) | One tab, labelled by the task; closing it opens a fresh home tab | 5.3 |
| 4 | Cold boot, item type unknown | key is already suffixed, so no provisional adoption needed; no duplicate | 5.1 |
| 5 | `?sorts=` present when clicking a card | Sorts ride the chat tab's query; the board tab keeps its own; identity ignores `sorts` (`tabKeyOf` never reads it) | 5.5 |
| 6 | `?tab=` stale / hand-edited | Treated as a fresh navigation and rewritten (`tabs.ts:447-454`) | existing |
| 7 | 50-tab cap | `enforceLimit` evicts oldest non-active (`tabs.ts:154-161`) | existing |
| 8 | Tab mode off | byte-for-byte today's behaviour (inline chat replacing the board) | 5.2 |
| 9 | Overlay views (`gitfile`/`skill`/`code-editor`) | untouched — `shouldTabify` returns `false` (`tabTarget.ts:229-237`) | existing |
| 10 | Back button after a card click | Card click `push`es, then the funnel `replace`s with `tab=`; Back → board URL → funnel focuses the board tab. No duplicate. | 5.2 |
| 11 | Notification dot on the card | Foreground open still calls `setActiveTask` → `markTaskHumanTouched`, unchanged from today | 5.5 |
| 12 | Design item task chat | Unchanged — still a `DesignChatDialog`, still one tab | 5.5 |
| 13 | `kanban-settings` page | Unchanged (`ks:<itemId>` key) | existing |
| 14 | Sidebar task row for a kanban item | Same as a card click (shared handler) | 5.5 |

---

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Sibling PR (#KanbanChat) is not merged or changes shape | This plan cannot land as written | §2 sequencing rule: stop and re-plan; a modal cannot be a tab body |
| `handleCloseTaskView` is called from other paths than the header ✕ | A tab could be closed unexpectedly | It is wired only from `KanbanChat`'s `@close` (sibling PR) and the former dialog's close paths; 5.5 sweep + the explicit `enabled`/`kind`/`chatTaskId` triple guard in 3.1 |
| Two tabs rendering the *same* board | Confusing strip | `tabKeyOf` for the bare URL is unchanged, so the board key can never collide with a chat key; test in 5.3 |
| Tab spam (the concern behind `03780fe2`) | Many chat tabs | Accepted product decision (§1.1); the 50-tab cap + `×` + close-others already bound it |
| Test churn in ~10 spec files | Time sink | 5.5 enumerates them up front; the identity flip is one line, most failures will be expectation strings |

---

## 10. Rollback

- **Feature level:** Settings → General → *Browser-style tabs* off → the strip is
  not rendered, the funnel no-ops, and the app behaves exactly as after the
  sibling PR (inline chat replacing the board). Nothing else to undo.
- **Commit level:** the identity change is one line in `tabTarget.ts` plus the
  `handleCloseTaskView` branch. Reverting those two restores the one-tab rule.

---

## 11. Verification (manual, after implementation)

Run `pnpm --dir src/apps/desktop dev` (port **5173** — never 8081), tab mode on:

- [ ] Board tab open → click a card → a **new tab** appears right of the board,
      labelled with the task name, and is active; the board tab is still there.
- [ ] Click the board tab → the board renders; click the chat tab → the chat
      renders with history + stream resume.
- [ ] ✕ in the chat header → the tab closes and the board tab becomes active
      with a bare `?view=workspace&itemId=…` URL.
- [ ] Reload → both tabs restored, chat tab still renders the chat.
- [ ] Click two cards → two chat tabs.
- [ ] Settings → General → tabs **off** → clicking a card behaves as before this
      plan (chat replaces the board, no strip).
