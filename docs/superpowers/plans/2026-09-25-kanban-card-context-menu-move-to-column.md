# Kanban card → right-click context menu (+ "Move to column")

**Status:** plan — awaiting human review
**Date:** 2026-09-25
**Task:** `task_1790439398272_10` (kanban `AGENTIC_KANBAN`)
**Wireframe:** [`docs/plans/2026-09-25-kanban-card-context-menu-wireframe.html`](../../plans/2026-09-25-kanban-card-context-menu-wireframe.html)

---

## 1. Problem

The kanban card renders a strip of four hover action buttons in the top row
(`WorkspaceItemTaskCard.vue`):

| # | Icon | Test id | Handler | Lines |
|---|------|---------|---------|-------|
| 1 | 📌 pin | `task-pin-toggle` | `handlePinToggle` | ~640–670 |
| 2 | ✏️ rename | *(none)* | `handleRenameTask` | ~671–687 |
| 3 | ⓘ details | `view-task-detail-btn` | `handleViewTaskDetail` | ~688–705 |
| 4 | ✕ delete | *(none)* | `handleDeleteTask` | ~706–722 |

Problems:

1. **Layout theft.** Four 24px buttons eat ~100px of a 280px-wide column
   (`KanbanColumn.vue` hard-codes `width: 280px`). The task name — the one
   thing the card exists to communicate — truncates to ~150px on most boards.
   The user's screenshot shows exactly this: `"gitlab supp..."`.
2. **Visual noise.** The buttons paint over the card on every hover,
   including during a drag (they sit under the drag ghost).
3. **No discoverability for the common action.** Moving a card between
   columns is only possible via drag-and-drop. There is no menu path, so it
   is unusable on touch/stylus, and invisible to anyone who doesn't know the
   gesture.
4. **Delete is one stray click from a card.** No confirmation step at the
   button level; the delete button sits at the far right, exactly where a
   mis-aimed click lands.

The card **already has** a right-click context menu
(`@contextmenu.prevent` → `useContextMenu` → `OpenInNewTabMenu`) that only
offers "Open chat in new tab", "Open details in new tab", and "Stop agent".
The fix is to make that menu the real action surface and delete the button
strip.

## 2. Goals / non-goals

### Goals

- G1. Remove the four hover buttons from the kanban card; recover the
  horizontal space for the task name.
- G2. Move every action the buttons performed (pin, rename, details,
  delete) into the right-click context menu, plus the two actions the menu
  already had.
- G3. **New feature: "Move to column"** — move the task to any other column
  on the same board without drag-and-drop.
- G4. Keep keyboard users served (card stays `role="button"` + `Enter`/`Space`),
  and add a `ContextMenu` key / long-press route so the menu is not
  mouse-only.
- G5. Keep sidebar rows (`WorkspaceItemTaskRow.vue`) unchanged in this pass —
  the screenshot is the kanban card; the sidebar is a denser list where the
  strip is less costly. See §8 for the follow-up.

### Non-goals

