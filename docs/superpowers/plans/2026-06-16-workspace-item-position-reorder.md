# Workspace Item Position Reorder Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add drag-and-drop reordering for workspace items (projects within a workspace), mirroring the existing workspaces reorder flow end-to-end. The first item ends up at the top of the workspace's expanded list.

**Architecture:** This plan copies the `workspaces_reorder` pattern end-to-end, scoped to a single workspace's items:
- A new `position` column on `workspace_items` (added via a new migration mirroring Migration043).
- A new HTTP handler `POST /api/workspaces/:workspace_id/items/reorder` (mirroring `workspaces_reorder.zig`).
- The list handler and create handler are updated to honor `position` (DESC for list, MAX+1 for create).
- The frontend adds a typed `reorderWorkspaceItems(workspaceId, orderedIds)` API function, a `reorderWorkspaceItems` store method, an `onReorderWorkspaceItems` event on `WorkspaceList.vue`, and wires it up in `Sidebar.vue` to call the store.

**Tech Stack:** Zig 0.16 (backend), Vue 3 + TypeScript + Pinia (frontend), SQLite (storage).

---

## File Structure

Files to create:
- `src/ai_workflow/tui/http_handlers/workspace_items_reorder.zig` — HTTP handler
- `src/ai_workflow/tui/http_handlers/workspace_items_reorder_test.zig` — static-check tests
- (No new frontend file: new code lands in existing files.)

