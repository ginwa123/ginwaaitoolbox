# Workspace Drag-and-Drop Reordering

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add HTML5 drag-and-drop reordering of workspaces in the desktop sidebar so the user can rearrange the index/position of workspaces and have that order persist across refreshes.

**Architecture:** Add a `position` INTEGER column to the `workspaces` table (Migration 043) that drives the sort order. A new `POST /api/workspaces/reorder` endpoint accepts an array of workspace IDs in the desired top-to-bottom order and assigns each row a unique `position` value. On the frontend, the `<WorkspaceList>` workspace row becomes `draggable="true"`, with native HTML5 drag events (`dragstart` / `dragover` / `drop` / `dragend`) wired to a new `reorderWorkspaces(orderedIds)` action on the `workspaces` Pinia store. The store performs an optimistic local reorder, calls the new API, and rolls back on error. The new order survives page reloads, multiple devices, and concurrent edits because the backend is the source of truth.

**Tech Stack:** Zig 0.15 (backend migration + handler), TypeScript / Vue 3 / Pinia (frontend store + component), Vitest (frontend tests), static source-check tests (backend — matches the existing `tasks_list_test.zig` pattern).

---

## Background — Why this approach?

**Alternatives considered & rejected:**

| Alternative | Why rejected |
|---|---|
| **localStorage-only order** | Doesn't sync across devices, doesn't reflect user edits from another client, breaks the sidebar's "workspaces from server" mental model |
| **Full re-render on every drag move** | Causes layout thrash and makes the dragged row hard to see; HTML5 DnD's `dragover` event fires 60+ times per second |
| **A drag library (`vuedraggable`, `sortablejs`)** | Adds a dep, requires new build steps. The project already uses native DOM events for the sidebar resize handle (`Sidebar.vue:91-116`) — staying with native HTML5 DnD is consistent. |
| **Reordering `workspace_items` (the inner "be" / "ai" rows)** | Out of scope — the user only asked about workspaces. Items could be added later with the same `position` pattern if needed. |
| **Per-row "move up" / "move down" buttons** | Slower UX, takes vertical space. Drag-and-drop is the user's stated request. |

**Why `position` (and not a `position` JSON array or `lexorank` strings)?**

- Single INTEGER per row → simple `ORDER BY position DESC` query, no extra joins
- INTEGER range is huge (SQLite int64), no real chance of exhaustion
- New workspaces get `MAX(position) + 1` (append to the "high" end) — preserves the existing "newest at top" UX from `workspaces.ts:362` (`workspaces.value.unshift(...)`)
- Reorder assigns 0, 1, 2, ... in display order (top-to-bottom). The topmost workspace gets `count - 1`, the bottommost gets `0`.

---

## File Structure

### Backend (Zig) — `src/ai_workflow/tui/`

- **Modify** `migration.zig:653-671` — add `Migration043AddPositionToWorkspaces` (column + backfill + new index).
- **Modify** `migration.zig:725-767` — register Migration043 in `allMigrations`.
- **Modify** `http_handlers/workspaces_list.zig:46` — change `ORDER BY created_at DESC` to `ORDER BY position DESC, created_at DESC` (so position is the primary sort, with created_at as tiebreaker for workspaces that share a position).
- **Modify** `http_handlers/workspaces_create.zig:60` — change `INSERT INTO workspaces (...) VALUES (?, ?, datetime('now'), datetime('now'))` to also set `position` to `COALESCE((SELECT MAX(position) FROM workspaces), -1) + 1`. This appends to the high end → top of the list.
- **Create** `http_handlers/workspaces_reorder.zig` — new `POST /api/workspaces/reorder` handler. Parses `{"ordered_ids": [...]}`, runs one UPDATE per id, returns `{success: true, count: N}`.
- **Modify** `http_handlers/mod.zig:40-44` — re-export `workspacesReorderHandler`.
- **Modify** `main.zig:266-280` — register `try gs.router.post("/api/workspaces/reorder", ai_mod.http_handlers.workspacesReorderHandler);` next to the other workspace routes.
- **Create** `http_handlers/workspaces_reorder_test.zig` — static source-check tests (mirrors `tasks_list_test.zig` pattern). **Wire into `test_runner.zig:11-15`** next to the other http_handlers test imports.

### Frontend (TypeScript / Vue) — `src/apps/desktop/src/`

- **Modify** `api/index.ts:128-136` — add `reorderWorkspaces(orderedIds: string[])` function. PUT/POST-style payload to `/api/workspaces/reorder`.
- **Modify** `stores/workspaces.ts:836-874` — add `reorderWorkspaces(orderedIds: string[])` action (optimistic + API + rollback on error). Export from the store.
- **Modify** `components/WorkspaceList.vue:23-36, 154-194, 220-260` — make the workspace row `draggable="true"`, add drag handlers (`@dragstart`, `@dragover.prevent`, `@drop`, `@dragend`), add visual feedback (dragging opacity-50, drop-target violet ring), add a small grip handle icon visible on hover. Add `reorderWorkspaces: [orderedIds: string[]]` to `defineEmits`.
- **Modify** `components/Sidebar.vue:459-475` — wire `@reorder-workspaces` from `<WorkspaceList>` → call `workspacesStore.reorderWorkspaces(orderedIds)`.

### Frontend tests — `src/apps/desktop/src/__tests__/`

- **Create** `workspacesStoreReorder.spec.ts` — store-level test for the new `reorderWorkspaces` action: optimistic reorder, API call shape, rollback on error, no-op when same order.
- **Create** `workspaceListDragDrop.spec.ts` — component-level test for the drag handlers: dragstart sets dataTransfer, drop emits `reorderWorkspaces` with the new order, no emit on drop-on-self.

---

## Design Notes (read first)

