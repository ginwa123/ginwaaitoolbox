# Plan: Per-task `cwd_session` (optional project root on Add Task) + optional kanban cwd

**Date:** 2026-08-06
**Tasks:**
- task_1785959915548 (kanban: sprint bulan juni → "when user want to create a kanban, make cwd session as optional")
- Follow-up user clarification: *"after we create a kanban, and then want to add task, add field input to select folder so it will become a cwd session"*

**Status:** Awaiting user approval before implementation
**Worktree (planned):** `worktree/kanban-cwd-session-optional`
**Decision:** **Option B** — per-task `cwd_session` (the folder picked in the Add Task dialog sets the **task's** own cwd_session, not the kanban's). Falls back to kanban-level cwd, then to a per-session sandbox.

## Mental model (the user's flow)

```
1. Create kanban "Sprint 12"                    ← cwd-less (no project root required)
2. Add task "Fix auth bug"
     → Add Task dialog shows a "Project Root" picker (OPTIONAL)
     → User picks "/home/me/proj-A"  ← this becomes task.cwd_session
     → Submit
3. Task is created with cwd_session = "/home/me/proj-A"
4. User clicks "Run agent" on the task
     → Agent's cwd = "/home/me/proj-A"  (per-task cwd)
     → git/file tools work on /home/me/proj-A
5. Add task "Refactor design system"
     → User picks "/home/me/proj-B"  ← DIFFERENT folder
     → Task's cwd = "/home/me/proj-B"  (different task, different cwd)
6. Add task "Quick note to self"
     → User SKIPS the picker  ← no cwd picked
     → Falls back to kanban-level cwd (cwd-less if kanban is cwd-less)
     → Then falls back to per-session sandbox
```

**Each task can have its own cwd_session** (different repo per task).
The kanban-level cwd still exists as a **fallback** for tasks that didn't pick one.
A cwd-less kanban no longer forces ALL tasks to be cwd-less.

This unlocks the user's actual mental model:
- A kanban is a **board** (Sprint 12, Q3 Backlog, etc.) — not a project
- Each **task** targets its own repo / context
- The kanban-level cwd is only the **default** for tasks that don't specify one

## Resolution priority chain (when a chat session starts)

`session_create.zig::useCase` resolves the cwd in this order:

```
1. task.cwd_session  ← per-task (NEW column, Migration 070)
2. workspace_item.path  ← kanban-level (existing column)
3. createSandbox(...)  ← per-session TMPDIR/session_<id>/ (existing fallback)
```

The frontend sends `cwd_session: task.cwd_session ?? kanban.path ?? ''` —
the backend re-derives the fallback chain itself for safety, but the
frontend's resolution is the primary contract.

