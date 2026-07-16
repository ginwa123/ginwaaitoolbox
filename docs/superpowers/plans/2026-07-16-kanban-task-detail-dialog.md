# Kanban Task Detail Dialog — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a focused, edit-in-place "Task detail" dialog to the kanban board — large task name display, large multi-line description textarea, and Save/Cancel — plus a new `description` column on the backend so descriptions actually persist.

**Architecture:**
1. **Backend** — Migration 061 adds `description TEXT` to `workspace_item_tasks`; `task_update.zig` and `task_create.zig` persist the value; task-list and single-task SELECT queries return the column. Mirrors the existing `kanban_columns.description` migration (053) pattern.
2. **Frontend** — New `KanbanTaskDetailDialog.vue` component (Teleport + modal pattern matching `KanbanSettingsDialog`); wired in through `WorkspaceItemTaskCard → KanbanCard → KanbanColumn → KanbanView → AppLayout`. Click on a new hover-revealed "ⓘ" icon on each card opens the dialog (distinct from the whole-card click that opens the chat). Save persists via the existing `PUT /api/workspaces/tasks/:task_id` endpoint with the new `description` field.

**Tech Stack:** Vue 3 + TypeScript + Pinia (frontend); Zig 0.16 + GinwaServer + sqlite3 (backend). Tests: Vitest (frontend), `zig build test` (backend).

---

## Design Decisions (commit upfront)

The user asked for "more detail like Task name, more bigger description, write a plan". To resolve scope:

1. **Editable, not view-only.** "more bigger description" implies the user wants to write/edit, not just view. The dialog is an EDIT form, not a read-only summary.
2. **Trigger = new "ⓘ" icon button** on the card, hover-revealed. Rationale: the whole-card click already opens the chat (`@click="handleSelectTask"` in `WorkspaceItemTaskCard.vue:219`); adding a separate gesture inside the card avoids a destructive UX change. The "ⓘ" icon follows the same hover-revealed-icon pattern as the existing pencil/delete/pin buttons.
3. **Save button (not autosave).** Save / Cancel at the bottom — same pattern as `AddTaskDialog` and `KanbanSettingsDialog`. The user must explicitly confirm.
4. **What it shows (v1):**
   - Big task-name input (editable, full width)
   - Big description textarea (rows=10, full width)
   - Compact read-only metadata strip below the name: column assignment, task type badge, pinned indicator, created/updated timestamps (if available)
   - Save / Cancel buttons (Save disabled while dirty=false)
5. **No chat history in v1.** The dialog is for editing the task's metadata, not viewing its chat. The "Open chat" affordance stays on the whole-card click.

---

## Scope check

This is a single feature that touches one dialog component + minimal backend wiring. It does NOT cover:

- Routine-schedule editing (already handled by `EditRoutineDialog`)
- Memory file editing (already handled by the memory feature)
- Tagging / labeling / assigning users
- Chat history inside the dialog

These are out of scope per YAGNI.

---

## File Structure

### New files

| File | Responsibility |
|---|---|
| `src/apps/desktop/src/components/KanbanTaskDetailDialog.vue` | The new modal component |
| `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts` | Vitest tests for the new dialog |
| `src/migrations/migration_061_test.zig` | Regression test for Migration 061 |

### Files to modify

| File | Change |
|---|---|
| `src/migrations/migration.zig` | Add `Migration061AddTaskDescription` struct + register in `migrations` array |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | Add `description: ?[]const u8 = null` to `TaskUpdateRequest`; remove "discarded" comment from `TaskCreateRequest.description` |
| `src/ai_workflow/tui/http_handlers/task_update.zig` | In `useCase`: when `body.description` is present, run an UPDATE that sets the column (or skip on null) |
| `src/ai_workflow/tui/http_handlers/task_create.zig` | When description is provided in the create body, persist via the new column |
| `src/ai_workflow/tui/llm_history.zig` | Add `description` to the SELECT queries at lines 3118 and 3434; update the matching `TUIHistory` row parsing; pass it through to the response builder |
| `src/ai_workflow/tui/test_runner.zig` | Register `migration_061_test.zig` |
| `src/apps/desktop/src/api/index.ts` | Add `description?: string` to the body types of `updateTask` and `updateTaskSimple` |
| `src/apps/desktop/src/stores/workspaces.ts` | Add `updateTaskDetails(workspaceId, itemId, taskId, { name?, description? })` action |
| `src/apps/desktop/src/components/KanbanView.vue` | Add `viewTaskDetail` emit; mount `KanbanTaskDetailDialog` at the bottom of the template |
| `src/apps/desktop/src/components/KanbanColumn.vue` | Add `viewTaskDetail` pass-through emit |
| `src/apps/desktop/src/components/KanbanCard.vue` | Add `viewTaskDetail` pass-through emit (KanbanCard wraps WorkspaceItemTaskCard and passes events through) |
| `src/apps/desktop/src/components/WorkspaceItemTaskCard.vue` | Add a hover-revealed "ⓘ" icon button on the top row that emits `viewTaskDetail` (next to the existing pencil/edit/pin/delete buttons) |
| `src/apps/desktop/src/components/AppLayout.vue` | Add `viewTaskDetail` handler that opens the dialog at AppLayout level (state: `showTaskDetailDialog: boolean`, `activeTaskDetailId: string \| null`) |
| `src/apps/desktop/src/__tests__/KanbanView.spec.ts` | Add tests covering the new emit pass-through + dialog render-on-show |

### Why this split?

- The **dialog component** owns only its own form state (name/description inputs, dirty tracking, save/cancel). It is purely presentational — emits `save` and `close`.
- The **host (AppLayout)** owns "is the dialog open and for which task?". This matches the pattern used by every other dialog in the codebase (`KanbanSettingsDialog`, `CopyKanbanSpecDialog`, `AddKanbanDialog`, etc.) and avoids state duplication.
- **KanbanCard → KanbanColumn → KanbanView → AppLayout** is a pure pass-through chain. Each layer adds zero logic — the same pattern as `selectTask`, `deleteTask`, `renameTask`.

---

## Chunk 1: Backend — persist description (Migration 061 + handler updates + SELECT updates)

**Why first:** The frontend cannot meaningfully persist a description until the backend stores it. Get the persistence layer right before building the UI.

### Task 1.1: Migration 061 — add `description` column to `workspace_item_tasks`

**Files:**
- Modify: `src/migrations/migration.zig` (around line 1780; add the new struct + registration line)
- Create: `src/migrations/migration_061_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig` (register the new test)

- [ ] **Step 1.1.1: Write the failing test**

```zig
// src/migrations/migration_061_test.zig
const std = @import("std");
const testing = std.testing;
const SqliteBackend = @import("sqlite").SqliteBackend;
const Threaded = std.Io.Threaded;
const Migration061 = @import("migration.zig").Migration061AddTaskDescription;

fn setupDb() !struct { db: SqliteBackend, threaded: Threaded } {
    const alloc = testing.allocator;
    var threaded = Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

test "Migration061 adds description column to workspace_item_tasks" {
    const ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Create the parent tables so the FK target exists.
    try ctx.db.exec(ctx.threaded.allocator(),
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY)", &.{});
    try ctx.db.exec(ctx.threaded.allocator(),
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)", &.{});

    try Migration061.up(&ctx.db, ctx.threaded.allocator());

    // Confirm the column exists.
    var q = try ctx.db.query(ctx.threaded.allocator(),
        "SELECT name FROM pragma_table_info('workspace_item_tasks') WHERE name = 'description'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(ctx.threaded.allocator());
    try testing.expectEqualStrings("description", row.values[0]);
}

test "Migration061 is idempotent on a column that already exists" {
    const ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(ctx.threaded.allocator(),
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY)", &.{});
    try ctx.db.exec(ctx.threaded.allocator(),
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, description TEXT NOT NULL DEFAULT '')", &.{});

    // Should not error — the column already exists. The helper
    // addColumnIfMissing handles this gracefully.
    try Migration061.up(&ctx.db, ctx.threaded.allocator());
}
```

