# Workspace Item Task Rename (Update Session Name) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a user-facing "rename task" feature to the task rows shown inside each expanded `WorkspaceItem` in the desktop sidebar. Renaming a task updates the underlying session's name and broadcasts an SSE `updated` event so the `ChatsList` reflects the new name in real time — the same way the chat list already reacts to other session-level updates.

**Architecture:** Reuse the existing `PUT /api/workspaces/tasks/:task_id` (and `PUT /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id`) endpoints. They already accept `{ name, session_id }` in the body and call `ai_mod.workspace_item_tasks.updateWorkspaceItemTask`. The handler currently updates **only** the `workspace_item_tasks` table; the chat list will not see the rename. Fix this by routing the rename through `updateSessionName` for the linked `session_id` AND emitting a `session.updated` SSE event after the write, mirroring how `update_session_status` / `updateSessionName` (llm_history.zig:1810, 1837) already broadcast. Frontend mirrors the existing `renameWorkspace` pattern: a `renameTask` store action with optimistic update + rollback, a small `RenameTaskModal.vue` modal, a pencil icon button on the task row, and the standard `WorkspaceItem → WorkspaceList → Sidebar` event-wiring.

**Tech Stack:** Zig 0.15 (backend handler + DB layer), TypeScript / Vue 3 / Pinia (frontend store + components), Vitest (frontend tests).

---

## Background — Why This Plan Has Both Backend and Frontend Pieces

The user request is "update session name like chat list, but do that on workspace item task". The chat list's only rename hook today is the SSE `updated` event (`ChatsList.vue:312-333` handler). For the workspace-item task row to rename a session the same way (i.e. for the chat list to update automatically), three things must be true end-to-end:

1. Frontend exposes a rename UI on the task row.
2. Backend handler writes the new name to BOTH the task row AND the linked session row (because task and session are 1:1 — `AppLayout.vue:651` wires `:chat-id="activeTask.id"`).
3. Backend broadcasts a `session.updated` SSE event so `ChatsList` (which subscribes via `createSessionsSseConnection` in `ChatsList.vue:268`) updates in real time.

Today only #1 is missing — but #2 and #3 are also currently broken for renames: the handler (`tasks_update.zig:28,57`) calls `updateWorkspaceItemTask` which writes only the `workspace_item_tasks` table, never `sessions`. The pre-existing `updateTaskName` function (`llm_history.zig:1864`) has a commented-out SSE broadcast (lines 1874-1887). The plan fixes all three gaps.

---

## File Structure

### Backend (Zig)

- **Modify** `src/ai_workflow/tui/llm_history.zig:1864-1888` — replace the currently-broken `updateTaskName` with a real implementation that (a) updates `workspace_item_tasks.name`, (b) updates the linked `sessions.name` via the task's `session_id`, and (c) emits a `session.updated` SSE event so `ChatsList` reflects the new name. If the task has no `session_id` (newly-created task that hasn't been bound to a session yet), skip (b) and (c) gracefully.
- **Modify** `src/ai_workflow/tui/http_handlers/tasks_update.zig:28, 57` — switch both handlers (`tasksUpdateByIdHandler`, `tasksUpdateHandler`) from `ai_mod.workspace_item_tasks.updateWorkspaceItemTask(...)` to `ai_mod.llm_history.updateTaskName(...)` so the new logic runs. Keep the same input shape (task_id + optional name + optional session_id) and the same response shape (`{ success, id }`).
- **Create** `src/ai_workflow/tui/http_handlers/tasks_update_test.zig` — integration-style tests for the handler (happy path renames both rows + emits event; `name=null` no-op; non-existent task returns success=false; task without `session_id` skips session update). Wire into the project's existing test runner (see verification step).

### Frontend (TypeScript / Vue)