Files to modify:
- `src/ai_workflow/tui/migration.zig` — add `Migration045AddPositionToWorkspaceItems` and register it
- `src/ai_workflow/tui/http_handlers/http_response.zig` — add `WorkspaceItemReorderResponse` struct + `makeWorkspaceItemReorderResponse` helper
- `src/ai_workflow/tui/http_handlers/http_handlers.zig` (or the equivalent route registration site) — register the new handler
- `src/ai_workflow/tui/http_handlers/workspace_items_get.zig` — `ORDER BY position DESC` in the SELECT
- `src/ai_workflow/tui/http_handlers/workspace_items_create.zig` — assign `position = MAX+1` on insert
- `src/ai_workflow/tui/http_handlers/workspace_items_update.zig` — no SQL change needed (item_type updates don't touch position)
- `src/ai_workflow/tui/test_runner.zig` — register the new test file
- `src/apps/desktop/src/api/index.ts` — add `reorderWorkspaceItems(workspaceId, orderedIds)`
- `src/apps/desktop/src/stores/workspaces.ts` — add `reorderWorkspaceItems(workspaceId, orderedIds)` action
- `src/apps/desktop/src/components/WorkspaceList.vue` — emit `onReorderWorkspaceItems` and call the store
- `src/apps/desktop/src/components/Sidebar.vue` — handle the new event from WorkspaceList
- `src/apps/desktop/src/__tests__/workspacesStoreItemReorder.spec.ts` (new) — store-level test
- `src/apps/desktop/src/__tests__/workspaceListItemDragDrop.spec.ts` (new) — component-level test

---

## Chunk 1: Backend — migration, response helper, route registration

### Task 1.1: Add `Migration045AddPositionToWorkspaceItems`

**Files:**
- Modify: `src/ai_workflow/tui/migration.zig`

- [ ] **Step 1: Add the migration struct after `Migration044AddRoutines`**

Insert the new migration struct directly after the closing brace of `Migration044AddRoutines` (around line 767) and before `MigrationManager`. Copy this verbatim, following the exact structure of `Migration043AddPositionToWorkspaces`:

```zig
pub const Migration045AddPositionToWorkspaceItems = struct {
    pub const version: u32 = 45;
    pub const name = "add_position_to_workspace_items";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Mirror of Migration043AddPositionToWorkspaces but scoped to
        // a single workspace's items. The new `position` column is
        // the sort key for the per-workspace item list (workspaces_list
        // returns items via workspace_items_get.zig which currently
        // does `ORDER BY created_at DESC`; we switch it to
        // `ORDER BY position DESC`). New items get
        // position = MAX(position) + 1 (top of the expanded workspace
        // list, since items are rendered top-to-bottom in DESC order).
        // The drag-and-drop reorder endpoint reassigns these values to
        // reflect the user's chosen order.
        try db.exec(allocator, "ALTER TABLE workspace_items ADD COLUMN position INTEGER NOT NULL DEFAULT 0", &[_][]const u8{});

        // Backfill. Per-workspace: the newest item gets the highest
        // position (so it appears at the TOP of the expanded list with
        // ORDER BY position DESC), the oldest gets position 0 (bottom).
        // This preserves the pre-existing visual order on upgrade.
        // The id tiebreaker (newer id > older id when timestamps tie) is
        // important so the backfill is deterministic when two items
        // share a created_at second.
        try db.exec(allocator,
            \\UPDATE workspace_items
            \\SET position = (
            \\    SELECT COUNT(*)
            \\    FROM workspace_items wi
            \\    WHERE wi.workspace_id = workspace_items.workspace_id
            \\        AND (wi.created_at > workspace_items.created_at
            \\            OR (wi.created_at = workspace_items.created_at AND wi.id > workspace_items.id))
            \\)
        , &[_][]const u8{});

        // Index on (workspace_id, position DESC) so the per-workspace
        // item list query uses an index even with hundreds of items
        // per workspace.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_items_workspace_position ON workspace_items(workspace_id, position DESC)", &[_][]const u8{});

        // Refresh query-planner stats (mirrors Migration043/044
        // pattern) so the new index is picked on pre-existing DBs.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
```

- [ ] **Step 2: Register the new migration in `allMigrations`**

Find the `allMigrations` array (the line that lists migrations 040, 041, ..., 044). Append one new entry after the Migration044 entry:

```zig
.{ .version = Migration045AddPositionToWorkspaceItems.version, .name = Migration045AddPositionToWorkspaceItems.name, .up = Migration045AddPositionToWorkspaceItems.up },
```

- [ ] **Step 3: Verify the build**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build --summary all 2>&1 | tail -30`
Expected: build succeeds with no errors. The migration table is now at version 45.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && git add src/ai_workflow/tui/migration.zig && git commit -m "feat(migration): add Migration045AddPositionToWorkspaceItems"
```

### Task 1.2: Add the typed response helper

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig`

- [ ] **Step 1: Add the struct + helper after the existing `WorkspacesReorderResponse` block**

Find the existing `WorkspacesReorderResponse` struct (around line 422) and its `makeWorkspacesReorderResponse` helper. Add the matching workspace-item version directly after, with the same shape:

```zig
// Typed response for `POST /api/workspaces/:workspace_id/items/reorder`.
// Uses the same std.json.Stringify.valueAlloc pattern as every other
// make*Response helper in this file (never manual JSON strings).
pub const WorkspaceItemReorderResponse = struct {
    success: bool = true,
    count: usize,
};

pub fn makeWorkspaceItemReorderResponse(allocator: std.mem.Allocator, count: usize) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, WorkspaceItemReorderResponse{ .count = count }, .{});
}
```

- [ ] **Step 2: Verify the build**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build --summary all 2>&1 | tail -10`
Expected: build succeeds. The new struct compiles and the helper is exposed.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && git add src/ai_workflow/tui/http_handlers/http_response.zig && git commit -m "feat(http): add WorkspaceItemReorderResponse + makeWorkspaceItemReorderResponse"
```

---

## Chunk 2: Backend — handler, list/create updates, tests

### Task 2.1: Add the reorder handler

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/workspace_items_reorder.zig`

- [ ] **Step 1: Write the failing static-test file (we will run it to ensure the contract is captured)**

