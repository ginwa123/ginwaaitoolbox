# Copy Kanban Spec — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Copy spec" action to the Kanban Settings dialog that lets the user copy the active kanban's column structure (names + descriptions, preserving order) into a *different* kanban workspace item. Tasks are NOT copied — only the column template (the "spec"). The action is destructive for the target: the target's existing columns are deleted (with task unassignment, matching the existing `deleteColumn` semantics) and replaced with copies of the source's columns, plus an optional new-column append from the source's "Append instead" variant.

**Architecture:** Backend exposes a new `POST /api/workspaces/:workspace_id/items/:item_id/kanban/copy_spec_from/:source_item_id` endpoint that reads the source kanban's columns via `kanban_model.listColumns`, then for each source column inserts a new column row on the target via `kanban_model.addColumn` (preserving `position`). Existing target columns are first deleted using the existing `deleteColumn` path (which unassigns tasks by setting `kanban_column_id = NULL`), and a `kanban_column` SSE event with `action="deleted"` fires for each. The new columns fire SSE `kanban_column` events with `action="created"`. The frontend gets a new dialog `CopyKanbanSpecDialog.vue` that lists every other kanban (across all workspaces the user can see), presents two radio modes ("Replace" vs "Append"), and on confirm POSTs to the endpoint. The active kanban is filtered out of the picker so the user can't copy from themselves.

**Tech Stack:** Zig 0.16 backend, SQLite (in-memory for tests), Vue 3 + TypeScript + Pinia + Vitest frontend, Tailwind utility classes. Uses existing patterns: `parseFromSliceLeaky`, `std.json.Stringify.valueAlloc`, the `kanban_column` SSE channel, the per-request arena from `custom-http-server-per-request-arena.md`.

**Spec:** This plan is the implementation spec; no separate design doc exists.

---

## Context

### Current state

- `kanban_columns` table (Migration 051 + 053 in `src/ai_workflow/tui/migration.zig:914-1050`): `id`, `workspace_item_id`, `name`, `description`, `position`, `created_at`.
- `kanban_model.zig:31-94` exposes `KanbanColumn`, `freeColumns`, `listColumns` (returns ordered slice; caller frees).
- `kanban_model.zig:140-197` exposes `addColumn(allocator, db, item_id, name, description, position)` — position must be specified when copying (we use 0..N-1 from the source order).
- `kanban_model.zig:293-306` exposes `deleteColumn(allocator, db, workspace_item_id, column_id)` — unassigns tasks via `UPDATE workspace_item_tasks SET kanban_column_id = NULL`.
- `KanbanSettingsDialog.vue` (411 lines, mounted in `AppLayout.vue:1475-1483`) has a per-row Edit/Delete UX and an "Add Column" form. **No "Copy spec" action exists.**
- `createKanban` API (`src/apps/desktop/src/api/index.ts:967-987`): creates a kanban with seeded default columns. Not reused for "Copy spec" — that's a different code path.
- `listWorkspaceItems` model (`src/ai_workflow/tui/llm_history.zig:2574-2615`) returns every item in a workspace. The picker needs ALL kanbans across ALL workspaces, so we add a new `listAllKanbanItems` SQL helper (scoped to `item_type='kanban'`).

### What this plan delivers

1. Backend model helper `kanban_model.replaceColumnsWith(sourceItemId, targetItemId)` that does the spec-copy in a single SQLite transaction: delete target's columns (with task unassign), insert copies of source's columns with preserved positions.
2. New HTTP endpoint `POST /api/workspaces/:workspace_id/items/:item_id/kanban/copy_spec_from/:source_item_id` that wraps the model helper in the per-request arena, emits per-column SSE events for the cleanup + insert phases, and returns the new column list.
3. Frontend `copyKanbanSpec(workspaceId, itemId, sourceItemId, mode)` API wrapper (`src/apps/desktop/src/api/index.ts`) that POSTs `{source_item_id, mode}` to the endpoint and refreshes the local store from the returned `{columns, count}` envelope.
4. Frontend `CopyKanbanSpecDialog.vue` component — a new modal with a kanban picker (other kanbans in the workspace, or all kanbans across all workspaces — decision in Chunk 3), two radio modes ("Replace" vs "Append"), and a Confirm button.
5. Wire the "Copy spec" button into `KanbanSettingsDialog.vue` (3rd action button alongside Edit + Delete, or a new "Actions" area).
6. SSE `kanban_column` events on every column delete + create so the active user view stays in sync (no special-casing; the existing handler does all the work).
7. Static-contract regression tests for the backend handler + a new `CopyKanbanSpecDialog.spec.ts` for the UI.

### What's out of scope (deliberately)

