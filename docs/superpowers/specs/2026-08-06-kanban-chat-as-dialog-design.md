# Kanban Chat — Convert Side-by-Side Pane into Centered Modal Dialog — Design

> **SUPERSEDED (2026-09-14).** The modal this spec designs was replaced by a
> normal view so the kanban chat could live in its own browser-style tab. See
> `docs/superpowers/plans/2026-09-14-kanban-task-opens-its-own-tab.md` and
> `docs/SPEC.md` §3.7.7.1. Kept for the rationale at the time, not as current
> behaviour — `KanbanChatDialog.vue` no longer exists.

> **For agentic workers:** This is a design spec. After the user approves, the next step is to invoke the `superpowers:writing-plans` skill to create a bite-sized implementation plan.

**Goal:** Replace the current side-by-side `[kanban board] [resize-handle] [ChatView]` layout (kanban-embed-chatview, 2026-08-06) with a centered modal dialog that opens **on top of** the kanban board. The kanban board stays full-width and interactive behind a dimmed+blurred backdrop while the chat is open. Click the backdrop, press Esc, or click the dialog's ✕ to close.

**Architecture:** New component `KanbanChatDialog.vue` mirrors the established project modal pattern (`KanbanTaskDetailDialog`, `FilePreviewModal`): `<Teleport to="body">`, `fixed inset-0 z-50 flex items-center justify-center p-4`, Esc keydown handler, backdrop click closes, `v-model:show` two-way binding + explicit `close` emit (backward compat). The dialog wraps `<ChatView>` with `:show-header="false"` so we don't double up on headers. `<KanbanView>` loses its second branch (the side-by-side mode) entirely — ~380 lines deleted — and reverts to the single full-width board layout that existed before 2026-08-06. `<KanbanChatDialog>` is mounted at the `<AppLayout>` level, driven by the existing `workspacesStore.activeTask` + `activeTaskWorkspaceItemId` selectors. URL routing for `?view=task&task=<id>` stays in `AppLayout.handleCloseTaskView` — reused unchanged.

**Tech Stack:** Vue 3 + TypeScript + Pinia + Vitest (`@vue/test-utils`). No new dependencies, no backend changes, no migration.

## 1. Why now — the problem

Today (post 2026-08-06 kanban-embed-chatview), opening a kanban task shrinks the board into ~40% of the main area to make room for a chat pane on the right. The user can resize the boundary (0-720px), but the chat still occupies a permanent slice of the layout even when closed (the click-to-open pattern was reshaped into a click-to-show pane). For a focused kanban UX, the user expects:

1. **Board is the hero** — full-width until they need a chat.
2. **Chat is a focused event** — opens in front, not beside. Easier to dismiss (Esc/backdrop/✕) than a layout shift.
3. **One action, one screen** — the chat belongs to the task, not to the kanban layout.

The current layout conflates "kanban is open" with "chat might be open" — every click on a task reshapes the main area. A centered modal restores the kanban's primacy while keeping the chat one click away.

**Design chat is out of scope.** The design canvas + chat 3-column block (`AppLayout.vue:1904`) uses a different chat-per-page model (one chat per design page, lazy-created on first 💬 click). That block stays as-is. Only the kanban chat changes.

## 2. Current state — what exists today

**Frontend**
- `AppLayout.vue` — mounts ONE `<KanbanView>` (after the 2026-08-06 relocate). Also mounts two `<ChatView>` instances for design mode (lines 1864 + 1904) which are untouched.
- `KanbanView.vue` (1056 lines) — branches on `showChatPane` computed:
  - **No chat** (line 742): full-width board — header + columns row + `<KanbanColumn>` list.
  - **Chat active** (line 880): `[kanban-side] [resize-handle] [chat-side]` layout in a `data-kanban-with-chat` wrapper. Hosts a 130-line drag-resize state machine (`kanbanColumnWidth`, `isKanbanResizing`, `startKanbanResize`, `handleKanbanResize`, `stopKanbanResize`, `kanbanColumnStyle`, `KANBAN_MIN_WIDTH`, `KANBAN_MAX_WIDTH`, `KANBAN_DEFAULT_WIDTH`, `KANBAN_WIDTH_STORAGE_KEY` — `localStorage` key `kanban-column-width`). Emits `closeChat` which `AppLayout.handleCloseTaskView` consumes for URL cleanup.
