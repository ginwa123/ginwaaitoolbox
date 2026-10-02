# Recommendation — chat-row right-click context menu (sidebar RECENT)

**Date:** 2026-10-02 · **Task:** `task_1790946799743_0` · **Status:** recommendation only, nothing implemented

## Where it stands today

`ChatsList.vue:1086-1092` mounts `OpenInNewTabMenu` with **no props**, so the row menu
renders exactly one item — `Open chat in new tab`. That is the menu in the screenshot.

The reference shape to copy is **`KanbanTaskContextMenu.vue`** (8 items, title bar,
separators, submenu, arrow-key nav, red destructive row last). Its ordering rationale is
already written down at `KanbanTaskContextMenu.vue:12-18` and plan §4.1:
*mutations first → submenu in its own group → "open in new tab" → destructive last, red.*

---

## 🔴 Read this before you write any of it — one landmine

**Do not implement Rename as `api.updateSession(sid, { name })`.**

`api/index.ts:1719-1723` unconditionally fills every field:

```ts
body: {
  selected_profile_model: updates.selectedProfile ?? '',   // ← always sent
  name:                    updates.name ?? '',
  is_auto_retry_until_stop: updates.isAutoRetryUntilStop ?? '',
}
```

and the Zig side documents `selected_profile_model` as *"Empty string OR missing key = clear"*
(`session_update.zig:13-14`), calling `updateSessionSelectedProfileModel` **unconditionally**
— *"always — even if empty, to allow clearing"* (`session_update.zig:84`). That function also
bumps `updated_at` (`llm_history.zig:4087`).

So renaming via that path would, in one call:
1. **silently reset the chat's model profile** to the top-level default, and
2. **jump the row to the top of RECENT**, because the sort key just changed.

Same bug hits the unattended toggle. ✅ Use **`api.updateTaskSimple(taskId, { name })`**
→ `PUT /api/workspaces/tasks/:task_id` (`main.zig:876`) → `updateTaskName`
(`llm_history.zig:3816`) → cascades to `updateSessionName`, whose SQL is
`UPDATE sessions SET name = ?` **only** (`llm_history.zig:3784`) — no profile write, no
`updated_at` bump, and it broadcasts `action="updated"` → `session_updated`
(`sse_on_event_send_session.zig:66`) → registered in `additionalEventTypes`
(`api/index.ts:3989`) → `ChatsList` reloads (`ChatsList.vue:790`). Rename repaints correctly.

For any future `updateSession` caller: **pass the current `selectedProfile` back** or you
will clear it.

---

## Tier 0 — ship these, backend already supports them

| # | Item | Wiring | Notes |
|---|---|---|---|
| 1 | **Rename chat** | `RenameTaskModal.vue` (already exists — props `{show, currentName}`, emits `rename(name)`) → `api.updateTaskSimple(item.id, { name })` | Chat row knows only `sessionId`; the id-only task PUT needs nothing more, because `task.id == session_id` (Migration 052) |
| 2 | **Stop agent** | `api.stopSession(item.id)` → `POST /api/llm/session/:session/stop` (`main.zig:543`) | Gate on `processingState[item.id]` — already injected at `ChatsList.vue:87`. ⚠️ Path param is `:session`, **not** `:session_id` |
| 3 | **Mark as reviewed** | `fireSessionTouched(item.id)` — already at `ChatsList.vue:395` | Clears the amber "AI is ahead of you" dot (`ChatsList.vue:1005`). Once-per-lifetime guard makes it a safe no-op on repeat |
| 4 | **Unattended mode** | `api.updateSession(item.id, { isAutoRetryUntilStop, selectedProfile: item.selected_profile_model })` | ⚠️ **Must pass `selectedProfile` back** or you clear it. Note: the always-visible badge was deliberately removed from this list (`ChatsList.vue:764-772`) and relocated to the task-detail dialog — a context-menu row is a softer reversal, but say so explicitly |

**Items 1–3 are one PR and roughly one hour.** Item 3 is the cheapest win on the list and
nothing currently surfaces it.

## Tier 1 — fix the backend first, then add the item

