# Agent-Mode Direct-to-Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In an agent-mode workspace item (`item_type === 'agent'`), clicking the green `+` (Add Task) skips the `New Task` picker dialog and directly creates a Standard Chat task and opens its chat.

**Architecture:** Branch once in `Sidebar.handleAddTask`: agent items run the existing standard-chat create-and-navigate path directly; all other item types keep the picker flow unchanged. Extract the standard path into a shared helper so picker-pick and direct-path cannot drift. Frontend-only, no backend/migration/API change.

**Tech Stack:** Vue 3 + Pinia (`useWorkspacesStore`), vue-router, existing `api.createTask` / `workspacesStore.addTask`, vitest.

## Global Constraints

- Frontend-only. No migration, no new endpoint, no wire-shape change, no new dependency.
- `AddTaskPickerDialog` (Standard Chat / Routine / Memory cards) stays exactly as-is for non-agent parents (folder, kanban-via-sidebar).
- Standard-chat semantics unchanged: auto-name `New Chat` (`DEFAULT_NEW_CHAT_NAME`), `setActiveTask` + `router.replace` with `buildTaskUrlQuery` (workspace/item breadcrumb preserved).
- Routine/Memory under agent items become unreachable via sidebar `+` — accepted per request ("directly open a chat"). Do NOT delete routine/memory code paths.
- Follow repo Vue patterns: `ref` picker state, `data-testid` selectors, Teleport-tested dialogs (see `AddTaskPickerDialog.spec.ts` + `vue-teleport-vitest-document-queryselector` skill).
- `pnpm` (not npm/bun) for frontend commands. `vue-tsc --noEmit` must stay clean.

## Current Flow (ground truth, verified 2026-09-09)

- Picker component: `src/apps/desktop/src/components/dialogs/AddTaskPickerDialog.vue:1-135` — props `show`, emits `close` + `pick: 'standard'|'routine'|'memory'`; Standard card `89-102` → `handleStandard:31-34` emits `pick='standard'` + `close`.
- `+` button (ALL item types): `src/apps/desktop/src/components/workspace/WorkspaceItem.vue:637-645` → `handleAddTask:179-182` emits `addTask`.
- Forward: `WorkspaceList.vue:217,681` → `Sidebar.vue:774-778` `handleAddTask(wsId, item)` sets `pickerWorkspaceId/pickerItemId` + `showAddTaskPicker=true`; mounted at `Sidebar.vue:1624`.
- Standard pick: `Sidebar.vue:794-832` `handleAddTaskPick('standard')` clears picker refs, `workspacesStore.addTask(ws, item, { name: 'New Chat' })` (`:809-811`), `setActiveTask(:813)`, `router.replace({ path:'/app', query: buildTaskUrlQuery(...) })` (`:821-830`).
- Store: `src/apps/desktop/src/stores/workspaces.ts:1154-1230` `addTask()` → `api.createTask` (`api/index.ts:846-849` → `POST /workspaces/:ws/items/:item/tasks { name, task_type:'standard' }`).
- Agent item identity: `workspace_items.item_type === 'agent'` (exact string, Migration 076 spec at `src/migrations/migration.zig:3297-3298`; created by `workspace_items_create_agent.zig:128,132`). Agent open = `?view=workspace&itemId=X`, chat-open = same + `chatTaskId` (`useCurrentMainView.ts:38-84`); main pane `AgentView` vs `AgentChatView` (`AppLayout.vue:2539-2566`). `AgentView` deliberately has NO New Chat button (`AgentView.spec.ts:298`, hint at `AgentView.vue:671-673`).
- External picker entry `Sidebar.vue:125-129` `openTaskPicker(wsId, itemId)` is only called by `KanbanView` column `+` — kanban-only, unaffected.

## File Map

| File | Change |
|---|---|
| `src/apps/desktop/src/components/shell/Sidebar.vue` (~774-832) | ONLY production change: branch on `item.item_type === 'agent'` + extract `createAndOpenStandardChat(workspaceId, itemId)` helper shared by direct path and `handleAddTaskPick('standard')` |
| `src/apps/desktop/src/components/shell/__tests__/Sidebar.addTask.spec.ts` (new; or extend existing Sidebar spec if one covers `handleAddTask`) | Failing-then-passing tests for agent-bypass vs non-agent-picker |
| `src/apps/desktop/src/__tests__/AddTaskPickerDialog.spec.ts` | NO change (regression guard only) |
| `docs/SPEC.md` (if it documents the picker) | 1-line note if applicable, else skip |