- [ ] **Step 1.1.2: Run test to verify it fails (column doesn't exist yet)**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: `migration_061_test` references undefined `Migration061` — compile error.

- [ ] **Step 1.1.3: Implement Migration061**

Add to `src/migrations/migration.zig` (place AFTER `Migration060RebackfillCreatedIso`):

```zig
pub const Migration061AddTaskDescription = struct {
    pub const version: u32 = 61;
    pub const name = "add_task_description";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Kanban task description — Chunk 1 of the kanban-task-detail-dialog
        // plan. Each task gets a free-form description field that the
        // detail dialog edits. Mirrors the kanban_columns.description
        // precedent (migration 053/054) — same DEFAULT '' so existing
        // rows (which have no description) survive the migration without
        // a separate backfill, and the empty string is the canonical
        // "no description" sentinel that the UI renders as a placeholder.
        //
        // Use the existing `addColumnIfMissing` helper (not raw ALTER)
        // so fresh-DB installs that re-play the canonical schema don't
        // crash on "duplicate column" — see the nalar-fresh-db-migration-
        // cascade memory.
        try addColumnIfMissing(
            db,
            allocator,
            "workspace_item_tasks",
            "description",
            "description TEXT NOT NULL DEFAULT ''",
        );
    }
};
```

- [ ] **Step 1.1.4: Register Migration061 in the migrations array**

In `src/migrations/migration.zig` around line 1778, add a line immediately after the Migration060 registration:

```zig
.{ .version = Migration061AddTaskDescription.version, .name = Migration061AddTaskDescription.name, .up = Migration061AddTaskDescription.up },
```

- [ ] **Step 1.1.5: Register the test in `src/ai_workflow/tui/test_runner.zig`**

Add: `_ = @import("../../migrations/migration_061_test.zig");`

- [ ] **Step 1.1.6: Run test to verify it passes**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 2 new `migration_061_*` tests pass; no regressions in the existing baseline.

- [ ] **Step 1.1.7: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/migrations/migration.zig src/migrations/migration_061_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat(migration): add description column to workspace_item_tasks (Migration 061)"
```

### Task 1.2: Update `TaskUpdateRequest` to accept `description`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig:132-143`

- [ ] **Step 1.2.1: Add the field**

In `http_response.zig`, find the `TaskUpdateRequest` struct and add the field:

```zig
pub const TaskUpdateRequest = struct {
    name: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    /// Free-form description. Mirrors `TaskCreateRequest.description`.
    /// When present (non-null), overwrites the existing value; the
    /// empty string is the canonical "no description" sentinel and is
    /// stored verbatim. UI uses an "Add a description…" placeholder for
    /// empty values; the DB column has DEFAULT '' so legacy rows
    /// without a description look identical.
    description: ?[]const u8 = null,
    /// Routine-only. New cron expression. Validated by the handler.
    /// When changed, next_run_at is recomputed.
    schedule: ?[]const u8 = null,
    /// Routine-only. New prompt text.
    initial_prompt: ?[]const u8 = null,
    /// Routine-only. New active flag. When false, the routine stays
    /// in the DB but is skipped by the scheduler.
    enabled: ?bool = null,
};
```

- [ ] **Step 1.2.2: Also fix the obsolete comment on `TaskCreateRequest.description`**

In `http_response.zig:99-130`, the comment currently says:

```
/// `workspace_item_tasks` has no `description` column, so the
/// value is parsed and accepted but not persisted — the
/// frontend holds the authoritative copy.
```

After Migration 061, this is no longer true. Update the comment to:

```zig
/// Free-form description attached to every task. The
/// `AddTaskDialog` and `AddRoutineDialog` both emit it.
/// Persisted on the `workspace_item_tasks.description` column
/// (Migration 061). Optional; the DB default '' is the
/// "no description" sentinel.
```

- [ ] **Step 1.2.3: Build to verify the type compiles**

Run: `timeout 180 zig build install:linux:system 2>&1 | tail -n 10`
Expected: 4/6 steps succeed (the cp-to-`/usr/local/bin/nalar` fails harmlessly with permission denied; that's fine).

- [ ] **Step 1.2.4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/http_response.zig
git commit -m "feat(http): add description to TaskUpdateRequest + update TaskCreateRequest docs"
```

### Task 1.3: Persist description in `task_update.zig`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/task_update.zig:133-163` (the `useCase` function)

- [ ] **Step 1.3.1: Write the failing test**

Append to `src/ai_workflow/tui/http_handlers/task_update_test.zig` (or a new `task_update_description_test.zig` registered in the test runner):

```zig
test "task_update persists description when present in body" {
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;
    const alloc = testing.allocator;

    // Seed: insert a parent workspace_item + a task with no description.
    const ws_id = "ws_desc_test_1";
    const item_id = "wi_desc_test_1";
    const task_id = "task_desc_test_1";
    try sqlite_db.exec(alloc,
        "INSERT INTO workspace_items (id, name) VALUES (?, 'W')",
        &[_][]const u8{ ws_id });
    try sqlite_db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES (?, 'Task', ?)",
        &[_][]const u8{ task_id, item_id });

    // Update with a description.
    const result = try updateTaskUseCaseForTest(alloc, .{
        .task_id = task_id,
        .description = "Hello, world",
        .db = sqlite_db,
        .io = undefined, // not needed for the description-only path
    });
    try testing.expectEqualStrings(task_id, result.task_id);

    // Verify the column was updated.
    var q = try sqlite_db.query(alloc,
        "SELECT description FROM workspace_item_tasks WHERE id = ?",
        &[_][]const u8{task_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.TaskMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("Hello, world", row.values[0]);
}

test "task_update persists description = '' (empty string is a valid clear)" {
    // ... same setup, but description = ""
    // ... verify row.values[0] == ""
}

test "task_update leaves description unchanged when description is null" {
    // ... seed with description = "existing"
    // ... call useCase with description = null
    // ... verify row.values[0] == "existing"
}
```

- [ ] **Step 1.3.2: Run test to verify it fails**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: compile error (the helper `updateTaskUseCaseForTest` and `description` field don't exist yet).

- [ ] **Step 1.3.3: Implement description persistence in `useCase`**

In `src/ai_workflow/tui/http_handlers/task_update.zig`, modify the `useCase` function. Add a new branch BEFORE the name cascade:

```zig
fn useCase(allocator: std.mem.Allocator, input: TaskUpdateInput) TaskUpdateError!TaskUpdateResult {
    const task_id = input.task_id;

    // Routine-fields branch (unchanged from before).
    if (input.body.schedule != null or input.body.initial_prompt != null or input.body.enabled != null) {
        try updateRoutineFields(allocator, input.db, input.io, task_id, input.body);
    }

    // NEW: Description update branch. When `body.description` is
    // present (non-null), overwrite the column with the new value.
    // Empty string is the canonical "no description" sentinel and is
    // stored verbatim — the UI distinguishes via `task.description`
    // being `''` vs `null` (the latter only happens for legacy rows
    // fetched before Migration 061, which the SELECT query returns
    // as `''` via COALESCE).
    if (input.body.description) |desc| {
        sqlite_db.exec(allocator,
            "UPDATE workspace_item_tasks SET description = ?, updated_at = datetime('now') WHERE id = ?",
            &.{ desc, task_id },
        ) catch return error.FailedToUpdateTask;
    }

    // Name cascade (unchanged from before).
    if (input.body.name) |n| {
        llm_history.updateTaskName(allocator, input.db, task_id, n) catch {
            return error.FailedToUpdateTask;
        };
    }

    return .{ .task_id = task_id };
}
```

**Also** add `sqlite_db` parameter binding inside `useCase`. The `input.db` is already typed as `*nalarcore.sqlite.SqliteBackend`. Update the body to reference `input.db.exec(...)` instead of `sqlite_db.exec(...)` (since `useCase` doesn't have direct `sqlite_db` access — it has `input.db`). The reference here is illustrative; re-read the file to make sure the variable name matches what you actually have.

Concretely, the line should be:

```zig
input.db.exec(allocator,
    "UPDATE workspace_item_tasks SET description = ?, updated_at = datetime('now') WHERE id = ?",
    &.{ desc, task_id },
) catch return error.FailedToUpdateTask;
```

- [ ] **Step 1.3.4: Re-run test to verify it passes**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 3 new `task_update description` tests pass; baseline unchanged.

- [ ] **Step 1.3.5: Build to verify the install target compiles**

Run: `timeout 180 zig build install:linux:system 2>&1 | tail -n 10`
Expected: 4/6 steps succeed.

- [ ] **Step 1.3.6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/task_update.zig src/ai_workflow/tui/http_handlers/task_update_test.zig
git commit -m "feat(http): persist description in task_update handler"
```

### Task 1.4: Persist description in `task_create.zig`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/task_create.zig`

- [ ] **Step 1.4.1: Find the INSERT statement and add description**

Locate the existing INSERT in `task_create.zig` (it currently inserts `id, name, workspace_item_id, created_at, updated_at` — find the literal SQL). Append `, description` to the column list and `, ?` to the value list. Bind the description at the appropriate index in the `&.{...}` args tuple:

```zig
sqlite_db.exec(allocator,
    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, description, created_at, updated_at) " ++
    "VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))",
    &.{ task_id, name, workspace_item_id, description orelse "" },
) catch ...;
```

If the create handler's INSERT uses different column names, adapt to match (the existing pattern at line ~280-300 of task_create.zig should be straightforward to extend).

- [ ] **Step 1.4.2: Write a test**

Add to `task_create_test.zig` (or a new file) — verify a create with description persists the value:

```zig
test "task_create persists description" {
    // Seed workspace_items, call createTaskUseCaseForTest(.{ description = "Hello" }),
    // SELECT description, assert it equals "Hello".
}
```

- [ ] **Step 1.4.3: Run test + build**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10` then `timeout 180 zig build install:linux:system 2>&1 | tail -n 10`
Expected: both clean; 1 new test pass.

- [ ] **Step 1.4.4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/task_create.zig src/ai_workflow/tui/http_handlers/task_create_test.zig
git commit -m "feat(http): persist description in task_create handler"
```

### Task 1.5: Return `description` from task SELECT queries

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:3118` (single-task fetch) and `:3434` (task list fetch)

- [ ] **Step 1.5.1: Add `description` to the single-task SELECT**

At line 3118, change:

```zig
const sql = "SELECT id, name, workspace_item_id, created_at, updated_at, task_type FROM workspace_item_tasks t WHERE t.id = ?";
```

to:

```zig
const sql = "SELECT id, name, workspace_item_id, description, created_at, updated_at, task_type FROM workspace_item_tasks t WHERE t.id = ?";
```

Find the matching row-parsing block (the `try allocator.dupe(u8, row.values[N])` chain) and add a new `description` parsing line. The field order changes, so ALL existing `row.values[N]` indices shift by one — update them carefully.

- [ ] **Step 1.5.2: Add `description` to the task-list SELECT**

At line 3434, the SELECT is huge. Add `t.description` to the column list (e.g. right after `t.name`). Update the row-parsing block accordingly.

- [ ] **Step 1.5.3: Update the response builder**

Find wherever the `Task` / `TUIHistory` struct gets built for the API response. Add `description: row_description` to the constructed struct (or set the field directly via a setter). Look for the response builder function that turns a row into a `Task` response — most likely in `llm_history.zig` itself or in the HTTP response builder.

- [ ] **Step 1.5.4: Update existing tests**

Search for tests that assert the exact column count or column ORDER returned by these SELECTs (likely in `llm_history_test.zig` and downstream). Add `description` to the expected row count and/or assert the new column shows up.

- [ ] **Step 1.5.5: Run test + build**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10` then `timeout 180 zig build install:linux:system 2>&1 | tail -n 10`
Expected: baseline test count + ~2-3 new tests for description round-trip.

- [ ] **Step 1.5.6: Smoke test against the running nalar**

Manually verify with curl:

```bash
# Boot the new binary
./zig-out/bin/nalar --port 8080 &
# Create a task with description
curl -X POST http://127.0.0.1:8080/api/workspaces/<ws_id>/items/<item_id>/tasks \
  -H 'Content-Type: application/json' \
  -d '{"name":"plan task","description":"test description"}'
# Fetch tasks and confirm description is in the response
curl http://127.0.0.1:8080/api/workspaces/<ws_id>/items/<item_id>/tasks | jq '.tasks[0].description'
# Should print: "test description"

# Update description
curl -X PUT http://127.0.0.1:8080/api/workspaces/tasks/<task_id> \
  -H 'Content-Type: application/json' \
  -d '{"description":"updated description"}'
# Fetch again and confirm
curl http://127.0.0.1:8080/api/workspaces/<ws_id>/items/<item_id>/tasks | jq '.tasks[0].description'
# Should print: "updated description"
```

- [ ] **Step 1.5.7: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/llm_history.zig src/ai_workflow/tui/llm_history_test.zig
git commit -m "feat(http): return description from task SELECT queries"
```

### Task 1.6: Backend smoke check + chunk commit

- [ ] **Step 1.6.1: Run the full backend test suite**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 10`
Expected: baseline count + ~6-8 new tests, no regressions.

- [ ] **Step 1.6.2: Verify fresh-DB migration cascade still works**

Run `scripts/ci-smoke-test.sh` against the new binary to confirm the fresh-DB migration chain (1 → 61) succeeds without errors. The smoke test isolates `$HOME` to a fresh tempdir, so it exercises the migration from scratch.

- [ ] **Step 1.6.3: Tag Chunk 1 done**

Report milestone: "Backend chunk 1 done — description column added (Migration 061), persists on create/update, returned by SELECT queries, frontend can now use it."

---

## Chunk 2: Frontend — API + store wiring

**Why second:** The store layer is the bridge between the UI and the backend. Get the API surface and the store action right before adding the dialog component, so the dialog can call a single, well-tested action.

### Task 2.1: Extend `updateTaskSimple` / `updateTask` to accept `description`

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:534-573`

- [ ] **Step 2.1.1: Add `description?: string` to both payload types**

Find the `updateTask` function (around line 534) and the `updateTaskSimple` function (around line 556). Add `description?: string` to BOTH body parameter types:

```typescript
// updateTask
export async function updateTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  data: Partial<Task>,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}`,
    { method: 'PUT', body: data },
  )
}

// updateTaskSimple — add description to the inline type
export async function updateTaskSimple(
  taskId: string,
  data: {
    name?: string
    session_id?: string
    description?: string  // ← NEW
    schedule?: string
    initial_prompt?: string
    enabled?: boolean
  },
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(`/workspaces/tasks/${taskId}`, {
    method: 'PUT',
    body: data,
  })
}
```

- [ ] **Step 2.1.2: Build to verify TypeScript types check**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: build succeeds, 0 errors.

- [ ] **Step 2.1.3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(frontend): add description to updateTask/updateTaskSimple body types"
```

### Task 2.2: Add `updateTaskDetails` action to `workspacesStore`

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts` (around line 1529-1569, after `renameTask`)

- [ ] **Step 2.2.1: Write the failing test**

Add to `src/apps/desktop/src/__tests__/workspacesStoreTaskUpdate.spec.ts` (create this file if it doesn't exist):

```typescript
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useWorkspacesStore } from '../stores/workspaces'
import * as api from '../api'
import type { Workspace, WorkspaceItem, Task } from '../stores/workspaces'

// Mock the api module
vi.mock('../api', () => ({
  updateTaskSimple: vi.fn(),
  updateTask: vi.fn(),
  getWorkspaces: vi.fn(),
  getWorkspacesItems: vi.fn(),
  // ... other functions as needed
}))

const TASK_ID = 'task_test_1'
const WS_ID = 'ws_test_1'
const ITEM_ID = 'item_test_1'

const makeTask = (overrides: Partial<Task> = {}): Task => ({
  id: TASK_ID,
  name: 'Original',
  description: 'old desc',
  ...overrides,
})

const makeItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: ITEM_ID,
  name: 'My Item',
  item_type: 'kanban',
  tasks: [makeTask()],
  kanban_columns: [],
  ...overrides,
})

const makeWorkspace = (): Workspace => ({
  id: WS_ID,
  name: 'Test WS',
  items: [makeItem()],
})

describe('workspacesStore.updateTaskDetails', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
    // Seed the store
    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspace()]
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('updates both name and description optimistically', async () => {
    const store = useWorkspacesStore()
    vi.mocked(api.updateTaskSimple).mockResolvedValue({ success: true })

    await store.updateTaskDetails(WS_ID, ITEM_ID, TASK_ID, {
      name: 'New Name',
      description: 'New desc',
    })

    const task = store.workspaces[0].items[0].tasks![0]
    expect(task.name).toBe('New Name')
    expect(task.description).toBe('New desc')
    expect(api.updateTaskSimple).toHaveBeenCalledWith(TASK_ID, {
      name: 'New Name',
      description: 'New desc',
    })
  })

  it('updates description only when name is omitted', async () => {
    const store = useWorkspacesStore()
    vi.mocked(api.updateTaskSimple).mockResolvedValue({ success: true })

    await store.updateTaskDetails(WS_ID, ITEM_ID, TASK_ID, {
      description: 'New desc only',
    })

    const task = store.workspaces[0].items[0].tasks![0]
    expect(task.name).toBe('Original')  // unchanged
    expect(task.description).toBe('New desc only')
    expect(api.updateTaskSimple).toHaveBeenCalledWith(TASK_ID, {
      description: 'New desc only',
    })
  })

  it('rolls back on API failure', async () => {
    const store = useWorkspacesStore()
    vi.mocked(api.updateTaskSimple).mockRejectedValue(new Error('500'))

    await expect(
      store.updateTaskDetails(WS_ID, ITEM_ID, TASK_ID, {
        name: 'New Name',
        description: 'New desc',
      })
    ).rejects.toThrow('500')

    const task = store.workspaces[0].items[0].tasks![0]
    expect(task.name).toBe('Original')  // rolled back
    expect(task.description).toBe('old desc')  // rolled back
  })

  it('treats description = "" as a valid clear (not a no-op)', async () => {
    const store = useWorkspacesStore()
    vi.mocked(api.updateTaskSimple).mockResolvedValue({ success: true })

    await store.updateTaskDetails(WS_ID, ITEM_ID, TASK_ID, {
      description: '',
    })

    const task = store.workspaces[0].items[0].tasks![0]
    expect(task.description).toBe('')  // cleared
    expect(api.updateTaskSimple).toHaveBeenCalledWith(TASK_ID, {
      description: '',
    })
  })
})
```

- [ ] **Step 2.2.2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run workspacesStoreTaskUpdate 2>&1 | tail -n 15`
Expected: 4 tests fail because `updateTaskDetails` doesn't exist yet.

- [ ] **Step 2.2.3: Implement `updateTaskDetails`**

Add to `src/apps/desktop/src/stores/workspaces.ts` AFTER the existing `renameTask` function (around line 1569):

```typescript
/**
 * Update a task's name AND/OR description. Mirrors the optimistic-
 * update + rollback pattern from `renameTask`. Sends BOTH fields to
 * the backend via PUT /api/workspaces/tasks/:task_id so the user
 * can edit either or both in one round trip (the detail dialog
 * uses this).
 *
 * - If `name` is undefined, the existing name is NOT sent (the
 *   backend treats absence as "leave unchanged"). Same for
 *   description.
 * - If `description === ''`, that IS sent (empty string = clear).
 *   This matches the user's "delete the description" intent in the
 *   dialog: they hit Save with an empty textarea, the description
 *   becomes ''.
 * - If both are undefined, the function is a no-op (no API call).
 *
 * Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md
 */
async function updateTaskDetails(
  workspaceId: string,
  itemId: string,
  taskId: string,
  fields: { name?: string; description?: string },
) {
  const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
  if (!workspace) return
  const item = workspace.items.find((i) => i.id === itemId)
  if (!item || !item.tasks) return
  const task = item.tasks.find((t) => t.id === taskId)
  if (!task) return

  // Build the patch — only include fields the caller actually sent.
  const patch: { name?: string; description?: string } = {}
  if (fields.name !== undefined) {
    const trimmed = fields.name.trim()
    if (!trimmed) return  // empty name is never a valid update
    patch.name = trimmed
  }
  if (fields.description !== undefined) {
    patch.description = fields.description
  }
  if (Object.keys(patch).length === 0) return

  // Optimistic update — capture previous values for rollback.
  const previousName = task.name
  const previousDescription = task.description
  if (patch.name !== undefined) task.name = patch.name
  if (patch.description !== undefined) task.description = patch.description

  // Keep the chat-view / chat-list header in sync if this is the active task.
  const wasActive = activeTaskId.value === taskId
  if (wasActive && patch.name !== undefined) {
    useNavigationStore().setActiveChatName(patch.name)
  }

  try {
    await api.updateTaskSimple(taskId, patch)
  } catch (err) {
    console.error('Failed to update task details:', err)
    task.name = previousName
    task.description = previousDescription
    if (wasActive) {
      useNavigationStore().setActiveChatName(previousName)
    }
    throw err
  }
}
```

Add `updateTaskDetails` to the store's return statement — find the `return { ... }` block at the end of the `useWorkspacesStore` function and add `updateTaskDetails,` to it.

- [ ] **Step 2.2.4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run workspacesStoreTaskUpdate 2>&1 | tail -n 15`
Expected: 4 tests pass.

- [ ] **Step 2.2.5: Run full build to verify type-check**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: 0 errors.

- [ ] **Step 2.2.6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/stores/workspaces.ts src/apps/desktop/src/__tests__/workspacesStoreTaskUpdate.spec.ts
git commit -m "feat(frontend): add updateTaskDetails action with optimistic update + rollback"
```

### Task 2.3: Chunk 2 verification

- [ ] **Step 2.3.1: Run full frontend build + tests**

Run:
```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
timeout 120 bunx vitest run 2>&1 | tail -n 10
```
Expected: build clean; all tests pass (baseline + 4 new).

- [ ] **Step 2.3.2: Tag Chunk 2 done**

Report milestone: "Frontend store + API chunk done — `updateTaskDetails` action works with optimistic update, rollback, and full test coverage."

---

## Chunk 3: Frontend — `KanbanTaskDetailDialog.vue` component

**Why third:** Build and test the new dialog in isolation before wiring it up to the kanban tree. A focused, testable component is the cleanest deliverable.

### Task 3.1: Create the dialog component (minimal viable)

**Files:**
- Create: `src/apps/desktop/src/components/KanbanTaskDetailDialog.vue`

- [ ] **Step 3.1.1: Create the file with the minimal structure**

```vue
<!--
  KanbanTaskDetailDialog — focused, edit-in-place task detail view.

  Layout (top → bottom):
    1. Header — "Task details" title + close button.
    2. Task name — large, editable input. Full width.
    3. Metadata strip (read-only) — column name, task type, pinned
       indicator, timestamps. Hidden when no metadata is available.
    4. Description label.
    5. Description textarea — large (rows=10 vs AddTaskDialog's 3),
       full width, monospace-friendly font (matches the existing
       AddTaskDialog / AddKanbanDialog description textarea).
    6. Save / Cancel buttons at the bottom right. Save is disabled
       when the form is clean (no changes) or the name is empty
       after trim.

  Public API:
    props:
      show       boolean
      task       Task | null  (the task to edit; null hides the form)
    emits:
      close      []
      save       [{ name: string, description: string }]
                Emitted when the user clicks Save. The host calls
                workspacesStore.updateTaskDetails(...) and closes
                the dialog on success.

  This dialog is purely presentational — no API calls, no store
  reads. The host (AppLayout) owns the "open + for which task"
  state and wires the `save` emit to a store action.

  Pattern source: KanbanSettingsDialog.vue — Teleport to body,
  max-height 70vh, transition + backdrop, semantic CSS variables
  for theme compatibility.
-->
<script setup lang="ts">
import { ref, computed, watch, nextTick } from 'vue'
import type { Task, KanbanColumn } from '../stores/workspaces'

const props = defineProps<{
  show: boolean
  task: Task | null
  column?: KanbanColumn | null  // optional — shown in metadata strip
}>()

const emit = defineEmits<{
  close: []
  save: [payload: { name: string; description: string }]
}>()

// ─── Form state ──────────────────────────────────────────────────────────

const name = ref('')
const description = ref('')
const nameInput = ref<HTMLInputElement | null>(null)
const DESCRIPTION_MAX = 5000

// Reset form whenever the dialog opens OR the target task changes.
watch(
  () => [props.show, props.task?.id] as const,
  async ([show]) => {
    if (show && props.task) {
      name.value = props.task.name
      description.value = props.task.description ?? ''
      await nextTick()
      // Focus + select the name input so the user can rename in
      // place with a single keystroke.
      nameInput.value?.focus()
      nameInput.value?.select()
    }
  },
  { immediate: true },
)

// Dirty tracking — the Save button enables only when something
// actually changed (compared to the props.task baseline).
const isDirty = computed<boolean>(() => {
  if (!props.task) return false
  const nameChanged = name.value.trim() !== props.task.name
  const descChanged = (description.value) !== (props.task.description ?? '')
  return nameChanged || descChanged
})

const isValid = computed<boolean>(() => name.value.trim().length > 0)
const canSave = computed<boolean>(() => isDirty.value && isValid.value)

// ─── Handlers ───────────────────────────────────────────────────────────

const handleSave = () => {
  if (!canSave.value) return
  emit('save', {
    name: name.value.trim(),
    description: description.value,
  })
}

const handleClose = () => {
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') handleClose()
}

// ─── Metadata helpers ───────────────────────────────────────────────────

const taskTypeLabel = computed<string | null>(() => {
  const t = props.task?.task_type
  if (t === 'routine') return 'Routine'
  if (t === 'memory') return 'Memory'
  return null  // 'standard' and undefined both show no badge
})

const columnLabel = computed<string | null>(() => {
  return props.column?.name ?? null
})
</script>

<template>
  <Teleport to="body">
    <Transition name="kanban-task-detail-modal">
      <div
        v-if="show && task"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="kanban-task-detail-title"
        data-testid="kanban-task-detail-dialog"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6);"
          @click="handleClose"
        />

        <!-- Dialog Card. Wider than AddTaskDialog (max-w-xl) so the
             description has room to breathe. min(80vh, ...) for the
             height so it scrolls on short viewports. -->
        <div
          class="relative w-full max-w-xl mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35);
            height: min(80vh, calc(100vh - 2rem));
          "
        >
          <!-- Header -->
          <div
            class="px-5 pt-5 pb-4 shrink-0 flex items-center justify-between gap-3"
            style="border-bottom: 1px solid var(--color-border);"
          >
            <h3
              id="kanban-task-detail-title"
              class="text-base font-semibold flex items-center gap-2"
              style="color: var(--semantic-text);"
            >
              <span aria-hidden="true">📝</span>
              Task details
            </h3>
            <button
              type="button"
              @click="handleClose"
              data-testid="kanban-task-detail-close"
              class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80"
              style="color: var(--semantic-text-muted);"
              title="Close"
            >
              <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>

          <!-- Body (scrollable) -->
          <div class="flex-1 overflow-y-auto min-h-0 px-5 py-4">
            <!-- Task name input — big, prominent, full-width -->
            <div class="mb-4">
              <label
                for="kanban-task-detail-name"
                class="block text-xs font-medium mb-2"
                style="color: var(--semantic-text-dim);"
              >
                Task name
              </label>
              <input
                id="kanban-task-detail-name"
                ref="nameInput"
                v-model="name"
                type="text"
                placeholder="Enter task name…"
                data-testid="kanban-task-detail-name"
                class="w-full px-3 py-2.5 rounded-lg text-base font-medium outline-none transition-all duration-200"
                style="
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text);
                "
                @keyup.enter="handleSave"
              />
            </div>

            <!-- Metadata strip (read-only). Hidden when no metadata
                 is available, which keeps the layout tight for the
                 common case (standard task with no pin / column
                 yet to load). -->
            <div
              v-if="columnLabel || taskTypeLabel || task?.is_pinned"
              class="mb-4 flex items-center gap-2 flex-wrap text-xs"
              style="color: var(--semantic-text-dim);"
              data-testid="kanban-task-detail-metadata"
            >
              <span v-if="columnLabel" data-testid="kanban-task-detail-column">
                <span aria-hidden="true">📋</span>
                <span class="ml-1">{{ columnLabel }}</span>
              </span>
              <span v-if="taskTypeLabel" data-testid="kanban-task-detail-type">
                <span aria-hidden="true">·</span>
                <span class="ml-1">{{ taskTypeLabel }}</span>
              </span>
              <span v-if="task?.is_pinned" data-testid="kanban-task-detail-pinned">
                <span aria-hidden="true">📌</span>
                <span class="ml-1">Pinned</span>
              </span>
            </div>

            <!-- Description textarea — big (10 rows vs AddTaskDialog's 3),
                 full width. resize-y so the user can drag the corner to
                 make it taller for long descriptions. -->
            <div>
              <label
                for="kanban-task-detail-description"
                class="block text-xs font-medium mb-2"
                style="color: var(--semantic-text-dim);"
              >
                Description
                <span class="ml-1 text-[10px]" style="color: var(--semantic-text-dim);">
                  ({{ description.length }} / {{ DESCRIPTION_MAX }})
                </span>
              </label>
              <textarea
                id="kanban-task-detail-description"
                v-model="description"
                :maxlength="DESCRIPTION_MAX"
                rows="10"
                placeholder="Add a description…"
                data-testid="kanban-task-detail-description"
                class="w-full px-3 py-2.5 rounded-lg text-sm outline-none transition-all duration-200 resize-y"
                style="
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text);
                  font-family: inherit;
                  min-height: 200px;
                "
              />
            </div>
          </div>

          <!-- Actions -->
          <div
            class="px-5 py-4 shrink-0 flex justify-end gap-2"
            style="border-top: 1px solid var(--color-border);"
          >
            <button
              type="button"
              @click="handleClose"
              data-testid="kanban-task-detail-cancel"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text-muted);
              "
            >
              Cancel
            </button>
            <button
              type="button"
              @click="handleSave"
              :disabled="!canSave"
              data-testid="kanban-task-detail-save"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
            >
              Save
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.kanban-task-detail-modal-enter-active,
.kanban-task-detail-modal-leave-active {
  transition: opacity 0.2s ease;
}

.kanban-task-detail-modal-enter-from,
.kanban-task-detail-modal-leave-to {
  opacity: 0;
}

.kanban-task-detail-modal-enter-active > div:last-child,
.kanban-task-detail-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}

.kanban-task-detail-modal-enter-from > div:last-child,
.kanban-task-detail-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>
```

- [ ] **Step 3.1.2: Build to verify TypeScript types check**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: build succeeds, 0 errors.

- [ ] **Step 3.1.3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanTaskDetailDialog.vue
git commit -m "feat(frontend): add KanbanTaskDetailDialog component (initial)"
```

### Task 3.2: Add Vitest tests for the dialog

**Files:**
- Create: `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts`

- [ ] **Step 3.2.1: Write the failing tests**

```typescript
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import KanbanTaskDetailDialog from '../components/KanbanTaskDetailDialog.vue'
import type { Task } from '../stores/workspaces'

const TASK: Task = {
  id: 'task_test_1',
  name: 'Original name',
  description: 'Original description',
  task_type: 'standard',
}

function mountDialog(task: Task | null = TASK, show = true) {
  return mount(KanbanTaskDetailDialog, {
    props: { show, task },
    attachTo: document.body,  // required for Teleport
  })
}

describe('KanbanTaskDetailDialog — render', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => setActivePinia(createPinia()))

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('does not render the dialog when show=false', () => {
    wrapper = mountDialog(TASK, false)
    expect(wrapper.find('[data-testid="kanban-task-detail-dialog"]').exists()).toBe(false)
  })

  it('renders the dialog when show=true and task is provided', async () => {
    wrapper = mountDialog()
    await flushPromises()
    expect(wrapper.find('[data-testid="kanban-task-detail-dialog"]').exists()).toBe(true)
  })

  it('pre-fills the name input with the task name', async () => {
    wrapper = mountDialog()
    await flushPromises()
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-task-detail-name"]')
    expect(input.element.value).toBe('Original name')
  })

  it('pre-fills the description textarea with the task description', async () => {
    wrapper = mountDialog()
    await flushPromises()
    const textarea = wrapper.find<HTMLTextAreaElement>('[data-testid="kanban-task-detail-description"]')
    expect(textarea.element.value).toBe('Original description')
  })

  it('pre-fills description with empty string when task has no description', async () => {
    wrapper = mountDialog({ ...TASK, description: undefined })
    await flushPromises()
    const textarea = wrapper.find<HTMLTextAreaElement>('[data-testid="kanban-task-detail-description"]')
    expect(textarea.element.value).toBe('')
  })
})

describe('KanbanTaskDetailDialog — save / cancel', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => setActivePinia(createPinia()))

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('emits save with the trimmed name + raw description', async () => {
    wrapper = mountDialog()
    await flushPromises()
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-task-detail-name"]')
    await input.setValue('  New name  ')
    const textarea = wrapper.find<HTMLTextAreaElement>('[data-testid="kanban-task-detail-description"]')
    await textarea.setValue('New description')
    await wrapper.find('[data-testid="kanban-task-detail-save"]').trigger('click')

    const emitted = wrapper.emitted('save')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([{ name: 'New name', description: 'New description' }])
  })

  it('emits save with description = "" when the textarea is cleared', async () => {
    wrapper = mountDialog()
    await flushPromises()
    const textarea = wrapper.find<HTMLTextAreaElement>('[data-testid="kanban-task-detail-description"]')
    await textarea.setValue('')
    await wrapper.find('[data-testid="kanban-task-detail-save"]').trigger('click')

    const emitted = wrapper.emitted('save')
    expect(emitted![0]).toEqual([{ name: 'Original name', description: '' }])
  })

  it('emits close (not save) when the cancel button is clicked', async () => {
    wrapper = mountDialog()
    await flushPromises()
    await wrapper.find('[data-testid="kanban-task-detail-cancel"]').trigger('click')
    expect(wrapper.emitted('close')).toBeTruthy()
    expect(wrapper.emitted('save')).toBeFalsy()
  })

  it('disables save when name is empty (after trim)', async () => {
    wrapper = mountDialog()
    await flushPromises()
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-task-detail-name"]')
    await input.setValue('   ')  // whitespace only
    const saveBtn = wrapper.find('[data-testid="kanban-task-detail-save"]')
    expect(saveBtn.attributes('disabled')).toBeDefined()
  })

  it('disables save when nothing changed (clean form)', async () => {
    wrapper = mountDialog()
    await flushPromises()
    const saveBtn = wrapper.find('[data-testid="kanban-task-detail-save"]')
    expect(saveBtn.attributes('disabled')).toBeDefined()
  })

  it('enables save when the name OR description changed', async () => {
    wrapper = mountDialog()
    await flushPromises()
    const textarea = wrapper.find<HTMLTextAreaElement>('[data-testid="kanban-task-detail-description"]')
    await textarea.setValue('Modified description')
    const saveBtn = wrapper.find('[data-testid="kanban-task-detail-save"]')
    expect(saveBtn.attributes('disabled')).toBeUndefined()
  })
})

describe('KanbanTaskDetailDialog — metadata strip', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => setActivePinia(createPinia()))

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('renders the column name when a column prop is provided', async () => {
    wrapper = mount(KanbanTaskDetailDialog, {
      props: {
        show: true,
        task: TASK,
        column: { id: 'col_1', workspace_item_id: 'item_1', name: 'In progress', position: 1 } as any,
      },
      attachTo: document.body,
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="kanban-task-detail-column"]').text()).toContain('In progress')
  })

  it('renders the routine type label when task_type is routine', async () => {
    wrapper = mountDialog({ ...TASK, task_type: 'routine' })
    await flushPromises()
    expect(wrapper.find('[data-testid="kanban-task-detail-type"]').exists()).toBe(true)
  })

  it('renders the pinned indicator when is_pinned is true', async () => {
    wrapper = mountDialog({ ...TASK, is_pinned: true })
    await flushPromises()
    expect(wrapper.find('[data-testid="kanban-task-detail-pinned"]').exists()).toBe(true)
  })

  it('hides the metadata strip when no metadata is available', async () => {
    wrapper = mountDialog({ ...TASK, is_pinned: false })
    await flushPromises()
    expect(wrapper.find('[data-testid="kanban-task-detail-metadata"]').exists()).toBe(false)
  })
})
```

- [ ] **Step 3.2.2: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run KanbanTaskDetailDialog 2>&1 | tail -n 25`
Expected: all ~15 tests pass.

- [ ] **Step 3.2.3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts
git commit -m "test(frontend): add Vitest tests for KanbanTaskDetailDialog"
```

### Task 3.3: Chunk 3 verification

- [ ] **Step 3.3.1: Run full build + tests**

Run:
```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
timeout 120 bunx vitest run 2>&1 | tail -n 10
```
Expected: build clean; baseline + ~15 new tests.

- [ ] **Step 3.3.2: Tag Chunk 3 done**

Report milestone: "Dialog component chunk done — `KanbanTaskDetailDialog.vue` is built, fully tested, and renders correctly in isolation."

---

## Chunk 4: Frontend — wire-up (Card → Column → View → AppLayout)

**Why last:** The dialog is already working in isolation. Wire-up is purely plumbing — pass the event up the tree, mount the dialog at AppLayout, handle the save action.

### Task 4.1: Add `viewTaskDetail` emit to `WorkspaceItemTaskCard.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceItemTaskCard.vue`

- [ ] **Step 4.1.1: Add the emit declaration**

In the `defineEmits` block (around line 44-51), add `viewTaskDetail: [taskId: string]`.

- [ ] **Step 4.1.2: Add the handler**

Add a `handleViewTaskDetail` function alongside the other handlers (in the destructured `useTaskActions` block doesn't expose this — handle it inline):

```typescript
const handleViewTaskDetail = (event: MouseEvent) => {
  // Stop propagation so the click doesn't also bubble up to the
  // card-root <button>'s @click="handleSelectTask" (which opens the
  // chat). Without this, both the dialog AND the chat would open.
  event.stopPropagation()
  event.preventDefault()
  emit('viewTaskDetail', props.task.id)
}
```

- [ ] **Step 4.1.3: Add the "ⓘ" button to the top row of the card**

In both the `<template v-if="isRoutine">` and the `<template v-else>` (standard) branches, add a new icon button BEFORE the existing pencil button. Pattern mirrors the other hover-revealed icons:

```vue
<!-- Info / view detail button (hover-revealed) -->
<button
  @click="handleViewTaskDetail"
  class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:bg-[--semantic-active-bg] hover:text-cyan-400"
  style="color: var(--semantic-text-dim);"
  title="View task details"
  data-testid="view-task-detail-btn"
>
  <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
  </svg>
</button>
```

The exact placement (e.g. before the pin toggle, or before the pencil) is a UX choice — pick "before the pencil" so info/edit/delete read left-to-right logically.

- [ ] **Step 4.1.4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/WorkspaceItemTaskCard.vue
git commit -m "feat(frontend): add viewTaskDetail emit + hover-revealed info button to task card"
```

### Task 4.2: Pass-through `viewTaskDetail` through `KanbanCard.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/KanbanCard.vue`

- [ ] **Step 4.2.1: Add the emit declaration**

In `defineEmits` (around line 48-58), add `viewTaskDetail: [taskId: string]`.

- [ ] **Step 4.2.2: Add the pass-through on the inner WorkspaceItemTaskCard**

In the template (around line 86-96), add `@view-task-detail="(id) => emit('viewTaskDetail', id)"`.

- [ ] **Step 4.2.3: Build to verify types**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: 0 errors.

- [ ] **Step 4.2.4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanCard.vue
git commit -m "feat(frontend): pass viewTaskDetail through KanbanCard"
```

### Task 4.3: Pass-through `viewTaskDetail` through `KanbanColumn.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/KanbanColumn.vue`

- [ ] **Step 4.3.1: Add the emit declaration**

In `defineEmits` (around line 57-82), add `viewTaskDetail: [taskId: string]`.

- [ ] **Step 4.3.2: Add the pass-through on the inner KanbanCard**

In the template (around line 455-468), add `@view-task-detail="(id) => emit('viewTaskDetail', id)"`.

- [ ] **Step 4.3.3: Build to verify types**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: 0 errors.

- [ ] **Step 4.3.4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanColumn.vue
git commit -m "feat(frontend): pass viewTaskDetail through KanbanColumn"
```

### Task 4.4: Add `viewTaskDetail` to `KanbanView.vue` + mount the dialog

**Files:**
- Modify: `src/apps/desktop/src/components/KanbanView.vue`

- [ ] **Step 4.4.1: Add the emit declaration**

In `defineEmits` (around line 95-127), add `viewTaskDetail: [taskId: string]`.

- [ ] **Step 4.4.2: Add the pass-through on the inner KanbanColumn**

In the template (around line 281-301), add `@view-task-detail="(id) => emit('viewTaskDetail', id)"`.

- [ ] **Step 4.4.3: Resolve the active task from the kanban item's `tasks` array**

Add a computed property that, given `activeTaskDetailId.value` (a task id), returns the matching Task (or null). This will be passed to the dialog as the `task` prop.

```typescript
// At the top of the script:
// (no new imports needed; Task is already imported)

const activeTaskDetailId = defineModel<string | null>('activeTaskDetailId', { default: null })
const activeTaskDetail = computed<Task | null>(() => {
  if (!activeTaskDetailId.value) return null
  return (props.item.tasks ?? []).find((t) => t.id === activeTaskDetailId.value) ?? null
})
```

Wait — `defineModel` is for `v-model` binding. For a one-shot "open this dialog for this task" pattern, use a regular prop OR define a separate prop pair (`showTaskDetail: boolean`, `activeTaskDetailId: string | null`).

Cleaner approach: use `v-model` on the `show` prop with the parent AppLayout. This matches the pattern of every other dialog (e.g. KanbanSettingsDialog uses `v-model:show`):

```typescript
// In KanbanView.vue's <script>:
const showTaskDetail = defineModel<boolean>('showTaskDetail', { default: false })
```

But that doesn't carry the activeTaskId. Better:

```typescript
const showTaskDetail = defineModel<boolean>('showTaskDetail', { default: false })
const activeTaskDetailId = defineModel<string | null>('activeTaskDetailId', { default: null })
```

- [ ] **Step 4.4.4: Mount the dialog at the bottom of the template**

After the existing `<FilePickerDialog>`, add:

```vue
<KanbanTaskDetailDialog
  v-model:show="showTaskDetail"
  :task="activeTaskDetail"
/>
```

(You'll need to import the new component at the top: `import KanbanTaskDetailDialog from './KanbanTaskDetailDialog.vue'`.)

Note: This mounting approach requires AppLayout to pass `v-model:showTaskDetail` and `v-model:activeTaskDetailId` to KanbanView — handled in Task 4.5.

- [ ] **Step 4.4.5: Add `viewTaskDetail` emit handler that closes the loop**

When the inner KanbanColumn emits `viewTaskDetail`, the KanbanView should:
1. Capture the task id
2. Open the dialog (set `showTaskDetail.value = true`)
3. Set `activeTaskDetailId.value = taskId`

But the emit goes UP to AppLayout, which owns the dialog state... Actually, since the dialog is mounted IN KanbanView (per Task 4.4.4), KanbanView owns the dialog state directly. So `viewTaskDetail` is NOT emitted to AppLayout — it's consumed internally:

```typescript
const handleViewTaskDetail = (taskId: string) => {
  activeTaskDetailId.value = taskId
  showTaskDetail.value = true
}
```

Then in the template: `@view-task-detail="handleViewTaskDetail"`.

This simplifies the chain: the `viewTaskDetail` emit only travels Card → Column → View, NOT View → AppLayout. AppLayout doesn't need to know about this dialog.

- [ ] **Step 4.4.6: Build to verify types**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: 0 errors.

- [ ] **Step 4.4.7: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanView.vue
git commit -m "feat(frontend): mount KanbanTaskDetailDialog in KanbanView + handle viewTaskDetail"
```

### Task 4.5: Wire `updateTaskDetails` to the dialog save emit

**Files:**
- Modify: `src/apps/desktop/src/components/KanbanView.vue` (continue from 4.4)

- [ ] **Step 4.5.1: Handle the dialog's `save` emit**

In `KanbanView.vue`, add a handler:

```typescript
const workspacesStore = useWorkspacesStore()

const handleTaskDetailSave = async (payload: { name: string; description: string }) => {
  if (!activeTaskDetailId.value) return
  try {
    await workspacesStore.updateTaskDetails(
      props.workspaceId,
      props.itemId || props.item.id,
      activeTaskDetailId.value,
      payload,
    )
    showTaskDetail.value = false
    activeTaskDetailId.value = null
  } catch (err) {
    console.error('Failed to save task details:', err)
    // Keep the dialog open so the user can retry / fix
  }
}
```

In the template, on the dialog:

```vue
<KanbanTaskDetailDialog
  v-model:show="showTaskDetail"
  :task="activeTaskDetail"
  @save="handleTaskDetailSave"
/>
```

- [ ] **Step 4.5.2: Build to verify types**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: 0 errors.

- [ ] **Step 4.5.3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanView.vue
git commit -m "feat(frontend): wire updateTaskDetails to KanbanTaskDetailDialog save"
```

### Task 4.6: Update `KanbanView.spec.ts` to cover the new emit

**Files:**
- Modify: `src/apps/desktop/src/__tests__/KanbanView.spec.ts`

- [ ] **Step 4.6.1: Add tests for the `viewTaskDetail` emit pass-through**

In `KanbanView.spec.ts`, in the existing "pass-through" describe block (search for `select-task` emit tests), add:

```typescript
it('passes through view-task-detail from KanbanColumn', async () => {
  const item = makeItem({ tasks: [makeTask({ id: 'task_42', name: 'X' })] })
  wrapper = mountView(item)

  // Find the KanbanColumn → KanbanCard → emit chain. The simplest
  // way is to find the KanbanColumn component, get its emitted
  // events, and re-emit one.
  const column = wrapper.findComponent({ name: 'KanbanColumn' })
  column.vm.$emit('viewTaskDetail', 'task_42')
  await flushPromises()

  expect(wrapper.emitted('viewTaskDetail')).toBeTruthy()
  expect(wrapper.emitted('viewTaskDetail')?.[0]).toEqual(['task_42'])
})
```

Note: Since the dialog state is now internal to KanbanView (per Task 4.4.5), this test asserts the NEW pass-through AND that the dialog renders. Update the test to also assert that the dialog is now in the DOM after the emit:

```typescript
it('opens the detail dialog when view-task-detail is emitted', async () => {
  const item = makeItem({ tasks: [makeTask({ id: 'task_42', name: 'My task', description: 'A description' })] })
  wrapper = mountView(item)
  await flushPromises()
  // Dialog not open yet
  expect(wrapper.find('[data-testid="kanban-task-detail-dialog"]').exists()).toBe(false)

  const column = wrapper.findComponent({ name: 'KanbanColumn' })
  column.vm.$emit('viewTaskDetail', 'task_42')
  await flushPromises()

  // Dialog now visible
  expect(wrapper.find('[data-testid="kanban-task-detail-dialog"]').exists()).toBe(true)
})
```

- [ ] **Step 4.6.2: Run tests**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run KanbanView 2>&1 | tail -n 15`
Expected: baseline + 2 new tests pass.

- [ ] **Step 4.6.3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/__tests__/KanbanView.spec.ts
git commit -m "test(frontend): cover viewTaskDetail pass-through in KanbanView"
```

### Task 4.7: Final smoke test

- [ ] **Step 4.7.1: Run the full frontend build + test suite**

Run:
```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
timeout 120 bunx vitest run 2>&1 | tail -n 10
```
Expected: build clean; baseline + all new tests pass.

- [ ] **Step 4.7.2: Run the full backend build + test suite**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 240 zig build test --summary all 2>&1 | tail -n 10
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
```
Expected: backend baseline + 6-8 new migration/handler tests pass; install target compiles.

- [ ] **Step 4.7.3: Manual end-to-end smoke test**

1. Boot `./zig-out/bin/nalar --port 8080` (use 8080; 8081 is in use by the always-on nalar per project rules)
2. Open the kanban view at http://127.0.0.1:8080 in a browser (or use the bundled nalar-desktop)
3. Hover over a task card → click the "ⓘ" info icon → dialog opens with name + description
4. Edit the name and description, click Save → dialog closes, card reflects new values, server-side `GET /api/workspaces/.../tasks` returns the new values
5. Verify the description persists across page reloads (refresh the browser → still there)

- [ ] **Step 4.7.4: Commit any final tweaks**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git status
# If clean: no commit needed.
# If dirty: commit with a descriptive message.
```

- [ ] **Step 4.7.5: Tag Chunk 4 done — feature complete**

Report: "Kanban Task Detail Dialog is complete and live. Backend persists descriptions (Migration 061 + handler updates). Frontend has a new `KanbanTaskDetailDialog` component reachable via the hover-revealed "ⓘ" button on each card. All tests pass."

---

## Cross-chunk reminders

- **Per project memory `nalar-build-cross-compile-blocked.md`**: never run `zig build install:windows`, `install:macos`, or `install:macos-arm` — they fail at link time on a Linux host. Use `zig build install:linux:system` (the cp-to-`/usr/local/bin/nalar` fails harmlessly with permission denied, but the `compile exe nalar` step runs).

- **Per project memory `verification-before-completion`**: never claim a chunk is "done" without running `bun run build` AND `bunx vitest run` AND `zig build test --summary all` AND `zig build install:linux:system` and seeing all four pass.

- **Per project memory `desktop-typescript-bun-build-as-typecheck`**: `bun run build` (NOT just `bunx vitest run`) is the authoritative type-check. Vitest type-erases; vue-tsc catches TS errors.

- **Per project memory `multimodal-file-reverts`**: if other workers share the worktree, commit early and often between tasks so your work survives any concurrent `git checkout`.

---

## Summary

| Chunk | Files Touched | Approx. LOC | Tests Added |
|---|---|---|---|
| 1 — Backend | 5 (1 new, 4 modify) | ~120 | ~6-8 |
| 2 — API + store | 3 (1 new, 2 modify) | ~80 | 4 |
| 3 — Dialog | 2 (2 new) | ~280 | ~15 |
| 4 — Wire-up | 5 (all modify) | ~60 | 2 |
| **TOTAL** | **15 (4 new, 11 modify)** | **~540** | **~27-29** |

Plan file: `docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md`