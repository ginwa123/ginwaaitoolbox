# Kanban: Embed ChatView inside KanbanView — Design Spec

**Date:** 2026-08-06
**Task:** #task_1785526795361 ("architectureal changes, in kanban mode move chatview into KanbanView")
**Status:** Approved (pure relocation, kanban mode only — `A` from the brainstorm question)
**Author:** session_1785526795361

---

## Goal

When the user is viewing a kanban workspace item and selects a task, the kanban board and the task's chatview render as a **single combined component** (`KanbanView`) — the chatview is no longer a sibling of `KanbanView` in `AppLayout`. The KanbanView hosts the board, the resize handle, and the chat pane, and decides internally whether to show the chat pane based on whether `activeTask` is set.

The change is **pure relocation**: UX is identical (same resize behavior, same `kanban-column-width` localStorage persistence, same `:key` strategies, same `@select-task` / `@close-chat` event flow upward). Only the owner of the layout changes — `AppLayout` shrinks and `KanbanView` grows.

---

## Why

### Today

`AppLayout.vue` mounts `KanbanView` **twice** as siblings of itself:

| Branch | Line | When | Layout |
|---|---|---|---|
| **3-column** | 1739-1825 | `activeTask && kanban item + task belongs to it` | `[KanbanView][handle][ChatView]` side-by-side |
| **standalone** | 1847-1868 | `kanban item + no task` | full-width KanbanView |

The 3-column branch owns ~120 lines of inline JSX + the entire kanban-column resize state machine (`KANBAN_MIN_WIDTH=0`, `KANBAN_MAX_WIDTH=720`, `kanbanColumnWidth`, `startKanbanResize`, `kanbanResizeStartX`, localStorage persistence, key `kanban-column-width`) — all in `AppLayout.vue:763-895`.

The two mounts of the same component exist only because the 3-column branch glues a `ChatView` next to the board. The board code (header, columns row, scroll preservation, column events) is identical — `AppLayout` just wraps the same 12 `:on` handlers twice.

### After

One mount of `KanbanView` in `AppLayout`. The component internally branches its template:

- **`!activeTask`** → full-width board (the old standalone layout, unchanged).
- **`activeTask && activeTaskWorkspaceItemId === item.id`** → 2-column: `[Board][resize-handle][ChatView]` (the old 3-column, but the chatview is KanbanView's child now, not AppLayout's).

**Net effect on AppLayout:**

- One `KanbanView` mount (was: two).
- ~150 lines removed (entire 3-column block + resize state machine + resize listeners + `kanbanColumnStyle` computed).
- `handleCloseTaskView` stays (URL is still the source of truth).

**Net effect on KanbanView:**

- Takes over the resize state + listeners + handle JSX.
- Renders a single combined template with a conditional inside.
- `@select-task` and `@close-chat` events still flow up to AppLayout — URL routing stays in AppLayout.

---

## Design Decisions