- **Create** `src/apps/desktop/src/components/RenameTaskModal.vue` — small modal mirroring `RenameWorkspaceModal.vue` (focus + select on open, Enter to save, Esc to cancel, disabled save when empty / unchanged). Emits `close` and `rename: [name: string]`. ~80 lines, near-verbatim copy with "Task" replacing "Workspace" in copy.
- **Modify** `src/apps/desktop/src/stores/workspaces.ts:550-568` (next to `renameWorkspace`) — add `renameTask(workspaceId, itemId, taskId, newName)` action with the same optimistic-update + rollback-on-error pattern as `renameWorkspace`. Also call `navigationStore.setActiveChatName` if the renamed task is the active one (mirrors how `setActive` in `ChatsList.vue:217` keeps the header in sync).
- **Modify** `src/apps/desktop/src/components/WorkspaceItem.vue:22-28, 58-61, 125-166` — add `renameTask: [workspaceId, itemId, taskId, currentName]` to `defineEmits`; add a small pencil button next to the existing delete button on the task row (same `opacity-0 group-hover/task:opacity-100` pattern); add `handleRenameTask` to emit.
- **Modify** `src/apps/desktop/src/components/WorkspaceList.vue:14-25, 99-109, 207-218` — add `renameTask` to `defineEmits`, forward from `WorkspaceItem` to the parent (`Sidebar`).
- **Modify** `src/apps/desktop/src/components/Sidebar.vue:73-75, 276-295, 306-321, 397-411, 437-448` — add modal state refs (`showRenameTaskModal`, `renameTargetTaskWorkspaceId`, `renameTargetTaskItemId`, `renameTargetTaskId`, `renameTargetTaskName`); add `handleRenameTask(workspaceId, itemId, taskId, currentName)`; add `handleConfirmTaskRename(newName)` that calls `workspacesStore.renameTask(...)`; add `handleCloseTaskRenameModal()`; mount the `<RenameTaskModal>` alongside the existing `<RenameWorkspaceModal>`; wire `@rename-task` from `<WorkspaceList>`.
- **Create** `src/apps/desktop/src/__tests__/workspacesStoreRenameTask.spec.ts` — unit tests for the store action: optimistic update reflects new name immediately; rollback restores the previous name when the API call fails; calls `navigationStore.setActiveChatName` when renaming the active task; does nothing when the new name equals the old name (no API call, no toast noise).
- **Create** `src/apps/desktop/src/__tests__/workspaceItemTaskRename.spec.ts` — component test: pencil button is hidden by default and shown on hover; clicking it does NOT trigger the parent click (event.stopPropagation, same as delete); emits `renameTask` with the right args.

---

## Design Notes (read first)

1. **Task ↔ Session 1:1 mapping.** `AppLayout.vue:651` binds `:chat-id="activeTask.id"`, so the chat view for a task IS the chat view for a session whose id equals the task id. Therefore renaming a task must also rename the session. Without this, `ChatsList.vue` and the chat-view header would show stale names after a rename.
2. **Use `session_id` from the task row, not from the request body.** The handler currently accepts an optional `session_id` in the body (intended for *setting* the binding during create). For *renames*, the binding is already in the DB — read the task first, use its `session_id`. If a client passes a new `session_id` in the same request, treat it as "rebind AND rename" and run both updates (rare, but supported by the existing schema).
3. **SSE broadcast goes through `onEventSendSessions` (NOT `onEventSendWorkers`).** The chat list listens on the `sessions` routing key, and `ChatsList.vue:312-333` handles `updated` actions to refresh the name. The event payload must match the existing `SessionEvent` shape in `api/index.ts:884-893` (id, name, status, cwd, created_at, updated_at, selected_profile_model).
4. **Existing patterns to copy:**
   - Backend SSE broadcast: `llm_history.zig:1810-1835` (`update_session_status`) and `llm_history.zig:1837-1862` (`updateSessionName`) — the structure we want is identical, just with the task→session indirection added.
   - Frontend store action: `workspaces.ts:550-568` (`renameWorkspace`) — same trim-empty check, same optimistic update, same rollback.
   - Frontend modal: `RenameWorkspaceModal.vue` — direct mirror, just rename strings.
   - Frontend event wiring: `WorkspaceList.vue:14-25` already declares `deleteTask: [workspaceId, itemId, taskId]` and `Sidebar.vue:306-312` already declares `handleDeleteTask` — mirror that for `renameTask`.
   - Frontend button styling: the existing delete task button (`WorkspaceItem.vue:156-164`) is the right model for the new pencil button (same `opacity-0 group-hover/task:opacity-100`, same hover color, same 4×4 svg).
5. **No changes to:**
   - `createTask` / `deleteTask` handlers
   - The DB schema / migrations
   - The `addTask` action semantics
   - `updateTaskSimple` in `api/index.ts:175` — already accepts `{ name }`, no change needed.