```zig
//! Static regression checks for the workspace-item reorder handler.
//!
//! Mirrors the contract enforced by `workspaces_reorder_test.zig`,
//! scoped to a single workspace's items. The handler must:
//!   1. Read `{ordered_ids: [...]}` from the request body.
//!   2. Issue a per-id `UPDATE workspace_items SET position = ?`.
//!   3. Return a typed `WorkspaceItemReorderResponse`.
//!   4. Refuse empty / unknown / duplicate IDs (silent skip matches
//!      the workspace reorder contract).
//!
//! Plan: docs/superpowers/plans/2026-06-16-workspace-item-position-reorder.md

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/workspace_items_reorder.zig";
const LIST_PATH = "src/ai_workflow/tui/http_handlers/workspace_items_get.zig";
const CREATE_PATH = "src/ai_workflow/tui/http_handlers/workspace_items_create.zig";
const RESPONSE_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";
const MIGRATION_PATH = "src/ai_workflow/tui/migration.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

test "workspace_items_reorder handler parses ordered_ids from the request body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "ordered_ids") == null) {
        std.debug.print(
            "\n!! {s} does not reference the `ordered_ids` field !!\n" ++
                "   The reorder endpoint is broken. The frontend POSTs\n" ++
                "   {{ordered_ids: [...]}} and expects a 200 + position\n" ++
                "   updates. Restore the field name in the handler.\n" ++
                "   See docs/plans/2026-06-16-workspace-item-position-reorder.md.\n",
            .{HANDLER_PATH},
        );
        return error.OrderedIdsMissing;
    }
}

test "workspace_items_reorder SQL UPDATE lives in the use case (same file)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "UPDATE workspace_items SET position") == null) {
        std.debug.print(
            "\n!! {s} does not UPDATE workspace_items.position !!\n" ++
                "   The reorder endpoint is silently a no-op.\n" ++
                "   Add: UPDATE workspace_items SET position = ? WHERE id = ?\n",
            .{HANDLER_PATH},
        );
        return error.PositionUpdateMissing;
    }
}

test "workspace_items_reorder uses a typed response (no manual JSON string)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "makeWorkspaceItemReorderResponse") == null) {
        std.debug.print(
            "\n!! {s} does not call makeWorkspaceItemReorderResponse !!\n" ++
                "   The response is being constructed manually. Use the\n" ++
                "   typed helper in http_response.zig instead:\n" ++
                "     try http_response.makeWorkspaceItemReorderResponse(allocator, result.count)\n",
            .{HANDLER_PATH},
        );
        return error.ManualJsonString;
    }
    if (std.mem.indexOf(u8, source, "std.fmt.allocPrint(allocator, \"{{") != null) {
        std.debug.print(
            "\n!! {s} still constructs a JSON string with std.fmt.allocPrint !!\n" ++
                "   Use the typed response helper. See the contract test\n" ++
                "   above for the helper name.\n",
            .{HANDLER_PATH},
        );
        return error.ManualJsonString;
    }
}

test "workspace_items_reorder use case assigns position = (count - 1 - i)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "count - 1 -") == null) {
        std.debug.print(
            "\n!! {s} is missing the 'count - 1 - i' position formula !!\n" ++
                "   The reorder endpoint will assign positions in the\n" ++
                "   wrong direction (bottom-to-top instead of top-to-bottom).\n" ++
                "   Restore: const new_pos: i64 = count - 1 - @as(i64, @intCast(i));\n",
            .{HANDLER_PATH},
        );
        return error.PositionFormulaMissing;
    }
}

test "workspace_items_get handler orders by position DESC" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LIST_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "ORDER BY position DESC") == null) {
        std.debug.print(
            "\n!! {s} does not ORDER BY position DESC !!\n" ++
                "   Drag-reorder will be lost on the next page load.\n" ++
                "   Restore: ORDER BY position DESC (in the workspace_items SELECT)\n",
            .{LIST_PATH},
        );
        return error.OrderByPositionMissing;
    }
}

test "workspace_items_create handler assigns a fresh MAX+1 position" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    const has_max_subquery = std.mem.indexOf(u8, source, "MAX(position)") != null;
    const has_position_col = std.mem.indexOf(u8, source, "position") != null;
    if (!has_max_subquery or !has_position_col) {
        std.debug.print(
            "\n!! {s} does not compute a fresh position for new rows !!\n" ++
                "   New items will land at the bottom of the list.\n" ++
                "   Add: COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1\n" ++
                "   to the INSERT statement (scoped by workspace_id).\n",
            .{CREATE_PATH},
        );
        return error.PositionAssignmentMissing;
    }
}

test "makeWorkspaceItemReorderResponse uses std.json.Stringify (typed response)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, RESPONSE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "makeWorkspaceItemReorderResponse") == null) {
        std.debug.print(
            "\n!! {s} is missing makeWorkspaceItemReorderResponse !!\n" ++
                "   The handler test (uses makeWorkspaceItemReorderResponse)\n" ++
                "   will fail. Add the helper:\n" ++
                "     pub fn makeWorkspaceItemReorderResponse(allocator, count) ![]u8 {{\n" ++
                "         return std.json.Stringify.valueAlloc(allocator, WorkspaceItemReorderResponse{{ .count = count }}, .{{}});\n" ++
                "     }}\n",
            .{RESPONSE_PATH},
        );
        return error.ResponseHelperMissing;
    }
    if (std.mem.indexOf(u8, source, "WorkspaceItemReorderResponse") == null) {
        std.debug.print(
            "\n!! {s} is missing the WorkspaceItemReorderResponse struct !!\n" ++
                "   Add: pub const WorkspaceItemReorderResponse = struct {{ success: bool = true, count: usize }};\n",
            .{RESPONSE_PATH},
        );
        return error.ResponseStructMissing;
    }
    if (std.mem.indexOf(u8, source, "std.json.Stringify") == null) {
        std.debug.print(
            "\n!! {s} does not use std.json.Stringify for the response !!\n" ++
                "   The response helper must serialize via\n" ++
                "   std.json.Stringify.valueAlloc(allocator, ..., .{{}}),\n" ++
                "   matching the pattern used by every other make*Response\n" ++
                "   helper in this file.\n",
            .{RESPONSE_PATH},
        );
        return error.TypedSerializationMissing;
    }
}

test "migration 045 adds the workspace_items.position column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MIGRATION_PATH);
    defer allocator.free(source);

    const has_version = std.mem.indexOf(u8, source, "Migration045AddPositionToWorkspaceItems") != null;
    const has_column = std.mem.indexOf(u8, source, "ADD COLUMN position") != null;
    if (!has_version or !has_column) {
        std.debug.print(
            "\n!! {s} is missing Migration 045 or the position column !!\n" ++
                "   Fresh databases will fail to ORDER BY position DESC.\n" ++
                "   Add Migration045AddPositionToWorkspaceItems with ALTER TABLE\n" ++
                "   workspace_items ADD COLUMN position INTEGER NOT NULL DEFAULT 0\n",
            .{MIGRATION_PATH},
        );
        return error.Migration045Missing;
    }
}
```