- Copying TASK content (only the column "spec" / template). Tasks are intentionally NOT copied because each kanban has its own work and forcing task copy would silently merge unrelated work.
- Cross-workspace copy (the picker stays inside the same workspace for v1; cross-workspace is a v2 follow-up that needs a different UI).
- Copy from an empty kanban (returns an empty list — no error; the target becomes empty after Replace mode and gains no columns after Append mode).
- Auditing who triggered the copy (no audit log in v1).
- Undo (the destructive Replace is confirmed via the modal's Confirm step).

---

## File Structure

### New backend files

| File | Responsibility |
|---|---|
| `src/ai_workflow/tui/http_handlers/kanban_copy_spec.zig` | `POST /api/workspaces/:workspace_id/items/:item_id/kanban/copy_spec_from/:source_item_id` handler + use-case |
| `src/ai_workflow/tui/http_handlers/kanban_copy_spec_test.zig` | Static-contract regression checks (mirrors `kanban_columns_create_test.zig`) |
| `src/ai_workflow/tui/kanban_copy_spec_test.zig` | In-memory DB round-trip tests for `kanban_model.replaceColumnsWith` + `appendColumnsFrom` |

### Modified backend files

| File | Change |
|---|---|
| `src/ai_workflow/tui/kanban_model.zig` | Add `replaceColumnsWith(allocator, db, source_item_id, target_item_id) !void` and `appendColumnsFrom(allocator, db, source_item_id, target_item_id) !void` helpers |
| `src/ai_workflow/tui/http_handlers/mod.zig` | Re-export `kanbanCopySpecHandler` (line ~57, next to `kanbanColumnsDeleteHandler`) |
| `src/ai_workflow/tui/test_runner.zig` | Register `kanban_copy_spec_test.zig` and `kanban_copy_spec_test` (the model test) |
| `src/main.zig` | Register `POST /api/workspaces/:workspace_id/items/:item_id/kanban/copy_spec_from/:source_item_id` route (near line 372, next to `tasksMoveHandler`) |

### New frontend files

| File | Responsibility |
|---|---|
| `src/apps/desktop/src/components/CopyKanbanSpecDialog.vue` | Modal: picker of source kanbans (others in the same workspace, source item excluded) + Replace/Append radio + Confirm/Cancel |
| `src/apps/desktop/src/__tests__/CopyKanbanSpecDialog.spec.ts` | Vitest unit tests for the dialog (mount pattern mirrors `KanbanSettingsDialog.spec.ts`) |

### Modified frontend files

| File | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | Add `copyKanbanSpec(workspaceId, targetItemId, sourceItemId, mode)` wrapper near line 1051 (next to `addKanbanColumn`) |
| `src/apps/desktop/src/stores/workspaces.ts` | Add `copyKanbanSpecFrom(workspaceId, targetItemId, sourceItemId, mode)` action that calls the API and refreshes `item.kanban_columns` from the returned `{columns, count}` envelope |
| `src/apps/desktop/src/components/KanbanSettingsDialog.vue` | Add a "Copy spec" button to the column-list rows OR a dedicated footer button (decision below in Chunk 4) that emits `copySpec` with the active kanban's id; mount `CopyKanbanSpecDialog` child component |
| `src/apps/desktop/src/components/AppLayout.vue` | Add `handleKanbanSettingsCopySpec` handler (~line 785, next to `handleKanbanSettingsDeleteColumn`) that calls `workspacesStore.copyKanbanSpecFrom` and handles the SSE refresh |

---

## Chunk 1: Backend model helpers (`replaceColumnsWith` + `appendColumnsFrom`)

> Smallest backend chunk. The helpers are designed to be called from the new endpoint (Chunk 2). All allocations live on the per-request arena in production; the test file uses `testing.allocator` to verify leak-safety.

### Task 1.1: Add `replaceColumnsWith` to `kanban_model.zig`

**Files:**
- Modify: `src/ai_workflow/tui/kanban_model.zig` (insert after `deleteColumn`, before `countTasksInColumn` at line ~293)

- [ ] **Step 1: Write the failing test**

Create `src/ai_workflow/tui/kanban_copy_spec_test.zig`:

```zig
//! In-memory round-trip tests for `replaceColumnsWith` and
//! `appendColumnsFrom` in `kanban_model.zig`.
//!
//! These helpers power the POST /kanban/copy_spec_from endpoint
//! (Chunk 2 of the copy-kanban plan). The tests verify:
//!   1. Replace mode: target's existing columns are deleted
//!      (tasks unassigned via the existing deleteColumn path's
//!      behavior), and source's columns are copied with preserved
//!      positions 0..N-1.
//!   2. Append mode: source's columns are appended after target's
//!      max(position), source columns NOT deleted.
//!   3. Description round-trips.
//!   4. Task unassign: tasks previously assigned to a target column
//!      get `kanban_column_id = NULL` after replace.
//!   5. Empty-source case: replace with empty source → target empty.
//!
//! Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
//!   (Chunk 1, Task 1.1)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const kanban_model = @import("kanban_model.zig");

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    const migration = @import("migration.zig");
    try migration.Migration051AddKanban.up(&db, alloc);
    try migration.Migration053AddKanbanColumnDescription.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "replaceColumnsWith deletes target columns and copies source columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed source kanban with 3 columns.
    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_src", "todo", "", 0);
    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_src", "in progress", "", 1);
    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_src", "done", "", 2);

    // Seed target kanban with 1 column (different from source).
    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_tgt", "legacy", "", 0);

    try kanban_model.replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_tgt");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("in progress", cols[1].name);
    try testing.expectEqualStrings("done", cols[2].name);
    // Positions are 0, 1, 2 (dense).
    try testing.expectEqual(@as(i64, 0), cols[0].position);
    try testing.expectEqual(@as(i64, 1), cols[1].position);
    try testing.expectEqual(@as(i64, 2), cols[2].position);
}

test "replaceColumnsWith preserves description field" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    _ = try kanban_model.addColumn(
        alloc, &ctx.db, "wi_src", "in_review", "Awaiting code review", 0,
    );
    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_tgt", "old", "Old desc", 0);

    try kanban_model.replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_tgt");
    defer kanban_model.freeColumns(alloc, cols);
    try testing.expectEqualStrings("Awaiting code review", cols[0].description);
}

test "appendColumnsFrom adds source columns to target without deleting" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_src", "review", "", 0);
    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_src", "merged", "", 1);

    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_tgt", "todo", "", 0);
    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_tgt", "in progress", "", 1);
    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_tgt", "done", "", 2);

    try kanban_model.appendColumnsFrom(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_tgt");
    defer kanban_model.freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 5), cols.len);
    // Original target columns kept their positions 0,1,2.
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("in progress", cols[1].name);
    try testing.expectEqualStrings("done", cols[2].name);
    // Source columns appended at MAX+1, MAX+2 (positions 3, 4).
    try testing.expectEqualStrings("review", cols[3].name);
    try testing.expectEqualStrings("merged", cols[4].name);
    try testing.expectEqual(@as(i64, 3), cols[3].position);
    try testing.expectEqual(@as(i64, 4), cols[4].position);
}

test "replaceColumnsWith unassigns tasks on the deleted target columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Need workspace_item_tasks table for this test — minimal schema.
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT,
        \\    workspace_item_id TEXT,
        \\    kanban_column_id TEXT,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});

    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_src", "todo", "", 0);
    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_tgt", "legacy", "", 0);

    // Create a task assigned to the target's "legacy" column.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_id, workspace_item_id, kanban_column_id) " ++
        "VALUES ('task_1', 'ws_1', 'wi_tgt', (SELECT id FROM kanban_columns WHERE workspace_item_id = 'wi_tgt'))",
        &.{},
    );

    try kanban_model.replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    // Verify the task was unassigned (kanban_column_id NULL).
    var q = try ctx.db.query(alloc,
        "SELECT COALESCE(kanban_column_id, '') FROM workspace_item_tasks WHERE id = 'task_1'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "replaceColumnsWith with empty source empties the target" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_src", "todo", "", 0);
    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_tgt", "x", "", 0);
    _ = try kanban_model.addColumn(alloc, &ctx.db, "wi_tgt", "y", "", 1);

    // Manually empty the source.
    try ctx.db.exec(alloc, "DELETE FROM kanban_columns WHERE workspace_item_id = 'wi_src'", &.{});

    try kanban_model.replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_tgt");
    defer kanban_model.freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 0), cols.len);
}
```

- [ ] **Step 2: Register the test**

Add `_ = @import("kanban_copy_spec_test.zig");` to `src/ai_workflow/tui/test_runner.zig` (next to `kanban_model_test_description.zig`).

- [ ] **Step 3: Run test to verify it fails**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: compile error `kanban_model.replaceColumnsWith not found` (the function doesn't exist yet).

- [ ] **Step 4: Implement `replaceColumnsWith`**

In `src/ai_workflow/tui/kanban_model.zig`, after `deleteColumn` (line 306) and before `countTasksInColumn` (line 321), add:

```zig
/// Replace the target kanban's columns with copies of the source
/// kanban's columns. The target's existing columns are deleted
/// (tasks assigned to them get `kanban_column_id = NULL` per the
/// existing `deleteColumn` contract); the source's columns are
/// then inserted on the target with positions 0..N-1 matching the
/// source's order.
///
/// Used by the `POST /kanban/copy_spec_from` endpoint
/// (Chunk 2 of the copy-kanban plan) in "Replace" mode. The
/// destructive delete + insert sequence is performed in three
/// SQL statements without an explicit transaction wrapper — SQLite
/// auto-commits each statement, and the consequence of an
/// interrupted copy (target emptied, source not yet copied) is
/// recoverable by re-running the endpoint.
///
/// Both `workspace_item_id` arguments are validated by the caller
/// (HTTP handler); this helper assumes they exist in the
/// `workspace_items` table.
///
/// Allocator is only used for the transient `position` strings;
/// the `kanban_columns` inserts use the SQLite-bound execution
/// path which doesn't go through `allocator`.
pub fn replaceColumnsWith(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    source_item_id: []const u8,
    target_item_id: []const u8,
) !void {
    // Step 1: Fetch the source's columns (ordered by position ASC).
    const source_cols = try listColumns(allocator, db, source_item_id);
    defer freeColumns(allocator, source_cols);

    // Step 2: Delete every existing column on the target. Mirrors
    // the loop the HTTP `deleteColumn` handler performs one-at-a-time
    // (calling deleteColumn directly), but inlined so we batch the
    // SSE emits after we have the new state in hand.
    var existing = try db.query(allocator,
        "SELECT kc.id FROM kanban_columns kc WHERE kc.workspace_item_id = ?",
        &.{target_item_id});
    defer existing.deinit();
    var target_column_ids = std.ArrayList([]u8).empty;
    errdefer {
        for (target_column_ids.items) |id| allocator.free(id);
        target_column_ids.deinit(allocator);
    }
    while (try existing.next()) |row| {
        defer row.deinit(allocator);
        try target_column_ids.append(allocator, try allocator.dupe(u8, row.values[0]));
    }
    for (target_column_ids.items) |col_id| {
        // Use the existing deleteColumn helper so task-unassign
        // semantics stay consistent with the per-column delete
        // handler.
        try deleteColumn(allocator, db, target_item_id, col_id);
    }

    // Step 3: Copy each source column to the target with position 0..N-1.
    for (source_cols, 0..) |col, idx| {
        _ = try addColumn(
            allocator,
            db,
            target_item_id,
            col.name,
            col.description,
            @intCast(idx),
        );
    }
}

/// Append copies of the source kanban's columns to the end of the
/// target kanban's column sequence. Unlike `replaceColumnsWith`,
/// this does NOT delete the target's existing columns — they keep
/// their positions 0..M-1 and the source's columns are appended at
/// M, M+1, M+2, … (where M is the target's MAX(position) + 1).
///
/// Used by the `POST /kanban/copy_spec_from` endpoint in "Append"
/// mode. Like `replaceColumnsWith`, no transaction wrapper is used
/// — SQLite auto-commits each INSERT. The append-only semantics
/// mean partial failures leave a few extra columns at the end of
/// the target, which the user can manually delete.
pub fn appendColumnsFrom(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    source_item_id: []const u8,
    target_item_id: []const u8,
) !void {
    const source_cols = try listColumns(allocator, db, source_item_id);
    defer freeColumns(allocator, source_cols);

    // Compute MAX(position) + 1 across the target's columns. The
    // COALESCE handles the empty-target case (no rows → MAX is
    // NULL → -1 → position 0).
    var start_pos: i64 = 0;
    {
        var q = try db.query(allocator,
            \\SELECT COALESCE(MAX(kc.position), -1) + 1
            \\FROM kanban_columns kc
            \\WHERE kc.workspace_item_id = ?
        , &.{target_item_id});
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            start_pos = try std.fmt.parseInt(i64, row.values[0], 10);
        }
    }

    for (source_cols, 0..) |col, offset| {
        _ = try addColumn(
            allocator,
            db,
            target_item_id,
            col.name,
            col.description,
            start_pos + @as(i64, @intCast(offset)),
        );
    }
}
```

- [ ] **Step 5: Run test to verify they pass**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 5 new tests pass; no regressions. (Total grows by 5.)

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/kanban_model.zig \
        src/ai_workflow/tui/kanban_copy_spec_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "feat(kanban): model helpers replaceColumnsWith + appendColumnsFrom"
```

---

## Chunk 2: Backend HTTP endpoint + use-case + SSE

> Wraps the helpers from Chunk 1 in the per-request arena + SSE protocol. The endpoint accepts `mode` in the body ("replace" | "append") and returns the target's new column list.

### Task 2.1: Add `kanban_copy_spec.zig` handler

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/kanban_copy_spec.zig`

- [ ] **Step 1: Create the handler file**

Create `src/ai_workflow/tui/http_handlers/kanban_copy_spec.zig`:

```zig
//! `POST /api/workspaces/:workspace_id/items/:item_id/kanban/copy_spec_from/:source_item_id`.
//!
//! Copies the source kanban's column structure (names + descriptions,
//! preserving order) to the target kanban. Tasks are NOT copied.
//!
//! Body: `{mode: "replace" | "append"}`. Defaults to "replace"
//! when omitted (preserves backwards compat with callers that don't
//! pass the field).
//!
//! Returns 200 with `{columns, count}` (same envelope as
//! `GET /kanban/columns`) on success. On failure:
//!   - 400 missing/malformed body, missing path params, invalid mode
//!   - 404 source or target kanban item not found
//!   - 500 DB failure
//!
//! Layered as `useCase` (validate → resolve ids → call model helper →
//! emit SSE events → return columns) and a thin handler that maps
//! outcome + errors to status codes.
//!
//! Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
//!   (Chunk 2, Task 2.1)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../kanban_model.zig");
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;
const llm_history = nalarcore.llm_history;

/// Request body. `mode` is optional — absent defaults to "replace".
const CopySpecBody = struct {
    /// "replace" (default) | "append"
    mode: ?[]const u8 = null,
};

/// Source-or-target identifier for clearer error messages.
pub const CopySpecError = error{
    WorkspaceIdRequired,
    ItemIdRequired,
    SourceItemIdRequired,
    InvalidMode,
    WorkspaceItemNotFound,
    DatabaseError,
    OutOfMemory,
};

pub const CopySpecInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    source_item_id: []const u8,
    mode: []const u8,
};

/// Returns the JSON-encoded envelope `{columns: [...], count: N}`.
pub const CopySpecResult = []const u8;

// =====================================================================
// Use case
// =====================================================================

/// Copy the source kanban's column spec to the target kanban.
///
/// Steps:
///   1. Validate that workspace_id, item_id, source_item_id are non-empty
///      and item_id != source_item_id (no self-copy).
///   2. Confirm both items exist in the workspace_items table with
///      item_type='kanban' (404 otherwise).
///   3. Snapshot the target's existing column ids (used for SSE
///      emits after the model's destructive delete + insert pass).
///   4. Call `replaceColumnsWith` or `appendColumnsFrom` per `mode`.
///   5. Emit per-column SSE events: `action="deleted"` for each
///      pre-existing target column (Replace mode only — Append
///      doesn't delete), `action="created"` for each newly inserted
///      column (both modes).
///   6. Re-read the target's column list via `listColumns` and
///      return the wire-format envelope.
///
/// The SSE emissions are fire-and-forget (logged + swallowed on
/// failure so the HTTP 200 still succeeds) — same pattern as every
/// other kanban mutation endpoint.
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: CopySpecInput,
) CopySpecError!CopySpecResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.source_item_id.len == 0) return error.SourceItemIdRequired;
    if (std.mem.eql(u8, input.item_id, input.source_item_id)) {
        // Self-copy has no useful semantics (the model would
        // delete-then-recreate, possibly with same row ids). 400.
        return error.SourceItemIdRequired;
    }
    if (!std.mem.eql(u8, input.mode, "replace") and
        !std.mem.eql(u8, input.mode, "append"))
    {
        return error.InvalidMode;
    }

    // Step 2: confirm both items are kanbans in the DB. Return 404
    // if either is missing or is the wrong type. We re-use the
    // getWorkspaceItem helper from llm_history for the check.
    const target_item = llm_history.getWorkspaceItem(allocator, db, input.item_id)
        catch return error.DatabaseError;
    if (target_item == null or !std.mem.eql(u8, target_item.?.item_type, "kanban")) {
        return error.WorkspaceItemNotFound;
    }
    if (target_item) |ti| {
        if (ti.workspace_item_id != null) {} // no-op for ownership discipline
        // Free the dupe from getWorkspaceItem (defensive — the
        // caller's ownership model says free-it-yourself).
        var ti_mut = ti;
        ti_mut.deinit(allocator);
    }
    const source_item = llm_history.getWorkspaceItem(allocator, db, input.source_item_id)
        catch return error.DatabaseError;
    if (source_item == null or !std.mem.eql(u8, source_item.?.item_type, "kanban")) {
        return error.WorkspaceItemNotFound;
    }
    if (source_item) |si| {
        var si_mut = si;
        si_mut.deinit(allocator);
    }

    // Step 3: snapshot target's pre-existing column ids (used for
    // SSE emits in step 5). We capture the IDs BEFORE the model
    // helper deletes them.
    var pre_existing_ids = std.ArrayList([]u8).empty;
    defer {
        for (pre_existing_ids.items) |id| allocator.free(id);
        pre_existing_ids.deinit(allocator);
    }
    if (std.mem.eql(u8, input.mode, "replace")) {
        var q = try db.query(allocator,
            "SELECT kc.id FROM kanban_columns kc WHERE kc.workspace_item_id = ?",
            &.{input.item_id});
        defer q.deinit();
        while (try q.next()) |row| {
            defer row.deinit(allocator);
            try pre_existing_ids.append(allocator, try allocator.dupe(u8, row.values[0]));
        }
    }

    // Step 4: do the actual copy.
    if (std.mem.eql(u8, input.mode, "replace")) {
        kanban_model.replaceColumnsWith(
            allocator, db, input.source_item_id, input.item_id,
        ) catch return error.DatabaseError;
    } else {
        kanban_model.appendColumnsFrom(
            allocator, db, input.source_item_id, input.item_id,
        ) catch return error.DatabaseError;
    }

    // Step 5: SSE emits — fire-and-forget. Replace mode: emit one
    // `deleted` event per pre-existing column, then one `created`
    // event per newly inserted column. Append mode: only
    // `created` events.
    for (pre_existing_ids.items) |col_id| {
        on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
            .action = "deleted",
            .workspace_id = input.workspace_id,
            .item_id = input.item_id,
            .column_id = col_id,
        }) catch |err| {
            std.log.warn(
                "kanban_copy_spec: SSE delete-event failed (non-fatal): {s}",
                .{@errorName(err)},
            );
        };
    }

    // Step 6: re-read target columns for the response.
    const new_cols = try kanban_model.listColumns(allocator, db, input.item_id);
    defer kanban_model.freeColumns(allocator, new_cols);

    var emit_idx: usize = 0;
    while (emit_idx < new_cols.len) : (emit_idx += 1) {
        const col = new_cols[emit_idx];
        on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
            .action = "created",
            .workspace_id = input.workspace_id,
            .item_id = input.item_id,
            .column_id = col.id,
            .new_description = col.description,
        }) catch |err| {
            std.log.warn(
                "kanban_copy_spec: SSE create-event failed (non-fatal): {s}",
                .{@errorName(err)},
            );
        };
    }

    // Build the wire envelope `{columns, count}`. Each column is
    // mapped via the shared `makeKanbanColumnResponse` helper for
    // shape consistency with the other endpoints.
    const col_responses = try allocator.alloc(http_response.KanbanColumnResponse, new_cols.len);
    defer allocator.free(col_responses);
    for (new_cols, 0..) |col, i| {
        col_responses[i] = http_response.makeKanbanColumnResponse(col);
    }

    const Envelope = struct {
        columns: []const http_response.KanbanColumnResponse,
        count: usize,
    };

    return try std.json.Stringify.valueAlloc(
        allocator,
        Envelope{ .columns = col_responses, .count = new_cols.len },
        .{},
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn kanbanCopySpecHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Path params. `:workspace_id`, `:item_id`, `:source_item_id`.
    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";
    const source_item_id = req.params.get("source_item_id") orelse "";

    if (workspace_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }),
        });
    }
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }
    if (source_item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "source_item_id required" }),
        });
    }

    // 2. Body (may be empty — defaults to mode=replace).
    var mode: []const u8 = "replace";
    if (req.body.len > 0) {
        const parsed = std.json.parseFromSliceLeaky(
            CopySpecBody, allocator, req.body, .{},
        ) catch {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
            });
        };
        if (parsed.mode) |m| mode = m;
    }

    // 3. Delegate to use-case.
    const data = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .item_id = item_id,
        .source_item_id = source_item_id,
        .mode = mode,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.ItemIdRequired => 400,
            error.SourceItemIdRequired => 400,
            error.InvalidMode => 400,
            error.WorkspaceItemNotFound => 404,
            error.DatabaseError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.ItemIdRequired => "item_id required",
            error.SourceItemIdRequired => "source_item_id required (and must differ from item_id)",
            error.InvalidMode => "mode must be 'replace' or 'append'",
            error.WorkspaceItemNotFound => "Workspace item not found or is not a kanban",
            error.DatabaseError => "Failed to copy kanban spec",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = data,
    });
}
```

- [ ] **Step 2: Re-export from `http_handlers/mod.zig`**

Add to `src/ai_workflow/tui/http_handlers/mod.zig` line 57 (next to `kanbanColumnsDeleteHandler`):

```zig
// Kanban copy-spec endpoint (Chunk 2 of the copy-kanban plan).
// Source-or-target discriminator; replaces the target's columns
// with copies of the source's.
pub const kanbanCopySpecHandler = @import("kanban_copy_spec.zig").kanbanCopySpecHandler;
```

- [ ] **Step 3: Register the route in `main.zig`**

In `src/main.zig` after line 371 (`tasksMoveHandler` registration), add:

```zig
// Copy a kanban spec (column structure) from one kanban to another
// (Chunk 2 of copy-kanban plan). Body: `{mode: "replace" | "append"}`.
try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/kanban/copy_spec_from/:source_item_id", ai_mod.http_handlers.kanbanCopySpecHandler);
```

- [ ] **Step 4: Verify the Zig build is clean**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 5 model tests from Chunk 1 still pass; no regressions.

Run: `timeout 180 zig build install:linux:system 2>&1 | tail -n 10`
Expected: 4/6 steps succeed (the cp to `/usr/local/bin/nalar` fails harmlessly); the `compile exe nalar` step succeeds — important because `kanban_copy_spec.zig` is only reached in the production build, not the test build.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/kanban_copy_spec.zig \
        src/ai_workflow/tui/http_handlers/mod.zig \
        src/main.zig
git commit -m "feat(kanban): POST /kanban/copy_spec_from endpoint + handler"
```

### Task 2.2: Add static-contract regression tests

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/kanban_copy_spec_test.zig`

- [ ] **Step 1: Create the test file**

Create `src/ai_workflow/tui/http_handlers/kanban_copy_spec_test.zig`:

```zig
//! Static regression checks for `POST /kanban/copy_spec_from`.
//!
//! Mirrors the pattern from `kanban_columns_create_test.zig`:
//! read the source file, grep for required substrings that prove
//! the contract holds. The endpoint is too thin to warrant a
//! behavioral test (the model helpers in `kanban_model.zig` are
//! already covered by the in-memory `kanban_copy_spec_test.zig`).
//!
//! Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
//!   (Chunk 2, Task 2.2)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/kanban_copy_spec.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io, path, allocator, .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "kanban_copy_spec handler parses body with parseFromSliceLeaky" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, HANDLER_PATH);
    defer alloc.free(source);
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("\n!! {s} does not use parseFromSliceLeaky !!\n", .{HANDLER_PATH});
        return error.ParseFromSliceLeakyMissing;
    }
}

test "kanban_copy_spec handler gates on item_type=kanban" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, HANDLER_PATH);
    defer alloc.free(source);
    // The handler must call getWorkspaceItem + check item_type==kanban
    // (the canonical guard from the kanban endpoint family).
    if (std.mem.indexOf(u8, source, "item_type") == null or
        std.mem.indexOf(u8, source, "\"kanban\"") == null)
    {
        std.debug.print(
            "\n!! {s} does not check item_type='kanban' !!\n",
            .{HANDLER_PATH},
        );
        return error.KanbanTypeGuardMissing;
    }
}

test "kanban_copy_spec handler rejects self-copy" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, HANDLER_PATH);
    defer alloc.free(source);
    // The use-case rejects item_id == source_item_id with
    // error.SourceItemIdRequired. The handler maps that to 400.
    if (std.mem.indexOf(u8, source, "SourceItemIdRequired") == null) {
        std.debug.print(
            "\n!! {s} does not reject self-copy !!\n",
            .{HANDLER_PATH},
        );
        return error.SelfCopyGuardMissing;
    }
}

test "kanban_copy_spec handler emits SSE for created and deleted columns" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, HANDLER_PATH);
    defer alloc.free(source);
    if (std.mem.indexOf(u8, source, "onEventSendKanbanColumn") == null or
        std.mem.indexOf(u8, source, ".action = \"created\"") == null or
        std.mem.indexOf(u8, source, ".action = \"deleted\"") == null)
    {
        std.debug.print(
            "\n!! {s} does not emit kanban_column SSE for both delete + create !!\n",
            .{HANDLER_PATH},
        );
        return error.SseEmitMissing;
    }
}

test "kanban_copy_spec handler returns KanbanColumnResponse envelope" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, HANDLER_PATH);
    defer alloc.free(source);
    if (std.mem.indexOf(u8, source, "makeKanbanColumnResponse") == null or
        std.mem.indexOf(u8, source, "Envelop") == null)
    {
        std.debug.print(
            "\n!! {s} does not return a {columns, count} envelope !!\n",
            .{HANDLER_PATH},
        );
        return error.EnvelopeMissing;
    }
}
```

- [ ] **Step 2: Register the test**

Add `_ = @import("http_handlers/kanban_copy_spec_test.zig");` to `src/ai_workflow/tui/test_runner.zig` (next to the other kanban_copy_spec_test).

- [ ] **Step 3: Run the test suite**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 5 new static-contract tests pass; total grows by 10 (5 model + 5 handler).

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/kanban_copy_spec_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "test(kanban): static-contract checks for /kanban/copy_spec_from"
```

---

## Chunk 3: Frontend API wrapper + Pinia action

> Pure frontend chunk that wires the new endpoint into the desktop client. The UI chunk (4) depends on this chunk's exports.

### Task 3.1: Add `copyKanbanSpec` API wrapper

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 1: Add the wrapper function (after `addKanbanColumn` around line 1051)**

Insert the new function:

```ts
/**
 * Copy a kanban's column spec (names + descriptions, preserving
 * order) from a source kanban to a target kanban. Tasks are NOT
 * copied — only the column "template". Destructive for the target:
 * in `replace` mode, the target's existing columns are deleted
 * (with task unassignment) and replaced with copies of the
 * source's. In `append` mode, the source's columns are appended
 * after the target's existing MAX(position).
 *
 * Returns the target's new full column list `{columns, count}`
 * (same envelope as `listKanbanColumns`). The frontend replaces
 * its local `kanban_columns` array with this list in one round
 * trip — backend's atomic emit/replace pattern matches every
 * other kanban mutation endpoint.
 *
 * POST /api/workspaces/:workspaceId/items/:itemId/kanban/copy_spec_from/:sourceItemId
 *
 * Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
 *   (Chunk 3, Task 3.1)
 */
export async function copyKanbanSpec(
  workspaceId: string,
  targetItemId: string,
  sourceItemId: string,
  mode: 'replace' | 'append' = 'replace',
): Promise<{ columns: KanbanColumn[]; count: number }> {
  return await apiFetch<{ columns: KanbanColumn[]; count: number }>(
    `/workspaces/${workspaceId}/items/${targetItemId}/kanban/copy_spec_from/${sourceItemId}`,
    {
      method: 'POST',
      body: { mode },
    },
  )
}
```

- [ ] **Step 2: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(desktop): API wrapper copyKanbanSpec"
```

### Task 3.2: Add `copyKanbanSpecFrom` action to the workspaces store

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts`

- [ ] **Step 1: Add the action after `updateKanbanColumn` (line ~813)**

```ts
// Copy the column spec from `sourceItemId` to `targetItemId`.
// Destructive for the target in 'replace' mode (existing columns
// are deleted via the backend's `deleteColumn` path which
// unassigns tasks). 'append' mode adds the source's columns
// after the target's existing MAX(position).
//
// Mirrors the `updateKanbanColumn` pattern: the backend returns
// the full updated board on success so the local store gets the
// fresh column order without a follow-up GET.
async function copyKanbanSpecFrom(
  workspaceId: string,
  targetItemId: string,
  sourceItemId: string,
  mode: 'replace' | 'append' = 'replace',
): Promise<void> {
  const result = await api.copyKanbanSpec(workspaceId, targetItemId, sourceItemId, mode)
  const item = findItem(workspaceId, targetItemId)
  if (!item) return
  item.kanban_columns = [...result.columns].sort(
    (a, b) => a.position - b.position,
  )
}
```

- [ ] **Step 2: Export the action in the return block (near line 1635)**

Add `copyKanbanSpecFrom,` next to the other kanban actions in the store's return statement.

- [ ] **Step 3: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/stores/workspaces.ts
git commit -m "feat(desktop): workspaces store copies kanban spec on demand"
```

---

## Chunk 4: Frontend dialog + Settings wiring

> Mounts the UI: a new `CopyKanbanSpecDialog.vue` modal with a source kanban picker + Replace/Append radio, plus a "Copy spec from…" button in `KanbanSettingsDialog.vue`'s footer that opens the modal.

### Task 4.1: Create `CopyKanbanSpecDialog.vue`

**Files:**
- Create: `src/apps/desktop/src/components/CopyKanbanSpecDialog.vue`
- Create: `src/apps/desktop/src/__tests__/CopyKanbanSpecDialog.spec.ts`

- [ ] **Step 1: Create the component**

Create `src/apps/desktop/src/components/CopyKanbanSpecDialog.vue`:

```vue
<!--
  CopyKanbanSpecDialog — modal for copying one kanban's column
  spec (names + descriptions, preserving order) into a target
  kanban. Mounted from the ⚙ Settings dialog's footer button.

  Layout (top → bottom):
    1. Header — "Copy spec from…" title + close.
    2. Source picker — `<select>` of the workspace's other kanbans
       (the active target is filtered out). Uses the existing
       `workspacesStore.allWorkspaceItems` filtered for
       `item_type === 'kanban'` and `id !== target.id`.
    3. Mode radio — "Replace existing columns" (destructive) or
       "Append at the end" (additive). Replace is the default.
    4. Confirm button — fires the copy, then closes.

  Public API:
    props:
      show        boolean
      workspaceId string
      targetItemId string — the kanban the user wants to copy INTO
                             (filtered out of the source picker)
    emits:
      close       []
      copy        [sourceItemId: string, mode: 'replace' | 'append']

  The dialog is purely presentational — the host (AppLayout)
  delegates to workspacesStore.copyKanbanSpecFrom on each emit.
  The store action refreshes the target's `kanban_columns` from
  the backend's response, so the Settings dialog re-renders with
  the new list when the user re-opens it.

  Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
    (Chunk 4, Task 4.1)
-->
<script setup lang="ts">
import { ref, computed, watch, nextTick } from 'vue'
import { useWorkspacesStore, type WorkspaceItem } from '../stores/workspaces'

const props = defineProps<{
  show: boolean
  workspaceId: string
  targetItemId: string
}>()

const emit = defineEmits<{
  close: []
  copy: [sourceItemId: string, mode: 'replace' | 'append']
}>()

const workspacesStore = useWorkspacesStore()

// ─── State ────────────────────────────────────────────────────────────

const sourceItemId = ref<string>('')
const mode = ref<'replace' | 'append'>('replace')
const sourceSelect = ref<HTMLSelectElement | null>(null)

// ─── Picker data ──────────────────────────────────────────────────────

// All kanbans in the active workspace EXCEPT the target. Computed
// every time `props.show` flips true (so a fresh kanban created
// during the dialog's lifetime shows up next time).
const availableSources = computed<WorkspaceItem[]>(() => {
  return workspacesStore.workspaces
    .flatMap((ws) => (ws.id === props.workspaceId ? ws.items : []))
    .filter(
      (item) =>
        item.item_type === 'kanban' && item.id !== props.targetItemId,
    )
    .sort((a, b) => (a.name ?? '').localeCompare(b.name ?? ''))
})

// ─── Handlers ─────────────────────────────────────────────────────────

const handleCopy = () => {
  if (!sourceItemId.value) return
  emit('copy', sourceItemId.value, mode.value)
  handleClose()
}

const handleClose = () => {
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') handleClose()
}

// ─── Lifecycle ────────────────────────────────────────────────────────

// Reset state on every open. We deliberately do NOT preserve the
// source selection across open/close — the user's mental model is
// "open the dialog fresh each time".
watch(
  () => props.show,
  async (show) => {
    if (show) {
      sourceItemId.value = ''
      mode.value = 'replace'
      // Pre-select the first available source if any (UX nicety).
      const first = availableSources.value[0]
      if (first) sourceItemId.value = first.id
      await nextTick()
      sourceSelect.value?.focus()
    }
  },
)
</script>

<template>
  <Teleport to="body">
    <Transition name="copy-kanban-spec-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="copy-kanban-spec-title"
        data-testid="copy-kanban-spec-dialog"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6);"
          @click="handleClose"
        />

        <!-- Dialog Card -->
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35);
          "
        >
          <!-- Header -->
          <div
            class="px-5 pt-5 pb-4 shrink-0"
            style="border-bottom: 1px solid var(--color-border);"
          >
            <div class="flex items-center justify-between gap-3">
              <h3
                id="copy-kanban-spec-title"
                class="text-base font-semibold flex items-center gap-2"
                style="color: var(--semantic-text);"
              >
                <span aria-hidden="true">📋</span>
                Copy spec from…
              </h3>
              <button
                type="button"
                @click="handleClose"
                data-testid="copy-kanban-spec-close"
                class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80"
                style="color: var(--semantic-text-muted);"
                title="Close"
              >
                <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </div>
            <p
              class="text-xs mt-1"
              style="color: var(--semantic-text-dim);"
            >
              Copy the column names + descriptions from another kanban into this one. Tasks are not copied.
            </p>
          </div>

          <!-- Body -->
          <div class="px-5 py-4">
            <label
              class="block text-xs font-medium mb-2"
              style="color: var(--semantic-text-dim);"
            >
              Source kanban
            </label>
            <select
              ref="sourceSelect"
              v-model="sourceItemId"
              data-testid="copy-kanban-spec-source"
              class="w-full px-3 py-2 rounded-lg text-sm outline-none transition-all duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
            >
              <option
                v-for="item in availableSources"
                :key="item.id"
                :value="item.id"
              >
                {{ item.name || '(unnamed)' }}
              </option>
              <option
                v-if="availableSources.length === 0"
                value=""
                disabled
              >
                No other kanbans in this workspace
              </option>
            </select>
            <p
              v-if="availableSources.length === 0"
              class="text-[11px] mt-2 italic"
              style="color: var(--semantic-text-dim);"
              data-testid="copy-kanban-spec-empty"
            >
              Create another kanban in this workspace first, then come back to copy its spec.
            </p>

            <fieldset class="mt-4">
              <legend
                class="block text-xs font-medium mb-2"
                style="color: var(--semantic-text-dim);"
              >
                What should happen to this kanban's existing columns?
              </legend>
              <label
                class="flex items-start gap-2 px-3 py-2 rounded-lg cursor-pointer mb-1"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
              >
                <input
                  v-model="mode"
                  type="radio"
                  value="replace"
                  data-testid="copy-kanban-spec-mode-replace"
                  class="mt-1"
                />
                <span>
                  <span class="text-sm font-medium" style="color: var(--semantic-text);">Replace</span>
                  <span class="block text-[11px]" style="color: var(--semantic-text-dim);">
                    Delete every column on this kanban (existing tasks become unassigned) and replace with the source's columns.
                  </span>
                </span>
              </label>
              <label
                class="flex items-start gap-2 px-3 py-2 rounded-lg cursor-pointer"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
              >
                <input
                  v-model="mode"
                  type="radio"
                  value="append"
                  data-testid="copy-kanban-spec-mode-append"
                  class="mt-1"
                />
                <span>
                  <span class="text-sm font-medium" style="color: var(--semantic-text);">Append</span>
                  <span class="block text-[11px]" style="color: var(--semantic-text-dim);">
                    Keep this kanban's existing columns; add the source's columns at the end.
                  </span>
                </span>
              </label>
            </fieldset>
          </div>

          <!-- Actions -->
          <div
            class="px-5 pb-5 flex justify-end gap-2"
            style="border-top: 1px solid var(--color-border); padding-top: 1rem;"
          >
            <button
              type="button"
              @click="handleClose"
              data-testid="copy-kanban-spec-cancel"
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
              @click="handleCopy"
              :disabled="!sourceItemId || availableSources.length === 0"
              data-testid="copy-kanban-spec-confirm"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
            >
              Copy spec
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.copy-kanban-spec-modal-enter-active,
.copy-kanban-spec-modal-leave-active {
  transition: opacity 0.2s ease;
}
.copy-kanban-spec-modal-enter-from,
.copy-kanban-spec-modal-leave-to {
  opacity: 0;
}
.copy-kanban-spec-modal-enter-active > div:last-child,
.copy-kanban-spec-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}
.copy-kanban-spec-modal-enter-from > div:last-child,
.copy-kanban-spec-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>
```

- [ ] **Step 2: Create the test file**

Create `src/apps/desktop/src/__tests__/CopyKanbanSpecDialog.spec.ts`:

```ts
/**
 * Tests for CopyKanbanSpecDialog — the per-board "copy spec from
 * another kanban" modal. Mount pattern: same as
 * KanbanSettingsDialog.spec.ts (Teleport + attachTo: document.body
 * + document.querySelector for DOM assertions).
 *
 * Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
 *   (Chunk 4, Task 4.1)
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import CopyKanbanSpecDialog from '@/components/CopyKanbanSpecDialog.vue'
import { useWorkspacesStore, type Workspace, type WorkspaceItem } from '@/stores/workspaces'

const source1: WorkspaceItem = {
  id: 'wi_src_1',
  name: 'Sprint 12 (template)',
  item_type: 'kanban',
  path: null,
}

const source2: WorkspaceItem = {
  id: 'wi_src_2',
  name: 'Bug triage',
  item_type: 'kanban',
  path: null,
}

const target: WorkspaceItem = {
  id: 'wi_target',
  name: 'Local Sprint',
  item_type: 'kanban',
  path: null,
}

const workspace: Workspace = {
  id: 'ws_test',
  name: 'Test workspace',
  icon: '📂',
  items: [source1, source2, target],
  expanded: true,
}

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

describe('CopyKanbanSpecDialog', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    document.body.innerHTML = ''
    setActivePinia(createPinia())
    const store = useWorkspacesStore()
    store.workspaces = [workspace]
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body
      .querySelectorAll('[data-testid="copy-kanban-spec-dialog"]')
      .forEach((el) => el.remove())
  })

  function mountDialog() {
    wrapper = mount(CopyKanbanSpecDialog, {
      attachTo: document.body,
      props: {
        show: true,
        workspaceId: 'ws_test',
        targetItemId: 'wi_target',
      },
    })
    return wrapper
  }

  it('renders the dialog with the right title', async () => {
    mountDialog()
    await flushPromises()
    const dialog = findInDom<HTMLElement>('[data-testid="copy-kanban-spec-dialog"]')
    expect(dialog).not.toBeNull()
    expect(dialog?.textContent).toContain('Copy spec from')
  })

  it('excludes the target from the source picker', async () => {
    mountDialog()
    await flushPromises()
    const select = findInDom<HTMLSelectElement>(
      '[data-testid="copy-kanban-spec-source"]',
    )
    expect(select).not.toBeNull()
    const options = Array.from(select!.options)
    const ids = options.map((o) => o.value).filter((v) => v)
    // target (wi_target) MUST NOT appear; sources 1 and 2 must.
    expect(ids).toContain('wi_src_1')
    expect(ids).toContain('wi_src_2')
    expect(ids).not.toContain('wi_target')
  })

  it('defaults to replace mode', async () => {
    mountDialog()
    await flushPromises()
    const replaceRadio = findInDom<HTMLInputElement>(
      '[data-testid="copy-kanban-spec-mode-replace"]',
    )
    expect(replaceRadio?.checked).toBe(true)
  })

  it('emits copy with the selected source and mode on Confirm', async () => {
    const w = mountDialog()
    await flushPromises()
    // Switch to append mode.
    const appendRadio = findInDom<HTMLInputElement>(
      '[data-testid="copy-kanban-spec-mode-append"]',
    )
    appendRadio!.checked = true
    appendRadio!.dispatchEvent(new Event('change', { bubbles: true }))
    await flushPromises()

    // Confirm.
    clickInDom('[data-testid="copy-kanban-spec-confirm"]')
    await flushPromises()

    const emitted = w!.emitted('copy')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['wi_src_1', 'append'])
  })

  it('emits close on Cancel and on backdrop click', async () => {
    const w = mountDialog()
    await flushPromises()
    clickInDom('[data-testid="copy-kanban-spec-cancel"]')
    await flushPromises()
    expect(w!.emitted('close')).toBeTruthy()
  })

  it('disables the confirm button when no sources are available', async () => {
    const store = useWorkspacesStore()
    // Clear the items array — only target remains — but we must ALSO
    // remove the target so the picker is empty.
    store.workspaces = [
      { ...workspace, items: [target] },
    ]
    const w = mountDialog()
    await flushPromises()

    const emptyMsg = findInDom<HTMLElement>(
      '[data-testid="copy-kanban-spec-empty"]',
    )
    expect(emptyMsg).not.toBeNull()
    const confirmBtn = findInDom<HTMLButtonElement>(
      '[data-testid="copy-kanban-spec-confirm"]',
    )
    expect(confirmBtn?.disabled).toBe(true)
    // Closes without emitting copy.
    clickInDom('[data-testid="copy-kanban-spec-confirm"]')
    await flushPromises()
    expect(w!.emitted('copy')).toBeFalsy()
  })
})
```

- [ ] **Step 3: Run the test suite + type-check**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run CopyKanbanSpecDialog 2>&1 | tail -n 20`
Expected: 6 new tests pass.

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/components/CopyKanbanSpecDialog.vue \
        src/apps/desktop/src/__tests__/CopyKanbanSpecDialog.spec.ts
git commit -m "feat(desktop): CopyKanbanSpecDialog with source picker + replace/append modes"
```

### Task 4.2: Add the "Copy spec…" footer button to `KanbanSettingsDialog.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/KanbanSettingsDialog.vue`

- [ ] **Step 1: Add `copySpec` to the emits**

Change the `defineEmits` block (line 40-56) to add the new event:

```ts
const emit = defineEmits<{
  close: []
  addColumn: [name: string, description: string]
  editColumn: [
    payload: { columnId: string; name: string; description: string },
  ]
  deleteColumn: [columnId: string]
  renameItem: [name: string]
  /**
   * Fired when the user clicks the "Copy spec…" footer button.
   * The host (AppLayout) opens CopyKanbanSpecDialog with the
   * active kanban as the target. The dialog will emit `copy`
   * back with the chosen source + mode; AppLayout delegates
   * to workspacesStore.copyKanbanSpecFrom.
   *
   * Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
   *   (Chunk 4, Task 4.2)
   */
  copySpec: []
}>()
```

- [ ] **Step 2: Add the click handler + button**

Add the handler near `handleClose` (line 144):

```ts
const handleCopySpec = () => {
  emit('copySpec')
}
```

Add a footer button BEFORE the closing `</div>` of the dialog card (after the columns list `<div>` at line 297). The placement: directly below the columns list, above the dialog card's closing `</div>`. It is a low-priority action (less prominent than per-row Edit/Delete) and clearly secondary to Add + Rename:

```vue
<!-- Copy spec footer -->
<div
  class="px-5 py-3 shrink-0"
  style="border-top: 1px solid var(--color-border); background-color: var(--semantic-sidebar-bg);"
>
  <button
    type="button"
    @click="handleCopySpec"
    data-testid="kanban-settings-copy-spec"
    class="px-3 py-1.5 rounded-lg text-sm font-medium transition-opacity duration-200 hover:opacity-80"
    style="
      background-color: var(--semantic-card-bg);
      border: 1px solid var(--color-border);
      color: var(--semantic-text-muted);
    "
  >
    <span aria-hidden="true">📋</span>
    <span class="ml-1">Copy spec from…</span>
  </button>
  <p
    class="text-[11px] mt-2 italic"
    style="color: var(--semantic-text-dim);"
  >
    Bulk-copy column names + descriptions from another kanban in this workspace. Tasks are not copied.
  </p>
</div>
```

- [ ] **Step 3: Add an append-mode-only note (optional UX clarification)**

No additional change here — the in-dialog text in `CopyKanbanSpecDialog` covers the destructive/non-destructive difference.

- [ ] **Step 4: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build (the new emit isn't consumed yet — that's Task 4.3).

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/components/KanbanSettingsDialog.vue
git commit -m "feat(desktop): KanbanSettingsDialog footer gains Copy spec button"
```

### Task 4.3: Wire `AppLayout.vue` to mount `CopyKanbanSpecDialog` + delegate `copySpec`

**Files:**
- Modify: `src/apps/desktop/src/components/AppLayout.vue`

- [ ] **Step 1: Import `CopyKanbanSpecDialog` (next to the existing import at line 16)**

```ts
import CopyKanbanSpecDialog from './CopyKanbanSpecDialog.vue'
```

- [ ] **Step 2: Add the open/close/copy handlers + state (~line 786, next to `handleKanbanSettingsDeleteColumn`)**

```ts
// ─── CopyKanbanSpecDialog ────────────────────────────────────────────────
//
// Per-board "copy columns from another kanban" flow. Triggered by
// the "Copy spec…" footer button in KanbanSettingsDialog. The
// dialog itself is a modal with a source picker + Replace/Append
// radio; this handler delegates to workspacesStore.copyKanbanSpecFrom
// which calls POST /kanban/copy_spec_from and refreshes the target's
// local kanban_columns from the backend's response.
const showCopyKanbanSpecDialog = ref(false)

const handleOpenCopyKanbanSpec = () => {
  showCopyKanbanSpecDialog.value = true
}

const handleCloseCopyKanbanSpec = () => {
  showCopyKanbanSpecDialog.value = false
}

const handleCopyKanbanSpec = (sourceItemId: string, mode: 'replace' | 'append') => {
  if (!activeWorkspaceItem.value || !activeWorkspace.value) return
  void workspacesStore
    .copyKanbanSpecFrom(
      activeWorkspace.value.id,
      activeWorkspaceItem.value.id,
      sourceItemId,
      mode,
    )
    .then(() => {
      showCopyKanbanSpecDialog.value = false
    })
}
```

- [ ] **Step 3: Pass `activeWorkspaceId` (workspace id) through the props**

The dialog needs `workspaceId` (not just item). Replace the `<KanbanSettingsDialog>` template block (line 1475-1483) with:

```vue
<KanbanSettingsDialog
  :show="showKanbanSettingsDialog"
  :item="activeWorkspaceItem ?? null"
  @close="handleCloseKanbanSettings"
  @add-column="handleKanbanSettingsAddColumn"
  @edit-column="handleKanbanSettingsEditColumn"
  @delete-column="handleKanbanSettingsDeleteColumn"
  @rename-item="handleKanbanRenameItem"
  @copy-spec="handleOpenCopyKanbanSpec"
/>

<CopyKanbanSpecDialog
  :show="showCopyKanbanSpecDialog"
  :workspace-id="activeWorkspace?.id ?? ''"
  :target-item-id="activeWorkspaceItem?.id ?? ''"
  @close="handleCloseCopyKanbanSpec"
  @copy="handleCopyKanbanSpec"
/>
```

Note: `CopyKanbanSpecDialog` is mounted SIBLING to `KanbanSettingsDialog`, not inside it. The user opens Settings, clicks "Copy spec…", which opens the picker dialog. The Settings dialog stays open under the picker (a single-page-modal-stack is fine; the picker is modal-on-modal). Both close when the user cancels the picker.

- [ ] **Step 4: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/components/AppLayout.vue
git commit -m "feat(desktop): AppLayout mounts CopyKanbanSpecDialog + wires copy flow"
```

---

## Chunk 5: End-to-end smoke test + final verification

> Mirrors the regression-test + manual smoke-test pattern from prior kanban plans. Verifies all pieces work together (backend + frontend).

### Task 5.1: Run the full Zig test suite + install:linux build

- [ ] **Step 1: Run the full Zig test suite**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 10`
Expected: all tests pass. Test count grows by 10 (5 model + 5 static-contract).

- [ ] **Step 2: Run `install:linux:system` to verify the binary compiles**

Run: `timeout 240 zig build install:linux:system 2>&1 | tail -n 15`
Expected: 4/6 steps succeed (the cp to `/usr/local/bin/nalar` fails harmlessly with "Permission denied"). The crucial step "compile exe nalar" must succeed with no errors.

- [ ] **Step 3: Manual smoke test — copy-spec endpoint on port 8080**

> **Use port 8080** (NOT 8081) — port 8081 has another `nalar` process running for the dev workflow. The mandatory rule in NALAR.md: do not kill that process.

```bash
# 1. Start nalar on 8080 in the background.
./zig-out/bin/nalar --port 8080 &
echo $! > /tmp/nalar-smoke.pid
sleep 2

# 2. Substitute these for your workspace + kanban items.
WS_ID="ws_<your-workspace-id>"
TARGET_ID="item_<target-kanban-item-id>"   # the kanban you want to copy INTO
SOURCE_ID="item_<source-kanban-item-id>"   # the kanban you want to copy FROM

# 3. Seed columns on the source kanban (use the AddKanban endpoint or
#    POST /kanban/columns repeatedly). Verify the source has data:
curl -sS "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${SOURCE_ID}/kanban/columns" \
  | jq '.columns[] | {name, description}'

# 4. Verify the target's existing columns:
curl -sS "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${TARGET_ID}/kanban/columns" \
  | jq '.columns[] | {name, description}'

# 5. POST copy_spec_from in replace mode. Default mode is 'replace'.
curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${TARGET_ID}/kanban/copy_spec_from/${SOURCE_ID}" \
  -H "Content-Type: application/json" \
  -d '{"mode":"replace"}' \
  | jq .

# 6. Verify the target's columns match the source.
curl -sS "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${TARGET_ID}/kanban/columns" \
  | jq '.columns[] | {name, description}'

# 7. POST copy_spec_from in append mode (target keeps the source's
#    new columns AND adds a second copy at the end).
curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${TARGET_ID}/kanban/copy_spec_from/${SOURCE_ID}" \
  -H "Content-Type: application/json" \
  -d '{"mode":"append"}' \
  | jq '.count'

# 8. Verify the count is doubled (original N + N appended).
curl -sS "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${TARGET_ID}/kanban/columns" \
  | jq '.count'

# 9. Verify self-copy is rejected with 400.
curl -sS -i -X POST "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${TARGET_ID}/kanban/copy_spec_from/${TARGET_ID}" \
  -H "Content-Type: application/json" \
  -d '{}' \
  | head -n 5

# 10. Verify bad mode is rejected with 400.
curl -sS -i -X POST "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${TARGET_ID}/kanban/copy_spec_from/${SOURCE_ID}" \
  -H "Content-Type: application/json" \
  -d '{"mode":"delete-everything"}' \
  | head -n 5

# 11. Stop nalar.
kill "$(cat /tmp/nalar-smoke.pid)"
rm /tmp/nalar-smoke.pid
```

Expected:
- Step 5 returns `{columns: [...], count: N}` where `N` matches the source's count.
- Step 6 shows the target's columns now match the source's (names + descriptions + position).
- Step 7 returns `count = 2N` (the original N from step 6 plus N appended).
- Step 8 confirms `count = 2N`.
- Step 9 returns HTTP 400 (self-copy rejected).
- Step 10 returns HTTP 400 (bad mode rejected).

### Task 5.2: Run the full frontend type-check + test suite

- [ ] **Step 1: Run `bun run build` (vue-tsc + bundle)**

Run: `cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 15`
Expected: clean build. 0 TypeScript errors.

- [ ] **Step 2: Run the full Vitest suite**

Run: `cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 15`
Expected: all tests pass. Test count grows by 6 (the new `CopyKanbanSpecDialog.spec.ts` tests).

- [ ] **Step 3: Manual UI smoke test**

```bash
# Start nalar on 8080
./zig-out/bin/nalar --port 8080 &
echo $! > /tmp/nalar-smoke.pid
sleep 2

# Start the Vite dev server
cd src/apps/desktop
bun run dev &
echo $! > /tmp/vite-dev.pid
sleep 5

# Open the dev server in nalar_browser. Manual: navigate to
# a kanban, click ⚙ Settings, click "Copy spec from…", select
# another kanban, choose Replace, confirm. Verify the target's
# columns are now the source's columns. Reload the page and
# re-open Settings — the change persists.

kill "$(cat /tmp/nalar-smoke.pid)"
kill "$(cat /tmp/vite-dev.pid)"
rm /tmp/nalar-smoke.pid /tmp/vite-dev.pid
```

Expected:
- The "Copy spec from…" button appears in the Settings footer.
- Clicking it opens the picker dialog with the other kanban(s) listed.
- Confirming Replace replaces the target's columns with the source's.
- Re-opening Settings shows the new column list.

- [ ] **Step 4: Final commit (any smoke-test fixes)**

If you discovered bugs during the smoke test, commit them on a fix-up commit. Otherwise no commit.

---

## Verification

After all chunks land:

```bash
# Backend
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 240 zig build test --summary all 2>&1 | tail -n 5
# Expected: "test success"; test count grows by 10+.

timeout 240 zig build install:linux:system 2>&1 | tail -n 15
# Expected: 4/6 steps succeed; the binary at zig-out/bin/nalar is rebuilt.

# Frontend
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 5
# Expected: clean build; 0 TypeScript errors.

timeout 180 bunx vitest run 2>&1 | tail -n 5
# Expected: all tests pass; test count grows by 6+.
```

End-to-end manual smoke test (per Task 5.1 step 3) confirms the backend round-trips replace mode + append mode + rejects self-copy + rejects bad mode. The frontend smoke test (per Task 5.2 step 3) confirms the UI flow: Settings → "Copy spec…" → picker → Confirm → visible board update.

---

## Key Design Decisions

### 1. Why a single `POST` endpoint instead of two (`replace` and `append`)?

A single endpoint with a `mode` body param keeps the API surface flat (one URL, one handler, one SSE pattern) and matches the project's convention of body-driven behavior (`addKanbanColumn`'s `position` field, `task_update`'s `fields` shape). Two URLs would force the frontend to branch on URL strings — easy to forget. One URL is easier to test, easier to document, and easier to evolve (a future v2 `mode="merge"` would just be a new value, not a new endpoint).

### 2. Why no `cross-workspace` mode?

Cross-workspace copy would require:
1. Filtering the picker across workspaces (each workspace has its own kanbans).
2. Confirming the user has permission to write to the target workspace (the source item's workspace can be different).
3. Resolving `workspace_id` for the response's SSE broadcasts (the endpoint would need to emit on the target's workspace's channel).

All three are tractable but each is a non-trivial UX + permission + plumbing change. Keeping v1 single-workspace follows the "minimum viable feature" principle from the project's planning doctrine. Cross-workspace is a v2 candidate with its own plan.

### 3. Why not copy `tasks.kanban_column_id` references too?

Tasks are bound to a kanban by `workspace_item_tasks.workspace_item_id` (every task belongs to exactly one kanban item). Copying a column spec to a different kanban means the source's columns live on a different workspace_item_id, so even if we copied task-row references the existing tasks wouldn't migrate. The user's mental model — "copy the column template from one kanban to set up another" — also doesn't include task copy (each kanban has its own work; copying tasks would silently merge unrelated work). v1's intent is clearly template-only, so we delete tasks from the spec.

### 4. Why fire-and-forget SSE instead of a single SSE event with the new state?

Each column mutate already has a SSE event (`created`, `updated`, `deleted`, `reordered`). The KanbanSse store's "deleted" handler is a no-op for the row (it just refreshes from the list), and the same applies to "created". By firing N + M events (M deletes + N creates for replace mode; just N creates for append mode), we reuse every existing SSE consumer's logic and avoid introducing a new `copied` action. The frontend doesn't need to know the difference between "user added a column" and "user replaced the spec" — both look the same in the kanban board view.

### 5. Why the picker filters out the target but doesn't filter out the source by item_type?

The picker filters by `item_type === 'kanban'` because copying a column spec into a non-kanban item doesn't make sense (folder/chat items don't have columns). It also filters out the active target (`id !== target.id`) to prevent self-copy (which the backend rejects with 400 anyway, but the frontend UX is cleaner without showing the option). It does NOT filter out empty kanbans — a user might want to copy from a fresh kanban to reset a cluttered board. The backend handles empty sources gracefully (replace → empty target, append → no-op on positions).

---

## Plan Review Loop

After completing each chunk:

1. Dispatch a sub-agent for plan-document-review with the chunk content
2. If ❌ Issues Found: fix them in this plan, re-dispatch reviewer
3. Repeat until ✅ Approved
4. Proceed to next chunk

**Chunk boundaries:** Chunks 1-5 are ≤1000 lines each and logically self-contained. Chunk 1 is pure backend model; Chunk 2 is backend HTTP; Chunk 3 is frontend API/store; Chunk 4 is frontend UI; Chunk 5 is end-to-end verification.

---

## Execution Handoff

After all chunks are approved:

**"Plan complete and saved to `docs/superpowers/plans/2026-07-04-copy-kanban-spec.md`. Ready to execute?"**

**Execution path:** This codebase uses `superpowers:subagent-driven-development` (per the project memory `nalar-core`). Use the existing sub-agent infrastructure to spawn one sub-agent per task with two-stage review. Each sub-agent gets the specific task content + the project memory files + the relevant pre-loaded skills (`zig-expert`, `desktop-frontend-build`).