- `ChatView.vue` (3140 lines) — chat implementation. Has `:show-header` prop (boolean). Currently `:show-header="true"` in the kanban-side mount (header shows task name + ✕). The `:show-header="false"` path already exists and is used elsewhere.
- `useChatScrollRestore` composable — persists VirtualScroller scroll position per `(task-id)` to localStorage (`chat-scroll-<task_id>`). Works transparently inside the dialog; no changes needed.
- `KanbanTaskDetailDialog`, `FilePreviewModal`, `KanbanSettingsDialog` — all use `<Teleport to="body">` + `fixed inset-0 z-50 flex items-center justify-center p-4` + Esc keydown + backdrop click. Established project modal pattern.
- `workspacesStore` — has `activeTask: Ref<Task | null>` and `activeTaskWorkspaceItemId: Ref<string | null>` getters (added in the kanban-embed-chatview plan, `workspaces.ts` getter exports).

**Backend**
- None — pure frontend relocation. No Zig, no migration, no schema.

**Test surface**
- `__tests__/KanbanView.chatPane.spec.ts` (8 tests) — locks in the side-by-side branch: `data-kanban-with-chat` wrapper, resize handle, task switch, close emit. These tests will be **migrated** to a new `KanbanChatDialog.spec.ts`.
- `__tests__/workspacesStore.activeTaskWorkspaceItemId.spec.ts` (3 tests) — locks in the store getters. Unchanged.
- `__tests__/KanbanView.scrollPreservation.spec.ts` — **already deleted** in the 2026-08-06 relocate (its layout-transition tests no longer applied at the AppLayout level). Unchanged here.

## 3. Design — UX, wire, sequencing

### 3.1 UX — the dialog

```
┌────────────────────────────────────────────────────────────────────┐
│ ░░░░░░░░░░░░░░░░░░░ dimmed + blurred backdrop ░░░░░░░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░┌──────────────────────────────────┐░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░│ 💬 <task name>             [✕]   │░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░├──────────────────────────────────┤░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░│                                  │░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░│  <ChatView with show-header=false>│░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░│                                  │░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░│  (history scrolls vertically)    │░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░│  (input box pinned at bottom)    │░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░│                                  │░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░└──────────────────────────────────┘░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
└────────────────────────────────────────────────────────────────────┘
```

- **Backdrop**: same as `KanbanTaskDetailDialog` / `FilePreviewModal` — `absolute inset-0 backdrop-blur-md` with `background: rgba(0,0,0,0.5)`. Click → close.
- **Dialog panel**: `width: 80vw`, `height: 80vh`, `max-width: 1100px`, `max-height: 800px`, `min-width: 480px`, `min-height: 320px`. Centered with `flex items-center justify-center p-4` on the wrapper.
- **Header** (new — dialog-owned):
  - Left: `💬 <task.name>` (h3, truncate).
  - Right: `✕` close button (px-2 py-1 rounded, hover opacity-80).
  - Border-bottom `1px solid var(--color-border)`.