## Tasks

### Task 1 — Failing test: agent `+` skips picker, creates + navigates

- [ ] Read `Sidebar.vue:774-832` + `AddTaskPickerDialog.spec.ts:54-67` (Teleport + `document.querySelector` pattern) + desktop-frontend-build skill for spec placement.
- [ ] Write failing spec `Sidebar.addTask.spec.ts`:
  - [ ] Case A (agent): call `handleAddTask(wsId, { id, item_type: 'agent' })` → expect `showAddTaskPicker === false` / no `[data-testid="add-task-picker"]` in DOM, expect `workspacesStore.addTask` called once with `{ name: 'New Chat' }`, expect `setActiveTask` + `router.replace` called with `taskId`.
  - [ ] Case B (folder/kanban regression): call `handleAddTask(wsId, { id, item_type: 'folder' })` → expect picker opens (`showAddTaskPicker === true`), expect `addTask` NOT called yet.
- [ ] Run it and confirm it FAILS (picker opens for agent today).
- [ ] Commit failing test (separate commit, message `test: agent-mode + skips picker (failing)`).

### Task 2 — Implement the branch + shared helper

- [ ] In `Sidebar.vue`, extract lines `803-832` (standard create+navigate block) into `const createAndOpenStandardChat = async (workspaceId: string, itemId: string) => {...}` with identical body (same `DEFAULT_NEW_CHAT_NAME`, same `buildTaskUrlQuery` fields).
- [ ] Rewrite `handleAddTask` to:
  ```ts
  const handleAddTask = (workspaceId: string, item: WorkspaceItem) => {
    if (item.item_type === 'agent') {
      void createAndOpenStandardChat(workspaceId, item.id)
      return
    }
    pickerWorkspaceId.value = workspaceId
    pickerItemId.value = item.id
    showAddTaskPicker.value = true
  }
  ```
- [ ] Rewrite `handleAddTaskPick('standard')` branch to `await createAndOpenStandardChat(workspaceId, itemId)` (keep the null-guard + picker-ref clearing above it). Routine/memory branches untouched.
- [ ] Leave `openTaskPicker()` (line 125) unchanged — kanban-only caller; add a code comment noting agent items never route through it.
- [ ] Run the Task 1 spec → must PASS.
- [ ] Run `pnpm test:unit` (full) + `npx vue-tsc --noEmit -p tsconfig.app.json` → clean.
- [ ] Commit (`feat: agent-mode + opens chat directly, skips picker`).

### Task 3 — Manual verification + edge review

- [ ] Manual: create/select an agent item → click green `+` → new `New Chat` row appears under the agent item AND `AgentChatView` opens immediately, no dialog flash. Reload → chat persists via URL.
- [ ] Manual regression: folder item `+` still shows the 3-card `New Task` dialog (screenshot in task); Standard still auto-navigates; Routine/Memory dialogs still open.
- [ ] Confirm no console errors, no double-create on double-click (existing `processingState` guard covers spam; note if a second guard is needed).
- [ ] If `docs/SPEC.md` or `2026-08-15-agent-mode.md` / `2026-08-22-agent-mode-ui-ux.md` describe the picker, append a 1-line amendment; otherwise skip docs.
- [ ] Report back for human review (card stays in `in_review_planning`; implementation happens only after approval).

## Open Questions for Reviewer

1. Routine/Memory under agent items become sidebar-unreachable — intended? (If they must stay reachable, alternative: keep picker for agent but pre-select/double-size Standard; NOT recommended — adds noise the request explicitly removes.)
2. Should `AgentView` (empty state, currently "Start a conversation from the sidebar" hint) also gain an inline `New Chat` button using the same helper? Suggest follow-up, not this plan.
3. Title default stays `New Chat` (auto-rename-on-first-message convention) — confirm no custom naming needed for agent chats.

## Verification

- [ ] Plan saved to `docs/superpowers/plans/2026-09-09-agent-mode-direct-chat.md`
- [ ] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task has bite-sized steps (test → implement → verify → commit)
- [ ] User has reviewed the plan before execution begins