- [ ] **Step 2: Confirm the tests fail (handler doesn't exist yet)**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test:ai_workflow:tui --summary all 2>&1 | tail -40`
Expected: tests fail with `error.OrderedIdsMissing`, `error.PositionUpdateMissing`, etc. The handler file doesn't exist yet.

- [ ] **Step 3: Write the handler implementation**

Create the file `src/ai_workflow/tui/http_handlers/workspace_items_reorder.zig` with the full implementation. Follow the structure of `src/ai_workflow/tui/http_handlers/workspaces_reorder.zig` exactly. The handler signature is `workspaceItemsReorderHandler(ctx, req, res)`. The route path contains `:workspace_id` and the path is `POST /api/workspaces/:workspace_id/items/reorder`. Note: the body still contains `ordered_ids`; the workspace_id is a URL param. Use the same `MAX_REORDER_IDS` cap (100) and the same `count - 1 - @as(i64, @intCast(i))` position formula. The SQL is:

```sql
UPDATE workspace_items SET position = ?, updated_at = datetime('now') WHERE id = ?
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test:ai_workflow:tui --summary all 2>&1 | tail -20`
Expected: all 7 new tests pass. (The full test count is whatever it was + 7.)

- [ ] **Step 5: Register the handler in `http_handlers/mod.zig`**

Open `src/ai_workflow/tui/http_handlers/mod.zig` and add:

```zig
pub const workspaceItemsReorderHandler = @import("workspace_items_reorder.zig").workspaceItemsReorderHandler;
```

Place it next to the existing `workspaceItemsUpdateHandler` line (around line 49).

- [ ] **Step 6: Wire the new test file into `test_runner.zig`**

Open `src/ai_workflow/tui/test_runner.zig`. Find the line that imports `workspaces_reorder_test.zig` (around line 26) and add the new test file directly below it:

```zig
_ = @import("http_handlers/workspace_items_reorder_test.zig");
```

- [ ] **Step 7: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && git add src/ai_workflow/tui/http_handlers/workspace_items_reorder.zig src/ai_workflow/tui/http_handlers/workspace_items_reorder_test.zig src/ai_workflow/tui/http_handlers/mod.zig src/ai_workflow/tui/test_runner.zig && git commit -m "feat(http): add workspace_items_reorder handler with static tests"
```

### Task 2.2: Update list handler to ORDER BY position DESC

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/workspace_items_get.zig`

- [ ] **Step 1: Update the list query**

The current code (in `listWorkspaceItems` called from this handler) sorts by `created_at DESC`. Switch it to `position DESC` so the drag-reordered order is preserved on reload. Find the SELECT statement used by `listWorkspaceItems` (it lives in `src/ai_workflow/tui/llm_history.zig` since `ai_mod.workspace_items` is re-exported from there per `mod.zig`). Change the trailing `ORDER BY created_at DESC` to `ORDER BY position DESC, id ASC`. The `id ASC` is a deterministic tiebreaker for items that share a position (shouldn't happen post-reorder, but defense-in-depth — mirrors the migration's tiebreaker style).

- [ ] **Step 2: Verify the build**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build --summary all 2>&1 | tail -10`
Expected: build succeeds. The static test from Task 2.1 (`ORDER BY position DESC`) still passes.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && git add src/ai_workflow/tui/llm_history.zig && git commit -m "feat(db): workspace_items list orders by position DESC"
```

### Task 2.3: Update create handler to assign MAX+1

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/workspace_items_create.zig`

- [ ] **Step 1: Add position assignment to the INSERT**

The current INSERT in `workspace_items_create.zig` is:

```sql
INSERT INTO workspace_items (id, workspace_id, item_type, name, path, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))
```

Update it to also assign a fresh position, scoped by `workspace_id`. The position value is `COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1`. The COALESCE handles the empty-workspace case (no rows → MAX is NULL → -1 → position 0). The new INSERT becomes:

```sql
INSERT INTO workspace_items
    (id, workspace_id, item_type, name, path, position, created_at, updated_at)