| ID | Decision | Why | Alternative rejected |
|----|----------|-----|----------------------|
| **D1** | **One** `KanbanView` mount in `AppLayout` replaces both branches (the standalone mount and the 3-column mount). | The two mounts only existed because the 3-column branch glued a `ChatView` next to the board. Once the chat is inside KanbanView, the combined component is **the natural primitive** — AppLayout no longer needs to know which layout variant to render. | Keep two mounts (rejected: would require duplicating the 12 `:on` handlers again, and the conditional already lives in KanbanView). |
| **D2** | KanbanView reads `activeTask` directly from `workspacesStore` and renders the chat internally. KanbanView does **not** receive `activeTask` as a prop. | The kanban -> task relationship is owned by the workspaces store (`activeTask` + `activeTaskWorkspaceItemId`). KanbanView is the natural view of "this kanban item with optional active task context". A prop would be redundant state. | Pass `activeTask: Task \| null` as a prop (rejected: forces AppLayout to read the store and pass it down — same data, more boilerplate). |
| **D3** | The 3-column branch's `data-kanban-three-column` selector is renamed to `data-kanban-host` (or kept as-is inside KanbanView). The selector `[data-kanban-three-column] > :first-child` (used by `startKanbanResize` to measure the rendered kanban column width) is updated to a new selector that lives inside the new template. | The selector was a leaky coupling — it used `:first-child` to find the kanban column from outside. With the resize now living inside KanbanView, the selector becomes a direct ref or a sibling-name CSS class inside the same component. | Keep the selector name + structure (rejected: the markup is moving, so the selector must move too). |
| **D4** | AppLayout owns URL routing + the navigation store mutations for `@select-task` and `@close-chat`. KanbanView emits these events upward; AppLayout handles them exactly as today. | URL is the source of truth (`view=task&task=<id>` vs `view=workspace&workspaceId=<id>&itemId=<id>`). The chatview's lifecycle is bound to `activeTask` + `activeTaskWorkspaceItemId === item.id`, which is global state owned by the store. | Move URL routing into KanbanView (rejected: spreads the URL contract across two components; AppLayout is the natural owner since it already handles `view=chat`, `view=task`, `view=workspace`, etc.). |
| **D5** | The localStorage key `kanban-column-width` is preserved exactly. The resize mechanics (drag 0-720px, default 40% of main area) are preserved exactly. | Same UX, just different owner. The user expects the resize to keep working across the refactor. | Drop the resize feature (rejected: explicit user feature in production). |
| **D6** | `:key` strategies: KanbanView uses `'kanban-' + item.id` (UNCHANGED). The chat pane inside KanbanView uses `'task-' + activeTask.id` (UNCHANGED — same as today). | `:key` is what drives Vue's remount-when-changed behavior. The current behavior already works (the chat remounts cleanly on task switch). | Drop the key (rejected: would let stale scroll position + SSE subscriptions leak across tasks). |
| **D7** | Design + chat 3-column (`AppLayout.vue:1904-2015`) is **NOT** in scope. Same architectural refactor could apply there (design + chat is structurally identical), but it's a separate plan. | The user's task title explicitly says "in kanban mode". Design chats are per-page (not per-task), so the shape is different. Mixing the two would conflate two distinct features. | Refactor design + chat too (rejected: scope creep; design needs its own brainstorm). |
| **D8** | KanbanView's `script setup` adds a `loadKanbanColumnWidth` helper + resize state (`kanbanColumnWidth`, `isKanbanResizing`, `kanbanResizeStartX`, `kanbanResizeStartWidth`) + `startKanbanResize` / `handleKanbanResize` / `stopKanbanResize` + `kanbanColumnStyle` computed. These come from `AppLayout.vue:763-895` verbatim (just moved). | The resize logic is fully self-contained — it has no dependency on AppLayout state. Moving it preserves all behavior. | Move resize into a composable (rejected: YAGNI — the resize has no other use site). |
| **D9** | All existing tests in `AppLayout.kanban.spec.ts` (41 tests), `AppLayout.kanbanScrollPreservation.spec.ts`, and any other `AppLayout.*spec.ts` that asserts `data-kanban-three-column` are updated to the new structure. New tests in `KanbanView.*spec.ts` cover the now-internal behavior (resize drag, the !activeTask vs activeTask branch, the chat mount key). | The behavior is the same; the selector needs to follow the markup. Behavioral tests that drive the board (e.g. "click a task → chatview visible") work unchanged because the user-visible behavior is identical. | Skip new tests (rejected: TDD requires coverage of the new layout). |
| **D10** | The "currently active task belongs to this kanban" check moves from AppLayout's v-else-if (`activeTaskWorkspaceItemId === activeWorkspaceItem.id`) into KanbanView's template (`activeTaskWorkspaceItemId === item.id`). | The check is purely about this kanban's chat context. AppLayout no longer needs to know about a kanban-specific active-task relationship. | Keep the check in AppLayout (rejected: defeats the encapsulation — AppLayout would still need to know which kanban the active task belongs to). |

---

## Architecture (after)

### File changes

| File | Action | Lines (approx) |
|---|---|---|
| `src/apps/desktop/src/components/AppLayout.vue` | **edit** | -150 (delete 3-column block + resize state machine + 1 mount → 1 mount) |
| `src/apps/desktop/src/components/kanban/KanbanView.vue` | **edit** | +150 (add resize state + chat pane branch + ChatView import) |
| `src/apps/desktop/src/__tests__/AppLayout.kanban.spec.ts` | **edit** | update selectors / expectations to match new structure |
| `src/apps/desktop/src/__tests__/AppLayout.kanbanScrollPreservation.spec.ts` | **edit** | update `data-kanban-three-column` references |
| `src/apps/desktop/src/__tests__/AppLayout.*spec.ts` | **edit** (any others) | update selectors as needed |
| `src/apps/desktop/src/__tests__/KanbanView.*spec.ts` | **new** | tests for the now-internal chat pane + resize |

### New behavior in KanbanView

