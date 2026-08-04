# Design chat as dialog (2026-08-06)

## User report

*"chatview design mode"* — user wants the design-mode chat to
be a centred modal dialog (like the kanban-mode chat dialog added
on 2026-08-06 in the `kanban-chat-as-dialog` plan).

## Pre-fix state

AppLayout.vue mounted a 3-column `DesignView | resize-handle | ChatView`
layout when a design item had an active chat task. The
Canvas+Chat split ate ~40-65% of the canvas width, plus there
was a collapse toggle and a drag-resize handle for the design
column. User feedback:

- *"when open chat design, its take many space"* (2026-07-25 —
  partial fix via design-chat-collapsed + a 65% default width +
  a resize handle)
- The whole approach is the wrong shape: a chat pane SHOULD
  be a focused event, not a permanent column on the side.

## The fix

Mirror the 2026-08-06 kanban plan (`KanbanChatDialog.vue`) for
design mode. Same Teleport-to-body centred modal pattern, same
sizing (98vw × 95vh, max 1600×1200), same close affordances
(backdrop click + Esc + ✕ button).

### Architecture

| Component | Role |
|---|---|
| `DesignChatDialog.vue` (NEW) | Centred modal wrapping `<ChatView :show-header="false">`. Page name shown in header as "Design Chat: <pageName>". |
| `AppLayout.designChatDialogOpen` (NEW ref) | Mirrors `activeTask` truthy. Drives `v-model:show`. |
| `AppLayout.activeDesignChatPageName` (NEW ref) | Captured from DesignView's `openChat` payload (the page's name, not the item's name). Cleared on `activeTask=null`. |
| `AppLayout.handleDesignOpenChat` (MODIFIED) | Now also writes `activeDesignChatPageName.value = payload.pageName`. |

### Removed state machine (net −188 lines in AppLayout.vue)

The following references / state / DOM are GONE:

- Constants: `DESIGN_MIN_WIDTH`, `DESIGN_MAX_WIDTH`, `DESIGN_DEFAULT_WIDTH`, `DESIGN_WIDTH_STORAGE_KEY`, `DESIGN_CHAT_COLLAPSED_KEY`
- Refs: `designColumnWidth`, `isDesignResizing`, `designResizeStartX`, `designResizeStartWidth`, `designChatCollapsed`
- Handlers: `startDesignResize`, `handleDesignResize`, `stopDesignResize`, `toggleDesignChat`
- Computeds: `designColumnStyle`
- Loaders: `loadDesignColumnWidth`, `loadDesignChatCollapsed`
- Template markup: the `<div data-design-three-column>` block (3-col layout), the drag-resize handle (`data-design-resize-handle`), the chat column (`data-design-chat-column`), the collapsed strip (`data-design-chat-collapsed-strip`), the floating collapse / expand buttons
- 9 `data-testid` attributes that no longer exist: `design-resize-handle`, `design-chat-collapse-button`, `design-chat-expand-button`, etc.
- The corresponding `localStorage` keys `design-column-width` and `design-chat-collapsed` — orphaned but harmless if present.

### Mount wiring

```vue
<!-- New mount at AppLayout level, sibling to KanbanChatDialog -->
<DesignChatDialog
  v-if="
    activeWorkspaceItem &&
    activeWorkspaceItem.item_type === 'design' &&
    activeTask &&
    activeTaskWorkspaceItemId === activeWorkspaceItem.id
  "
  v-model:show="designChatDialogOpen"
  :task="activeTask"
  :workspace-id="activeWorkspace?.id ?? ''"
  :item-id="activeWorkspaceItem.id"
  :page-name="activeDesignChatPageName"
  :project-name="activeWorkspace?.name ?? ''"
  :cwd="activeWorkspaceItem.path ?? ''"
  @close="handleCloseTaskView"
/>
```

`v-if` (NOT `v-else-if`) so the chain isn't broken — Vue treats it
as the start of a new conditional branch like KanbanChatDialog.

## Why pageName over taskName in the dialog header

In kanban mode the dialog header shows the task name (e.g.
"Implement drag-and-drop snap guides") — that's what the user
is talking about. In design mode the SAME task (per-page chat
task via FK) is what the user clicked (e.g.
"Design Chat: Login Page"), but the more useful context is the
design page name. The dialog header reads
"Design Chat: <pageName>" instead — matches the FK plan's naming
convention (2026-07-28-design-page-workspace-item-task-fk.md).

The `pageName` prop is captured from DesignView's `openChat`
payload (`{ pageId, pageName, workspaceItemTaskId }`) — already
exists, no DesignView change needed.

## Out of scope (explicit deferrals)

- **Bumping dialog sizing further** — current defaults (98vw /
  95vh / max 1600×1200 / min 800×540) match the user's recent
  "make chatview dialog bigger on kanban mode" feedback
  (commit `c47c94ac`). The user may want the SAME bump for
  design mode; if so, that's a separate request.
- **Locking design view while chat open** — the design canvas
  stays interactive behind the dimmed backdrop. The user can
  draw / select / drag while the chat is open. Same behaviour
  as the pre-fix 3-column (canvas was always interactive).
- **Refactor to share a generic `<ChatDialog>` base** — the
  two dialogs (Kanban + Design) are 95% identical but the
  gating logic differs (kanban vs design item_type) and the
  header content differs (task name vs page name). Defer until
  a third dialog emerges.