VALUES (?, ?, ?, ?, ?,
    COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1,
    datetime('now'), datetime('now'))
```

Update the bound-args tuple accordingly — the new `?` for the subquery needs the `workspace_id` value (which is already in the `&.{ ... }` tuple, just place it in the right position).

- [ ] **Step 2: Verify the build and the static test from Task 2.1**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test:ai_workflow:tui --summary all 2>&1 | tail -10`
Expected: build succeeds. The `workspace_items_create handler assigns a fresh MAX+1 position` test passes.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && git add src/ai_workflow/tui/http_handlers/workspace_items_create.zig && git commit -m "feat(http): workspace_items_create assigns MAX+1 position scoped to workspace_id"
```

---

## Chunk 3: Frontend — API function + store action

### Task 3.1: Add the API function

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 1: Add `reorderWorkspaceItems` next to `reorderWorkspaces`**

Find the existing `reorderWorkspaces` function (around line 168). The signature is `async function reorderWorkspaces(orderedIds: string[]): Promise<...>`. Add the new function directly after, with the same shape but the path includes the workspace_id:

```ts
/**
 * POST /api/workspaces/:workspace_id/items/reorder with body
 * `{ordered_ids: [...]}`. The response is the same shape as the
 * workspaces reorder endpoint (see `reorderWorkspaces`).
 */
export async function reorderWorkspaceItems(
  workspaceId: string,
  orderedIds: string[]
): Promise<{ success: boolean; count: number }> {
  const response = await fetch(
    `${API_BASE}/workspaces/${encodeURIComponent(workspaceId)}/items/reorder`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ordered_ids: orderedIds }),
    }
  )
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${await response.text()}`)
  }
  return response.json()
}
```