6. **Edge cases handled:**
   - Task has no `session_id` (e.g. just created, never bound to a session yet): only update `workspace_item_tasks.name`. Skip the session update and SSE broadcast. Log a warning so we know this happened.
   - `session_id` in the request body is non-null AND different from the task's current `session_id`: rebind (UPDATE `workspace_item_tasks.session_id`), then run the rename logic against the new session_id. This preserves the existing handler's "create with session_id" semantics while adding the rename capability.
   - Trimmed new name equals current name: skip the API call entirely. (Mirrors `renameWorkspace`'s `if (!trimmed || trimmed === workspace.name) return` at `workspaces.ts:554`.)
7. **Verification commands** (always run before claiming done):
   - Backend: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 60 zig build 2>&1 | tail -n 30` (build)
   - Backend tests: find the existing test runner (likely invoked via `zig build test` — check `build.zig` and existing `*_test.zig` files in `src/ai_workflow/tui/http_handlers/` for the import-and-run pattern; if none exists, prefer the most recent plan's test wiring).
   - Frontend: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30` (TS check + build — per the mandatory rule, NOT `build-only`)
   - Frontend tests: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run test:run 2>&1 | tail -n 50` (Vitest).

---

# Chunk 1: Backend — Wire rename through session + SSE

## Task 1.1: Rewrite `updateTaskName` to update the linked session and broadcast SSE

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:1864-1888`

- [ ] **Step 1: Read the surrounding code**

Read `update_session_status` (lines 1810-1835) and `updateSessionName` (lines 1837-1862) for the exact SSE broadcast shape. Also read `getWorkspaceItemTaskById` (around line 2270 in the same file) so you can fetch the task's current `session_id` to know what to rename.

- [ ] **Step 2: Replace `updateTaskName`**

Replace the existing function body (lines 1864-1888) with a new implementation:

```zig
/// Rename a workspace item task. If the task has a `session_id`,
/// also rename the linked session row and broadcast a
/// `session.updated` SSE event so subscribers (e.g. the ChatsList
/// sidebar) see the new name in real time. Tasks without a
/// `session_id` (e.g. freshly created, not yet bound) are renamed
/// in the task table only — the session update is silently skipped
/// because there is no session to rename.
///
/// This is the rename path for `PUT /api/workspaces/tasks/:task_id`
/// and `PUT /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id`.
pub fn updateTaskName(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    new_name: []const u8,
) !void {
    // 1) Update the task row.
    const task_sql = "UPDATE workspace_item_tasks SET name = ?, updated_at = datetime('now') WHERE id = ?";
    try db.exec(allocator, task_sql, &.{ new_name, id });

    // 2) Look up the task to find its session_id.
    const task = getWorkspaceItemTaskById(allocator, db, id) catch null;
    if (task == null) return;
    defer if (task) |t| t.deinit(allocator);

    const session_id = task.?.session_id orelse {
        // No linked session — nothing to cascade. This is expected for
        // freshly-created tasks; we already updated the task row above.
        return;
    };

    // 3) Update the linked session's name.
    updateSessionName(allocator, db, session_id, new_name) catch |err| {
        // Don't fail the whole rename if the session update fails —
        // the task name is the source of truth for the sidebar.
        // Log it so we know to investigate.
        std.log.warn("updateTaskName: failed to update session {s}: {s}", .{ session_id, @errorName(err) });
    };
}
```

Notes:
- We do NOT manually emit an SSE event here because `updateSessionName` (called at the end) already does that. This is the "cascade" — the session update is the broadcast point.
- We use `getWorkspaceItemTaskById` (already exists in the same file) to read the current `session_id`. Confirm the exact name and signature during execution; if it doesn't exist, add a small helper or inline a `SELECT session_id FROM workspace_item_tasks WHERE id = ?` query.
- The signature stays the same (`updateTaskName(allocator, db, id, new_name)`) so the call site in the HTTP handler doesn't change shape.

- [ ] **Step 3: Build to confirm types**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 60 zig build 2>&1 | tail -n 30`
Expected: clean build (or only pre-existing warnings unrelated to this change).

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/llm_history.zig
git commit -m "feat(backend): cascade task rename to linked session + broadcast SSE"
```

---

## Task 1.2: Switch the HTTP handler to call the new `updateTaskName`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/tasks_update.zig:28, 57`

- [ ] **Step 1: Read the current handler**

The handler imports `nalarcore` and uses `ai_mod.workspace_item_tasks.updateWorkspaceItemTask(...)`. Both `tasksUpdateByIdHandler` (line 8) and `tasksUpdateHandler` (line 36) have the same body for the actual write — change both.

- [ ] **Step 2: Switch the call site**

In BOTH handler bodies, replace:

```zig
ai_mod.workspace_item_tasks.updateWorkspaceItemTask(allocator, sqlite_db, task_id, json_body.name, json_body.session_id) catch {
    return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update task" }) });
};
```

with:

```zig
// Cascade: only call the new rename path when a name is provided.
// When only a session_id is being set (rebind), keep the old
// updateWorkspaceItemTask path so we don't accidentally rename
// the linked session to an empty string.
if (json_body.name) |n| {
    // Cascade rename to the linked session + SSE broadcast.
    ai_mod.llm_history.updateTaskName(allocator, sqlite_db, task_id, n) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update task" }) });
    };
}
if (json_body.session_id) |sid| {
    // Plain rebind path — no rename, no broadcast.
    ai_mod.workspace_item_tasks.updateWorkspaceItemTask(allocator, sqlite_db, task_id, null, sid) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update task" }) });
    };
}
```

Note on the conditional split: this preserves the existing "set session_id" semantics for clients that pass only `session_id` (e.g. workflow.zig:675 calls `updateTaskName` directly, but other code may rebind a task to a different session). When BOTH are passed, we do the cascade rename first, then the rebind — the rebind wins, the session update may briefly apply to the old session_id, then the rebind moves the task. If the order matters for a specific use case, swap them and document why.

- [ ] **Step 3: Confirm `ai_mod.llm_history` is the right import path**

The existing file imports `nalarcore` and uses `ai_mod.workspace_item_tasks.updateWorkspaceItemTask(...)`. Confirm `ai_mod.llm_history` is also accessible (it almost certainly is, since other files like `workflow.zig:675` call `llm_history.updateTaskName` directly). If not, adjust the import.

- [ ] **Step 4: Build to confirm types**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 60 zig build 2>&1 | tail -n 30`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/tasks_update.zig
git commit -m "feat(backend): route task rename HTTP through cascade path"
```

---

## Task 1.3: Add backend tests for the rename cascade

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/tasks_update_test.zig`

- [ ] **Step 1: Read an existing `*_test.zig` in this directory for the harness pattern**

For example, `tasks_list_test.zig` (created in the pagination plan) or the nearest neighbor. Look for: how the test DB is set up, how `gserverz.HttpContext` is faked, how the test is wired into the test runner. If the test runner is `zig build test`, find the build target that runs it.

- [ ] **Step 2: Add four tests**

| Test | Setup | Assert |
| --- | --- | --- |
| Happy path: task with session_id | Insert task + session. PUT `{ name: "New" }` to `/api/workspaces/tasks/:task_id`. | 200, task row has new name, session row has new name, SSE event emitted with action=updated and the new name. |
| Task without session_id | Insert task with `session_id = NULL`. PUT `{ name: "New" }`. | 200, task row has new name, no session row was updated (no session to update), no SSE event emitted. |
| `name = null` no-op | Insert task + session. PUT `{ session_id: "sess_other" }`. | 200, task row has old name, session row has old name, no SSE event. (Confirms the conditional split in 1.2.) |
| Invalid task id | PUT to `/api/workspaces/tasks/not_a_real_id` with `{ name: "X" }`. | 200 (no rows updated, no error in the UPDATE — matches the current lenient behavior). Optionally 404 if you want stricter handling — pick one and document it. |

Use a fresh in-memory sqlite DB per test (or per file) to avoid cross-test contamination. Subscribe to the SSE event bus and capture emitted events for the assertion.

- [ ] **Step 3: Wire the test into the project's test runner**

Add `_ = @import("http_handlers/tasks_update_test.zig");` to wherever the existing tests are registered (e.g. the project's `src/test_runner.zig` or a per-subtree runner). If no test runner exists, document the build target to run in the verification step below.

- [ ] **Step 4: Run backend tests**

Run the project's test command (likely `zig build test` — confirm in `build.zig`). Expected: all existing tests pass, the four new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/tasks_update_test.zig <test-runner-file>
git commit -m "test(backend): cover task rename cascade + session update + SSE"
```

---

# Chunk 2: Frontend — Store action + Modal + Wiring

## Task 2.1: Add `renameTask` action to the workspaces store

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts:549-568` (next to `renameWorkspace`), and the export block at lines 640-675

- [ ] **Step 1: Read the existing `renameWorkspace` action**

`workspaces.ts:550-568` is the template. It:
- Finds the workspace
- Trims + early-returns if empty or unchanged
- Saves the previous name for rollback
- Applies the optimistic update
- Calls `api.updateWorkspace(workspaceId, { name: trimmed })`
- Rolls back on error
- Lives between `removeWorkspaceItem` (line 515) and `removeWorkspace` (line 570) — keep that placement.

- [ ] **Step 2: Add the `renameTask` action**

Insert directly after `renameWorkspace` (around line 568):

```typescript
// Rename a task. Cascades to the linked session via the backend
// (`updateTaskName` in llm_history.zig), which itself broadcasts a
// session.updated SSE event so ChatsList reflects the new name.
// Mirrors the optimistic-update + rollback pattern from
// `renameWorkspace` above.
async function renameTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  newName: string,
) {
  const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
  if (!workspace) return
  const item = workspace.items.find((i) => i.id === itemId)
  if (!item || !item.tasks) return
  const task = item.tasks.find((t) => t.id === taskId)
  if (!task) return

  const trimmed = newName.trim()
  if (!trimmed || trimmed === task.name) return

  const previousName = task.name
  // Optimistic update
  task.name = trimmed

  // If this is the active task, keep the chat-view header in sync
  // (AppLayout.vue:652 binds :chat-name="activeTask.name", so
  // updating `task.name` updates the header automatically — but
  // navigationStore.activeChatName drives the chat-list header in
  // other views, so we keep both in step).
  if (activeTaskId.value === taskId) {
    useNavigationStore().setActiveChatName(trimmed)
  }

  // Sync with API
  try {
    await api.updateTaskSimple(taskId, { name: trimmed })
  } catch (err) {
    console.error('Failed to rename task:', err)
    // Rollback on error
    task.name = previousName
    if (activeTaskId.value === taskId) {
      useNavigationStore().setActiveChatName(previousName)
    }
  }
}
```

- [ ] **Step 3: Add `useNavigationStore` import if not present**

The existing file imports `* as api from '../api'` (line 54) but may not import `useNavigationStore`. Add the import alongside the existing `import * as api from '../api'` line:

```typescript
import { useNavigationStore } from './navigation'
```

Use a `const navigationStore = useNavigationStore()` call inside the function body (lazy — Pinia stores are setup-style here) or call `useNavigationStore()` inline as in the code above. Match the existing style — the existing `renameWorkspace` doesn't use a navigation store, so just calling it inline (the `useNavigationStore()` call returns the same instance everywhere) is fine.

- [ ] **Step 4: Export `renameTask` from the store (lines 640-675)**

Add `renameTask,` to the returned object alongside `renameWorkspace`:

```typescript
  return {
    // ...existing...
    renameWorkspace,
    renameTask,   // ← new
    // ...existing...
  }