## The chain of effects (when this is implemented)

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. AddKanbanDialog submit WITHOUT a folder picked                   │
│    handleCreate: emits create(name, '') → handleClose()             │
│    (Same as before — AddKanbanDialog's path is OPTIONAL)            │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. workspacesStore.addKanbanItem(wsId, name, '')                    │
│    api.createKanban → backend stores NULL path                       │
│    item.path = '' (cwd-less kanban)                                  │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. KanbanView.vue banner "⚠️ Set project root" surfaces (existing)   │
│    Optional backfill — user can skip entirely                        │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4. User clicks "Add task" → KanbanTaskDetailDialog (create mode)     │
│    NEW: dialog shows "Project Root (optional)" field with picker     │
│    - User picks "/home/me/proj-A" → selectedPath = "/home/me/proj-A"│
│    - User skips → selectedPath = ''                                  │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 5. User clicks "Create" → dialog emits create payload                │
│    create({                                                            │
│      mode: 'create',                                                  │
│      name: '...', description: '...',                                 │
│      cwd_session: '/home/me/proj-A'  ← NEW payload field           │
│    })                                                                 │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 6. KanbanView.handleCreateTaskSave(payload)                          │
│    workspacesStore.addTask({ name, ..., cwdSession })                │
│      → api.createTask({ name, ..., cwd_session })                    │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 7. Backend: POST /api/workspaces/:wsId/items/:itemId/tasks           │
│    body: { name, description, cwd_session: '/home/me/proj-A', ... }│
│    TaskCreateRequest.cwd_session: ?[]const u8 = null  (NEW field)   │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 8. task_create.zig::useCase (standard path)                          │
│    createWorkspaceItemTask(                                          │
│      allocator, db, id, name, item_id, 'standard',                  │
│      description, tags, image_urls,                                  │
│      cwd_session  ← NEW 9th arg                                      │
│    )                                                                  │
│    INSERT INTO workspace_item_tasks (..., cwd_session, ...)          │
│      VALUES (..., ?, ...)                                            │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 9. Migration 070 — add cwd_session column                            │
│    ALTER TABLE workspace_item_tasks                                  │
│    ADD COLUMN cwd_session TEXT NOT NULL DEFAULT ''                   │
│    Existing rows backfill to '' (cwd-less legacy tasks)             │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 10. WorkspaceItemTaskInfo struct: add cwd_session field             │
│     SELECT includes t.cwd_session column                             │
│     WorkspaceItemTaskResponse.cwd_session: []u8 = "" (wire shape)    │
│     tasks_list.zig populates .cwd_session from result.tasks[].cwd_session│
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 11. Frontend Task interface: add cwdSession?: string                 │
│     workspacesStore normalizes task.cwdSession in addTask + update   │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 12. User clicks "Run agent" on the task (create_and_run mode)        │
│     KanbanView.handleCreateTaskSave(mode='create_and_run')           │
│       cwd: payload.cwd_session                                       │
│            || task.cwdSession                                        │
│            || item.path                                              │
│            || ''                                                      │
│     runAgentOnNewTask({ cwd, ... })                                   │
│     api.sendChatMessage(taskId, msg, cwdSession, ...)                  │
│       → POST /api/llm/session                                         │
│         body.cwd_session = '/home/me/proj-A'                          │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 13. session_create.zig::useCase (NEW 3-level fallback)               │
│     if (parsed.cwd_session.len > 0)                                   │
│         effective_cwd = cwd_session                                   │
│     else if (task_row.cwd_session.len > 0)  ← NEW                    │
│         effective_cwd = task_row.cwd_session                          │
│     else if (item_row.path.len > 0)                                  │
│         effective_cwd = item_row.path                                 │
│     else                                                              │
│         effective_cwd = createSandbox(...)                            │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 14. Agent runs in /home/me/proj-A (per-task cwd)                    │
│     git/file tools work on the project's actual context              │
│     Edit-mode ("Save" button on KanbanTaskDetailDialog)              │
│       → PUT /api/workspaces/tasks/:task_id  { cwd_session }           │
│       → User can change the cwd after creation via the dialog        │
└────────────────────────────────┬────────────────────────────────────┘
```

## Behaviour matrix

| Scenario | cwd_session sent to backend | Where agent runs |
|---|---|---|
| Task created with picker → "/home/me/proj-A" | "/home/me/proj-A" (per-task) | /home/me/proj-A |
| Task created without picker (cwd-less kanban) | '' (empty) → backend falls back | Per-session sandbox |
| Task created without picker, kanban has path "/home/parent" | "/home/parent" (kanban-level fallback) | /home/parent |
| Task created with picker → "/home/A", kanban path "/home/parent" | "/home/A" (per-task wins) | /home/A |
| Edit-mode: user changes cwd after creation | PUT body.cwd_session updated | Future sessions use new cwd |

## What landed (planned changes)

### Backend (Zig)

**New migration** — `src/migrations/migration.zig::Migration070AddTaskCwdSession`:
```zig
pub const Migration070AddTaskCwdSession = struct {
    pub const version: u32 = 70;
    pub const name = "add_task_cwd_session";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // cwd_session TEXT NOT NULL DEFAULT ''
        // Empty string is the canonical "no per-task cwd" sentinel.
        // Same pattern as description / tags / image_urls.
        try addColumnIfMissing(
            db, allocator,
            "workspace_item_tasks",
            "cwd_session",
            "cwd_session TEXT NOT NULL DEFAULT ''",
        );
    }
};
```
Registered in `allMigrations` slice. **6 inline behavioural tests** in
`src/migrations/migration_070_test.zig` (mirrors `migration_069_test.zig`):
column exists with right type+default, idempotent on re-run, pre-existing
rows backfill to `''`, registered in `allMigrations`.

**Schema layer** — `src/ai_workflow/tui/llm_history.zig`:
- `WorkspaceItemTaskInfo.cwd_session: []u8 = &.{}` — new field, freed by `deinit`.
- `listWorkspaceItemTasksWithCursor` SELECT: add `t.cwd_session` to the column list.
- `createWorkspaceItemTask` signature: add `cwd_session: ?[]const u8` arg.
  Dynamic SQL builder pattern (same shape as `image_urls`): null → omit
  column, "" → SQL '' literal, "x…" → bind via `?`. The returned task's
  `cwd_session` is duped + populated in the response builder.

**HTTP layer** — `src/ai_workflow/tui/http_handlers/http_response.zig`:
- `TaskCreateRequest.cwd_session: ?[]const u8 = null` — NEW field.
- `TaskUpdateRequest.cwd_session: ?[]const u8 = null` — NEW field (semantics:
  null → no change, "" → clear, "x…" → set).
- `WorkspaceItemTaskResponse.cwd_session: []u8 = ""` — NEW wire field.
- 5 inline behavioural tests for the create/update handlers' cwd_session
  round-trip (mirrors `task_create.zig`'s existing image_urls tests).

**HTTP handler** — `src/ai_workflow/tui/http_handlers/task_create.zig`:
- Pass `input.body.cwd_session` through to `createWorkspaceItemTask`.
- Set the response's `.cwd_session` from the returned task.

**HTTP handler** — `src/ai_workflow/tui/http_handlers/task_update.zig`:
- Add cwd_session PATCH branch (same dynamic-SQL pattern as description).

**HTTP handler** — `src/ai_workflow/tui/http_handlers/tasks_list.zig`:
- Populate `.cwd_session` on every task response (slice borrow from
  WorkspaceItemTaskInfo).

**HTTP handler** — `src/ai_workflow/tui/http_handlers/session_create.zig`:
- **NEW 3-level fallback** in `useCase`:
  ```zig
  var effective_cwd: []const u8 = "";
  if (parsed.cwd_session.len > 0) {
      effective_cwd = try alloc.dupe(u8, parsed.cwd_session);
  } else if (parsed.session_id.len > 0) {
      // Look up task.cwd_session → kanban.path fallback chain.
      // SELECT t.cwd_session, wi.path FROM workspace_item_tasks t
      //   JOIN workspace_items wi ON wi.id = t.workspace_item_id
      //   WHERE t.id = ?
      // → if task.cwd_session len > 0 → use it
      // → elif wi.path len > 0 → use it
      // → else → createSandbox(...)
  } else {
      effective_cwd = createSandbox(alloc, io, environment, session_id) catch
          environment.get("TMPDIR") orelse "/tmp";
  }
  ```
- 6 inline behavioural tests in `session_create.zig` covering:
  - explicit cwd wins
  - task.cwd_session wins when no explicit cwd
  - kanban.path wins when task.cwd_session is empty
  - createSandbox fallback when neither is set
  - sandbox creation failure → TMPDIR fallback
  - session_id missing → createSandbox (legacy)

### Frontend (Vue/TS)

**API** — `src/apps/desktop/src/api/index.ts`:
- `createTask` `params.cwdSession?: string` — forwarded as `cwd_session` on the wire.
- `updateTaskSimple` `data.cwdSession?: string` — forwarded as `cwd_session`.
- `Task` interface: `cwdSession?: string` (the per-task cwd).
- Response normalization: `normalizeTaskCwdSessionInPlace` splits/filters the
  string (mirrors `normalizeTaskTagsInPlace` for the JSON tags array).

**Store** — `src/apps/desktop/src/stores/workspaces.ts`:
- `addTask` `params.cwdSession?: string` — forwards to `api.createTask`.
- Local Task interface: `cwdSession?: string`.
- All task-fetch normalization sites call `normalizeTaskCwdSessionInPlace`.

**KanbanView** — `src/apps/desktop/src/components/kanban/KanbanView.vue`:
- `handleCreateTaskSave` payload: add `cwd_session: payload.cwdSession ?? ''`.
- 3-level frontend fallback in the cwd-resolution for `runAgentOnNewTask`:
  ```ts
  const effectiveCwd =
    payload.cwdSession  // ← per-task (NEW)
    || task.cwdSession  // ← task-fetched (back-compat)
    || props.item.path  // ← kanban-level
    || ''                // ← cwd-less → backend sandbox
  ```

**KanbanTaskDetailDialog** — `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue`:
- **NEW** "Project Root (optional)" field in the create-mode form.
  Same FilePickerDialog + same `loadItemsForPicker` adapter as
  AddKanbanDialog.
- Create payload: add `cwdSession?: string` field.
- Edit-mode: show the current `task.cwdSession` in a read-only strip
  ("Cwd: /home/me/proj-A"). Edit-mode cwd change is OUT OF SCOPE
  for this PR — edit is for name/description/tags/columns today.
  (The cwd can still be changed via the kanban-level "Set project
  root" banner, which becomes a less prominent affordance when tasks
  have their own cwd.)
- 5 new behavioural tests (folder picker opens, picker select populates
  field, "Skip" placeholder when empty, picker shows kanban-level path
  hint when present, no picker in edit mode).

**AddKanbanDialog** — `src/apps/desktop/src/components/dialogs/AddKanbanDialog.vue`:
- (Same change as the previous version of this plan) — make path
  picker OPTIONAL. The picker is now optional here too (consistent
  with the new "cwd is per-task" model — kanban cwd is just a default
  fallback). UI: "Skip (no project root)" placeholder, "(optional)"
  hint, picker hidden when no path set.

### Files

**New (2):**
- `src/migrations/migration_070_test.zig`
- `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.cwdSession.spec.ts`

**Modified (15+):**
- `src/migrations/migration.zig` (Migration070 struct + registration)
- `src/migrations/test_runner.zig` (register migration_070_test)
- `src/ai_workflow/tui/llm_history.zig` (struct + SELECT + create fn)
- `src/ai_workflow/tui/http_handlers/http_response.zig` (3 wire types)
- `src/ai_workflow/tui/http_handlers/task_create.zig` (pass-through)
- `src/ai_workflow/tui/http_handlers/task_update.zig` (PATCH branch)
- `src/ai_workflow/tui/http_handlers/tasks_list.zig` (populate response)
- `src/ai_workflow/tui/http_handlers/session_create.zig` (3-level fallback)
- `src/apps/desktop/src/api/index.ts` (createTask + updateTaskSimple + Task interface)
- `src/apps/desktop/src/stores/workspaces.ts` (addTask + normalization)
- `src/apps/desktop/src/components/kanban/KanbanView.vue` (handleCreateTaskSave + cwd fallback)
- `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` (folder picker)
- `src/apps/desktop/src/components/dialogs/AddKanbanDialog.vue` (optional path)
- `src/apps/desktop/src/__tests__/AddKanbanDialog.spec.ts` (update existing tests + new)
- `src/apps/desktop/src/__tests__/kanbanStore.spec.ts` (cwdSession round-trip)

**Doc (1):**
- `docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md` (this file)

## Why per-task cwd (B) was chosen over lazy kanban assignment (A)

1. **User intent** — the user said *"add field input to select folder so it
   will become a cwd session"*. Reading "a cwd session" as singular + "the
   task" context → the picked folder is for THAT task's session, not the
   kanban's. Different tasks can target different repos.

2. **Reuse of existing data model** — `workspace_item_tasks` already has
   per-task fields (description, tags, image_urls). Adding cwd_session
   fits naturally; the kanban path stays as a fallback column.

3. **Flexibility** — if a user later wants per-task cwd to fall back to
   a different per-task default (e.g. "all tasks under 'frontend' kanban
   inherit /home/me/frontend"), the kanban-level column is the natural
   carrier for that fallback.

4. **The kanban is a board, not a project** — kanbans can span multiple
   repos (frontend + backend + mobile for a "Sprint 12" board). Per-task
   cwd matches this mental model.

## Out of scope (deferred)

- **Edit-mode cwd change** — `KanbanTaskDetailDialog` (edit mode) shows the
  current cwd in a read-only strip. Changing it requires a new "Edit cwd"
  button → another PATCH round-trip. Defer to follow-up. (The user can
  always delete + recreate the task to change cwd, OR rely on the
  kanban-level "Set project root" banner for the rare case.)
- **Drag-to-reparent with cwd inheritance** — when a task moves between
  kanbans, does its cwd change? Probably NOT (the user picked the cwd
  intentionally). No action needed for v1.
- **Bulk cwd change** — selecting multiple tasks + setting cwd for all.
  Future UX. v1 is one-task-at-a-time.
- **Per-task cwd validation** — the frontend validates the path exists
  in the picker (FilePickerDialog already does). No additional backend
  validation needed; the OS-level error happens at agent tool time.
- **Workspace-item path removal** — with per-task cwd, the kanban path
  is a fallback. We could remove it entirely. But it's still useful as
  a "default for tasks that didn't pick" and for the banner UX. KEEP.
- **Per-task cwd for design items** — design items have their own path
  semantics (on-disk HTML files). The cwd_session concept doesn't apply.
  No change to design.

## Open questions (please confirm before implementation)

1. **Should the picker in the Add Task dialog default to the kanban's
   path when the kanban has one?** Default: yes — if `item.path === '/x'`,
   the picker opens with `/x` selected. The user can change or skip.
   This makes "add task to kanban with a project root" feel like the
   path is the default, not an interruption.

2. **Should the picker in AddKanbanDialog also default to the system
   folder (home dir)?** Default: no — leave it empty. The user
   explicitly chooses the kanban cwd or skips it.

3. **Should the picker in Add Task be HIDDEN when the kanban has no
   path (cwd-less kanban)?** Default: NO — show it always, with the
   "(optional)" hint. A cwd-less kanban can still have tasks that
   pick their own cwd. (This is the user-visible value of option B.)

4. **Edit-mode: show the cwd as read-only or hidden?** Default: read-only
   strip below the description, with a small tooltip explaining how to
   change it ("Create a new task to use a different cwd, or update the
   kanban's project root via the banner").

5. **What does the "(optional)" label say?** Default: "Project Root
   (optional — used as cwd for this task's chat sessions)". Slightly
   different from the kanban-level hint which says "for chat sessions".

If any defaults are wrong, please flag them before implementation.
Otherwise the defaults above will be used.

## TDD trace (planned)

1. **RED** — write migration_070_test (6 tests) — fail because the
   column doesn't exist.
2. **GREEN** — add `Migration070AddTaskCwdSession` struct + register
   it. All 6 tests pass.
3. **RED** — update `WorkspaceItemTaskInfo` + SELECT + create fn +
   wire types. Existing tests start failing because the SQL now
   SELECTs 1 more column than the row reader expects.
4. **GREEN** — populate the new `cwd_session` field in the row
   reader + response builder. Existing tests pass + new tests pass.
5. **RED** — write session_create.zig 3-level fallback tests (6).
   Fail because the backend currently only checks `parsed.cwd_session`.
6. **GREEN** — wire the 3-level fallback into `useCase`. All 6 pass.
7. **RED** — frontend AddKanbanDialog existing test "Add button is
   disabled when no folder is picked" still asserts disabled — fails.
8. **GREEN** — patch AddKanbanDialog to drop the path requirement.
   Existing test renamed + flipped + 3 new tests pass.
9. **RED** — KanbanTaskDetailDialog cwdSession picker tests (5) —
   fail because the field doesn't exist.
10. **GREEN** — wire the picker + payload field + normalize. All 5
    pass.

## Verification

- `bun run build` clean (vue-tsc + vite).
- `zig build test --summary all` — 2300+ pass (existing baseline + 12
  new backend tests + 3 new frontend tests).
- `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` clean.
- `zig build-obj -fno-emit-bin -target aarch64-macos` clean.
- `bunx vitest run` — full suite. Pre-existing baseline is 2070 pass
  / 19 fail (all unrelated static-contract + nudge clamp + etc.).
- Live smoke (port 8080, isolated $HOME):
  1. Open Add Project Kanban → type "Sprint 12" → click Add (no folder).
     → Kanban appears, cwd-less. "⚠️ Set project root" banner visible.
  2. Click + Add task → dialog opens → pick "/tmp" → Create.
     → Task created. Backend: SELECT cwd_session FROM
     workspace_item_tasks WHERE id = task_id → "/tmp".
  3. Click "Run agent" → agent runs in /tmp. Tools work normally.
  4. Open the task in edit mode → read-only strip shows "Cwd: /tmp".
  5. Add another task → SKIP the picker → Create → click Run agent →
     cwd falls back to sandbox ($TMPDIR/session_<id>/).

## Branch / commit (planned)

- Branch: `worktree/kanban-cwd-session-optional`
- Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-cwd-session-optional`
- Commits: 6-8 atomic commits (one per task: migration, schema, handlers,
  session_create fallback, AddKanbanDialog, AddTask cwd picker, normalization,
  tests). Squash-merge candidate.
- PR: TBD after implementation lands.