```
KanbanView (always mounted on a kanban item)
├── <header>           (unchanged — kanban name + "+ Column" + ⚙️ Settings)
├── <columns row>      (unchanged — horizontally scrollable columns)
│   ├── <KanbanColumn>     (unchanged — board items)
│   └── <KanbanColumn>     (unchanged)
└── <chat pane>        (NEW — only when activeTask && activeTaskWorkspaceItemId === item.id)
    ├── <resize handle>     (moved from AppLayout)
    └── <ChatView>          (now mounted by KanbanView, not AppLayout)
```

```
<template>
  <div class="flex-1 flex flex-col min-h-0" data-kanban-host>
    <!-- when no task selected: full-width board (UNCHANGED) -->
    <div v-if="!showChatPane" class="flex-1 flex flex-col min-h-0">
      <header>...</header>
      <div class="overflow-x-auto">...columns row...</div>
    </div>

    <!-- when a task is selected: board + chat side by side (NEW) -->
    <div v-else class="flex-1 flex min-h-0" data-kanban-with-chat>
      <div class="flex flex-col h-full min-h-0" :style="kanbanColumnStyle" style="border-right: 1px solid var(--color-border)">
        <header>...</header>
        <div class="overflow-x-auto flex-1">...columns row...</div>
      </div>
      <div class="shrink-0 w-2 cursor-col-resize ..." data-kanban-resize-handle ...>
        ...svg circles...
      </div>
      <div class="flex-1 flex flex-col h-full min-w-0 min-h-0">
        <ChatView
          :key="'task-' + activeTask.id"
          :chat-id="activeTask.id"
          :chat-name="activeTask.name"
          :type="'task'"
          :cwd="item.path || ''"
          :task-id="activeTask.id"
          :task-name="activeTask.name"
          :project-name="item.name || ''"
          :show-header="true"
          @close="$emit('close-chat')"
        />
      </div>
    </div>
  </div>
</template>
```

`showChatPane` is a `computed`:
```ts
const activeTask = computed(() => workspacesStore.activeTask)
const activeTaskWorkspaceItemId = computed(() => workspacesStore.activeTaskWorkspaceItemId)
const showChatPane = computed(
  () => !!(activeTask.value && activeTaskWorkspaceItemId.value === effectiveItemId.value),
)
```

`@select-task` is already emitted by KanbanView today (passed through from `KanbanColumn`). No change.

**New `@close-chat` emit** flows up to AppLayout's `handleCloseTaskView` (unchanged).

### New behavior in AppLayout

```
<template>
  ...
  <KanbanView
    v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'kanban'"
    :key="'kanban-' + activeWorkspaceItem.id"
    :item="activeWorkspaceItem"
    :workspace-id="activeWorkspace?.id ?? ''"
    :item-id="activeWorkspaceItem.id"
    @move-task="handleKanbanMoveTask"
    @add-column="handleKanbanAddColumn"
    @rename-column="handleKanbanRenameColumn"
    @delete-column="handleKanbanDeleteColumn"
    @reorder-column="handleKanbanReorderColumn"
    @request-rename-column="handleKanbanRequestRenameColumn"
    @request-delete-column="handleKanbanRequestDeleteColumn"
    @select-task="handleKanbanSelectTask"
    @delete-task="handleKanbanDeleteTask"
    @rename-task="handleKanbanRenameTask"
    @edit-routine="handleKanbanEditRoutine"
    @run-routine="handleKanbanRunRoutine"
    @pin-task="handleKanbanPinTask"
    @open-settings="handleOpenKanbanSettings"
    @rename-item="handleKanbanRenameItem"
    @close-chat="handleCloseTaskView"
  />
  ...
</template>
```

AppLayout's `handleKanbanSelectTask` (line 1306) is unchanged. `handleCloseTaskView` (line 727) is unchanged. The full 3-column block (lines 1739-1825) is **deleted**. The resize state machine (lines 763-895) is **deleted**.

### State the workspaces store needs to expose

KanbanView needs `activeTaskWorkspaceItemId` from the store. Currently this is a computed in `AppLayout.vue:701-712`. **Two options:**

- **(a)** Move the computed into `workspaces` store as a getter. AppLayout and KanbanView both consume it.
- **(b)** Keep the computed in AppLayout and pass `activeTaskWorkspaceItemId` as a prop to KanbanView.

Decision: **(a)** — move it into the store. The store already owns `activeTask` and `activeTaskId`. The "which item owns this task" relationship is store state, not view state. This is a small, surgical move (one computed).