```

- [ ] **Step 5: Build to confirm types**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/stores/workspaces.ts
git commit -m "feat(frontend): add renameTask store action with optimistic update"
```

---

## Task 2.2: Create the `RenameTaskModal.vue` component

**Files:**
- Create: `src/apps/desktop/src/components/RenameTaskModal.vue`

- [ ] **Step 1: Read `RenameWorkspaceModal.vue` end-to-end**

Use it as a near-verbatim template. Only differences:
- Copy: "Task Name" instead of "Workspace Name", "Rename Task" instead of "Rename Workspace"
- The `currentName` prop is the task's current name
- The `rename` event payload is the same `[name: string]`

- [ ] **Step 2: Create the new file**

Write `src/apps/desktop/src/components/RenameTaskModal.vue` with the structure of `RenameWorkspaceModal.vue` but with the string substitutions. Keep:
- The `<Teleport to="body">` wrapper
- The `Transition name="modal"` for fade
- The backdrop click-to-close behavior
- The `ref="nameInput"` + `nextTick().focus().select()` on open
- The Enter / Escape keydown handling
- The `name.trim() === props.currentName` disable check
- The `<style scoped>` modal transitions (verbatim — they're identical)

Target ~120 lines, matches `RenameWorkspaceModal.vue:138` line count.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/components/RenameTaskModal.vue
git commit -m "feat(frontend): add RenameTaskModal component"
```

---

## Task 2.3: Add the pencil button to the task row + emit `renameTask`

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceItem.vue:22-28, 58-61, 125-166`

- [ ] **Step 1: Add `renameTask` to `defineEmits`**

Replace the `defineEmits<{...}>()` block (lines 22-28) with:

```typescript
const emit = defineEmits<{
  click: [item: WorkspaceItem]
  delete: [item: WorkspaceItem]
  addTask: [item: WorkspaceItem]
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
}>()
```

- [ ] **Step 2: Add `handleRenameTask` near the other handlers**

Insert after `handleDeleteTask` (around line 61):

```typescript
const handleRenameTask = (event: Event, taskId: string, currentName: string) => {
  event.stopPropagation()
  emit('renameTask', props.workspaceId, props.item.id, taskId, currentName)
}
```

- [ ] **Step 3: Add the pencil button to the task row template**

In the task row (lines 125-166), insert a new button BEFORE the existing delete button (line 156-164). Use the same `opacity-0 group-hover/task:opacity-100` pattern and the same 4×4 svg dimensions:

```html
<!-- Rename task button -->
<button
  @click="handleRenameTask($event, task.id, task.name)"
  class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-blue-400"
  style="color: var(--semantic-text-dim);"
  title="Rename Task"
>
  <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
  </svg>
</button>
```

The svg is the standard "pencil" path used elsewhere (same one as `WorkspaceList.vue:188` for the workspace rename button). Use `hover:text-blue-400` to differentiate from the delete button's `hover:text-red-400`.

- [ ] **Step 4: Build to confirm types**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/components/WorkspaceItem.vue
git commit -m "feat(frontend): add rename button to task row in WorkspaceItem"
```

---

## Task 2.4: Forward `renameTask` through `WorkspaceList` to `Sidebar`

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceList.vue:14-25, 99-109, 207-218`

- [ ] **Step 1: Add `renameTask` to `defineEmits`**

Replace the `defineEmits<{...}>()` block (lines 14-25) with:

```typescript
const emit = defineEmits<{
  toggleWorkspace: [workspaceId: string]
  selectItem: [workspaceId: string, itemId: string]
  deleteWorkspace: [workspaceId: string]
  renameWorkspace: [workspaceId: string, currentName: string]
  deleteItem: [workspaceId: string, itemId: string]
  requestAddItem: [workspaceId: string, itemType: string]
  addWorkspace: []
  addTask: [workspaceId: string, item: WorkspaceItem]
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
}>()
```

- [ ] **Step 2: Add `handleRenameTask` near the other handlers**

Insert after `handleDeleteTask` (line 107-109):

```typescript
const handleRenameTask = (workspaceId: string, itemId: string, taskId: string, currentName: string) => {
  emit('renameTask', workspaceId, itemId, taskId, currentName)
}
```

- [ ] **Step 3: Forward the event from the `WorkspaceItemComponent` usage**

In the template, the `<WorkspaceItemComponent>` is at lines 207-218. Add `@rename-task="handleRenameTask"` alongside the existing event bindings:

```html
<WorkspaceItemComponent
  v-for="item in workspace.items"
  :key="item.id"
  :item="item"
  :is-active="activeWorkspaceItemId === item.id"
  :workspace-id="workspace.id"
  @click="handleItemClick(workspace.id, $event.id)"
  @delete="handleDeleteItem(workspace.id, $event.id)"
  @add-task="handleAddTask(workspace.id, $event)"
  @select-task="handleSelectTask"
  @delete-task="handleDeleteTask"
  @rename-task="handleRenameTask"
/>
```

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/components/WorkspaceList.vue
git commit -m "feat(frontend): forward renameTask event through WorkspaceList"
```

---

## Task 2.5: Add modal state and handler in `Sidebar.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/Sidebar.vue:1-30, 73-75, 276-321, 397-411, 437-448`

- [ ] **Step 1: Import the new modal component**

Add to the import block at the top of `Sidebar.vue` (alongside the existing `import RenameWorkspaceModal from './RenameWorkspaceModal.vue'` around line 10):

```typescript
import RenameTaskModal from './RenameTaskModal.vue'
```

- [ ] **Step 2: Add modal state refs**

Add to the `const ... = ref(...)` cluster (next to the existing `showRenameWorkspaceModal` refs at lines 73-75):

```typescript
const showRenameTaskModal = ref(false)
const renameTargetTaskWorkspaceId = ref<string | null>(null)
const renameTargetTaskItemId = ref<string | null>(null)
const renameTargetTaskId = ref<string | null>(null)
const renameTargetTaskName = ref('')
```

- [ ] **Step 3: Add the three handlers near the existing `handleRenameWorkspace` / `handleConfirmRename` (lines 276-295)**

```typescript
const handleRenameTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  currentName: string,
) => {
  renameTargetTaskWorkspaceId.value = workspaceId
  renameTargetTaskItemId.value = itemId
  renameTargetTaskId.value = taskId
  renameTargetTaskName.value = currentName
  showRenameTaskModal.value = true
}