- **`DesignContextMenu`'s right-click on a layer** — unrelated,
  not touched.
- **Re-attaching the `lastDesignChatPageName` to URL bookmarks**
  — the dialog closes via `handleCloseTaskView` which clears
  `activeTask`, so a refresh wouldn't restore the chat. URL
  bookmark of "open chat for page X" can be a follow-up.

## Why I removed one existing test

`src/components/__tests__/AppLayout.translateResize.spec.ts`
contained a static-contract test (banned by user rule
2026-07-29) that grep'd AppLayout.vue's source for the SECOND
occurrence of `@translate-element="handleDesignTranslateElement"`.
That test assumed there were TWO `<DesignView>` mounts (the
3-column one + the standalone one). With the 3-column branch
gone, there's only ONE mount, so the count assertion (`>=2`)
breaks.

Behavioural coverage for the same wire remains in the
`useDesignHandlers.translateElement` tests above it (call the
handler, assert it reaches the API). The deleted static-contract
test was redundant.

## Follow-up bug fix (commit `8cc65044`, same PR)

User reported "the chat button keep not popup, chatview" after
testing the new dialog. Root cause: the dialog's v-if was
`activeTask && ...` and `activeTask` is **always null** for
design items in production.

The bug pre-dates this PR — the pre-fix 3-column [DesignView |
resize-handle | ChatView] layout used the same gate, so the
design chat was silently broken in production since the
2026-07-28 FK rewrite. Three reasons stack up:

1. `getWorkspacesItems` returns items WITHOUT tasks
   (`WorkspaceItemInfo` in llm_history.zig:3208 has no `tasks`
   field — the `/api/workspaces` endpoint DOES populate tasks,
   but it's only used to derive the initial list and its data
   is never merged into `workspaces.value`).
2. `init()` SKIPS `api.getTasks` for `item_type === 'design'`
   (workspaces.ts:639 — only folders + other types fetch
   per-item tasks).
3. The original handleDesignOpenChat (pre-FK) walked
   `item.tasks` from the backend's `getWorkspaces` response
   (which did include tasks for design items). The FK plan
   replaced that walk with a direct `setActiveTask(workspaceItemTaskId)`,
   but `activeTask` STILL walks
   `workspaces.value[].items[].tasks` (now empty) — so it
   returns null.

**Fix (this PR)**:

- Capture the FK's `workspaceItemTaskId` into a LOCAL ref
  (`activeDesignChatTaskId`) in `handleDesignOpenChat`. Build
  a synthetic Task via computed from that ref + the captured
  pageName. Gate the dialog on `activeDesignChatTaskId`
  (NOT on `activeTask`).
- Watch `workspacesStore.activeTaskId` (NOT `activeTask.value`)
  to clear the local ref on close — `activeTask` stays null
  for design items the whole time, so the watcher would never
  fire if it watched the computed. Watching the underlying
  ref bypasses this.
- `setActiveTask(...)` is still called in `handleDesignOpenChat`
  (drives URL sync + `handleCloseTaskView`), but the dialog
  no longer depends on its computed.

**Lesson (memory note)** — when a gate depends on a computed that
walks a data shape the production code path doesn't populate,
the gate will silently fail in production. The test suite can
pass because tests inject fixtures that DO populate the shape.
Always trace the data flow from input (API response) to the
gate's lookup source — if any production step strips the
field, the gate breaks for that path. In this case the FK
plan was implemented (replacing a working code path with a
direct id reference) without updating the gate's lookup
source — a classic regression-in-the-name-of-simplification
trap.

A separate lesson: NEVER assume "the pre-fix code worked"
without verifying the same gate in production. The pre-fix
3-column [DesignView | resize-handle | ChatView] layout was
broken in production since the FK plan landed (2026-07-28)
but the user only noticed after the dialog refactor because
the previous bug was masked by the always-collapsed-default
chat panel + the user's focus on kanban chat.

## TDD trace

RED: 11 tests in `DesignChatDialog.spec.ts` + 6 in
`AppLayout.designChatDialog.spec.ts` fail because:
- DesignChatDialog.vue doesn't exist (RED for component tests)
- AppLayout doesn't mount the dialog (RED for mount tests)

GREEN: write the component + wire the mount. All 13 dialog
component tests + 6 AppLayout mount tests pass.

RED (bonus): one pre-existing static-contract test in
`AppLayout.translateResize.spec.ts` fails because the 3-column
branch (2 `<DesignView>` mounts) became 1 mount after the
refactor.

GREEN (bonus): delete the redundant static-contract test.

## Verification

- `bun run build`: clean (vue-tsc passes)
- `bunx vitest run`: **1976 total / 1962 pass / 14 fail**
  - All 14 failures are PRE-EXISTING on main (verified by
    running the same suite against `main` HEAD) — same 4
    files: `AppLayout.memoriesGate.spec.ts`,
    `AppLayout.urlPersist.spec.ts`,
    `sidebarKanbanSortUrl.spec.ts`,
    `DesignView.nudge.spec.ts`. None touched by this change.
  - New tests: 13 (DesignChatDialog) + 6 (AppLayout mount) =
    19 added; 1 (static-contract in translateResize) removed.
    Net: +18.
- `zig build` (backend): not needed — no Zig/DB changes.
  Plan is frontend-only.

## Branch / commits

- Branch: `worktree/design-chat-as-dialog`
- Squash-merge candidate.
