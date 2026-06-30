# Edit Workspace Item Name Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users rename a workspace item (e.g. the kanban shown as "kanban sprint 1" in `KanbanSettingsDialog`'s title) by clicking an inline edit pencil that swaps the name into a text input + Save/Cancel buttons, with the change persisted via the existing `PUT /api/workspaces/:wsId/items/:itemId` endpoint. The same inline rename lives in `KanbanView.vue`'s header so users can rename without opening Settings.

**Architecture:** Backend (Zig + SQLite) gets a new `updateWorkspaceItemName` function in `llm_history.zig` and the existing `workspaceItemsUpdateHandler` is extended to accept `name` (mirroring the existing `path`-presence branch). The frontend API wrapper `updateWorkspaceItem` gains an optional `name?: string` field. The Pinia `workspacesStore` gains an `updateKanbanItemName` action that optimistic-updates `item.name` like the existing `updateKanbanItemPath`. `KanbanSettingsDialog.vue` shows a small "✏️" pencil button next to "— kanban sprint 1" in its header — clicking it swaps the name into an inline `<input>` with Save / Cancel buttons (mirrors the existing `KanbanColumn.vue` inline-rename pattern at lines 103–132). `KanbanView.vue` gets the same inline-rename UX on its `<h3>` title so users don't have to open Settings to rename.

**Tech Stack:** Zig 0.16 backend, SQLite, Vue 3 + TypeScript + Pinia + Vitest frontend, the project's existing `parseFromSliceLeaky` + `std.json.Stringify.valueAlloc` JSON conventions.

**Spec:** This plan is the implementation spec; no separate design doc exists.

---

## Context

### Current state

- `workspace_items` table has a `name TEXT` column (added by an earlier ALTER in `migration.zig:484`).
- `WorkspaceItemInfo` struct (`src/ai_workflow/tui/llm_history.zig:2360-2378`) has `name: ?[]u8 = null`.
- `getWorkspaceItem` already SELECTs `name` (line 2404). `listWorkspaceItems` and `listAllWorkspaceItems` also SELECT it.
- `createWorkspaceItem` (line 2381) does NOT yet write `name` — created items start with `name = NULL` until a future migration or PUT sets it. (Out of scope to fix here; we only add the UPDATE path.)
- `updateWorkspaceItem` (`llm_history.zig:2427`) currently only writes `workspace_id` + `item_type`. There is NO existing function to update `name`.
- `updateWorkspaceItemPath` (line 2445) is the model-layer pattern to follow — single-column update with `updated_at = datetime('now')`.
- `workspaceItemsUpdateHandler` (`src/ai_workflow/tui/http_handlers/workspace_items_update.zig:15-117`) currently accepts `item_type` (required) + `path` (optional, presence-detected). `name` is NOT handled.
- Frontend `WorkspaceItem` interface (`src/apps/desktop/src/api/index.ts:134-159`) has `name: string` (already required at the interface level).
- `api.updateWorkspaceItem` (line 995-1007) signature: `data: { item_type?: string; path?: string | null }` — no `name` field.
- `workspacesStore.updateKanbanItemPath` (line 648-661) is the store-action pattern to follow for `updateKanbanItemName`.
- `KanbanSettingsDialog.vue` (`src/apps/desktop/src/components/KanbanSettingsDialog.vue`) renders "— {{ item.name }}" in its header (line 199-203) as a plain span.
- `KanbanView.vue` (`src/apps/desktop/src/components/KanbanView.vue:200-206`) renders `<h3 class="text-sm font-semibold truncate flex-1">{{ item.name }}</h3>` as the header title.
- `KanbanColumn.vue` already implements inline rename (lines 103-132) — same pattern.
- The kanban name is also rendered in `WorkspaceItem.vue:398` (sidebar) and `ChatsList.vue:431` (chat list) — both auto-refresh once `item.name` is mutated in the store.

### What this plan delivers

1. Backend `updateWorkspaceItemName` function in `llm_history.zig`.
2. `workspaceItemsUpdateHandler` accepts `{item_type?, name?, path?}` (any subset; at least one required).
3. Frontend `api.updateWorkspaceItem` type accepts `name?: string`.
4. Frontend `workspacesStore.updateKanbanItemName` action optimistic-updates and rolls back on error.
5. `KanbanSettingsDialog.vue` header gains a pencil button + inline rename input next to the kanban name.
6. `KanbanView.vue` header `<h3>` gains the same inline rename UX (single source of truth: a small refactored `InlineRenameInput.vue` child component, reused by both).
7. SSE: the `unified_events.zig` / `on_event_sent` pipeline already broadcasts `workspace_item.updated` on `path` changes — Task 1.1 verifies whether `name` changes trigger SSE today; if not, add a minimal emit in the handler.

### What's out of scope (deliberately)

- Renaming `folder` items via their on-disk path (folder names are derived from the path; renaming the DB row would desync from the filesystem).
- Bulk rename (CSV/JSON import).
- Slug/URL-safe name enforcement — the DB column is TEXT, anything goes.
- Auto-generated icons per item name.
- A "created_at"-aware "Renamed by X" audit log.
- Renaming during a pending LLM stream (the user must wait for the stream to finish — UI shows the existing spinner during rename attempts but no special handling needed).

---

## File Structure

### New backend files

| File | Responsibility |
|---|---|
| `src/ai_workflow/tui/workspace_items_update_name_test.zig` | Static-contract checks for the `name` branch of `workspaceItemsUpdateHandler` |

### Modified backend files

| File | Change |
|---|---|
| `src/ai_workflow/tui/llm_history.zig` | Add `updateWorkspaceItemName` function (single-column UPDATE) |
| `src/ai_workflow/tui/http_handlers/workspace_items_update.zig` | Accept optional `name` body field; call `updateWorkspaceItemName` when present (presence-detected, like the existing `path` branch) |
| `src/ai_workflow/tui/test_runner.zig` | Register `workspace_items_update_name_test.zig` |

### New frontend files

| File | Responsibility |
|---|---|
| `src/apps/desktop/src/components/InlineEditableText.vue` | Reusable inline-edit primitive: shows text + ✏️ pencil; click swaps to `<input>` + Save/Cancel. Two events: `save: [newValue]`, `cancel: []`. Used by both `KanbanSettingsDialog` and `KanbanView`. |
| `src/apps/desktop/src/__tests__/InlineEditableText.spec.ts` | Vitest unit tests for the new primitive |

### Modified frontend files