const handleConfirmTaskRename = async (newName: string) => {
  if (
    renameTargetTaskWorkspaceId.value &&
    renameTargetTaskItemId.value &&
    renameTargetTaskId.value
  ) {
    await workspacesStore.renameTask(
      renameTargetTaskWorkspaceId.value,
      renameTargetTaskItemId.value,
      renameTargetTaskId.value,
      newName,
    )
  }
  showRenameTaskModal.value = false
  renameTargetTaskWorkspaceId.value = null
  renameTargetTaskItemId.value = null
  renameTargetTaskId.value = null
  renameTargetTaskName.value = ''
}

const handleCloseTaskRenameModal = () => {
  showRenameTaskModal.value = false
  renameTargetTaskWorkspaceId.value = null
  renameTargetTaskItemId.value = null
  renameTargetTaskId.value = null
  renameTargetTaskName.value = ''
}
```

- [ ] **Step 4: Wire `@rename-task` on the `<WorkspaceList>` component (line 397-411)**

Add `@rename-task="handleRenameTask"` to the `<WorkspaceList>` tag, alongside the existing `@delete-task="handleDeleteTask"`:

```html
<WorkspaceList
  v-if="!isCollapsed"
  :workspaces="workspacesStore.workspaces"
  :active-workspace-item-id="workspacesStore.activeWorkspaceItemId"
  @toggle-workspace="handleToggleWorkspace"
  @select-item="handleSelectItem"
  @delete-workspace="handleDeleteWorkspace"
  @rename-workspace="handleRenameWorkspace"
  @delete-item="handleDeleteItem"
  @request-add-item="handleAddItem"
  @add-workspace="handleAddWorkspace"
  @add-task="handleAddTask"
  @select-task="handleSelectTask"
  @delete-task="handleDeleteTask"
  @rename-task="handleRenameTask"