- Reordering *within* a column from the menu (position is always "append to
  end"). Drag-and-drop already covers intra-column reordering.
- Moving a task to a board other than its own.
- Backend changes. `POST .../move` already exists and is exercised by the
  drag-and-drop path.

## 3. Existing wiring (what we reuse)

```
WorkspaceItemTaskCard.vue          (owns the menu state)
  └─ emits: renameTask / deleteTask / pinTask / viewTaskDetail
       (already declared — no new emits needed for those 4)
  └─ emits: moveTaskToColumn  ← NEW (only for G3)
       │
       KanbanCard.vue               (re-emits verbatim)
       │
       KanbanColumn.vue             (re-emits verbatim + resolves append position)
       │
       KanbanView.vue               (:columns="sortedColumns"  — L479
       │                            already computed, sorted by position)
       │   emits: moveTask  →  re-emitted as an existing event shape
       ▼
       AppLayout.vue  handleKanbanMoveTask (L2032)  — ALREADY EXISTS
       │
       ▼
       workspacesStore.moveTaskToColumn(ws, item, taskId, columnId, position)
       │                            (workspaces.ts L2177)
       ▼
       api.moveTask(...)            → backend PATCH, re-numbers siblings
       │
       ▼
       kanbanSse.ts                 → `kanban_task` SSE event → mirrorKanbanTaskMove
                                      (this is what keeps a second browser tab
                                       in sync — already implemented, no work)
```

**Key finding: the entire move pipeline already exists end-to-end for
drag-and-drop. G3 is a *new input surface*, not a new feature area.** The
only genuinely new code is: the submenu component, the column list threaded
down to the card, and the append-position calculation.

### Existing infrastructure we build on

| Asset | Path | Why it fits |
|---|---|---|
| `useContextMenu()` | `composables/useContextMenu.ts` | Owns `{x,y}`, Esc + outside-mousedown dismiss. Already used by the card. |
| `OpenInNewTabMenu` | `components/shell/OpenInNewTabMenu.vue` | Teleported to `body` so the virtual scroller / column overflow can't clip it. Opt-in items via props. |
| `GitBranchMenu` | `components/shell/GitBranchMenu.vue` | Second example of the teleported-menu pattern, incl. a title header + disabled items. |
| `moveTaskToColumn` | `stores/workspaces.ts` L2177 | POST + optimistic local patch + cache write. |
| `handleKanbanMoveTask` | `AppLayout.vue` L2032 | Already bound to `@move-task` (L2995). |
| `sortedColumns` | `KanbanView.vue` L479 | Column list already sorted by `position`. No new fetch. |
| `KanbanTaskDetail`'s `column-change` | `KanbanTaskDetail.vue` | Precedent for the "columnId" payload shape in create mode. |

## 4. Design

### 4.1 The menu

Right-clicking a card opens a single menu, teleported to `body`, anchored at
the cursor:

```
┌────────────────────────────────┐
│  📌  Pin task                   │
│  ✏️  Rename task                │
│  ⓘ  View details               │
│  ──────────────────────────    │
│  ▸  Move to column          ›  │   ← NEW (G3), submenu
│  ──────────────────────────    │
│  ↗  Open chat in new tab        │   (existing)
│  ↗  Open details in new tab     │   (existing)
│  ■  Stop agent                  │   (existing; only when a worker runs)
│  ──────────────────────────    │
│  ✕  Delete task            ⌫⌫  │   ← moved to the bottom, red
└────────────────────────────────┘
```

Ordering rationale — frequency and reversibility:

1. **Most-used first.** Pin and Rename are the two people reach for daily.
2. **Details** third — it's a navigation action, not a mutation, but it's
   used often enough to stay above the fold.
3. **Move to column** in its own group: it is the headline new capability and
   the only one with a submenu, so it gets a separator above it.
4. **"Open in new tab"** grouped after mutations — this is a lower-frequency
   power-user path.
5. **Delete last**, red, with a `⌫⌫` shortcut hint and a right-hand column
   for shortcuts on the destructive row.

Deliberate: **Delete keeps an explicit confirm step.** Moving a destructive
item to the bottom of a menu (rather than removing it) is a real risk
reduction, but it is not sufficient on its own — see §6.

### 4.2 The "Move to column" submenu

Hovering (or arrowing onto) "Move to column" opens a second, nested panel
offset to the right:

```
┌──────────────────┐   ┌──────────────────────────┐
│  Pin task        │   │  in progress          3 │   ← current column
│  Rename task     │   │  todo                 0 │
│  View details    │   │  in review            2 │
│  ──────────────  │   │  merged             195 │
│  Move to column ›│──▶│  blocked (no tasks)   0 │
│  ──────────────  │   │  archived             4 │
│  …               │   └──────────────────────────┘
│  Delete task     │
└──────────────────┘
```

Submenu rules:

- Lists **all** columns from `sortedColumns`, with each column's live task
  count in dim text on the right.
- The card's **current** column is shown with a `●` marker and a muted
  background; clicking it is a no-op (the menu just closes). Keeping it
  visible is deliberate — it confirms *where the card is now*, which is the
  most common question the user has when they open this menu.
- Columns with 0 tasks are **not** disabled. An empty column is a legitimate
  destination, and greying it out would read as "unavailable".
- Clicking a target column closes the whole menu (both panels) and fires the
  move.
- **Position = append to the end of the target column.** This matches the
  existing drag-and-drop drop handler exactly (`KanbanColumn.handleDrop`,
  `const position = cardsInColumn.value.length`). Reusing that rule means the
  menu move and the drag move produce identical state, so a user who
  accidentally does one and then the other never sees a surprise.

### 4.3 Submenu flip

The submenu opens to the **right** by default. If the parent menu's left edge
+ parent width + submenu width would exceed `window.innerWidth`, it opens to
the **left** instead. The root `useContextMenu` already stores only `clientX/Y`;
this is a pure rendering-time computation in the submenu component, so it
needs no new state in the composable.

The root menu itself also needs edge clamping: right-clicking near the
right edge of a 280px column currently places the menu at `clientX`, which can
push it off-screen. This is a pre-existing bug that the submenu makes much
more visible (a wider combined footprint), so we fix it in the same change.

## 5. Implementation — three chunks

Each chunk is independently shippable and independently testable.

---

### Chunk 1 — Move the action buttons into the context menu

**Nothing is deleted yet.** We add the items, verify them, then remove the
strip in Chunk 3. This keeps every commit green and makes the diff reviewable
in two halves.

**Files**

| File | Change |
|---|---|
| `components/kanban/KanbanTaskContextMenu.vue` | **NEW.** The card's right-click menu. Props: `x`, `y`, `isPinned`, `isAgentRunning`, `taskName`. Emits: `pin`, `rename`, `viewDetail`, `delete`, `openInNewTab`, `openDetailsInNewTab`, `stop`. Teleported to `body`; renders separators + red delete row. |
| `components/workspace/WorkspaceItemTaskCard.vue` | Import + render the new menu in place of `<OpenInNewTabMenu show-details :show-stop>`. Route the 4 new menu emits to the existing `handlePinToggle` / `handleRenameTask` / `handleViewTaskDetail` / `handleDeleteTask` handlers. |
| `composables/useContextMenu.ts` | Add optional edge clamping to `openAt` (clamp `x`/`y` to the viewport minus an estimated menu size). No signature break — existing callers keep working. |

**Menu-item → handler mapping** (all four already exist and already
`stopPropagation`, so no new plumbing below the card):

| Menu item | Handler | Payload emitted |
|---|---|---|
| Pin task / Unpin task | `handlePinToggle` | `pinTask(ws, item, id, !task.is_pinned)` |
| Rename task | `handleRenameTask` | `renameTask(ws, item, id, task.name)` |
| View details | `handleViewTaskDetail` | `viewTaskDetail(id)` |
| Delete task | `handleDeleteTask` | `deleteTask(ws, item, id)` |

**Label toggling:** the pin row reads `Pin task` / `Unpin task` based on
`task.is_pinned`, matching the current button's `title` attribute. The icon
fills when pinned, matching the current SVG swap.

**Test ids** (mirroring the existing `open-new-tab-menu` convention):

```
kanban-task-context-menu
kanban-task-context-menu-pin
kanban-task-context-menu-rename
kanban-task-context-menu-details
kanban-task-context-menu-delete
kanban-task-context-menu-open-chat
kanban-task-context-menu-open-details
kanban-task-context-menu-stop
```

**Tests** — `__tests__/WorkspaceItemTaskCard.contextMenu.spec.ts` (new), modelled
on the existing `WorkspaceItemTaskRow.contextMenu.spec.ts` (right-click the
card → `document.body.querySelector('[data-testid="…"]')` → `.click()` →
assert `wrapper.emitted(...)`):

1. Right-click opens the menu at the cursor's coordinates.
2. `pin` emits `pinTask` with the **inverted** pin value.
3. `rename` emits `renameTask` with the current name.
4. `viewDetail` emits `viewTaskDetail` — and does **not** also emit
   `selectTask` (the propagation trap the current `handleViewTaskDetail`
   comment warns about).
5. `delete` emits `deleteTask`.
6. `stop` only appears when `processingState[task.id] === true`.
7. Esc closes the menu.

---

### Chunk 2 — "Move to column" submenu

**Files**

| File | Change |
|---|---|
| `components/kanban/KanbanTaskContextMenu.vue` | Add the "Move to column" row + submenu panel state (hover + arrow-key). Accept a new `columns` prop. |
| `components/workspace/WorkspaceItemTaskCard.vue` | New emit `moveTaskToColumn: [{ columnId: string, position: number }]`. Compute `position` for the chosen column. New optional prop `columns?: KanbanColumn[]`. |
| `components/kanban/KanbanCard.vue` | Declare + re-emit `moveTaskToColumn`; accept and pass through a `columns` prop. |
| `components/kanban/KanbanColumn.vue` | Accept a `columns` prop; re-emit `moveTaskToColumn` from `KanbanCard`. |
| `components/kanban/KanbanView.vue` | `:columns="sortedColumns"` on `<KanbanColumn>`; re-emit `moveTaskToColumn` upward. |

**Position calculation** lives in the card (it owns the task list via
`props.task`… actually it does not — so the position is computed by
`KanbanColumn`, which already has `cardsInColumn`). Concretely:

```ts
// KanbanColumn.vue — the host that knows the board
const handleMoveToColumn = (columnId: string) => {
  emit('moveTaskToColumn', {
    taskId: props.task.id,          // from the KanbanCard it re-emits
    columnId,
    position: targetColumnCount(columnId),
  })
}
```

The cleanest split, and the one we recommend:

- **The card** emits `moveTaskToColumn: [{ columnId }]` — just the intent.
  It does *not* compute a position; it has no view of the board.
- **`KanbanColumn`** re-emits as `moveTask: [{ taskId, columnId, position }]`
  — the **existing** event shape — computing `position` as the target
  column's card count. It already has `cardsInColumn` for its own column and
  `props.tasks` for the whole board, so
  `props.tasks.filter(t => t.kanban_column_id === columnId).length` is exact.
- **`KanbanView` → `AppLayout`** then need **zero** changes: the event shape
  and the handler already exist.

This means Chunk 2 adds one prop and one re-emit per level and changes no
existing logic. Good.

**Edge cases**

- **Target is the current column** → guard, no emit. Prevents a pointless
  POST that would bump `kanban_position` and renumber siblings for nothing.
- **Board has one column** → the "Move to column" row is hidden entirely.
  A submenu with a single (disabled) item is worse than no submenu.
- **`columns` is empty/undefined** (sidebar-row host, legacy board, or a
  board whose columns haven't loaded) → the row is hidden. Never render a
  dead submenu.
- **Rapid-fire moves** → the menu closes on the first pick, so a second pick
  requires a fresh right-click. The store action is already
  idempotent-safe, and SSE reconciles any out-of-order arrival.
- **Virtual scroller** → the menu is teleported to `body`, so scrolling the
  column while the menu is open cannot clip it, and the card unmounting
  (scrolled out of view) does not remove the menu from the DOM, because it
  lives in the *card's* subtree. ⚠️ **This is a real bug we must handle**:
  if the user opens the menu and then scrolls the card out of the viewport,
  `VirtualScroller` unmounts the card and the menu with it. Fix: the menu is
  mounted but we add a `pointerdown`/`wheel` listener while open that closes
  the menu — extend `useContextMenu` to also dismiss on `wheel` and `scroll`
  (capture phase). Cheap and it removes the whole class of problem.

**Tests**

`__tests__/WorkspaceItemTaskCard.moveToColumn.spec.ts` (new):

1. The "Move to column" row is hidden when `columns` is empty.
2. The row is hidden when `columns.length === 1` (only own column).
3. The current column renders with a `●` marker; other columns do not.
4. Hovering the row opens the submenu listing every other column.
5. Picking column B emits `moveTaskToColumn` with `columnId: B`.
6. Picking the current column emits nothing.
7. The submenu renders left-aligned when it would overflow the viewport right edge.

`__tests__/KanbanColumn.moveToColumn.spec.ts` (new):

8. `moveTaskToColumn` from a card re-emits as `moveTask` with
   `position === <target column's card count>`.
9. Moving to the same column the card is already in emits nothing.

---

### Chunk 3 — Remove the hover button strip

Now that Chunk 1's menu items are proven, delete the four `<button>` elements
from `WorkspaceItemTaskCard.vue` (L~640–722).

**Knock-on effects to handle in the same chunk:**

1. **`handleViewTaskDetail` becomes menu-only.** It exists only to
   `stopPropagation` away from the card root's `@click`. Once the button is
   gone, the only caller is the menu. Keep the `stopPropagation` — the menu is
   teleported to `body`, so a click there does *not* bubble to the card, but
   `handleSelectTask` could still be triggered by a stray root click. Keeping
   the guard is free.
2. **The pin *indicator* stays.** The `v-if="task.is_pinned"` yellow pin
   glyph to the left of the name is information, not an action. It is not
   part of this removal.
3. **The `data-has-agent-error` style is `button[...]`-scoped** in the
   `<style scoped>` block but the root element is a `<div>`. It is
   *already* dead CSS. Fix the selector to `[data-has-agent-error='true']`
   while we are in the file — one line, and it makes the error ring actually
   render.
4. **`useTaskActions` keeps `handleDeleteTask` / `handleRenameTask` /
   `handlePinToggle`.** They are shared with `WorkspaceItemTaskRow`, which
   still has the buttons. No composable change.
5. **Layout.** With the buttons gone the top row is
   `[status glyphs] [pin] [name]`. The name gets its natural flex-1 width
   back — from ~150px to ~250px on a 280px column. "gitlab support" now fits
   on one line, which is the whole point.

**Tests** — extend `workspaceItemTaskCard.spec.ts`:
- The four buttons are no longer in the DOM
  (`view-task-detail-btn`, `task-pin-toggle`, and by tag the two untagged ones).
- The card still opens on click and on `Enter`/`Space`.
- The pin indicator still renders when `task.is_pinned`.

### Rollback

Chunks 1 and 2 are additive. If Chunk 3 is wrong, reverting it restores the
strip with the menu still available — the two coexist by design.

## 6. Confirm-on-delete

`Delete task` in the context menu is a *different* risk profile from the
button: the button required a precise click on a 24px target; the menu item
requires right-clicking the card and then picking one row out of eight. The
probability of a stray hit is comparable, and the consequence is a lost task.

Recommendation: add a lightweight confirm. The repo already has
`RenameTaskModal`; a matching `ConfirmDialog` or a reuse of an existing
modal would be the low-cost path. **Flagged as a decision for the reviewer**
— it is in scope for this plan but can ship as a follow-up chunk if the
reviewer prefers to land the menu first.

## 7. Keyboard / accessibility

Per the repo rule that every view switch must be reachable, the menu is
opened by the standard `ContextMenu` key too:

- The card root is already `role="button" tabindex="0"` and handles
  `Enter` / `Space` (`handleCardKeydown`). Add `event.key === 'ContextMenu'`
  and `event.key === 'F10'` (macOS/Windows convention) → open the menu
  anchored at the card's bounding-rect centre.
- `role="menu"` + `role="menuitem"` on every row (matching the existing
  `OpenInNewTabMenu` markup).
- Arrow keys move between items; `→` / `Enter` on "Move to column" opens the
  submenu; `Esc` closes the submenu, then the menu (two-stage, standard).
- `Delete` / `Backspace` on a focused card opens the menu focused on the
  Delete row rather than firing immediately — the shortcut hints shown in the
  menu must be honest.
- `aria-disabled` (not `disabled`) on the current column's row, so it stays
  focusable and screen readers can still announce "current column".

## 8. Out of scope, but queued

- **Sidebar rows** (`WorkspaceItemTaskRow.vue`, L265/288/303) keep their
  three buttons. Same treatment is worthwhile — the sidebar is the *narrower*
  surface, so the buttons hurt proportionally more — but the sidebar row is
  also the primary navigation surface and a bigger blast radius. Follow-up.
- **Intra-column reordering from the menu** ("Move to position 3 of 7").
  Drag-and-drop covers it.
- **Move to another board.** A different backend endpoint, a different
  confirm UX, and a different data model. Separate plan.
- **Unassign (move out of all columns).** Needs a decision on whether
  unassigned tasks are shown anywhere — the board currently filters them out
  (`KanbanColumn.cardsInColumn` requires a matching `kanban_column_id`), so
  an "unassign" action would make a card vanish.

## 9. Verification

**Static**

- `pnpm vue-tsc --noEmit` (or the repo's typecheck script) — the new
  `columns` prop and `moveTaskToColumn` emit must type through four levels.
- ESLint + Prettier on all touched files.

**Unit (vitest)**

- `WorkspaceItemTaskCard.contextMenu.spec.ts` — 7 cases, Chunk 1.
- `WorkspaceItemTaskCard.moveToColumn.spec.ts` — 7 cases, Chunk 2.
- `KanbanColumn.moveToColumn.spec.ts` — 2 cases, Chunk 2.
- `workspaceItemTaskCard.spec.ts` — extended, Chunk 3.
- **Full existing card suite must stay green** — there are 7 existing
  `WorkspaceItemTaskCard.*.spec.ts` files (tags, image, agentError,
  gitBranch, gitPrStatus, gitPrConflict, base) that mount the card and could
  be sensitive to removing buttons from the top row.

**Manual (browser, the only honest way to check this)**

1. Right-click a card → menu appears at the cursor, fully on-screen, even
   when the cursor is at the far right edge of a 280px column.
2. Every menu item works; the delete confirm fires.
3. "Move to column" → submenu lists all columns with counts, current one
   marked; picking one moves the card to the **bottom** of the target.
4. With a second browser tab open on the same board, the move appears in the
   second tab within the SSE round-trip (this is the `kanbanSse.ts` →
   `mirrorKanbanTaskMove` path — if it regresses, this is where it shows).
5. The task name is no longer truncated at ~150px.
6. Open the menu on a card, then scroll the column — the menu closes
   (the `wheel`/`scroll` dismiss from §5 Chunk 2).
7. Keyboard only: `Tab` to a card, `ContextMenu` key, arrow through the menu
   including into and out of the submenu, `Esc` twice.

## 10. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Removing the buttons strands a user who never learned right-click | Medium | Keep `Task details` reachable by other means (double-click the card opens details — cheap add, listed as a decision for the reviewer). Show a one-time hint toast on the board: *"Right-click a card for actions and Move to column."* |
| Column list is empty on a legacy/unloaded board → dead submenu | Low | Row hidden when `columns.length < 2`; covered by test 1/2. |
| Virtual scroller unmounts the card while its menu is open | Medium | `wheel`/`scroll` (capture) dismiss added to `useContextMenu`; covered by manual step 6. |
| `moveTaskToColumn` fires while a drag is in flight | Low | The menu closes on mousedown-anywhere; a drag cannot start with the menu open (the card is `draggable` — we `event.preventDefault()` in `openAt`, which already suppresses the native drag). |
| Existing card specs break on button removal | Medium | 7 existing spec files mount this card; run the full suite, not just the new specs, in Chunk 3. |
| Four-level prop/emit threading introduces a typo that only shows at runtime | Low | `vue-tsc` + the two new column-level specs. |

## 11. Files touched — summary

```
M  components/workspace/WorkspaceItemTaskCard.vue   (menu host, emit, prop, strip removal)
M  components/kanban/KanbanCard.vue                 (re-emit + pass-through)
M  components/kanban/KanbanColumn.vue               (position calc + re-emit)
M  components/kanban/KanbanView.vue                 (:columns="sortedColumns")
M  composables/useContextMenu.ts                    (edge clamp, wheel/scroll dismiss)
A  components/kanban/KanbanTaskContextMenu.vue      (NEW — the menu)
A  __tests__/WorkspaceItemTaskCard.contextMenu.spec.ts
A  __tests__/WorkspaceItemTaskCard.moveToColumn.spec.ts
A  __tests__/KanbanColumn.moveToColumn.spec.ts
M  __tests__/workspaceItemTaskCard.spec.ts
```

No backend change. No store change. No `KanbanView`/`AppLayout` logic change.

## 12. Open decisions for the reviewer

1. **Confirm-on-delete** — in scope (§6) or a follow-up?
2. **Which buttons go?** This plan removes all four. Keeping the pin button
   is defensible (pinning is a one-click, high-frequency action). Say the
   word and we keep pin.
3. **Double-click = details?** A discoverable non-menu route to the action
   most affected by this change. Default: yes, but it needs a
   `dblclick`-vs-`click` guard so it doesn't double-fire.
4. **One-time hint toast** on the board after this ships, so existing users
   learn the menu exists.
5. **Sidebar rows** in this change or a follow-up (§8)?