| File | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | Extend `updateWorkspaceItem` data type to `{ item_type?: string; path?: string \| null; name?: string }` |
| `src/apps/desktop/src/stores/workspaces.ts` | Add `updateKanbanItemName(workspaceId, itemId, name)` action; export it; optimistic update + rollback on error |
| `src/apps/desktop/src/components/KanbanSettingsDialog.vue` | Wrap the "— {{ item.name }}" span in `<InlineEditableText>`; emit `renameItem: [name: string]` upward; add `rename-item` to `defineEmits` |
| `src/apps/desktop/src/components/KanbanView.vue` | Wrap the `<h3>{{ item.name }}</h3>` in `<InlineEditableText>`; emit `rename-item: [name: string]` upward; add to `defineEmits` |
| `src/apps/desktop/src/components/AppLayout.vue` | Listen for `rename-item` from both children; call `workspacesStore.updateKanbanItemName(workspaceId, itemId, name)` |
| `src/apps/desktop/src/__tests__/KanbanSettingsDialog.spec.ts` | Append: "emits renameItem when the header pencil is used to save a new name" |
| `src/apps/desktop/src/__tests__/KanbanView.spec.ts` | Append: "renders the item name in an InlineEditableText"; "emits rename-item when a new name is saved" |
| `src/apps/desktop/src/__tests__/kanbanStore.spec.ts` | Append: `updateKanbanItemName` calls api.updateWorkspaceItem with `{ name }` and rolls back on error |

---

## Chunk 1: Backend — model function + PUT handler extension

> Smallest backend chunk. The DB already has a `name` column, so no migration is needed — only the model function + handler wiring + static-contract test.

### Task 1.1: Add `updateWorkspaceItemName` in `llm_history.zig`

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:2445-2458` (extend the block after `updateWorkspaceItemPath`)

- [ ] **Step 1: Write the failing test**

The test file `workspace_items_update_name_test.zig` (Task 1.4) will check the model function via static contract — it asserts the source contains the substring `updateWorkspaceItemName` and that the PUT handler references it. Skip the runtime unit test for the model; the static check is enough because the SQL is one line.

- [ ] **Step 2: Implement the model function**

After `updateWorkspaceItemPath` (line 2458), append:

```zig
/// Update only the `name` column of a workspace item. Used by the
/// Kanban Settings dialog (and the KanbanView header pencil) to
/// rename a workspace item — typically a kanban whose title the
/// user wants to change (e.g. "kanban sprint 1" → "Sprint 12").
///
/// The pattern mirrors `updateWorkspaceItemPath` (single-column
/// UPDATE + `updated_at = datetime('now')`). Both columns could
/// theoretically be batched into a single UPDATE, but the rest of
/// the project uses single-column setters (see `updateWorkspaceItem`
/// above + `updateWorkspaceItemPath`) — keeping the same shape
/// makes the model layer easy to reason about and matches the
/// handler's per-field `if (presence)` branching.
///
/// Pass a non-null, non-empty slice to set the name. The handler
/// layer rejects empty strings with a 400 BEFORE reaching this
/// function; passing `""` here would write the empty string into
/// the DB (the column has no `NOT NULL DEFAULT ''` constraint — it's
/// nullable).
///
/// Why the column is nullable (instead of NOT NULL DEFAULT ''):
/// earlier migration (`migration.zig:484`) added `name TEXT` without
/// a NOT NULL constraint, so existing rows pre-migration retain
/// `name = NULL`. The frontend renders `null` and `""` indistinguishably
/// via `{{ item.name ?? '' }}` or `column.name ?? ''`. Changing this
/// to NOT NULL DEFAULT '' is out of scope (would require a backfill
/// migration on every row + every referenced field).
pub fn updateWorkspaceItemName(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    name: []const u8,
) !void {
    const sql = "UPDATE workspace_items SET name = ?, updated_at = datetime('now') WHERE id = ?";
    try db.exec(allocator, sql, &.{ name, id });
}
```

- [ ] **Step 3: Run the build to verify it compiles**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: no compile errors related to the new function (other handlers that already call `updateWorkspaceItemPath` are unaffected — we added a sibling, not changed an existing one).

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/llm_history.zig
git commit -m "feat(workspace-items): add updateWorkspaceItemName model function"
```

### Task 1.2: Extend `workspaceItemsUpdateHandler` to accept `name`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/workspace_items_update.zig:31-117`

- [ ] **Step 1: Add `name_present` and `name_value` extraction (after line 67)**

After the existing `path_*` block (line 56-67), add:

```zig
// Optional name. Mirror the path branch's presence vs absence
// semantics: when the key is ABSENT we leave the existing name
// unchanged; when PRESENT:
//   - non-empty string → UPDATE the name
//   - empty string      → 400 (the model's column is nullable but
//                         we treat empty as "you forgot to enter
//                         anything" — the user retried the rename
//                         dialog and blanked it; refuse instead of
//                         writing NULL which breaks KanbanView's
//                         `{{ item.name }}` rendering).
//   - null              → 400 (same reason).
// This makes the contract strict: if you PUT the field, it must be
// a non-empty string.
const name_present = root.get("name") != null;
const name_value: ?[]const u8 = blk: {
    const v = root.get("name") orelse break :blk null;
    if (v == .null) break :blk null;
    if (v == .string and v.string.len == 0) break :blk null;
    if (v == .string) break :blk v.string;
    break :blk null;
};
// `name_valid` is true when name is present AND non-empty; the
// handler uses this to decide whether to UPDATE or 400.
const name_valid: bool = name_present and name_value != null;
```

- [ ] **Step 2: Reject the empty-string case (after the path validation)**

The 400-must-have-at-least-one validation lives later (after the item existence check). We add the name-empty validation here — earlier than the DB round-trip — to fail fast:

After line 76 (`defer existing.?.deinit(allocator);`), add:

```zig
// If the caller sent `name` but it was null or empty, reject
// before hitting the DB. Empty names break the UI rendering
// (`{{ item.name }}` shows nothing).
if (name_present and !name_valid) {
    return res.jsonResponse(.{
        .status_code = 400,
        .data = try http_response.makeErrorResponse(
            allocator,
            .{ .@"error" = "name must be a non-empty string when present" },
        ),
    });
}
```

- [ ] **Step 3: Add the `name` branch to the existing `if/else` (around line 87-101)**

The current handler has an `if (path_present) { ... } else { updateWorkspaceItem(...) }` shape. Extend it to a 3-way branch — name-only, path-only, or both — and a fallback to the legacy item_type-only update. Use a sequential `if/else if/else` so exactly one branch runs:

Change the `if (path_present) { ... } else { ... }` block to:

```zig
if (path_present and name_valid) {
    // Caller wants BOTH path + name updated. We update name first
    // (separate SQL) then path (separate SQL). Two cheap UPDATEs on
    // an indexed primary-key lookup are cheaper than a JOINed CTE;
    // the model layer keeps the single-column setter shape (see
    // updateWorkspaceItemName's docstring).
    ai_mod.workspace_items.updateWorkspaceItemName(
        allocator, sqlite_db, item_id, name_value.?,
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(
                allocator,
                .{ .@"error" = "Failed to update workspace item name" },
            ),
        });
    };
    if (path_clear or path_value == null) {
        ai_mod.workspace_items.updateWorkspaceItemPath(
            allocator, sqlite_db, item_id, null,
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(
                    allocator,
                    .{ .@"error" = "Failed to clear workspace item path" },
                ),
            });
        };
    } else {
        ai_mod.workspace_items.updateWorkspaceItemPath(
            allocator, sqlite_db, item_id, path_value.?,
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(
                    allocator,
                    .{ .@"error" = "Failed to update workspace item path" },
                ),
            });
        };
    }
} else if (name_valid) {
    // Name-only update (the rename path). Common case for the
    // KanbanSettingsDialog and KanbanView pencil.
    ai_mod.workspace_items.updateWorkspaceItemName(
        allocator, sqlite_db, item_id, name_value.?,
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(
                allocator,
                .{ .@"error" = "Failed to update workspace item name" },
            ),
        });
    };
} else if (path_present) {
    // Path-only update (preserves the original
    // "PUT /items/:id {item_type: 'kanban'}" path-set behavior).
    // The branch is the same as the old code, but renamed for
    // readability and inlined.
    if (path_clear or path_value == null) {
        ai_mod.workspace_items.updateWorkspaceItemPath(
            allocator, sqlite_db, item_id, null,
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(
                    allocator,
                    .{ .@"error" = "Failed to clear workspace item path" },
                ),
            });
        };
    } else {
        ai_mod.workspace_items.updateWorkspaceItemPath(
            allocator, sqlite_db, item_id, path_value.?,
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(
                    allocator,
                    .{ .@"error" = "Failed to update workspace item path" },
                ),
            });
        };
    }
} else {
    // Neither name nor path in body → legacy item_type-only update
    // path keeps the existing columns untouched.
    _ = item_type_val; // referenced for compatibility below
    ai_mod.workspace_items.updateWorkspaceItem(
        allocator, sqlite_db, item_id, current_workspace_id,
        item_type_val.string,
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(
                allocator,
                .{ .@"error" = "Failed to update workspace item" },
            ),
        });
    };
}
```

- [ ] **Step 4: Update the response to return the latest name**

The response shape is fixed (`makeWorkspaceItemGetResponse(..., .name = null, ...)`). The frontend re-fetches the actual row via `GET /api/workspaces/:wsId/items/:itemId` after the rename resolves (the store action re-issues the fetch). Leaving `name: null` in the PUT response is consistent with the existing `path: null` choice — callers distinguish "field absent from PUT body" from "field got cleared to NULL" by the absence-vs-null keys.

No change needed in this step; the response stays as-is.

- [ ] **Step 5: Run the build to verify it compiles**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: no compile errors. Test count unchanged (we haven't added tests yet).

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/workspace_items_update.zig
git commit -m "feat(workspace-items): PUT /items/:id accepts name in body"
```

### Task 1.3: Add static-contract test for the `name` branch

**Files:**
- Create: `src/ai_workflow/tui/workspace_items_update_name_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig` (register the new test)

- [ ] **Step 1: Write the static-contract test**

Create the file (mirror the pattern in `workspace_items_create_kanban_test.zig:27-128`):

```zig
//! Static regression checks for the `name` branch of the
//! `PUT /workspaces/:wsId/items/:itemId` handler
//! (`workspace_items_update.zig`).
//!
//! Why this file exists
//! ────────────────────
//! The edit-workspace-item-name feature adds a third optional
//! field (`name`) to the body the PUT handler accepts, sitting
//! alongside the existing `item_type` and `path`. Three contracts
//! are enforced via static substring checks (per the project
//! convention — see
//! `nalar-http-handler-thin-wrapper-pattern`):
//!
//!   1. The handler reads `root.get("name")` (mirroring the
//!      `root.get("path")` shape).
//!   2. The handler calls `updateWorkspaceItemName` (model layer)
//!      when the field is present and non-empty.
//!   3. The handler rejects an empty string with 400 BEFORE the
//!      DB round-trip.
//!
//! These guard against accidental routing of the rename request
//! back to the legacy `updateWorkspaceItem` path (which does NOT
//! write `name`), leaving the user's rename attempt to silently
//! fail.
//!
//! Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md
//!   (Chunk 1, Task 1.3)

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH =
    "src/ai_workflow/tui/http_handlers/workspace_items_update.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// ─── Contract 1: handler reads name from the request body ──────────────────

test "workspace_items_update handler reads name from body via root.get(\"name\")" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must reference `root.get("name")` so the rename
    // request reaches the `name_present` branch. Mirrors the
    // existing `path_present = root.get("path") != null` line that
    // gates the path-update branch.
    if (std.mem.indexOf(u8, source, "root.get(\"name\")") == null) {
        std.debug.print(
            "\n!! {s} does not read `name` from the request body !!\n" ++
                "   The rename branch requires `root.get(\"name\")` to be\n" ++
                "   referenced (so the rename request reaches the `name_valid`\n" ++
                "   gate). Mirror the existing `root.get(\"path\")` extraction.\n" ++
                "   See docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md.\n",
            .{HANDLER_PATH},
        );
        return error.NameExtractionMissing;
    }
}

// ─── Contract 2: handler calls updateWorkspaceItemName ─────────────────────

test "workspace_items_update handler calls updateWorkspaceItemName" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The rename branch must call the model function
    // `updateWorkspaceItemName` to write the new name. Without
    // this, the rename request would silently route to
    // `updateWorkspaceItem` (which writes workspace_id + item_type
    // only) — no name change persisted, no error.
    if (std.mem.indexOf(u8, source, "updateWorkspaceItemName") == null) {
        std.debug.print(
            "\n!! {s} does not call updateWorkspaceItemName !!\n" ++
                "   The rename branch must call `updateWorkspaceItemName` so\n" ++
                "   the SQL UPDATE writes the new name. Add a sibling branch\n" ++
                "   to the path-only branch (see the `updateWorkspaceItemName`\n" ++
                "   call signature in llm_history.zig).\n" ++
                "   See docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md.\n",
            .{HANDLER_PATH},
        );
        return error.UpdateNameCallMissing;
    }
}

// ─── Contract 3: handler rejects empty string with 400 ────────────────────