- [ ] **Step 2: Verify the TypeScript build**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -20`
Expected: `bun run build` succeeds (type check + bundle). If the new function is unused, that's OK — TS will warn but not error; the workspace store will import it in Task 3.2.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && git add src/apps/desktop/src/api/index.ts && git commit -m "feat(api): add reorderWorkspaceItems(workspaceId, orderedIds)"
```

### Task 3.2: Add the store action

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts`

- [ ] **Step 1: Add `reorderWorkspaceItems` next to `reorderWorkspaces`**

Find the existing `async function reorderWorkspaces(orderedIds: string[])` (around line 851) and add the new function directly after, with the same shape but scoped to a single workspace. The function:

1. Looks up the workspace by `workspaceId` in `workspaces.value`.
2. Bails on length mismatch, missing workspace, or same-order no-op (mirrors `reorderWorkspaces`).
3. Snapshots the previous items array.
4. Builds the new items array in the requested order.
5. Reassigns `workspaces.value` (the workspace is a ref inside the array, so this preserves reactivity).
6. POSTs to the backend. On failure, restores the snapshot.

Concretely, the new function is:

```ts
/**
 * Reorder the items of one workspace to match `orderedIds` and persist
 * the new order via `POST /api/workspaces/:workspace_id/items/reorder`.
 * Mirrors `reorderWorkspaces` but scoped to a single workspace's items
 * (no length-mismatch concern: the client sends the FULL item list
 * for the workspace). No-op when the order is unchanged.
 *
 * Plan: docs/superpowers/plans/2026-06-16-workspace-item-position-reorder.md
 */
async function reorderWorkspaceItems(
  workspaceId: string,
  orderedIds: string[]
) {
  const workspace = workspaces.value.find((w) => w.id === workspaceId)
  if (!workspace) {
    console.error(
      `[workspacesStore.reorderWorkspaceItems] workspace ${workspaceId} not found`
    )
    return
  }
  const current = workspace.items
  if (orderedIds.length === 0) return
  if (orderedIds.length !== current.length) {
    console.error(
      `[workspacesStore.reorderWorkspaceItems] orderedIds length ${orderedIds.length} != current ${current.length}; refusing reorder`
    )
    return
  }
  const currentIdSet = new Set(current.map((i) => i.id))
  const newIdSet = new Set(orderedIds)
  const isSameSet =
    currentIdSet.size === newIdSet.size &&
    [...currentIdSet].every((id) => newIdSet.has(id))
  if (isSameSet && current.every((i, idx) => i.id === orderedIds[idx])) {
    return
  }

  const previousOrder = current.slice()
  const byId = new Map(current.map((i) => [i.id, i]))
  const reordered: typeof current = []
  for (const id of orderedIds) {
    const item = byId.get(id)
    if (item) reordered.push(item)
  }
  for (const item of current) {
    if (!orderedIds.includes(item.id)) reordered.push(item)
  }
  workspace.items = reordered

  try {
    await api.reorderWorkspaceItems(workspaceId, orderedIds)
  } catch (err) {
    console.error(
      '[workspacesStore.reorderWorkspaceItems] API call failed, rolling back:',
      err
    )
    workspace.items = previousOrder
  }
}
```

- [ ] **Step 2: Export it from the store's `return`**

Find the existing `return { ..., reorderWorkspaces, ... }` block in the store definition (around line 1063). Add the new action next to `reorderWorkspaces`:

```ts
reorderWorkspaceItems,
```

- [ ] **Step 3: Verify the build**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -20`
Expected: type check passes. The store now exposes `reorderWorkspaceItems`.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && git add src/apps/desktop/src/stores/workspaces.ts && git commit -m "feat(store): add reorderWorkspaceItems(workspaceId, orderedIds) action"
```

---

## Chunk 4: Frontend — Vue components + tests

### Task 4.1: Update `WorkspaceList.vue` to support item drag-and-drop

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceList.vue`

- [ ] **Step 1: Add the new emit alongside the existing `onReorderWorkspaces`**

Find the `emits: [...]` block (currently includes `onReorderWorkspaces`). Add `onReorderWorkspaceItems` with the same signature pattern but with `(workspaceId: string, orderedItemIds: string[])`:

```ts
onReorderWorkspaceItems: (_workspaceId: string, _orderedItemIds: string[]) => true,
```