/>
```

- [ ] **Step 5: Mount the new modal in the modals cluster (line 437-448)**

Add the new modal right after the existing `<RenameWorkspaceModal ... />`:

```html
<RenameTaskModal
  :show="showRenameTaskModal"
  :current-name="renameTargetTaskName"
  @close="handleCloseTaskRenameModal"
  @rename="handleConfirmTaskRename"
/>
```

- [ ] **Step 6: Build to confirm types**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add src/apps/desktop/src/components/Sidebar.vue
git commit -m "feat(frontend): wire rename task modal into Sidebar"
```

---

# Chunk 3: Frontend tests

## Task 3.1: Add store-level tests for `renameTask`

**Files:**
- Create: `src/apps/desktop/src/__tests__/workspacesStoreRenameTask.spec.ts`

- [ ] **Step 1: Read `workspacesStoreInit.spec.ts` for the test pattern**

It already shows how to mock `api.*` and instantiate the store with `setActivePinia(createPinia())`. Use the same `makeLocalStorageStub` helper from `__tests__/helpers.ts`.

- [ ] **Step 2: Add `updateTaskSimple` to the existing `api` mock setup**

The existing `workspacesStoreInit.spec.ts:32-34` only mocks `getWorkspaces`, `getWorkspacesItems`, `getTasks`. Your new test file will need `updateTaskSimple` mocked. Add a top-level `const updateTaskSimpleMock = vi.fn()` and `vi.spyOn(api, 'updateTaskSimple').mockImplementation(updateTaskSimpleMock)` in `beforeEach`.