---

## Test strategy

### Behavioral tests (TDD)

**Updated:**
- `AppLayout.kanban.spec.ts` — 41 tests. Tests that drive "click task → chatview appears" continue to work (the DOM still has the chatview). Tests that use `data-kanban-three-column` are updated to the new selector.
- `AppLayout.kanbanScrollPreservation.spec.ts` — same selector update.

**New (`KanbanView.*spec.ts`):**
- Render with no active task → renders full-width board, no chat pane.
- Render with active task belonging to this item → renders board + chat pane + resize handle. ChatView is in the DOM with `key="task-<id>"`.
- Render with active task belonging to a DIFFERENT item → renders full-width board (no chat). The chat belongs to a different kanban.
- Drag the resize handle → `kanbanColumnWidth` updates → `kanbanColumnStyle` updates → localStorage `kanban-column-width` is written on mouseup.
- Mount + clear localStorage → falls back to 40% default.
- Emits `@close-chat` when ChatView's close button fires.

**New (resilience):**
- Switching between two kanban items → KanbanView remounts (per `:key`), chat pane disappears when activeTaskWorkspaceItemId doesn't match the new item.id.

---

## Out of scope (deferred)

- **Design + chat 3-column** (`AppLayout.vue:1904-2015`) — structurally identical, but design chats are per-page and the design item's chat assignment is different. A separate plan can apply the same refactor.
- **Always-visible chat pane with collapsed state** — UX change, not a relocation. Could be a follow-up.
- **Snap behavior or different resize UX** — current drag-to-resize works; changing it is a separate UX plan.
- **Marquee / layer / drag from layers panel** — already mentioned in `docs/SPEC.md` §5 Pending. Not related to this refactor.

---

## Migration / rollout

- **No new migration.** No backend changes. Pure frontend refactor.
- **No new endpoint.** No API changes.
- **No new stores.** Only one computed moves from AppLayout into the workspaces store.
- **No new tests files for the backend** (none touched).
- **Smoke test on a real running `nalar` instance** (port 8080, not 8081) — open a kanban, click a task, confirm chatview appears; drag the resize handle, confirm width changes; close the chat, confirm board fills the main area.

---

## Verification (post-implementation)

```bash
# 1. Static unit tests
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all

# 2. Build the Linux binary (catches lazy-analysis errors)
timeout 180 zig build install:linux:system

# 3. Fresh rebuild
rm -rf zig-out/bin && timeout 360 zig build

# 4. Cross-compile smoke (Windows + macOS)
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig

# 5. Frontend type-check
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
timeout 180 bunx vitest run 2>&1 | tail -n 20
```

**Behavioral smoke (port 8080):**
- Open a kanban → board alone, no chat.
- Click a task → chatview appears on the right, board on the left.
- Drag resize handle → board shrinks, chatview grows.
- Close the chatview → board fills the main area again.
- Reload the page → resize width persists.
- Open a different kanban → board alone again (chat is per-kanban).
- Click a second task → chatview re-mounts with the new task's content.

---

## Pitfalls

- **`data-kanban-three-column` selector coupling** — many tests reference this. Update them in one pass, not incrementally.
- **The "active task belongs to this kanban" check** must use `effectiveItemId.value` (the same value the v-else-if in AppLayout used), not `item.id` — there's a subtle difference when `itemId` is overridden.
- **`@close` on ChatView vs `@close-chat` on KanbanView** — they are different events. KanbanView translates `@close` (from ChatView) into `@close-chat` (for AppLayout). Don't drop `@close-chat` thinking `@close` propagates up — it doesn't.
- **The `data-kanban-resize-handle`** needs to move into KanbanView's template together with the resize state — otherwise the handle is in the DOM but the listeners are not.
- **The KanbanView's `:key` is `'kanban-' + item.id`** — switching between two kanbans remounts the entire KanbanView (including the chat pane). This is the same behavior as today (today, switching kanbans also remounts because the 3-column branch is below the standalone branch in the v-else-if chain, so Vue picks one or the other — and the new mount has a fresh key). The new layout has the same behavior: the active task belongs to the new kanban only if `activeTaskWorkspaceItemId === item.id`, which is unlikely to be true after switching kanban items.
- **vue-tsc** will catch the prop / emit / type mismatches — `bun run build` is the first defense.
- **The 12 `@on` handlers on KanbanView remain** — AppLayout still forwards all of them. The `@close-chat` is the only new one (translating from ChatView's `@close`).