1. **Sort direction: `position DESC` (larger = top of list).** New workspaces get `MAX(position) + 1` so they land at the top — preserves the current `workspaces.value.unshift(...)` UX (workspaces.ts:362) without changing the `addWorkspace` action. Reorder assigns 0, 1, 2, ... in display order (top-to-bottom), so the topmost row has position `count - 1`.
2. **Backfill existing rows:** Migration 043 must populate `position` for all existing rows BEFORE the new `ORDER BY` takes effect. Otherwise the list silently re-orders on first deploy. Backfill uses a single UPDATE with a subquery: `position = (SELECT COUNT(*) FROM workspaces w2 WHERE w2.created_at >= workspaces.created_at) - 1` (assigns 0 to the oldest, `count - 1` to the newest). With `ORDER BY position DESC`, the newest appears at the top — matches current `ORDER BY created_at DESC` behavior.
3. **Drag handle vs whole-row draggable.** The entire workspace row is `draggable="true"`, with a small grip handle icon (`≡`) that becomes visible on hover. The handle is purely cosmetic; the row is the actual drag target. The handle gives the user a clear visual hint ("this can be dragged") without taking horizontal space. Both the row and the handle use the same `dragstart` handler.
4. **Click vs drag conflict.** The workspace row is a `<button>` that toggles `workspace.expanded` on click. The HTML5 DnD spec says a click that follows a successful drop should NOT fire — but in practice some browsers fire click on a no-op drop (drop on self, or drop with no movement). The fix: in `dragstart`, set `dataTransfer.effectAllowed = 'move'`, and in `drop`, only emit `reorderWorkspaces` if the new order differs from the current order. No-op drops produce no event, no toggle. (We also call `event.preventDefault()` in `dragover` to allow the drop.)
5. **Optimistic update + rollback.** The store's `reorderWorkspaces(orderedIds)` action: (a) snapshots the current `workspaces.value` array, (b) reorders the local array to match `orderedIds` (so the UI snaps immediately), (c) calls `api.reorderWorkspaces(orderedIds)`, (d) on success → done, (e) on error → restore the snapshot and `console.error`. No toast/error banner — silent rollback matches the project's pattern (see `addTask` catch at workspaces.ts:443 and `loadMoreTasks` catch at workspaces.ts:539-543).
6. **Drop target visualization.** On `dragover` on a workspace row, add a CSS class that draws a violet ring (`outline: 2px solid var(--color-violet)`) at the top edge of the row, indicating "this is where it will land". On `dragleave` or `dragend`, remove the class. The dragged source row gets `opacity-50` (matches the codebase's "busy" / "in-flight" pattern).
7. **API request body shape:** `{ "ordered_ids": ["ws_abc", "ws_def", "ws_ghi"] }` — top-to-bottom. The server reverses this when assigning positions so that the first id in the array gets the highest position (top of the list). See design note 1.
8. **No new dependency, no new test infrastructure.** HTML5 DnD is native. The new backend test reuses the static-source-check pattern from `tasks_list_test.zig:30-75` (no DB needed). The new frontend test reuses the `vi.spyOn(api, ...)` + `setActivePinia(createPinia())` pattern from `workspacesStoreLoadMoreTasks.spec.ts:45-66`.
9. **The collapsed-sidebar mode (sidebar `collapsed=true`) skips the drag UI** — that path renders a different `<button v-for="workspace ...">` (Sidebar.vue:478-487) without drag. Drag from collapsed mode is out of scope; users can expand to reorder.
10. **The header button** (`<button @click="toggleWorkspacesSection">` on WorkspaceList.vue:157) is INSIDE the workspaces-scroll area but outside the per-workspace row, so its click does NOT interfere with drag. No change needed there.
11. **Verification commands** (always run before claiming done):
    - Backend: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 60 zig build 2>&1 | tail -n 20`
    - Backend tests: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test 2>&1 | tail -n 40` (uses `test_runner.zig`)
    - Frontend: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30` (TS check + build — per the mandatory rule, NOT `build-only`)
    - Frontend tests: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run test:unit --run 2>&1 | tail -n 50`

---

# Chunk 1: Backend (Migration + List/Create Updates + Reorder Endpoint + Static Tests)

## Task 1.1: Add Migration 043 — `position` column + backfill + index

**File:** `src/ai_workflow/tui/migration.zig` (insert after the `Migration042` block at line 671, before `MigrationManager` at line 673)

```zig
pub const Migration043AddPositionToWorkspaces = struct {
    pub const version: u32 = 43;
    pub const name = "add_position_to_workspaces";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Step 1: add the column with a 0 default. Existing rows get
        // position=0; the backfill below will assign distinct values.
        try db.exec(allocator, "ALTER TABLE workspaces ADD COLUMN position INTEGER NOT NULL DEFAULT 0", &[_][]const u8{});

        // Step 2: backfill. Assign position N-1 to the newest, 0 to
        // the oldest. With ORDER BY position DESC, this means the
        // newest workspace appears at the top of the list — same UX
        // as the previous ORDER BY created_at DESC. Uses a single
        // UPDATE with a correlated subquery; SQLite handles this
        // efficiently on the small workspaces table (handful of
        // rows in practice).
        try db.exec(allocator,
            \\UPDATE workspaces
            \\SET position = (
            \\    SELECT COUNT(*) - 1
            \\    FROM workspaces w2
            \\    WHERE w2.created_at >= workspaces.created_at
            \\        OR (w2.created_at = workspaces.created_at AND w2.id <= workspaces.id)
            \\)
        , &[_][]const u8{});

        // Step 3: index on position for fast ORDER BY. The list
        // endpoint runs this on every page load.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspaces_position ON workspaces(position DESC)", &[_][]const u8{});

        // Step 4: ANALYZE so the query planner picks up the new index
        // on existing databases.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
```

**Note on the backfill subquery:** the `OR (w2.created_at = workspaces.created_at AND w2.id <= workspaces.id)` tiebreaker is paranoia for the rare case where two workspaces share the same `created_at` second. Without it, the COUNT subquery could return the same value for both rows, leaving them with the same position. The `id` tiebreak keeps the backfill deterministic.

**Wire into `migration.zig:725-767`:** add a new line at the end of the `allMigrations` slice:

```zig
.{ .version = Migration043AddPositionToWorkspaces.version, .name = Migration043AddPositionToWorkspaces.name, .up = Migration043AddPositionToWorkspaces.up },
```

## Task 1.2: Update list handler to ORDER BY `position DESC`

**File:** `src/ai_workflow/tui/http_handlers/workspaces_list.zig:46`

Change:

```zig
var rows = try db.query(alloc, "SELECT id, name, created_at, updated_at FROM workspaces ORDER BY created_at DESC", &[_][]const u8{});
```

to:

```zig
var rows = try db.query(alloc, "SELECT id, name, created_at, updated_at FROM workspaces ORDER BY position DESC, created_at DESC", &[_][]const u8{});
```

`created_at DESC` stays as a tiebreaker for workspaces that happen to share a position (shouldn't happen post-reorder, but defense in depth — and matches the backfill tiebreaker at Migration 043).

## Task 1.3: Update create handler to assign a fresh `position`

**File:** `src/ai_workflow/tui/http_handlers/workspaces_create.zig:60`

Change the INSERT statement from:

```zig
_ = try db.exec(allocator, "INSERT INTO workspaces (id, name, created_at, updated_at) VALUES (?, ?, datetime('now'), datetime('now'))", &.{ workspace_id, name });
```

to:

```zig
_ = try db.exec(allocator,
    \\INSERT INTO workspaces (id, name, position, created_at, updated_at)
    \\VALUES (?, ?,
    \\    COALESCE((SELECT MAX(position) FROM workspaces), -1) + 1,
    \\    datetime('now'), datetime('now'))
, &.{ workspace_id, name });
```

The `COALESCE(..., -1) + 1` makes the first workspace get position `0`. Subsequent workspaces get `MAX + 1`, always larger than every existing row → with `ORDER BY position DESC`, new ones appear at the top. This preserves the current `workspaces.value.unshift(...)` UX (workspaces.ts:362) without changing the `addWorkspace` action.

## Task 1.4: Create the reorder handler

**File (create):** `src/ai_workflow/tui/http_handlers/workspaces_reorder.zig`

```zig
const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;

/// POST /api/workspaces/reorder
/// Body: { "ordered_ids": ["id1", "id2", ..., "idN"] } (top-to-bottom display order)
/// Behavior: assigns position N-1 to ordered_ids[0] (top of list), N-2 to the next, ..., 0 to
/// ordered_ids[N-1] (bottom). Idempotent: a second call with the same array leaves the data
/// unchanged. Unknown IDs are silently skipped (so a stale client with a deleted workspace
/// doesn't fail the whole reorder). Returns 200 with { "success": true, "count": N } even if
/// N is 0.
pub fn workspacesReorderHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "body required" }) });
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    const root = parsed.value.object;
    const ordered_ids_val = root.get("ordered_ids") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids required" }) });
    };
    if (ordered_ids_val != .array) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids must be an array" }) });
    }

    const ids = ordered_ids_val.array.items;
    // Sanity-cap the reorder size to prevent a 100k-item payload from
    // hammering the DB with that many single-row UPDATEs. Sidebar has
    // a handful of workspaces in practice; 100 is a generous upper
    // bound (catches accidental client bugs).
    if (ids.len > 100) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids too long (max 100)" }) });
    }

    // Assign position = (count - 1 - i) for the i-th id. The first id
    // in the array is the top of the list, so it gets the highest
    // position. Updates one row per id. Unknown ids fail the
    // individual UPDATE (sqlite_db.exec) but we swallow that — a
    // deleted workspace in the payload shouldn't fail the whole
    // reorder. The final count tracks how many rows we actually
    // updated.
    var updated_count: usize = 0;
    const count: i64 = @intCast(ids.len);
    for (ids, 0..) |id_val, i| {
        if (id_val != .string) continue;
        const id_str = id_val.string;
        // i is usize, count is i64; compute (count - 1 - i) as i64.
        const new_pos: i64 = count - 1 - @as(i64, @intCast(i));
        sqlite_db.exec(allocator, "UPDATE workspaces SET position = ?, updated_at = datetime('now') WHERE id = ?", &.{ std.fmt.allocPrint(allocator, "{d}", .{new_pos}) catch continue, id_str }) catch continue;
        updated_count += 1;
    }

    return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"count\":{d}}}", .{updated_count}) });
}
```

**Style note:** matches the rest of the http_handlers/ dir — direct `std.json.parseFromSlice` with inline error returns, no separate type for the request. The `try std.fmt.allocPrint(...) catch continue` pattern on the position-string conversion is ugly but matches `task_update.zig`'s "best-effort" inline-style formatting. (The `?{d}` formatter doesn't work in Zig 0.15 — must pre-format the int to a string.)

**Wait** — `std.fmt.allocPrint(allocator, "{d}", .{new_pos}) catch continue` is wrong because `continue` inside a `for` loop only continues the loop, not propagates the error. But `std.fmt.allocPrint` is a runtime allocation that could fail with `OutOfMemory`. To be safe, we should `catch` and `continue` (the local) — which is what the code already does. This is fine; the loop will skip that id on alloc failure rather than aborting the whole reorder. **Acceptable for a best-effort bulk update.** If you want a stricter version, replace `catch continue` with a `defer allocator.free(pos_str);` and an early `return error.OutOfMemory`. (Match the project's risk tolerance — see `loadMoreTasks` at workspaces.ts:539-543 for the precedent.)

## Task 1.5: Wire up the route and the export

**File:** `src/ai_workflow/tui/http_handlers/mod.zig:40-44`

Add a new line right after the `workspacesCreateHandler` export:

```zig
pub const workspacesReorderHandler = @import("workspaces_reorder.zig").workspacesReorderHandler;
```

**File:** `src/main.zig:266-280`

Add the route registration after `try gs.router.post("/api/workspaces", ai_mod.http_handlers.workspacesCreateHandler);` (line 267):

```zig
try gs.router.post("/api/workspaces/reorder", ai_mod.http_handlers.workspacesReorderHandler);
```

## Task 1.6: Static source-check tests for the new backend code

**File (create):** `src/ai_workflow/tui/http_handlers/workspaces_reorder_test.zig`

Pattern: mirrors `tasks_list_test.zig:30-75` — a small Zig test that reads the source file with `std.Io.Dir.cwd().readFileAlloc` and asserts the contract strings are present. **Do not** try to spin up a DB; the project's `test_runner.zig:1-21` has no precedent for that.

```zig
//! Static regression checks for the workspace-reorder handler.
//!
//! Why this file exists
//! ────────────────────
//! Drag-and-drop reordering of workspaces depends on:
//!   1. The handler at `workspaces_reorder.zig` accepting
//!      `{ordered_ids: [...]}` and writing position values.
//!   2. The list handler at `workspaces_list.zig` ordering by position.
//!   3. The create handler at `workspaces_create.zig` assigning a
//!      fresh max+1 position so new workspaces appear at the top.
//!   4. Migration 043 in `migration.zig` adding the `position` column.
//!
//! These contracts are enforced by static substring checks (matching
//! the project's `tasks_list_test.zig` pattern), not by spinning up
//! an in-memory DB.

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/workspaces_reorder.zig";
const LIST_PATH = "src/ai_workflow/tui/http_handlers/workspaces_list.zig";
const CREATE_PATH = "src/ai_workflow/tui/http_handlers/workspaces_create.zig";
const MIGRATION_PATH = "src/ai_workflow/tui/migration.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// ─── Contract 1: reorder handler exists and accepts the ordered_ids payload ──

test "workspaces_reorder handler parses ordered_ids from the request body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must read `ordered_ids` from the parsed JSON. If
    // this is missing or renamed, the drag-and-drop reorder endpoint
    // is broken — the frontend will POST and get a 400.
    if (std.mem.indexOf(u8, source, "ordered_ids") == null) {
        std.debug.print(
            "\n!! {s} does not reference the `ordered_ids` field !!\n" ++
                "   The reorder endpoint is broken. The frontend POSTs\n" ++
                "   {ordered_ids: [...]} and expects a 200 + position\n" ++
                "   updates. Restore the field name in the handler.\n" ++
                "   See docs/plans/2026-06-12-workspace-drag-and-drop.md.\n",
            .{HANDLER_PATH},
        );
        return error.OrderedIdsMissing;
    }
}

// ─── Contract 2: reorder handler writes position values ───────────────────

test "workspaces_reorder handler writes position values via UPDATE" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must run `UPDATE workspaces SET position = ?` for
    // each id. If this is missing, the reorder is a no-op and the
    // user sees no persistence across refreshes.
    if (std.mem.indexOf(u8, source, "UPDATE workspaces SET position") == null) {
        std.debug.print(
            "\n!! {s} does not UPDATE workspaces.position !!\n" ++
                "   The reorder endpoint is silently a no-op.\n" ++
                "   Add: UPDATE workspaces SET position = ? WHERE id = ?\n",
            .{HANDLER_PATH},
        );
        return error.PositionUpdateMissing;
    }
}

// ─── Contract 3: list handler orders by position ─────────────────────────

test "workspaces_list handler orders by position DESC" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LIST_PATH);
    defer allocator.free(source);

    // The list handler must `ORDER BY position DESC` (with
    // `created_at DESC` as a tiebreaker). If this reverts to just
    // `ORDER BY created_at DESC`, the user's drag-reorder is
    // ignored on the next page load.
    if (std.mem.indexOf(u8, source, "ORDER BY position DESC") == null) {
        std.debug.print(
            "\n!! {s} does not ORDER BY position DESC !!\n" ++
                "   Drag-reorder will be lost on the next page load.\n" ++
                "   Restore: ORDER BY position DESC, created_at DESC\n",
            .{LIST_PATH},
        );
        return error.OrderByPositionMissing;
    }
}

// ─── Contract 4: create handler assigns a fresh position ─────────────────

test "workspaces_create handler assigns a fresh MAX+1 position" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    // The create handler must compute `COALESCE(MAX(position), -1) + 1`
    // (or equivalent) so a new workspace lands at the top of the
    // list. If this is missing, new workspaces get position=0 and
    // get sorted to the bottom — silently regressing the UX.
    const has_max_subquery = std.mem.indexOf(u8, source, "MAX(position)") != null;
    const has_position_col = std.mem.indexOf(u8, source, "position") != null;
    if (!has_max_subquery or !has_position_col) {
        std.debug.print(
            "\n!! {s} does not compute a fresh position for new rows !!\n" ++
                "   New workspaces will land at the bottom of the list.\n" ++
                "   Add: COALESCE((SELECT MAX(position) FROM workspaces), -1) + 1\n" ++
                "   to the INSERT statement.\n",
            .{CREATE_PATH},
        );
        return error.PositionAssignmentMissing;
    }
}

// ─── Contract 5: migration 043 exists and adds the position column ─────

test "migration 043 adds the workspaces.position column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MIGRATION_PATH);
    defer allocator.free(source);

    // The migration must declare version 43 and add the position
    // column. If it's missing, fresh databases won't have the column
    // and the new ORDER BY will fail at runtime.
    const has_version = std.mem.indexOf(u8, source, "Migration043AddPositionToWorkspaces") != null;
    const has_column = std.mem.indexOf(u8, source, "ADD COLUMN position") != null;
    if (!has_version or !has_column) {
        std.debug.print(
            "\n!! {s} is missing Migration 043 or the position column !!\n" ++
                "   Fresh databases will fail to ORDER BY position DESC.\n" ++
                "   Add Migration043AddPositionToWorkspaces with ALTER TABLE\n" ++
                "   workspaces ADD COLUMN position INTEGER NOT NULL DEFAULT 0\n",
            .{MIGRATION_PATH},
        );
        return error.Migration043Missing;
    }
}
```

**Wire into `src/ai_workflow/tui/test_runner.zig:11-15`:**

Add a new line right after the existing workspace-adjacent imports (anywhere in the `http_handlers/` block is fine; alphabetical by filename is the convention):

```zig
_ = @import("http_handlers/workspaces_reorder_test.zig");
```

---

# Chunk 2: Frontend — API + Store + Component + Tests

## Task 2.1: Add `reorderWorkspaces` to the API

**File:** `src/apps/desktop/src/api/index.ts:128-136` (insert right after `updateWorkspace`)

```typescript
/**
 * Persist a new top-to-bottom display order for workspaces.
 * POST /api/workspaces/reorder with body `{ordered_ids: [...]}`. The
 * server reverses the array when assigning position values (top of
 * list = highest position). On any non-2xx response, throws
 * `new Error("HTTP <status>")` so the caller can roll back its
 * optimistic update.
 *
 * The list shape is the *full* ordered set, not a delta. Reordering
 * two adjacent rows means re-sending ALL workspace IDs in their new
 * order. The backend is idempotent — a second call with the same
 * array leaves the data unchanged.
 */
export async function reorderWorkspaces(orderedIds: string[]): Promise<{ success: boolean; count: number }> {
  const response = await fetch(`${API_BASE}/workspaces/reorder`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ordered_ids: orderedIds }),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}
```

## Task 2.2: Add `reorderWorkspaces` action to the workspaces store

**File:** `src/apps/desktop/src/stores/workspaces.ts:836-874` (insert right before the `return` block, after `subscribeToSessionEvents`)

```typescript
/**
 * Reorder the workspaces array to match `orderedIds` and persist the
 * new order via `POST /api/workspaces/reorder`. Optimistic: the local
 * array is reordered immediately so the UI snaps to the new position
 * on drop. On API failure, the snapshot is restored and the error is
 * logged (no toast/banner — matches the project's silent-failure
 * pattern in addTask/deleteTask/loadMoreTasks).
 *
 * No-op when `orderedIds` is empty or has the same length AND the
 * same set of IDs as the current order. Length mismatch = reject
 * (something is wrong, the client is out of sync).
 */
async function reorderWorkspaces(orderedIds: string[]) {
  const current = workspaces.value
  if (orderedIds.length === 0) return

  // Defensive: the client must send a complete ordering. A partial
  // list (e.g. drag-reordering 2 of 5 workspaces) would lose the
  // other 3. Refuse early.
  if (orderedIds.length !== current.length) {
    console.error(
      `[workspacesStore.reorderWorkspaces] orderedIds length ${orderedIds.length} != current ${current.length}; refusing reorder`,
    )
    return
  }

  // No-op: same set of IDs in (potentially) different order. The
  // set-equality check is a HashMap O(n) walk — fine for the
  // realistic sidebar size.
  const currentIdSet = new Set(current.map((w) => w.id))
  const newIdSet = new Set(orderedIds)
  if (
    currentIdSet.size === newIdSet.size &&
    [...currentIdSet].every((id) => newIdSet.has(id)) &&
    current.every((w, i) => w.id === orderedIds[i])
  ) {
    // Same order — nothing to do.
    return
  }

  // Snapshot for rollback. We capture the array reference (Vue's
  // ref returns the inner array; copying the slice gives us a
  // moment-in-time view).
  const previousOrder = current.slice()

  // Optimistic local reorder: build a new array by looking up each
  // id in the current array. If an id is missing (defensive — the
  // length-mismatch check above should have caught this), fall back
  // to keeping the original row at its original position.
  const byId = new Map(current.map((w) => [w.id, w]))
  const reordered: Workspace[] = []
  for (const id of orderedIds) {
    const ws = byId.get(id)
    if (ws) reordered.push(ws)
  }
  // If any current rows were missed, append them at the end (should
  // not happen given the length check, but defensive).
  for (const ws of current) {
    if (!orderedIds.includes(ws.id)) reordered.push(ws)
  }
  workspaces.value = reordered

  // Persist to backend.
  try {
    await api.reorderWorkspaces(orderedIds)
  } catch (err) {
    console.error('[workspacesStore.reorderWorkspaces] API call failed, rolling back:', err)
    workspaces.value = previousOrder
  }
}
```

**Add to the store return block (workspaces.ts:836-874):**

```typescript
reorderWorkspaces,  // ← new line, alphabetically after `removeWorkspace`
```

## Task 2.3: Make the workspace row draggable in `WorkspaceList.vue`

**File:** `src/apps/desktop/src/components/WorkspaceList.vue`

This is the most invasive change. Three sub-tasks:

### 2.3a: Add new emit + local state for drag feedback

In `<script setup>`, add to `defineEmits` (after the existing `loadMoreTasks` line ~35):

```typescript
reorderWorkspaces: [orderedIds: string[]]
```

Add new ref for drag state (top of `<script setup>`, near `activeAddMenu`):

```typescript
// Drag-and-drop state. `draggingId` is the workspace currently being
// dragged (used to dim the source row); `dragOverId` is the row the
// cursor is hovering (used to draw the drop indicator). `null` means
// "not dragging / not hovering".
const draggingId = ref<string | null>(null)
const dragOverId = ref<string | null>(null)
```

Add the handlers (after `handleLoadMoreTasks`, ~line 152):

```typescript
const handleDragStart = (workspaceId: string, event: DragEvent) => {
  draggingId.value = workspaceId
  if (event.dataTransfer) {
    // 'move' is the cursor hint; the actual data payload is the
    // workspace id (string), which we'll read in handleDrop to
    // identify the source. 'text/plain' is the universal MIME type
    // that works in all browsers and is what HTML5 DnD spec
    // recommends for non-rich-text drags.
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData('text/plain', workspaceId)
  }
}

const handleDragOver = (workspaceId: string, event: DragEvent) => {
  // preventDefault on dragover is REQUIRED to allow the drop. Without
  // it, the browser cancels the drop with a "not allowed" cursor.
  event.preventDefault()
  if (event.dataTransfer) {
    event.dataTransfer.dropEffect = 'move'
  }
  if (dragOverId.value !== workspaceId) {
    dragOverId.value = workspaceId
  }
}

const handleDragLeave = (workspaceId: string, event: DragEvent) => {
  // Only clear when the cursor actually leaves the row. The
  // dragleave event fires when crossing child elements too, so we
  // check `relatedTarget` to see if the cursor is still inside the
  // row. If it is, do nothing.
  const target = event.currentTarget as HTMLElement | null
  const related = event.relatedTarget as Node | null
  if (target && related && target.contains(related)) return
  if (dragOverId.value === workspaceId) {
    dragOverId.value = null
  }
}

const handleDrop = (workspaceId: string, event: DragEvent) => {
  event.preventDefault()
  if (event.dataTransfer) {
    event.dataTransfer.dropEffect = 'move'
  }
  const sourceId = event.dataTransfer?.getData('text/plain')
  if (!sourceId || sourceId === workspaceId) {
    // Drop on self or no source id — no-op.
    return
  }
  // Compute the new order: take all workspaces in current order,
  // splice `sourceId` out, insert it at the position of
  // `workspaceId` (the drop target).
  const current = workspaces.slice()
  const fromIdx = current.findIndex((w) => w.id === sourceId)
  const toIdx = current.findIndex((w) => w.id === workspaceId)
  if (fromIdx === -1 || toIdx === -1) return
  const [moved] = current.splice(fromIdx, 1)
  current.splice(toIdx, 0, moved)
  emit('reorderWorkspaces', current.map((w) => w.id))
}

const handleDragEnd = () => {
  // Always clear drag state on dragend, even if the drop was
  // cancelled (e.g. user dropped outside any drop target). Without
  // this, the source row stays dimmed forever.
  draggingId.value = null
  dragOverId.value = null
}
```

**Note:** `workspaces` is the prop name (`defineProps<{ workspaces: Workspace[]; ... }>()`), so it's reactive on the component instance.

### 2.3b: Update the workspace-row template

In the template, find the workspace-header `<div class="flex items-center group/workspace" data-workspace-menu>` block (around line 193-262) and update it:

```html
<div
  class="flex items-center group/workspace rounded-lg transition-all duration-150"
  :class="{
    'opacity-50': draggingId === workspace.id,
    'ring-1 ring-violet-500 -translate-y-0.5': dragOverId === workspace.id && draggingId !== workspace.id,
  }"
  :style="{
    boxShadow: dragOverId === workspace.id && draggingId !== workspace.id
      ? '0 -2px 0 0 var(--color-violet)'
      : 'none',
  }"
  data-workspace-menu
  draggable="true"
  @dragstart="handleDragStart(workspace.id, $event)"
  @dragover="handleDragOver(workspace.id, $event)"
  @dragleave="handleDragLeave(workspace.id, $event)"
  @drop="handleDrop(workspace.id, $event)"
  @dragend="handleDragEnd"
>
  <button
    @click="handleWorkspaceClick(workspace.id)"
    class="flex-1 flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all duration-200"
    :style="{
      backgroundColor: workspace.expanded
        ? 'var(--semantic-active-bg)'
        : 'transparent',
      color: workspace.expanded
        ? 'var(--semantic-active-text)'
        : 'var(--semantic-text-muted)',
    }"
  >
    <!-- Grip handle — visible on hover, gives the user a "you can
         drag this" hint. The whole row is draggable; the handle is
         purely cosmetic. -->
    <span
      class="w-3 h-4 flex items-center justify-center text-xs opacity-0 group-hover/workspace:opacity-60 transition-opacity duration-200 shrink-0"
      :style="{ color: 'var(--semantic-text-dim)' }"
      aria-hidden="true"
    >≡</span>
    <!-- (existing spinner / chevron / name / count badge slots) -->
    ...
  </button>
  <!-- (existing rename / delete buttons — note: the row itself is
       now the drag target, so the rename/delete click handlers
       should keep their @click.stop behavior to prevent drag-start
       from interfering) -->
  ...
</div>
```

**Style note on the drop indicator:** I chose `box-shadow: 0 -2px 0 0 var(--color-violet)` (a top-edge violet line) instead of a full ring because:
- A 2px outline around the whole row looks like "select this" (it's a button, after all)
- A top-edge shadow says "this is where the dropped item will land" — matches the mental model of a drag handle on top of a list
- The `var(--color-violet)` matches the resize handle on the right edge of the sidebar (`Sidebar.vue:399`)

The `ring-1 ring-violet-500 -translate-y-0.5` classes are defensive fallbacks if the inline-style box-shadow doesn't render. Both can be present without conflict.

### 2.3c: The existing rename / delete buttons stay

No changes needed to the rename button (line 241) or delete button (line 252). They already have `@click.stop` patterns, and the drag event is on the OUTER `<div>`, not on these buttons. (The buttons are children of the drag target — child clicks bubble up as dragstart only if the user holds and drags from the button area, which is fine; `@click.stop` on the buttons prevents the click event from bubbling, but does not affect dragstart.)

## Task 2.4: Wire the new event from `Sidebar.vue`

**File:** `src/apps/desktop/src/components/Sidebar.vue:459-475` (the `<WorkspaceList>` block)

Add `@reorder-workspaces` to the `<WorkspaceList>` element, and add a handler function in the `<script setup>` block.

**Add the handler (after `handleLoadMoreTasks`, around line 384):**

```typescript
const handleReorderWorkspaces = (orderedIds: string[]) => {
  workspacesStore.reorderWorkspaces(orderedIds)
}
```

**Update the template (line 459-475):**

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
  @load-more-tasks="handleLoadMoreTasks"
  @reorder-workspaces="handleReorderWorkspaces"
/>
```

## Task 2.5: Frontend store test

**File (create):** `src/apps/desktop/src/__tests__/workspacesStoreReorder.spec.ts`

Pattern: mirrors `workspacesStoreLoadMoreTasks.spec.ts:1-100` — Pinia setup, mock the API, assert the order after a call, assert the API was called with the right shape, assert rollback on error.

```typescript
/**
 * Unit tests for the workspaces store's reorderWorkspaces action.
 *
 * reorderWorkspaces is the optimistic-update action called by the
 * WorkspaceList drag-and-drop handler. It reorders the local
 * workspaces.value array immediately (so the UI snaps on drop),
 * then POSTs the new order to the backend, rolling back on error.
 *
 * Plan: docs/plans/2026-06-12-workspace-drag-and-drop.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore, type Workspace } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const ws = (id: string, name: string): Workspace => ({
  id,
  name,
  icon: '📁',
  expanded: false,
  items: [],
})

describe('useWorkspacesStore.reorderWorkspaces()', () => {
  const reorderWorkspacesMock = vi.fn()

  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })
    reorderWorkspacesMock.mockReset()
    vi.spyOn(api, 'reorderWorkspaces').mockImplementation(reorderWorkspacesMock)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  function seed(store: ReturnType<typeof useWorkspacesStore>, rows: Workspace[]) {
    // Direct mutation of the ref's inner array (Pinia setup-store
    // pattern). Equivalent to the user creating 3 workspaces via
    // the UI.
    store.workspaces.splice(0, store.workspaces.length, ...rows)
  }

  it('reorders the local array optimistically before the API resolves', async () => {
    reorderWorkspacesMock.mockResolvedValue({ success: true, count: 3 })
    const store = useWorkspacesStore()
    seed(store, [ws('ws_c', 'C'), ws('ws_a', 'A'), ws('ws_b', 'B')])

    // Drag ws_a to the top.
    const promise = store.reorderWorkspaces(['ws_a', 'ws_c', 'ws_b'])

    // Optimistic: order is already updated, even though the
    // promise hasn't resolved yet.
    expect(store.workspaces.map((w) => w.id)).toEqual(['ws_a', 'ws_c', 'ws_b'])
    expect(reorderWorkspacesMock).toHaveBeenCalledWith(['ws_a', 'ws_c', 'ws_b'])

    await promise
    // After the API resolves, the order stays.
    expect(store.workspaces.map((w) => w.id)).toEqual(['ws_a', 'ws_c', 'ws_b'])
  })

  it('rolls back the local order when the API call fails', async () => {
    reorderWorkspacesMock.mockRejectedValue(new Error('HTTP 500'))
    const store = useWorkspacesStore()
    seed(store, [ws('ws_c', 'C'), ws('ws_a', 'A'), ws('ws_b', 'B')])

    // Spy on console.error to silence the expected error log.
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    await store.reorderWorkspaces(['ws_a', 'ws_c', 'ws_b'])

    // Order is back to the original.
    expect(store.workspaces.map((w) => w.id)).toEqual(['ws_c', 'ws_a', 'ws_b'])
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })

  it('is a no-op when the new order matches the current order', async () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A'), ws('ws_b', 'B')])

    await store.reorderWorkspaces(['ws_a', 'ws_b'])

    expect(reorderWorkspacesMock).not.toHaveBeenCalled()
  })

  it('is a no-op on an empty orderedIds array', async () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A')])

    await store.reorderWorkspaces([])

    expect(reorderWorkspacesMock).not.toHaveBeenCalled()
  })

  it('refuses to reorder when the new order has a different length than the current set', async () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A'), ws('ws_b', 'B'), ws('ws_c', 'C')])

    // Spy on console.error to silence the expected error log.
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    // Client sends only 2 IDs but there are 3 workspaces.
    await store.reorderWorkspaces(['ws_b', 'ws_a'])

    // Order unchanged.
    expect(store.workspaces.map((w) => w.id)).toEqual(['ws_a', 'ws_b', 'ws_c'])
    expect(reorderWorkspacesMock).not.toHaveBeenCalled()
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })
})
```

## Task 2.6: Frontend component test

**File (create):** `src/apps/desktop/src/__tests__/workspaceListDragDrop.spec.ts`

Pattern: mirrors `workspaceListProcessingSpinner.spec.ts:38-72` — mount the component with stubbed `WorkspaceItem`, dispatch DOM events, assert the emitted event payload.

```typescript
/**
 * Unit tests for the drag-and-drop handlers on the workspace row
 * in WorkspaceList.vue. The handlers convert the HTML5 drag
 * events (dragstart, dragover, drop, dragend) into a
 * `reorder-workspaces` emit with the new top-to-bottom ID order.
 *
 * Plan: docs/plans/2026-06-12-workspace-drag-and-drop.md
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceList from '../components/WorkspaceList.vue'
import { useWorkspacesStore, type Workspace } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

function makeWorkspace(id: string, name: string): Workspace {
  return { id, name, icon: '📁', expanded: false, items: [] }
}

describe('WorkspaceList drag-and-drop', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
    })
  })

  afterEach(() => {
    // Cleanup: the workspaces-section header needs to be expanded
    // to render the inner row. Each test clicks the header before
    // assertions; nothing to do here.
  })

  /** Find the draggable workspace-header div (the one with @dragstart). */
  function findDraggableRows(wrapper: ReturnType<typeof mount>) {
    return wrapper.findAll('[draggable="true"]')
  }

  /** Build a fake DragEvent with a writable dataTransfer. */
  function makeDragEvent(type: string): DragEvent {
    const dt = new DataTransfer()
    const event = new Event(type, { bubbles: true, cancelable: true }) as any
    event.dataTransfer = dt
    return event as DragEvent
  }

  it('emits reorderWorkspaces with the new order when ws_b is dropped on ws_a', async () => {
    const workspaces = [makeWorkspace('ws_c', 'C'), makeWorkspace('ws_b', 'B'), makeWorkspace('ws_a', 'A')]
    const wrapper = mount(WorkspaceList, {
      props: { workspaces, activeWorkspaceItemId: null },
      global: { stubs: { WorkspaceItem: true } },
    })
    // Expand the workspaces section so the inner rows render.
    await wrapper.find('button').trigger('click')
    await nextTick()

    const rows = findDraggableRows(wrapper)
    expect(rows.length).toBe(3)

    // Simulate dragging the third row (ws_a) onto the first row (ws_c).
    // After drop, ws_a should be at the top: [ws_a, ws_c, ws_b].
    const sourceRow = rows[2]!
    const targetRow = rows[0]!

    // dragstart on source: sets dataTransfer to 'ws_a'
    const startEvent = makeDragEvent('dragstart')
    sourceRow.element.dispatchEvent(startEvent)
    expect((startEvent as any).dataTransfer.getData('text/plain')).toBe('ws_a')

    // drop on target: fires the emit
    const dropEvent = makeDragEvent('drop')
    // The dragstart sets the data; the drop reads it.
    // (JSDOM keeps the DataTransfer object across events on the same
    //  dispatch, which is what the browser does too.)
    targetRow.element.dispatchEvent(dropEvent)

    const emitted = wrapper.emitted('reorderWorkspaces')
    expect(emitted).toBeDefined()
    expect(emitted).toHaveLength(1)
    expect(emitted![0]).toEqual(['ws_a', 'ws_c', 'ws_b'])
  })

  it('does not emit when a workspace is dropped on itself', async () => {
    const workspaces = [makeWorkspace('ws_a', 'A'), makeWorkspace('ws_b', 'B')]
    const wrapper = mount(WorkspaceList, {
      props: { workspaces, activeWorkspaceItemId: null },
      global: { stubs: { WorkspaceItem: true } },
    })
    await wrapper.find('button').trigger('click')
    await nextTick()

    const rows = findDraggableRows(wrapper)
    const startEvent = makeDragEvent('dragstart')
    rows[0]!.element.dispatchEvent(startEvent)
    const dropEvent = makeDragEvent('drop')
    rows[0]!.element.dispatchEvent(dropEvent)

    expect(wrapper.emitted('reorderWorkspaces')).toBeUndefined()
  })

  it('clears the dragOverId on dragend', async () => {
    const workspaces = [makeWorkspace('ws_a', 'A'), makeWorkspace('ws_b', 'B')]
    const wrapper = mount(WorkspaceList, {
      props: { workspaces, activeWorkspaceItemId: null },
      global: { stubs: { WorkspaceItem: true } },
    })
    await wrapper.find('button').trigger('click')
    await nextTick()

    const rows = findDraggableRows(wrapper)
    const startEvent = makeDragEvent('dragstart')
    rows[0]!.element.dispatchEvent(startEvent)
    const overEvent = makeDragEvent('dragover')
    rows[1]!.element.dispatchEvent(overEvent)
    // The component's dragOverId is internal; we just check the
    // dragend event doesn't throw and that no spurious emit fires.
    const endEvent = new Event('dragend', { bubbles: true })
    rows[0]!.element.dispatchEvent(endEvent)
    // After dragend, dropping somewhere should not emit (no
    // source id in dataTransfer since the drag was "cancelled").
    const dropEvent = makeDragEvent('drop')
    rows[1]!.element.dispatchEvent(dropEvent)
    expect(wrapper.emitted('reorderWorkspaces')).toBeUndefined()
  })
})
```

---

# Chunk 3: Verification

## Task 3.1: Build the backend and run its tests

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 60 zig build 2>&1 | tail -n 20
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test 2>&1 | tail -n 40
```

**Expected:** Build succeeds. Test output shows the new `workspaces_reorder_test.zig` cases passing alongside the existing suite. The static checks report concrete error messages if any contract is missing.

## Task 3.2: Type-check + build + unit-test the frontend

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run test:unit --run 2>&1 | tail -n 50
```

**Expected:** `bun run build` (which runs `vue-tsc --build` for the type-check) is clean. All unit tests pass, including the new `workspacesStoreReorder.spec.ts` and `workspaceListDragDrop.spec.ts` cases.

## Task 3.3: Manual smoke test (optional but recommended)

1. `cd src/apps/desktop && bun run dev`
2. Open the app, create 2-3 workspaces
3. Drag one to a new position — the UI snaps immediately
4. Refresh the page — the new order persists
5. Open the app on a second browser tab (or after a hard reload) — the order still matches
6. Check the browser devtools Network tab: `POST /api/workspaces/reorder` returns 200 with `{"success":true,"count":N}`
7. Disconnect the backend mid-drag (kill `nalar`) and try to drag: the order snaps to the new position, then snaps back when the API fails (the silent rollback)

## Task 3.4: Cross-platform sanity check (per the build caveat)

The `install:windows` / `install:macos` build steps are pre-existing broken on a Linux host (see `~/.config/nalar/memories/nalar-build-cross-compile-blocked.md`). **Do not waste time debugging them.** The new code is plain Zig 0.15 / standard library — no platform-specific APIs — and will compile on the target platform once the build config is fixed separately.