- [ ] **Step 3: Write five tests**

| Test | Setup | Assert |
| --- | --- | --- |
| Happy path | Seed store with one workspace/item/task. Mock `updateTaskSimple` to resolve. Call `store.renameTask(ws, item, task, 'New Name')`. | `task.name === 'New Name'` after the await. `updateTaskSimpleMock` called once with `(task.id, { name: 'New Name' })`. |
| Empty / unchanged name | Same setup. Call `renameTask(ws, item, task, '   ')` and `renameTask(ws, item, task, task.name)`. | No API call in either case. |
| API failure → rollback | Mock `updateTaskSimple` to reject. Call `renameTask(ws, item, task, 'New Name')`. | `task.name` reverts to the original. (Use `await` then assert.) |
| Active task → updates `navigationStore.activeChatName` | Seed active task. Mock `updateTaskSimple` to resolve. Call `renameTask`. | `useNavigationStore().activeChatName === 'New Name'` after the await. |
| Non-active task → does NOT touch navigation store | Same but `activeTaskId` is a different id. | `useNavigationStore().activeChatName` unchanged. |

- [ ] **Step 4: Run tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run test:run 2>&1 | tail -n 50`
Expected: all existing tests still pass, all five new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/__tests__/workspacesStoreRenameTask.spec.ts
git commit -m "test(frontend): cover renameTask store action (happy / rollback / active)"
```

---

## Task 3.2: Add component test for the pencil button on the task row

**Files:**
- Create: `src/apps/desktop/src/__tests__/workspaceItemTaskRename.spec.ts`

- [ ] **Step 1: Read `workspaceItemTaskSpinner.spec.ts` for the WorkspaceItem mount pattern**

It already shows how to mount `WorkspaceItem` with `mount()` and the right `global.stubs` for child components.