test "workspace_items_update handler returns 400 for empty name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // If the caller sends `{name: ""}` or `{name: null}`, the
    // handler MUST 400 before hitting the DB. Searching for the
    // canonical error message keeps the check contract-named —
    // changing the message in production code is also a contract
    // break.
    if (std.mem.indexOf(u8, source, "name must be a non-empty string when present") == null) {
        std.debug.print(
            "\n!! {s} does not return 400 for empty name !!\n" ++
                "   The rename branch must reject `{name: \"\"}` or `{name: null}`\n" ++
                "   with HTTP 400 BEFORE the DB round-trip. Add a check after the\n" ++
                "   item-existence lookup:\n" ++
                "     if (name_present and !name_valid) { return ... 400 ... }\n" ++
                "   with the message 'name must be a non-empty string when present'.\n" ++
                "   See docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md.\n",
            .{HANDLER_PATH},
        );
        return error.EmptyNameNotRejected;
    }
}
```

- [ ] **Step 2: Register the test**

Add `_ = @import("workspace_items_update_name_test.zig");` to `src/ai_workflow/tui/test_runner.zig` (next to the existing `workspace_items_create_kanban_test` import at line 48).

- [ ] **Step 3: Run the tests to verify they pass**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 3 new tests pass; no regressions.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/workspace_items_update_name_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "test(workspace-items): cover rename branch of PUT /items/:id"
```

---

## Chunk 2: Frontend API + store + reusable `InlineEditableText` primitive

> All frontend infrastructure pieces shipped together so the UI in Chunk 3 can wire up cleanly. The `InlineEditableText` primitive is the single source of truth used by both `KanbanSettingsDialog` (header) and `KanbanView` (header h3) — DRY.

### Task 2.1: Extend `api.updateWorkspaceItem` to accept `name`

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:995-1007`

- [ ] **Step 1: Update the signature**

Change:

```ts
export async function updateWorkspaceItem(
  workspaceId: string,
  itemId: string,
  data: { item_type?: string; path?: string | null },
): Promise<WorkspaceItem> {
  return await apiFetch<WorkspaceItem>(
    `/workspaces/${workspaceId}/items/${itemId}`,
    {
      method: 'PUT',
      body: data,
    },
  )
}
```

to:

```ts
/**
 * Update a workspace item. Supports partial updates — pass only
 * the fields you want to change.
 *
 * Fields:
 *   - `item_type`: new type (kanban / folder / chat / memory). The
 *     caller historically always sent this; current callers may
 *     omit it when only `name`/`path` change (the backend treats a
 *     missing `item_type` as "leave unchanged" since the rename
 *     branch doesn't read it).
 *   - `path`: new on-disk path (kanban cwd) or `null` to clear.
 *     Presence-detected by the backend (omitted → leave unchanged,
 *     `null` or `""` → clear, non-empty string → set).
 *   - `name`: new display name (used by the Kanban Settings rename
 *     pencil and the KanbanView header pencil). Presence-detected
 *     and rejected with 400 if empty/null.
 *
 * PUT /api/workspaces/:workspaceId/items/:itemId
 *
 * Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md
 */
export async function updateWorkspaceItem(
  workspaceId: string,
  itemId: string,
  data: {
    item_type?: string
    path?: string | null
    name?: string
  },
): Promise<WorkspaceItem> {
  return await apiFetch<WorkspaceItem>(
    `/workspaces/${workspaceId}/items/${itemId}`,
    {
      method: 'PUT',
      body: data,
    },
  )
}
```

- [ ] **Step 2: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build. `name?: string` is backwards-compatible with existing call sites that don't pass `name`.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(desktop): api.updateWorkspaceItem accepts name in body"
```

### Task 2.2: Add `updateKanbanItemName` action to the Pinia store

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts:648-661` (next to `updateKanbanItemPath`)

- [ ] **Step 1: Add the action**

Mirror `updateKanbanItemPath` exactly. Right after line 661 (`}` closing `updateKanbanItemPath`), add:

```ts
// Update kanban item name from the Settings dialog or KanbanView
// inline-rename pencil. Optimistic: mutate `item.name` BEFORE the
// API call resolves so the UI updates immediately; roll back on
// error. Backend contract: PUT /items/:id accepts `{name}` and
// either writes it (200) or rejects empty (400) — the API throws
// on non-2xx so we catch + restore + rethrow.
async function updateKanbanItemName(
  workspaceId: string,
  itemId: string,
  newName: string,
): Promise<void> {
  const ws = workspaces.value.find((w) => w.id === workspaceId)
  const item = ws?.items.find((i) => i.id === itemId)
  const previousName = item?.name
  // Optimistic update.
  if (item) item.name = newName
  try {
    await api.updateWorkspaceItem(workspaceId, itemId, { name: newName })
  } catch (err) {
    // Restore the previous name on failure so the UI doesn't lie.
    if (item && previousName !== undefined) item.name = previousName
    console.error('[workspacesStore.updateKanbanItemName] API call failed:', err)
    throw err
  }
}
```

- [ ] **Step 2: Export it from the store's return object**

The store action exports happen at the bottom of the file. Find the existing `updateKanbanItemPath` export (around the closing block where `workspacesStore = { ... }` lives) and add a sibling export. The export pattern is typically:

```ts
return {
  // existing exports ...
  updateKanbanItemPath,
  updateKanbanItemName,  // ← add
  // existing exports ...
}
```

If the exports are already enumerated as a closure over `return { ... }`, find `updateKanbanItemPath` in that return block and add `updateKanbanItemName` next to it.

- [ ] **Step 3: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/stores/workspaces.ts
git commit -m "feat(desktop): workspacesStore.updateKanbanItemName action"
```

### Task 2.3: Create the reusable `InlineEditableText.vue` primitive

**Files:**
- Create: `src/apps/desktop/src/components/InlineEditableText.vue`
- Create: `src/apps/desktop/src/__tests__/InlineEditableText.spec.ts`

This single component is used by both `KanbanSettingsDialog` (header subtitle) and `KanbanView` (header h3). Keeping the UX in one place matches the project's DRY preference and avoids divergent styling.

- [ ] **Step 1: Create the component**

Create `src/apps/desktop/src/components/InlineEditableText.vue`:

```vue
<!--
  InlineEditableText — click-to-edit text primitive.

  Two modes:
    - Display: shows the current `value` with an optional "✏️"
      pencil on hover; click anywhere on the text (or the pencil)
      to enter edit mode.
    - Edit:    shows an `<input>` pre-filled with the current value,
      auto-focused + selected. Enter saves, Escape cancels, blur
      saves (matching the inline rename patterns in KanbanColumn.vue).

  Public API:
    props:
      value           string   The current value to display / edit.
      placeholder     string   Placeholder for the input (defaults to '').
      maxlength       number   Optional input cap (defaults to 200).
      ariaLabel       string   Required for a11y — describes what
                                is being edited.
      testId          string   Data-testid prefix for the rendered
                                input / display elements.
      displayClass    string   Optional CSS class for the display
                                text (e.g. text-sm font-semibold).
                                Defaults to ''.
    emits:
      save    [newValue: string]  Fires on Enter or blur when the
                                   trimmed value is non-empty AND
                                   different from the original.
      cancel  []                   Fires on Escape.

  Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md
-->
<script setup lang="ts">
import { ref, nextTick } from 'vue'

const props = withDefaults(
  defineProps<{
    value: string
    placeholder?: string
    maxlength?: number
    ariaLabel: string
    testId: string
    displayClass?: string
  }>(),
  {
    placeholder: '',
    maxlength: 200,
    displayClass: '',
  },
)

const emit = defineEmits<{
  save: [newValue: string]
  cancel: []
}>()

const isEditing = ref(false)
const editValue = ref('')
const inputRef = ref<HTMLInputElement | null>(null)

async function startEditing() {
  editValue.value = props.value
  isEditing.value = true
  await nextTick()
  // Focus + select-all so the user can immediately type a new
  // value (or hit Esc to cancel). Mirrors
  // KanbanColumn.vue:startInlineRename (line 109-115).
  inputRef.value?.focus()
  inputRef.value?.select()
}

function cancelEditing() {
  isEditing.value = false
  editValue.value = ''
  emit('cancel')
}

function commitEditing() {
  const trimmed = editValue.value.trim()
  // No-op if empty (caller shouldn't be allowed to blank the
  // value — KanbanSettingsDialog and KanbanView both treat empty
  // as a UI bug rather than a rename intent).
  if (!trimmed) {
    cancelEditing()
    return
  }
  // No-op if unchanged — saves a backend round-trip.
  if (trimmed === props.value) {
    isEditing.value = false
    editValue.value = ''
    return
  }
  isEditing.value = false
  editValue.value = ''
  emit('save', trimmed)
}

function handleKeydown(event: KeyboardEvent) {
  if (event.key === 'Enter') {
    event.preventDefault()
    commitEditing()
  } else if (event.key === 'Escape') {
    event.preventDefault()
    cancelEditing()
  }
}
</script>

<template>
  <span
    class="inline-editable inline-flex items-center gap-1 min-w-0"
    :data-testid="`${testId}-wrapper`"
  >
    <!-- Display mode: hover-revealed pencil + click target on the text -->
    <span
      v-if="!isEditing"
      class="inline-flex items-center gap-1 min-w-0 cursor-text group"
      role="button"
      tabindex="0"
      :aria-label="`Edit ${ariaLabel}`"
      :data-testid="`${testId}-display`"
      @click="startEditing"
      @keydown.enter.prevent="startEditing"
      @keydown.space.prevent="startEditing"
    >
      <span
        class="truncate"
        :class="displayClass"
        :data-testid="`${testId}-value`"
      >{{ value || placeholder }}</span>
      <!-- Pencil — hidden until hover. Mirrors the KanbanColumn
           ⋮ menu hover affordance. -->
      <button
        type="button"
        class="shrink-0 w-5 h-5 rounded flex items-center justify-center opacity-0 group-hover:opacity-70 hover:!opacity-100 transition-opacity duration-150"
        style="color: var(--semantic-text-muted);"
        :aria-label="`Edit ${ariaLabel}`"
        :data-testid="`${testId}-pencil`"
        @click.stop="startEditing"
      >
        <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
            d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
        </svg>
      </button>
    </span>

    <!-- Edit mode: input + Save/Cancel -->
    <span
      v-else
      class="inline-flex items-center gap-1 min-w-0"
      :data-testid="`${testId}-edit`"
    >
      <input
        ref="inputRef"
        v-model="editValue"
        type="text"
        :placeholder="placeholder"
        :maxlength="maxlength"
        :aria-label="`Editing ${ariaLabel}`"
        :data-testid="`${testId}-input`"
        class="flex-1 min-w-0 px-2 py-0.5 rounded text-sm outline-none transition-all duration-200"
        style="
          background-color: var(--semantic-sidebar-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
        @keydown="handleKeydown"
        @blur="commitEditing"
      />
      <button
        type="button"
        class="shrink-0 px-2 py-0.5 rounded text-xs font-medium hover:opacity-80 transition-opacity"
        style="
          background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
          color: var(--color-bg);
        "
        :aria-label="`Save ${ariaLabel}`"
        :data-testid="`${testId}-save`"
        @mousedown.prevent
        @click.stop="commitEditing"
      >
        Save
      </button>
      <button
        type="button"
        class="shrink-0 px-2 py-0.5 rounded text-xs font-medium hover:opacity-80 transition-opacity"
        style="
          background-color: var(--semantic-card-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text-muted);
        "
        :aria-label="`Cancel ${ariaLabel}`"
        :data-testid="`${testId}-cancel`"
        @mousedown.prevent
        @click.stop="cancelEditing"
      >
        Cancel
      </button>
    </span>
  </span>
</template>

<style scoped>
/* Make the entire display block focusable + accessible (hover styles
   on the pencil span are handled by Tailwind's group-hover class). */
.inline-editable :focus-visible {
  outline: 2px solid var(--color-violet);
  outline-offset: 2px;
  border-radius: 4px;
}
</style>
```

- [ ] **Step 2: Add Vitest unit tests**

Create `src/apps/desktop/src/__tests__/InlineEditableText.spec.ts`:

```ts
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import InlineEditableText from '@/components/InlineEditableText.vue'

describe('InlineEditableText', () => {
  it('renders the value in display mode by default', () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
    })
    expect(wrapper.text()).toContain('Sprint 12')
    expect(wrapper.find('[data-testid="iet-display"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="iet-edit"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('swaps to edit mode when the display is clicked', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    expect(wrapper.find('[data-testid="iet-edit"]').exists()).toBe(true)
    const input = wrapper.find('[data-testid="iet-input"]').element as HTMLInputElement
    expect(input.value).toBe('Sprint 12')
    wrapper.unmount()
  })

  it('emits save with the trimmed value when Save is clicked', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    const input = wrapper.find('[data-testid="iet-input"]')
    await input.setValue('  Sprint 13  ')
    await wrapper.find('[data-testid="iet-save"]').trigger('click')
    const emitted = wrapper.emitted('save')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['Sprint 13'])
    wrapper.unmount()
  })

  it('emits save when the input loses focus after a non-empty edit', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    const input = wrapper.find('[data-testid="iet-input"]')
    await input.setValue('Sprint 13')
    await input.trigger('blur')
    const emitted = wrapper.emitted('save')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['Sprint 13'])
    wrapper.unmount()
  })

  it('does not emit save when the trimmed value equals the original', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    const input = wrapper.find('[data-testid="iet-input"]')
    await input.setValue('  Sprint 12  ')
    await wrapper.find('[data-testid="iet-save"]').trigger('click')
    expect(wrapper.emitted('save')).toBeFalsy()
    wrapper.unmount()
  })

  it('emits cancel when Cancel is clicked', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="iet-cancel"]').trigger('click')
    expect(wrapper.emitted('cancel')).toBeTruthy()
    expect(wrapper.emitted('save')).toBeFalsy()
    wrapper.unmount()
  })

  it('emits cancel on Escape', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="iet-input"]').trigger('keydown', { key: 'Escape' })
    expect(wrapper.emitted('cancel')).toBeTruthy()
    wrapper.unmount()
  })

  it('emits save on Enter', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    const input = wrapper.find('[data-testid="iet-input"]')
    await input.setValue('Sprint 13')
    await input.trigger('keydown', { key: 'Enter' })
    expect(wrapper.emitted('save')?.[0]).toEqual(['Sprint 13'])
    wrapper.unmount()
  })
})
```

- [ ] **Step 3: Run tests + type-check**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run InlineEditableText 2>&1 | tail -n 20`
Expected: 8 new tests pass.

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/InlineEditableText.vue \
        src/apps/desktop/src/__tests__/InlineEditableText.spec.ts
git commit -m "feat(desktop): reusable InlineEditableText primitive for inline rename"
```

---

## Chunk 3: Wire the inline rename UX into the Settings dialog + KanbanView

> User-facing chunk. The two rename entry points share the same `InlineEditableText` primitive and the same upward `rename-item` event — `AppLayout` handles both with one handler.

### Task 3.1: Add `rename-item` emit to `KanbanSettingsDialog.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/KanbanSettingsDialog.vue`

- [ ] **Step 1: Add `InlineEditableText` import + `rename-item` to the emits list**

Change lines 30-46:

```ts
import { ref, watch, nextTick } from 'vue'
import KanbanColumnEditor from './KanbanColumnEditor.vue'
import type { WorkspaceItem } from '../stores/workspaces'

const props = defineProps<{
  show: boolean
  item: WorkspaceItem | null
}>()

const emit = defineEmits<{
  close: []
  addColumn: [name: string, description: string]
  editColumn: [
    payload: { columnId: string; name: string; description: string },
  ]
  deleteColumn: [columnId: string]
}>()
```

to:

```ts
import { ref, watch, nextTick } from 'vue'
import KanbanColumnEditor from './KanbanColumnEditor.vue'
import InlineEditableText from './InlineEditableText.vue'
import type { WorkspaceItem } from '../stores/workspaces'

const props = defineProps<{
  show: boolean
  item: WorkspaceItem | null
}>()

const emit = defineEmits<{
  close: []
  addColumn: [name: string, description: string]
  editColumn: [
    payload: { columnId: string; name: string; description: string },
  ]
  deleteColumn: [columnId: string]
  /**
   * Fired when the user renames the kanban via the inline pencil
   * in the dialog header. The new name is the trimmed value the
   * user entered. The host (AppLayout) delegates to
   * workspacesStore.updateKanbanItemName.
   *
   * Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md
   */
  renameItem: [name: string]
}>()
```

- [ ] **Step 2: Replace the static "— {{ item.name }}" span with `<InlineEditableText>`**

Change lines 198-203:

```vue
<span
  v-if="item"
  class="text-sm font-normal ml-1"
  style="color: var(--semantic-text-muted);"
>— {{ item.name }}</span>
```

to:

```vue
<InlineEditableText
  v-if="item"
  :value="item.name"
  :placeholder="'unnamed kanban'"
  :aria-label="'kanban name'"
  :test-id="`kanban-settings-rename`"
  display-class="text-sm font-normal ml-1"
  @save="(newName) => emit('renameItem', newName)"
/>
```