- [ ] **Step 2: Make the per-item `<li>` draggable and add drag handlers**

Find the per-item row template (the one that renders the `<WorkspaceItem>` inside the expanded workspace). The pattern is `<li>` containing a clickable button. Mirror the existing workspace-header drag-and-drop pattern (which sets `draggable="true"` on the wrapper and wires `onDragstart`/`onDragover`/`onDragleave`/`onDrop`). For items:

- Add `draggable="true"` to the `<li>` wrapper.
- Add a `data-item-id` attribute (`workspace.items[i].id`).
- Add a `data-workspace-id` attribute (so the `drop` handler knows which workspace to reorder).
- Wire `onDragstart` to set `text/plain` to the item's id.
- Wire `onDragover` / `onDragleave` / `onDrop` to compute the new order: splice the dragged item id out of the workspace's items, insert it at the drop position, and emit `onReorderWorkspaceItems(workspaceId, items.map(i => i.id))`.

Reuse the same visual drop indicator pattern as the workspace-level drop (the `c` ref + `l.value === e` check + opacity / shadow classes) so the UX is consistent.

- [ ] **Step 3: Verify the build**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -20`
Expected: type check passes.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && git add src/apps/desktop/src/components/WorkspaceList.vue && git commit -m "feat(ui): workspace items are draggable, emit onReorderWorkspaceItems"
```

### Task 4.2: Wire the event in `Sidebar.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/Sidebar.vue`

- [ ] **Step 1: Add the handler next to the existing `onReorderWorkspaces` handler**

Find where the parent (`Sidebar.vue`) handles the `onReorderWorkspaces` event from `WorkspaceList.vue`. The pattern is:

```vue
@reorder-workspaces="$store.workspaces.reorderWorkspaces($event)"
```

Add the matching event handler for items:

```vue
@reorder-workspace-items="(workspaceId, orderedItemIds) => $store.workspaces.reorderWorkspaceItems(workspaceId, orderedItemIds)"
```