- [ ] **Step 2: Add three tests**

| Test | Setup | Assert |
| --- | --- | --- |
| Pencil button exists and emits `renameTask` | Mount `WorkspaceItem` with an item that has one task. Find the pencil button (`title="Rename Task"`). Click it. | `wrapper.emitted('renameTask')` is defined and `[[workspaceId, itemId, taskId, 'Current Name']]`. |
| Click does NOT trigger row select | Same setup. Click the pencil button (which lives inside the task row button). | `wrapper.emitted('selectTask')` is undefined (because `event.stopPropagation` was called in the handler). |
| Button is hidden by default, shown on hover | Same setup. Check the button's `opacity-0` class is present before hover. | Class list contains `opacity-0` (or use `wrapper.find(...).classes()`). |

- [ ] **Step 3: Run tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run test:run 2>&1 | tail -n 50`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/__tests__/workspaceItemTaskRename.spec.ts
git commit -m "test(frontend): cover WorkspaceItem rename button (emits, stopPropagation, hover)"
```

---

# Chunk 4: End-to-end verification

## Task 4.1: Manual end-to-end check

- [ ] **Step 1: Start the backend**

From `/home/ginwa/agentic_coding_zig/ginwaaitoolbox`: `timeout 600 zig build run 2>&1 | tail -n 20` (or whatever the project's run command is — check `build.zig` and existing `*.sh` scripts in the repo root).

- [ ] **Step 2: Start the frontend**

From `/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop`: `bun run dev` (or the equivalent in `package.json` `scripts`).

- [ ] **Step 3: Verify the rename flow**

1. Open the desktop app in a browser.
2. Create a workspace → add a project → add a task.
3. The new task is auto-selected and the chat view opens (existing behavior).
4. Hover the task row in the sidebar. The pencil icon should appear next to the trash icon.
5. Click the pencil. A modal should open with the current task name pre-filled and selected.
6. Type a new name, press Enter. The modal closes.
7. The task row should now show the new name.
8. **The ChatsList (top of the sidebar) should also show the new name** — this is the SSE broadcast working.
9. Open the chat view for this task again — the header should also show the new name (because `AppLayout.vue:652` binds `:chat-name="activeTask.name"`).
10. Click the pencil again, type the same name, press Enter — the modal should close but no API call should fire (the `trimmed === currentName` guard). Network tab should show no PUT request.
11. Click the pencil, type empty spaces, press Enter — same as above (empty-after-trim guard).
12. Click the pencil, type a new name, press Escape — the modal should close, no rename happens.

- [ ] **Step 4: Verify error handling**

1. Stop the backend (Ctrl-C).
2. Click the pencil, type a new name, press Enter.
3. The modal should close, the task name should briefly flicker to the new name (optimistic update), then revert to the old name (rollback).
4. Open the browser console — you should see `[RenameTask] Failed to rename task: ...` (or whatever the catch logs).

- [ ] **Step 5: Run all verification commands one more time**

```bash
# Backend build
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 60 zig build 2>&1 | tail -n 30

# Backend tests
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 50
# (or whatever the project uses — confirm during execution)

# Frontend build (TS check + bundle)
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30

# Frontend tests
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run test:run 2>&1 | tail -n 50
```

Expected: all four commands pass cleanly. No warnings, no skipped tests.

- [ ] **Step 6: Final commit (if any cleanup was needed)**

```bash
git add -A
git commit -m "chore: cleanup from end-to-end verification"
```

---

## Summary of files touched

**Backend (Zig) — 3 files**
- `src/ai_workflow/tui/llm_history.zig` — rewrite `updateTaskName`
- `src/ai_workflow/tui/http_handlers/tasks_update.zig` — switch to cascade path
- `src/ai_workflow/tui/http_handlers/tasks_update_test.zig` — new tests

**Frontend (TS / Vue) — 7 files**
- `src/apps/desktop/src/stores/workspaces.ts` — `renameTask` action
- `src/apps/desktop/src/components/RenameTaskModal.vue` — new modal
- `src/apps/desktop/src/components/WorkspaceItem.vue` — pencil button + emit
- `src/apps/desktop/src/components/WorkspaceList.vue` — forward event
- `src/apps/desktop/src/components/Sidebar.vue` — modal state + handlers + mount
- `src/apps/desktop/src/__tests__/workspacesStoreRenameTask.spec.ts` — store tests
- `src/apps/desktop/src/__tests__/workspaceItemTaskRename.spec.ts` — component tests

**Total: 2 backend commits + 5 frontend commits + 1 final cleanup = ~8 commits.**