- **Body**: `<ChatView>` with `:show-header="false"` (hides ChatView's internal header — no double-header).
- **No footer** — ChatView's own input box is the "footer" effectively.

### 3.2 Close affordances (standard modal pattern)

| Action | Behaviour |
|--------|-----------|
| Click backdrop | Dialog closes; URL `?view=task&task=<id>` strips via existing `handleCloseTaskView` |
| `Esc` keydown (anywhere on the page while dialog is open) | Dialog closes (same path) |
| Click `✕` in dialog header | Dialog closes (same path) |
| Click inside dialog (not on backdrop) | **No close** — `@click.stop` on the panel |
| Click a different task card while dialog is open | Dialog stays open; content swaps via `:key="'task-' + newTask.id"` remount (Notion/Linear pattern) |

Body scroll lock is **NOT** applied — matches existing `KanbanTaskDetailDialog` behaviour (no body scroll lock in the project). Focus management is **minimal**: focus the dialog wrapper on mount so Esc works without a prior click. **Do NOT** auto-focus the chat input (would steal the user's typing position from a previously-open chat).

### 3.3 Wire — `KanbanChatDialog` props + emits

```ts
// src/apps/desktop/src/components/kanban/KanbanChatDialog.vue

const props = withDefaults(
  defineProps<{
    show: boolean
    task: Task | null                          // active task; null when closed
    workspaceId: string
    itemId: string                             // the kanban item id (for context)
    projectName: string                        // → ChatView :project-name
    cwd: string                                // → ChatView :cwd
  }>(),
  {
    workspaceId: '',
    itemId: '',
    projectName: '',
    cwd: '',
  },
)

const emit = defineEmits<{
  'update:show': [value: boolean]              // v-model:show close
  close: []                                    // explicit close (backward compat)
}>()

const closeDialog = () => {
  emit('update:show', false)
  emit('close')
}
```

Mounted in `AppLayout.vue` next to the existing `<KanbanView>`:

```vue
<KanbanChatDialog
  v-if="workspacesStore.activeTask && workspacesStore.activeTaskWorkspaceItemId === activeKanbanItemId"
  v-model:show="kanbanChatDialogOpen"
  :task="workspacesStore.activeTask"
  :workspace-id="workspaceId"
  :item-id="activeKanbanItemId"
  :project-name="activeKanbanItem?.name ?? ''"
  :cwd="activeKanbanItem?.path ?? ''"
  @close="handleCloseTaskView"
/>
```

The `v-if` guards against rendering when the active task belongs to a non-kanban item (design chat, routine standalone, etc.) — those still use their own mounts.

### 3.4 Wire — `ChatView` props inside the dialog

Unchanged from today (kanban-embed-chatview plan):

```vue
<ChatView
  v-if="task"
  :key="'task-' + task.id"
  :chat-id="task.id"
  :chat-name="task.name"
  :type="'task'"
  :cwd="cwd"
  :task-id="task.id"
  :task-name="task.name"
  :project-name="projectName"
  :show-header="false"
  @close="closeDialog"
/>
```

- `:key="'task-' + task.id"` — critical for keeping chat scroll position via `useChatScrollRestore` and for the "click a different task card → content swaps" flow (Notion/Linear pattern).
- `:show-header="false"` — new (was `true` in the side-by-side layout). ChatView's internal header (with its own task name + ✕) is suppressed; the dialog's header takes over.
- `@close` → `closeDialog` → emits `update:show:false` + `close` → AppLayout's `handleCloseTaskView` (existing) clears URL + activeTask.

### 3.5 Sequencing — `AppLayout.vue` changes

1. **Remove** the import of `<KanbanView>`'s chat-related glue (none — KanbanView is self-contained, the only AppLayout references are the `@closeChat` handler wiring).
2. **Add** the `<KanbanChatDialog>` mount. Source `activeKanbanItem` from `props.itemId` + `props.itemType` (AppLayout already knows the active item type).
3. **Reuse** `handleCloseTaskView` (existing) — it already strips `?view=task&task=<id>` from the URL and clears `workspacesStore.activeTask`. No changes.
4. **Reuse** `handleSelectTask` (existing) — clicking a task card already sets `activeTask` + navigates URL. No changes.

The new wiring is purely additive: a new mount that reads from stores that are already populated by the existing URL handler.

### 3.6 Sequencing — `KanbanView.vue` changes

**Deletions (large, all in one go):**
- Lines 93-104 — `activeTask`, `activeTaskWorkspaceItemId`, `showChatPane` computed.
- Lines 106-211 — resize state machine: `KANBAN_MIN_WIDTH`, `KANBAN_MAX_WIDTH`, `KANBAN_DEFAULT_WIDTH`, `KANBAN_WIDTH_STORAGE_KEY`, `loadKanbanColumnWidth`, `kanbanColumnWidth`, `isKanbanResizing`, `kanbanResizeStartX`, `kanbanResizeStartWidth`, `startKanbanResize`, `handleKanbanResize`, `stopKanbanResize`, `kanbanColumnStyle`.
- Lines 213-216 — `close-chat` emit comment.
- Lines 232-250 — update the scroll-preservation comment to reference the single-board branch (no more 3-column reference).
- Line 742 (`<template v-if="!showChatPane">`) → remove the `v-if` wrapper (the board branch is now unconditional).
- Lines 873-980 — the entire `v-else` branch (side-by-side layout): `data-kanban-with-chat` wrapper + duplicated header + columns row + KanbanColumn mount + resize handle div + chat-side `<ChatView>` mount.
- Line 989 (around there) — remove the `import ChatView from '../views/ChatView.vue'` import.

**Net result**: KanbanView drops from 1056 lines to ~680 lines (~ -376 lines, mostly the second branch + the resize state machine).

**Preserved:** the horizontal scroll preservation composable (`useKanbanScrollRestore`-style for kanban columns, not chat). The `kanbanScrollStorageKey` + `kanbanColumnsContainer` ref stay — the user's column-row scroll position still needs to survive across task open/close.

### 3.7 Migration of the orphaned localStorage key

`localStorage` key `kanban-column-width` is left in place (no migration). Users who had it set during the 2026-08-06 side-by-side era will have an orphan value that nothing reads. New code never writes it. Acceptable — the key is private to the old implementation, not shared with anything else.

## 4. Out of scope (deferred)

- **Design chat (`AppLayout.vue:1864` + `:1904`)** — design canvas + chat 3-column block stays as-is. Different chat-per-page model, different wiring. Can be migrated in a follow-up plan.
- **Body scroll lock** — not added; matches existing `KanbanTaskDetailDialog` behaviour.
- **Focus trap** — user can Tab out of the dialog; matches existing dialogs.
- **Auto-focus the chat input on open** — would steal typing position from a previously-open chat. Intentional omission.
- **Animation choreography** — Vue `<Transition>` with default fade+scale (200ms) matching existing dialogs. No custom easing.
- **Resize-on-the-fly for the dialog** — the dialog is a fixed size; no drag-resize. The chat scroll position is independent (preserved per task via `useChatScrollRestore`).
- **Marquee-style multiple chats open at once** — single active chat at a time (same as today). Switching tasks closes nothing; the dialog content just swaps.
- **A migration of `kanban-column-width` localStorage key** — orphan value is harmless.

## 5. Files to touch

| Type | Path | Change |
|------|------|--------|
| NEW  | `src/apps/desktop/src/components/kanban/KanbanChatDialog.vue` | The new centered modal dialog (Teleport, backdrop, Esc, v-model:show + close) wrapping `<ChatView :show-header="false">` |
| EDIT | `src/apps/desktop/src/components/kanban/KanbanView.vue` | Delete chat-pane branch + resize state machine (~376 lines); remove `<ChatView>` import; revert to single full-width board branch |
| EDIT | `src/apps/desktop/src/components/AppLayout.vue` | Add `<KanbanChatDialog>` mount (driven by `activeTask` + `activeTaskWorkspaceItemId`); no other changes |
| DELETE | `src/apps/desktop/src/__tests__/KanbanView.chatPane.spec.ts` | Tests for the deleted chat-pane branch |
| NEW  | `src/apps/desktop/src/__tests__/KanbanChatDialog.spec.ts` | New behavioural tests for the dialog (open, close on backdrop/Esc/✕, content swaps on task switch, header hidden, header has task name, v-model:show + close both work) |
| EDIT | `docs/SPEC.md` | Update §3.7 (Kanban layout) entry to reflect the dialog change; add §10.2.1 PR index row |
| EDIT | `NALAR.md` | Append "### 2026-08-06: kanban chat-as-dialog" changelog entry |

Total: **7 files** (2 NEW, 4 EDIT, 1 DELETE). No backend changes. No migration. No Zig changes.

## 6. Verification

- `bun run build` clean (vue-tsc) — required for type-check (vitest alone doesn't type-check).
- `bunx vitest run` — all new behavioural tests pass; no regressions.
- `zig build test --summary all` — no regression (frontend-only change but verify nothing touched Zig compiles).
- `zig build install:linux:system` — binary still builds.
- Manual smoke (port 8080, isolated tmpdir):
  1. Open kanban → click a task card → assert dialog opens centered, chat history visible, kanban board visible behind dimmed backdrop.
  2. Press `Esc` → dialog closes; URL strips `view=task&task=<id>`; kanban board back to full-width.
  3. Click backdrop → dialog closes (same as Esc).
  4. Click `✕` in dialog header → dialog closes (same).
  5. Click inside dialog (chat body) → dialog stays open; no accidental close.
  6. Open task A → while dialog is open, click task B card in kanban → assert dialog stays open, content swaps to B, scroll position for B is restored (if previously saved) or starts at bottom.
  7. Open task A → scroll up → close dialog → reopen task A → assert scroll position restored.
  8. Refresh the page while dialog is open → assert dialog stays open, content stays mounted, URL routing preserved.

## 7. Risks & open questions

- **None blocking.** Frontend-only change; no backend risk.
- **Open**: is `80vw × 80vh, max 1100×800` the right size? — matches existing dialog conventions; tunable if user feedback disagrees. Spec'd as a baseline; can be tuned in a follow-up.
- **Open**: should the dialog auto-focus the chat input on open? — NO (would steal typing position). Spec'd.
- **Open**: should the dialog also support drag-resize? — NO (fixed size; matches "focused modal" pattern). Spec'd.
- **Risk**: a user with a very small viewport (< 480×320) sees the dialog clamped to min-width/min-height, possibly overflowing. Mitigation: `overflow: hidden` on the dialog body; `overflow-y: auto` on the chat container. Standard CSS — `ChatView` already handles its own scroll.
- **Risk**: the `data-kanban-with-chat` selector was referenced by external test code or static docs. Mitigation: search for it post-implementation and update any references; the only known use was the deleted `KanbanView.chatPane.spec.ts` and a comment block in `KanbanView.vue:117` (both deleted).