(Pinia store is typically accessed via the parent's setup — adjust to the actual idiom used in this file; if `$store` is available, use it; otherwise, import `useWorkspacesStore` and call the action.)

- [ ] **Step 2: Verify the build**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -20`
Expected: type check passes.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && git add src/apps/desktop/src/components/Sidebar.vue && git commit -m "feat(ui): wire reorderWorkspaceItems event from WorkspaceList to store"
```

### Task 4.3: Add the store-level test

**Files:**
- Create: `src/apps/desktop/src/__tests__/workspacesStoreItemReorder.spec.ts`

- [ ] **Step 1: Write the failing test**

Mirror the structure of `src/apps/desktop/src/__tests__/workspacesStoreReorder.spec.ts`. The test cases:

1. **Happy path:** seed two workspaces each with 3 items in a known order; call `reorderWorkspaceItems(wsId, [item2.id, item1.id, item3.id])`; assert local items array is reordered; assert `api.reorderWorkspaceItems` was called with the right URL/body.
2. **Length mismatch:** call with `orderedIds.length !== items.length`; assert no API call was made and the local order is unchanged.
3. **No-op same-order:** call with the same order; assert no API call.
4. **Workspace not found:** call with a nonexistent workspaceId; assert no API call, no crash.
5. **API failure rollback:** stub `api.reorderWorkspaceItems` to reject; assert local items array is restored to the snapshot.

Use the same vitest patterns (mock `api.reorderWorkspaceItems` with `vi.fn()`/`mockResolvedValue`/`mockRejectedValue`) and the same fixture-setup helpers from the existing `workspacesStoreReorder.spec.ts`.

- [ ] **Step 2: Run the test to confirm it fails for the right reason**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bunx vitest run __tests__/workspacesStoreItemReorder.spec.ts 2>&1 | tail -30`
Expected: tests fail with "reorderWorkspaceItems is not a function" (the store doesn't expose it yet — but Task 3.2 just added it, so it should now fail with something different like a missing `api.reorderWorkspaceItems` mock).

- [ ] **Step 3: Verify the test passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bunx vitest run __tests__/workspacesStoreItemReorder.spec.ts 2>&1 | tail -20`
Expected: all 5 tests pass.

- [ ] **Step 4: Run the full vitest suite + type check**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -20 && timeout 120 bunx vitest run 2>&1 | tail -20
```
Expected: type check clean, all tests pass (count = prior + 5 new).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && git add src/apps/desktop/src/__tests__/workspacesStoreItemReorder.spec.ts && git commit -m "test(store): add reorderWorkspaceItems store action tests"
```

### Task 4.4: Add the component-level test

**Files:**
- Create: `src/apps/desktop/src/__tests__/workspaceListItemDragDrop.spec.ts`

- [ ] **Step 1: Write the failing test**

Mirror the structure of `src/apps/desktop/src/__tests__/workspaceListDragDrop.spec.ts`. The test cases:

1. **Drag item to new position:** mount a `WorkspaceList` with two workspaces, each with 3 items in a known order; simulate a `dragstart` on item 2, a `dragover` + `drop` before item 0; assert the `onReorderWorkspaceItems` event was emitted with the right `(workspaceId, [item2.id, item1.id, item3.id])` payload.
2. **No emit when drop position is the same as start:** simulate dragstart on item 1 and drop in the same slot; assert no event emitted (the same-order no-op fires inside the store, but the component should still emit so the store is the one that decides no-op-ness). Actually — to keep the contract simple, the component ALWAYS emits; the store decides whether to call the API. So: assert the event IS emitted with the unchanged order, and verify in Task 4.3 that the store short-circuits.
3. **Different workspace doesn't cross-contaminate:** drag an item from workspace A, drop on a slot in workspace B; assert the event is emitted with workspace B's id, not A's (UX: cross-workspace drop should be a no-op, or move between workspaces — out of scope; we restrict to same-workspace drops only by checking the data-workspace-id in the drop handler).

Use the same `attachTo: document.body` + Teleport / native HTML5 drag-and-event dispatch pattern from the existing `workspaceListDragDrop.spec.ts`. Stub the workspaces store (or the api) so the test doesn't need a live backend.

- [ ] **Step 2: Run the test to confirm it fails for the right reason**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bunx vitest run __tests__/workspaceListItemDragDrop.spec.ts 2>&1 | tail -30`
Expected: tests fail because the `onReorderWorkspaceItems` event isn't emitted yet (Tasks 4.1 and 4.2 just added the wiring, so it should now actually emit and the tests should pass — confirm by running the next step).

- [ ] **Step 3: Verify the test passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bunx vitest run __tests__/workspaceListItemDragDrop.spec.ts 2>&1 | tail -20`
Expected: all 3 tests pass.

- [ ] **Step 4: Run the full vitest suite + type check**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -20 && timeout 120 bunx vitest run 2>&1 | tail -20
```
Expected: type check clean, all tests pass (count = prior + 8 new — 5 from Task 4.3 + 3 from Task 4.4).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && git add src/apps/desktop/src/__tests__/workspaceListItemDragDrop.spec.ts && git commit -m "test(ui): add workspace item drag-and-drop component tests"
```

---

## Verification

After all chunks are complete, the feature is correct if:

- [ ] Backend:
  - `timeout 180 zig build test:ai_workflow:tui --summary all` — green. The 7 new static tests in `workspace_items_reorder_test.zig` pass.
  - `timeout 180 zig build --summary all` — green. The whole project compiles.
  - Manual smoke test with a fresh DB: `rm ~/.config/nalar/nalar.db; ./zig-out/bin/nalar` (in a worktree). The migration log shows version 45 applied. Create a workspace, add 3 items, drag-reorder them, reload the page — the new order persists.

- [ ] Frontend:
  - `cd src/apps/desktop && timeout 120 bun run build` — clean (no TS errors).
  - `cd src/apps/desktop && timeout 120 bunx vitest run` — green. All new tests pass; no existing tests regress.
  - Manual smoke test in the dev server (`bun run dev`): open the sidebar, expand a workspace, drag a project name to a new position in the list. The UI updates immediately, the new order survives a hard reload, and the backend `zig-out/bin/nalar` log shows `POST /api/workspaces/.../items/reorder 200`.