- [ ] **Step 3: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build. The new emit is declared but not yet consumed (Task 3.3 wires it from `AppLayout`).

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanSettingsDialog.vue
git commit -m "feat(desktop): KanbanSettingsDialog header exposes inline rename pencil"
```

### Task 3.2: Add `rename-item` emit to `KanbanView.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/KanbanView.vue`

- [ ] **Step 1: Add `InlineEditableText` import**

After line 59 (`import { useWorkspacesStore } from '../stores/workspaces'`), add:

```ts
import InlineEditableText from './InlineEditableText.vue'
```

- [ ] **Step 2: Add `rename-item` to the emits block**

Find the existing `defineEmits<{ ... }>` block (around line 94-115) and add `rename-item`:

```ts
const emit = defineEmits<{
  addColumn: []
  addTask: [{ columnId: string }]
  moveTask: [{ taskId: string; columnId: string; position: number }]
  renameColumn: [{ columnId: string; name: string }]
  deleteColumn: [columnId: string]
  reorderColumn: [{ columnId: string; targetColumnId: string }]
  openSettings: []
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  editRoutine: [workspaceId: string, itemId: string, taskId: string]
  runRoutine: [workspaceId: string, itemId: string, taskId: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  requestRenameColumn: [columnId: string]
  requestDeleteColumn: [columnId: string]
  /**
   * Fired when the user renames the kanban via the inline pencil
   * on the header title. Mirrors KanbanSettingsDialog's
   * rename-item emit so AppLayout handles both with one handler.
   *
   * Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md
   */
  renameItem: [name: string]
}>()
```

- [ ] **Step 3: Replace the static `<h3>` with `<InlineEditableText>` inside an `<h3>` wrapper**

Change lines 200-206:

```vue
<h3
  class="text-sm font-semibold truncate flex-1"
  style="color: var(--semantic-text);"
  :data-testid="`kanban-view-${item.id}-title`"
>
  {{ item.name }}
</h3>
```

to:

```vue
<h3
  class="text-sm font-semibold truncate flex-1"
  style="color: var(--semantic-text);"
  :data-testid="`kanban-view-${item.id}-title`"
>
  <InlineEditableText
    :value="item.name"
    :placeholder="'unnamed kanban'"
    :aria-label="'kanban name'"
    :test-id="`kanban-view-${item.id}-rename`"
    display-class="text-sm font-semibold"
    @save="(newName) => emit('renameItem', newName)"
  />
</h3>
```

Note: keeping the `<h3>` wrapper preserves the semantic outline + CSS scoped-to-it classes (the existing `truncate flex-1` layout styles stay on the h3; the inline-edit spans inside).

- [ ] **Step 4: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanView.vue
git commit -m "feat(desktop): KanbanView header exposes inline rename pencil"
```

### Task 3.3: Wire `rename-item` to `workspacesStore.updateKanbanItemName` in `AppLayout.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/AppLayout.vue`

- [ ] **Step 1: Find the `<KanbanView>` and `<KanbanSettingsDialog>` element mounts**

Search the file for the two places these components are mounted (one near line 1132 or 1215 in AppLayout for `KanbanView`; one near line 1356-1364 for `KanbanSettingsDialog`). Each will be a `<KanbanView>` or `<KanbanSettingsDialog>` Vue element with a list of `@event="handler"` binds.

- [ ] **Step 2: Add the handler near the existing `handleKanbanRequestRenameColumn`**

Find an appropriate spot in `<script setup>` (next to `handleKanbanRequestRenameColumn`, which is around line 639-646) and add:

```ts
/**
 * Forward a kanban rename (from either the Settings dialog header
 * pencil or the KanbanView header pencil) to the store. Both
 * children emit `rename-item` with the trimmed new name; the
 * store action optimistic-updates + rolls back on error.
 *
 * Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md
 */
const handleKanbanRenameItem = (newName: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanItemName(ws.id, activeWorkspaceItem.value.id, newName)
}
```

- [ ] **Step 3: Bind `@rename-item` on both `<KanbanView>` and `<KanbanSettingsDialog>` elements**

For the `<KanbanView>` element, add `@rename-item="handleKanbanRenameItem"`. For the `<KanbanSettingsDialog>` element, add the same bind. The two children can each emit the same event upward and one handler serves both.

- [ ] **Step 4: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/AppLayout.vue
git commit -m "feat(desktop): AppLayout forwards kanban rename to workspacesStore"
```

### Task 3.4: Add frontend tests for the rename path

**Files:**
- Modify: `src/apps/desktop/src/__tests__/KanbanSettingsDialog.spec.ts`
- Modify: `src/apps/desktop/src/__tests__/KanbanView.spec.ts`
- Modify: `src/apps/desktop/src/__tests__/kanbanStore.spec.ts`

- [ ] **Step 1: Add `KanbanSettingsDialog` rename test**

Append to `src/apps/desktop/src/__tests__/KanbanSettingsDialog.spec.ts`:

```ts
describe('KanbanSettingsDialog rename pencil', () => {
  it('emits renameItem with the new name when the header pencil saves', async () => {
    const wrapper = mount(KanbanSettingsDialog, {
      props: { show: true, item: baseItem },
      attachTo: document.body,
    })
    // Click the header display to enter edit mode.
    await wrapper
      .find('[data-testid="kanban-settings-rename-display"]')
      .trigger('click')
    await flushPromises()
    // Edit the value + click Save.
    await wrapper
      .find('[data-testid="kanban-settings-rename-input"]')
      .setValue('Sprint 13')
    await wrapper
      .find('[data-testid="kanban-settings-rename-save"]')
      .trigger('click')
    const emitted = wrapper.emitted('renameItem')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['Sprint 13'])
    wrapper.unmount()
  })
})
```

- [ ] **Step 2: Add `KanbanView` rename test**

Append to `src/apps/desktop/src/__tests__/KanbanView.spec.ts`:

```ts
describe('KanbanView inline rename', () => {
  it('emits rename-item with the new name when the header pencil saves', async () => {
    const item = makeItem({ name: 'Sprint 12' })
    const wrapper = mountView(item)
    // Click the header display to enter edit mode.
    const itemId = item.id
    await wrapper
      .find(`[data-testid="kanban-view-${itemId}-rename-display"]`)
      .trigger('click')
    await flushPromises()
    // Edit + save.
    await wrapper
      .find(`[data-testid="kanban-view-${itemId}-rename-input"]`)
      .setValue('Sprint 13')
    await wrapper
      .find(`[data-testid="kanban-view-${itemId}-rename-save"]`)
      .trigger('click')
    const emitted = wrapper.emitted('renameItem')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['Sprint 13'])
    wrapper.unmount()
  })

  it('renders the item name in an InlineEditableText by default', () => {
    const item = makeItem({ name: 'Sprint 12' })
    const wrapper = mountView(item)
    const itemId = item.id
    expect(
      wrapper.find(`[data-testid="kanban-view-${itemId}-rename-value"]`).text(),
    ).toBe('Sprint 12')
    wrapper.unmount()
  })
})
```

Note: the existing `KanbanView.spec.ts` imports `flushPromises` from `@vue/test-utils` — add it to imports if missing.

- [ ] **Step 3: Add `workspacesStore.updateKanbanItemName` tests**

Append to `src/apps/desktop/src/__tests__/kanbanStore.spec.ts`:

```ts
describe('updateKanbanItemName', () => {
  it('calls api.updateWorkspaceItem with the new name and updates the local store', async () => {
    const store = useWorkspacesStore()
    await store.loadWorkspaces()
    const ws = store.workspaces[0]
    const item = ws.items[0]
    item.name = 'Old Name'
    const spy = vi.spyOn(api, 'updateWorkspaceItem').mockResolvedValueOnce({
      ...item,
      name: 'New Name',
    })
    await store.updateKanbanItemName(ws.id, item.id, 'New Name')
    expect(spy).toHaveBeenCalledWith(ws.id, item.id, { name: 'New Name' })
    expect(item.name).toBe('New Name')
    spy.mockRestore()
  })

  it('rolls back the local name and rethrows when the API fails', async () => {
    const store = useWorkspacesStore()
    await store.loadWorkspaces()
    const ws = store.workspaces[0]
    const item = ws.items[0]
    item.name = 'Old Name'
    const spy = vi
      .spyOn(api, 'updateWorkspaceItem')
      .mockRejectedValueOnce(new Error('boom'))
    await expect(
      store.updateKanbanItemName(ws.id, item.id, 'New Name'),
    ).rejects.toThrow('boom')
    // Optimistic update was rolled back.
    expect(item.name).toBe('Old Name')
    spy.mockRestore()
  })
})
```

Note: the `workspacesStore` typically has a `loadWorkspaces()` setup; the existing test patterns in this file already populate `store.workspaces`. Mirror the existing fixture setup (use whatever helper makes the existing `updateKanbanColumn` tests pass).

- [ ] **Step 4: Run frontend tests + build**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run InlineEditableText KanbanSettingsDialog KanbanView kanbanStore 2>&1 | tail -n 20`
Expected: all tests pass (8 new + 4 store + 4 dialog + 3 view).

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/__tests__/KanbanSettingsDialog.spec.ts \
        src/apps/desktop/src/__tests__/KanbanView.spec.ts \
        src/apps/desktop/src/__tests__/kanbanStore.spec.ts