| # | Item | The blocker |
|---|---|---|
| 5 | **Delete chat** | **Already broken.** `ChatsList.removeChat` splices the row optimistically then calls `api.deleteChat` → `DELETE /api/chats/:id` (`api/index.ts:1941`). **That route does not exist** — `rg '/chats' src/main.zig` returns nothing. The error is swallowed by a `catch` + `console.error`, so the row vanishes and **reappears on reload**. Shipping a Delete menu item without fixing this ships a lie. Working delete is task-scoped: `DELETE /api/workspaces/:ws/items/:item/tasks/:task_id` — needs `wsId` + `itemId`, which the chat row doesn't carry; resolve via `api.getSessionWorkspaceId` or emit up to `Sidebar.vue:1029`. Gate behind the existing `ConfirmDialog.vue` |
| 6 | **Pin chat** | `is_pinned` exists **only** on `workspace_item_tasks` — there is no `sessions.is_pinned` column. Because `task.id == session_id` the task-pin endpoint would technically work, but the sidebar list is sorted by `sessions.updated_at`, so nothing would visibly change. Needs a column + list sort, or it's a decorative toggle |

## Tier 2 — genuine backend work, not menu work

Don't scope these into the menu PR; each is its own feature.

- **Archive** — zero occurrences anywhere. No column, handler, or route.
- **Export transcript** (markdown/JSON) — no export path. `/api/files/download` downloads repo files, not conversations.
- **Duplicate / Fork** — no copy-session endpoint. `parent_session_id` only *describes* a sub-agent that already exists.
- **Move to project** — `sessions.workspace_id` **is never written**. A repo-wide `UPDATE sessions SET` sweep touches only `cwd`, `user_id`, `status`, `name`, `is_auto_retry_until_stop`, `selected_profile_model`, `sub_agent_name`, `git_worktree_cwd`, `pr_url`, `last_human_touched_at_nano`. Membership is *derived at read time* by `workspace_scope.resolveWorkspaceId`. This one looks cheap on the wire and is the most expensive to build.

---

## Two things to do regardless of which items you pick

**1. Keyboard parity.** `ChatsList.vue:971` binds `@contextmenu.prevent` only — there is no
`ContextMenu` / `Shift+F10` path, unlike the kanban card (`WorkspaceItemTaskCard.vue:172`).
Reuse `clampToViewport` from `useContextMenu` to anchor at the row's bounding-rect centre.
`docs/plans/2026-09-29-sidebar-three-menus.md` T5 already schedules this.

**2. Check the plan before you build.** `docs/plans/2026-09-29-sidebar-three-menus.md` (task
`task_1790616057649_4`) already plans to move sidebar **pin / rename / delete into this exact
context menu** and add `Shift F10`. T1+T2 are done; T3-T13 are not. Caveat: the human
approved only **D12-D17** (spacing & type) — **D1-D11, including the D5 decision that schedules
the move, is explicitly *not* signed off**. Reconcile before duplicating.

---

## Implementation notes

- **Extend `OpenInNewTabMenu`, don't hand-roll — *if* you keep it small.** It already has
  `showStop`, `showSettings` etc. as opt-in props. Rename/delete/unattended are new rows.
  This is the cheap path and it costs zero CSS.
- **Build a new `ChatRowContextMenu.vue` (mirroring `KanbanTaskContextMenu`) if you want a
  title bar + submenu + arrow keys.** Note `menu-row` / `menu-ic` / `menu-sep` are defined in a
  `<style scoped>` block inside `KanbanTaskContextMenu.vue:451-520` and **cannot be reused**
  from another component — a new menu must duplicate that CSS or lift it to a global sheet.
- **The teleported menu root must carry `data-context-menu`.** Without it, `useContextMenu`'s
  mousedown handler (`useContextMenu.ts:73`) closes the menu on the very click that picks an
  item. `GitBranchMenu.vue` has this bug today; only works because each item closes itself.
- **Spec guardrail.** `__tests__/ChatsList.contextMenu.spec.ts:63` asserts
  `[data-testid="open-new-tab-item"]` still exists and still contains `Open chat in new tab`,
  and `:68` asserts `window.open` is called **exactly once**. It finds its row via
  `findAll('button').find(b => b.text().includes('Hello'))` — a text match over all buttons.
  Any new in-row button containing "Hello" breaks the selector. Keep item count/order free —
  the spec doesn't assert them — but keep that testid and that label.

---

## Suggested order

1. **Stop agent** + **Mark as reviewed** — 20 min, zero risk, both already-wired endpoints.
2. **Rename chat** — the most-used mutation; must use `updateTaskSimple`, not `updateSession`.
3. **Fix `deleteChat`, then add Delete** — a live bug, not a menu feature.
4. Keyboard path + title bar, as cleanup.
5. Everything in Tier 2 as separate features.