git commit -m "test(desktop): cover kanban rename pencil + store optimistic update"
```

---

## Chunk 4: End-to-end smoke test + final verification

> Final chunk: verify all pieces work together (backend + frontend) and commit the regression test.

### Task 4.1: Run the full Zig test suite + install:linux build

- [ ] **Step 1: Run the full test suite**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 10`
Expected: all tests pass. Test count grows by 3 (the 3 new static-contract tests in `workspace_items_update_name_test.zig`).

- [ ] **Step 2: Run the install:linux build to verify the binary compiles**

Run: `timeout 240 zig build install:linux:system 2>&1 | tail -n 15`
Expected: 4/6 steps succeed (the cp to /usr/local/bin/nalar fails harmlessly with "Permission denied"). The crucial step "compile exe nalar" must succeed with no errors.

- [ ] **Step 3: Manual smoke test the rename end-to-end on port 8080**

> Use port 8080 (NOT 8081) — port 8081 has another `nalar` process running for the dev workflow.

```bash
# 1. Start nalar on 8080 in the background.
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080 &
echo $! > /tmp/nalar-smoke.pid
sleep 2

# 2. Substitute these for your workspace + kanban item.
WS_ID="ws_<your-workspace-id>"
ITEM_ID="item_<your-kanban-item-id>"

# 3. Verify the current name.
curl -sS "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${ITEM_ID}" \
  | jq '.item.name'

# 4. PUT a new name via the rename path.
curl -sS -X PUT "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${ITEM_ID}" \
  -H "Content-Type: application/json" \
  -d '{"name":"Sprint 13"}' \
  | jq .

# 5. Re-fetch and confirm the new name persisted.
curl -sS "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${ITEM_ID}" \
  | jq '.item.name'
# Expected: "Sprint 13"

# 6. Try the rejection path — empty string should 400.
curl -sS -X PUT "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${ITEM_ID}" \
  -H "Content-Type: application/json" \
  -d '{"name":""}' \
  -w "\nHTTP %{http_code}\n"
# Expected: "name must be a non-empty string when present" with HTTP 400

# 7. Stop nalar.
kill "$(cat /tmp/nalar-smoke.pid)"
rm /tmp/nalar-smoke.pid
```

Expected: step 5 prints `"Sprint 13"`; step 6 prints the error message + HTTP 400.

### Task 4.2: Run the full frontend type-check + test suite

- [ ] **Step 1: Run `bun run build` (vue-tsc + bundle)**

Run: `cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 15`
Expected: clean build. 0 TypeScript errors.

- [ ] **Step 2: Run the full Vitest suite**

Run: `cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 15`
Expected: all tests pass. Test count grows by 15 (8 InlineEditableText + 1 KanbanSettingsDialog + 2 KanbanView + 2 kanbanStore + 1 + 1 stub - some tests are removed/updated by the API change so the delta may be ±2).

- [ ] **Step 3: Manual UI smoke test (use `bun run dev` against port 8080 nalar)**

```bash
# 1. Start nalar on 8080 in the background.
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080 &
echo $! > /tmp/nalar-dev.pid
sleep 2

# 2. Start the Vite dev server.
cd src/apps/desktop
bun run dev &
echo $! > /tmp/vite-dev.pid
sleep 5

# 3. In nalar_browser:
#    a. Navigate to http://localhost:5173/ and open a kanban view.
#    b. Click the pencil next to the kanban name in the header
#       (or open Settings first).
#    c. Edit the name → press Enter (or click Save).
#    d. Confirm:
#       - The new name appears in the kanban header.
#       - The sidebar (WorkspaceItem) shows the new name.
#       - The Settings dialog subtitle shows the new name.
#       - Re-fetch /api/workspaces/.../items/<id> in DevTools confirms DB write.

# 4. Stop both processes.
kill "$(cat /tmp/nalar-dev.pid)"
kill "$(cat /tmp/vite-dev.pid)"
rm /tmp/nalar-dev.pid /tmp/vite-dev.pid
```

Expected: rename succeeds in both directions (settings dialog header AND kanban view header); sidebar updates immediately; backend persists; reload restores the new name.

### Task 4.3: Move the task to done on the kanban board

After all smoke tests pass, call `kanban_move_task` to move `task_1782730149654` from `in progress` to `done`.

---

## Verification

After all chunks land:

```bash
# Backend
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 240 zig build test --summary all 2>&1 | tail -n 5
# Expected: "test success"; test count grows by 3.

timeout 240 zig build install:linux:system 2>&1 | tail -n 15
# Expected: 4/6 steps succeed; the binary at zig-out/bin/nalar is rebuilt.

# Frontend
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 5
# Expected: clean build; 0 TypeScript errors.

timeout 180 bunx vitest run 2>&1 | tail -n 5
# Expected: all tests pass; test count grows by 15+.
```

End-to-end manual smoke test (per Task 4.1 step 3 + 4.2 step 3) confirms:
- The PUT endpoint writes the new name to the DB.
- Empty/null name returns 400 with the error message.
- The frontend pencil in both locations (kanban view header + settings dialog header) swaps to edit mode → saves → updates the UI optimistically → backend persists.
- Sidebar `WorkspaceItem.vue:398` reflects the new name immediately (same Pinia store).

---

## Plan Review Loop

After completing each chunk:

1. Dispatch a sub-agent for plan-document-review with the chunk content
2. If ❌ Issues Found: fix them in this plan, re-dispatch reviewer
3. Repeat until ✅ Approved
4. Proceed to next chunk

**Chunk boundaries:** Chunks 1-4 are ≤1000 lines each and logically self-contained. Chunk 1 is pure backend; Chunk 2 is frontend infrastructure + the reusable `InlineEditableText` primitive; Chunk 3 is the user-facing UX wiring into both the Settings dialog and KanbanView; Chunk 4 is end-to-end verification.

---

## Execution Handoff

After all chunks are approved:

**"Plan complete and saved to `docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md`. Ready to execute?"**

**Execution path:** This codebase uses `superpowers:subagent-driven-development` (per the project memory `nalar-core`). Use the existing sub-agent infrastructure to spawn one sub-agent per task with two-stage review. Each sub-agent gets the specific task content + the project memory files + the relevant pre-loaded skills (`zig-expert`, `desktop-frontend-build`).
