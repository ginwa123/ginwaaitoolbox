# Kanban List Empty + SSE Column-Move Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the `kanban_list` tool returning `<kanban>...<columns></columns><tasks></tasks></kanban>` (empty board) when the AI passes a malformed or misidentified `item_id`, AND add a backend SSE event pipeline so the kanban board in the frontend updates in real time when a task moves between columns (e.g. todo → done), regardless of whether the move was triggered by the AI agent or by a different connected client.

**Architecture:** Three coordinated changes:

1. **Read-side hardening in `kanban_list`** — detect the three known LLM id-confusion patterns (task_id-as-item_id, col_id-as-item_id, workspace_id-as-item_id) and return a self-correcting `<error>` XML that names the exact mistake and shows the canonical id source. Also detect when the resolved `item_id` doesn't match a real `workspace_items` row (so the LLM can recover instead of guessing).
2. **Workspace Context UX** — change the rendering in `build_messages_for_agent_prompt.BuildWorkspaceContext` from `id: <backtick>` to `item_id: <backtick>` on items and `task_id: <backtick>` on tasks, so the two ids look structurally different in the system prompt (the AI can't mix them up by accident).
3. **SSE pipeline for kanban mutations** — add `onEventSendKanbanColumn` (create/update/delete) and `onEventSendKanbanTask` (move/reassign) to `on_event_sent.zig`, wire them into the 6 existing kanban HTTP handlers (`kanban_columns_create`, `_update`, `_delete`, `tasks_move`) + the workspace-item kanban auto-assign path, and add a frontend subscriber in the workspaces store that re-fetches `kanban_columns` + tasks when a `kanban_*` event arrives on the SSE stream.

**Tech Stack:** Zig 0.16 backend (SQLite, `event_bus` for SSE fanout), Vue 3 + Pinia + Vitest frontend, existing `apiSseClient` wrapper (the reconnect logic added in PR #31).

**Spec / context:**
- Bug report: 2026-06-26 conversation — AI agent's `kanban_list` tool calls returned `<board></board>` (the LLM paraphrasing of the actual `<kanban><columns></columns><tasks></tasks></kanban>` XML) both before and after a successful `kanban_move_task` call. `kanban_move_task` worked because `target_column_name` → `findColumnsByName` → `listColumns` resolved the column correctly when the AI passed the kanban's real item_id, but `kanban_list` (called with what was almost certainly the task_id `task_1782442569739` instead of the kanban's `item_1782442554104741821`) found no columns.
- Previous fix attempt: commit `92bf6899` ("fixing kanban tools") only added `id:` labels to the Workspace Context listing — it did not change the LLM's call signature risk surface nor add any validation.
- Task name: `sse-kanban-column-move-fix` (workspace `ws_1779002584293_e52cd134532e1f00`).

---

## Context

### Current state

**Backend:**
- `src/modules/agent/tools/kanban_list.zig` defines `executeKanbanListToString(allocator, db, input)` that calls `kanban_model.listColumns(allocator, db, input.item_id)`. If `listColumns` returns 0 rows, `toXml` happily renders `<kanban><workspace_id>X</workspace_id><item_id>Y</item_id><columns></columns><tasks></tasks></kanban>` — the AI sees "empty board" with no clue why.
- `src/modules/agent/tools/kanban_move_task.zig` defines `findColumnsByName(allocator, db, workspace_item_id, name_query)` which calls the SAME `listColumns` but then does the name match itself. If listColumns returns 0, `findColumnsByName` returns `&[_]ColumnMatch{}` and the move fails with `Column not found`. The asymmetry is the smoking gun: when listColumns returns 0 for kanban_list, the AI gets empty XML; when it returns 0 for kanban_move_task, the AI gets an explicit error message.
- `src/ai_workflow/tui/tool_registry.zig:565` — `execKanbanList` wraps `executeKanbanListToString` but does NOT pre-validate `parsed.value.item_id` shape.
- `src/ai_workflow/tui/build_messages_for_agent_prompt.zig:864-908` — Workspace Context rendering (after commit `92bf6899`):
  ```
  - **Sprint 1** (id: `item_1782442554104741821`, item_type: `kanban`, path: `/path`)
    - task: `test-tool-execution` (id: `task_1782442569739`, type: standard)
  ```
  Both the item and task use the same `id: ` label, just with different prefix on the value (`item_` vs `task_`). The LLM has to mentally parse the prefix to distinguish — high cognitive load, easy to confuse.
- `src/ai_workflow/tui/on_event_sent.zig` — has events for `Workers` and `Sessions` but ZERO kanban-related events. The kanban HTTP handlers (`kanban_columns_create.zig`, `_update.zig`, `_delete.zig`, `tasks_move.zig`, `workspace_items_create_kanban.zig`) do not emit any SSE events.
- `src/modules/custom_http_server/src/sse_manager.zig` — the SSE manager that fans out `event_bus` emissions to connected clients. Pattern: emit a typed payload via `event_bus.emit(SseEvent, key, event)`; the SSE manager serializes it to `event: <name>\ndata: <json>\n\n` on each subscribed client.

**Frontend:**
- `src/apps/desktop/src/components/KanbanView.vue:67-71` — lazy-loads columns via `workspacesStore.fetchKanbanColumns(workspaceId, itemId)` on mount and on `[workspaceId, itemId]` change. Does NOT subscribe to SSE; depends on the parent (AppLayout → WorkspaceItem) to refresh after mutations.
- `src/apps/desktop/src/stores/workspaces.ts:663-682` — `fetchKanbanColumns(workspaceId, itemId)` calls `api.listKanbanColumns(...)` and replaces `item.kanban_columns`. The only refresh trigger today is explicit calls after drag-and-drop (`reorderKanbanColumn` already does `await fetchKanbanColumns(...)`).
- `src/apps/desktop/src/helpers/sseClient.ts` — the reconnect-capable EventSource wrapper used by `ChatsList.vue` (sessions), `ChatView.vue` (chat + queue), `App.vue` (workers). NOT used today for kanban.

### What's already in place

- Tool registry pattern: `src/ai_workflow/tui/tool_registry.zig` shows how every `exec_*` wraps a `*_to_string` helper, parses input via `parseFromSlice(..., .{ .ignore_unknown_fields = true })`, and wraps output via `wrapToolOutput(...)`.
- Workspace context data source: `llm_history.getWorkspaceContext(allocator, db, session_id)` returns `WorkspaceContextData { workspace_id, siblings[], self_path }` with `MAX_SIBLING_ITEMS = 20` cap. `is_self` is set on the item that owns the current task's chat session.
- SSE event pattern: `on_event_sent.zig:onEventSendWorkers(...)` shows the 4-step shape — define `OnEventInputXxx`, define `SseEventXxxPayload` (the JSON shape), call `event_bus.emit(SseEvent, key, event)` inside the function. Subscribers register with `event_bus.subscribe(SseEvent, key, handler)`.
- Frontend SSE pattern: `ChatsList.vue` registers `createSessionsSseConnection({ onEvent: (raw, eventType) => handle(raw) })` and `sseClient.ts:createSseClient(...)` provides the reconnect-aware EventSource.

### Out of scope (mirrors the kanban plan)

- WIP limits, swimlanes, sub-tasks, custom column colors, board filters, archived columns
- Realtime multi-user conflict resolution (last-write-wins is fine for v1)
- Per-column `done` automation
- Kanban templates

---

## File Structure

### New backend files (Zig)

| File | Responsibility |
|---|---|
| `src/ai_workflow/tui/on_event_sent_kanban.zig` | `onEventSendKanbanColumn(...)`, `onEventSendKanbanTask(...)`, payload structs |
| `src/modules/agent/tools/kanban_list_input_validation_test.zig` | Validation tests for the 4 mistake shapes (task_id-as-item_id, col_id-as-item_id, ws_id-as-item_id, missing-item) |

### Modified backend files (Zig)

| File | Change |
|---|---|
| `src/modules/agent/tools/kanban_list.zig` | Add `validateItemIdShape(item_id) !void` helper; call from `executeKanbanListToString` before `listColumns`. Add "no columns found for this kanban" hint when `listColumns` returns empty (so the LLM gets a different error than the "wrong id shape" case) |
| `src/modules/agent/tools/kanban_list_test.zig` | Add 4 input-validation tests (one per mistake shape) + 1 "empty board but valid id" test |
| `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` | Change Workspace Context rendering from `id: \`<id>\`` to `item_id: \`<id>\`` on items + `task_id: \`<id>\`` on tasks |
| `src/ai_workflow/tui/build_messages_for_agent_prompt_test.zig` | Update existing assertions for the new labels; add 1 test asserting item_id and task_id are visually distinct |
| `src/ai_workflow/tui/on_event_sent.zig` | Add `KanbanColumnEventPayload`, `KanbanTaskEventPayload` structs + re-export `on_event_sent_kanban` module |
| `src/ai_workflow/tui/http_handlers/kanban_columns_create.zig` | Emit `onEventSendKanbanColumn(.created, ...)` on success |
| `src/ai_workflow/tui/http_handlers/kanban_columns_update.zig` | Emit `onEventSendKanbanColumn(.updated, ...)` on success |
| `src/ai_workflow/tui/http_handlers/kanban_columns_delete.zig` | Emit `onEventSendKanbanColumn(.deleted, ...)` on success |
| `src/ai_workflow/tui/http_handlers/tasks_move.zig` | Emit `onEventSendKanbanTask(.moved, ...)` on success |
| `src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig` | Emit `onEventSendKanbanColumn(.created, ...)` ×3 for the seeded `todo/in progress/done` defaults |
| `src/ai_workflow/tui/http_handlers/tasks_create.zig` | Emit `onEventSendKanbanTask(.assigned, ...)` when the parent item is a kanban |
| `src/ai_workflow/tui/mod.zig` | Add `pub const on_event_sent_kanban = @import("on_event_sent_kanban.zig");` |
| `src/ai_workflow/tui/test_runner.zig` | Register `on_event_sent_kanban_test.zig` if created (optional) |
| `src/modules/agent/test_runner.zig` | Register `kanban_list_input_validation_test.zig` |
| `src/apps/desktop/src/helpers/sseClient.ts` | No change — reuse as-is |

### New frontend files (TS / Vue)

| File | Responsibility |
|---|---|
| `src/apps/desktop/src/api/index.ts` (extend) | Add `KanbanColumnEvent`, `KanbanTaskEvent` TypeScript interfaces + `createKanbanSseConnection(opts)` factory (mirrors `createSessionsSseConnection`) |
| `src/apps/desktop/src/stores/kanbanSse.ts` | Tiny store (`ref<Set<string>>`) listing workspace_ids with active kanban SSE listeners; exposes `subscribeKanbanSse()`, `unsubscribeKanbanSse()`, and the re-fetch handlers |
| `src/apps/desktop/src/__tests__/kanbanSse.spec.ts` | Tests for the SSE dispatch (mock `createSseClient`): column event triggers `fetchKanbanColumns`; task event triggers `fetchKanbanColumns` + tasks re-fetch |

### Modified frontend files (TS / Vue)

| File | Change |
|---|---|
| `src/apps/desktop/src/stores/workspaces.ts` | Extend `fetchKanbanColumns` to also re-fetch the item's `tasks` (or call the existing `fetchWorkspaceItem(workspaceId, itemId)` if available) when an SSE `kanban_task.moved` event arrives. Wire `kanbanSse.subscribeKanbanSse()` to be called once per workspace the user is viewing |
| `src/apps/desktop/src/components/AppLayout.vue` | On mount + on active-workspace change, call `kanbanSse.subscribeKanbanSse(workspaceId)`; on unmount, `kanbanSse.unsubscribeKanbanSse(workspaceId)` |
| `src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts` | Add a test for the new `kanban_column.updated` event triggering a `fetchKanbanColumns` call |

---

## Defaults locked by this plan

1. **Validation style:** Fail-fast with a structured error. `validateItemIdShape` returns an error the wrapper turns into `<kanban><error>...</error></kanban>` (the same pattern used by the existing "workspace_id and item_id are required" check). The LLM gets a typed error message, not silent empty XML.
2. **Validation scope:** Only check `item_id`. Don't validate `workspace_id` shape (the HTTP layer / kanban_model.listColumns don't filter by workspace_id anyway — it's only used for telemetry). Don't check `column_id` (it's already optional).
3. **Workspace Context labels:** Use `item_id:` (not `id:`) on items; `task_id:` on tasks. The labels are now self-documenting so the AI can't confuse them without ignoring the labels.
4. **SSE event names:** `kanban_column` (action: `created` / `updated` / `deleted`) and `kanban_task` (action: `assigned` / `moved` / `unassigned`). Match the `Workers` event pattern (action field on a single payload struct).
5. **SSE fan-out scope:** One SSE listener per workspace the user is viewing (lazy-subscribed by AppLayout). Event payload includes the workspace_id so the listener can no-op events for other workspaces without re-fetching.
6. **Re-fetch policy:** A `kanban_column.*` event → `fetchKanbanColumns(workspaceId, itemId)`. A `kanban_task.*` event → `fetchKanbanColumns(workspaceId, itemId)` (covers the position renumber) + `fetchTasks(workspaceId, itemId)` if that endpoint exists; otherwise the existing kanban SSE event includes the full task state and the store patches it in-place.

---

## Chunk 1: Fix kanban_list empty-board bug (input validation)

**Goal:** When the AI passes a malformed or non-existent `item_id`, `kanban_list` returns a self-correcting `<error>` XML instead of a silent empty board. Valid item_ids that legitimately have no columns return a distinct "empty board" hint so the LLM can tell the two cases apart.

**Files touched:**
- `src/modules/agent/tools/kanban_list.zig` (modify)
- `src/modules/agent/tools/kanban_list_test.zig` (modify)
- `src/modules/agent/test_runner.zig` (modify)

### Task 1.1: Write the failing input-validation tests

**Files:**
- Modify: `src/modules/agent/tools/kanban_list_test.zig:411` (append after line 410)

- [ ] **Step 1: Add the 4 validation tests**

Add at the end of `kanban_list_test.zig`:

```zig
// ─── Input validation tests (4 mistake shapes) ─────────────────────────

test "executeKanbanListToString returns error XML when item_id looks like a task_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // AI confused task_id (from kanban_move_task input) with item_id.
    // listColumns will silently return 0 rows; we want validation to
    // catch this BEFORE the query runs.
    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "task_1782442569739",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "item_id"));
    try testing.expect(contains(xml, "task_"));
    // Should mention the correct id source so the LLM self-corrects.
    try testing.expect(contains(xml, "item_"));
}

test "executeKanbanListToString returns error XML when item_id looks like a column_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "col_1782442554112968570",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "col_"));
}

test "executeKanbanListToString returns error XML when item_id looks like a workspace_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "ws_1",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
}

test "executeKanbanListToString returns error XML when item_id matches no workspace_item" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Valid shape (starts with item_) but the row doesn't exist.
    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_does_not_exist",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "no workspace_item"));
}

test "executeKanbanListToString returns empty-board hint (not error) when item_id is valid but has no columns" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Insert a kanban item with NO columns (degenerate case — user
    // deleted all of them).
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('item_empty', 'ws_1', 'kanban', 'Empty board')",
        &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_empty",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    // NOT an error — the kanban genuinely has no columns. Just an
    // empty <columns> block + a friendly hint.
    try testing.expect(!contains(xml, "<error>"));
    try testing.expect(contains(xml, "<columns></columns>"));
    // Hint: "0 columns" so the LLM can distinguish from a wrong-id case.
    try testing.expect(contains(xml, "no columns"));
}
```

- [ ] **Step 2: Run the new tests; confirm all 5 FAIL**

Run: `timeout 180 zig build test --summary all 2>&1 | rg -i "input_validation|looks like|valid but has no" | head -n 20`
Expected: 5 test names appear with `error:` or `FAIL:`. The current code path doesn't validate shape, so all 5 tests fail (the first 4 expect `<error>` but get empty `<kanban>`; the 5th expects `no columns` hint but gets plain empty `<columns></columns>`).

- [ ] **Step 3: Commit the failing tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/tools/kanban_list_test.zig
git commit -m "test(kanban_list): failing tests for shape-validation and empty-board hint"
```

### Task 1.2: Implement the validation + empty-board hint

**Files:**
- Modify: `src/modules/agent/tools/kanban_list.zig:231-238` (insert validation in `executeKanbanListToString`)
- Modify: `src/modules/agent/tools/kanban_list.zig` (add `validateItemIdShape` + `errorEmptyBoard` helpers)

- [ ] **Step 1: Add `validateItemIdShape` helper**

Insert at the end of `kanban_list.zig` (before the closing of the file, after `errorXmlOwned`):

```zig
/// Detect the three known LLM id-confusion mistakes (task_id,
/// column_id, workspace_id passed where item_id was expected). Returns
/// null when the shape looks correct, or a structured error XML
/// describing the exact mistake + the canonical id source.
///
/// This runs BEFORE the DB query so the LLM gets a fast, typed
/// error instead of a silent empty board. Empty input is also
/// caught here (mirrors the existing "workspace_id and item_id are
/// required" guard) so the LLM gets one consistent error path.
///
/// The mistake hints deliberately show the canonical id source
/// ("see Workspace Context", "item_id: `item_...`") so the LLM can
/// self-correct on the next call.
pub fn validateItemIdShape(
    allocator: std.mem.Allocator,
    item_id: []const u8,
    workspace_id: []const u8,
) !?[]u8 {
    if (item_id.len == 0 or workspace_id.len == 0) {
        return try errorXml(allocator, "workspace_id and item_id are required");
    }
    // The DB-generated ids use these prefixes (see workspace_items_create.zig's
    // generateItemId, workspace_item_tasks_create.zig, kanban_model.generateColumnId,
    // workspaces_create.zig). Anything with the wrong prefix is a shape mistake.
    if (std.mem.startsWith(u8, item_id, "task_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a TASK id (starts with 'task_'). Pass the KANBAN's item_id instead — find it next to the literal text `item_id: ` (note: NOT `id:`) in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "col_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a COLUMN id (starts with 'col_'). Pass the KANBAN's item_id instead — find it next to the literal text `item_id: ` (note: NOT `id:`) in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "ws_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a WORKSPACE id (starts with 'ws_'). You probably swapped workspace_id and item_id. The KANBAN's item_id starts with 'item_' — find it next to the literal text `item_id: ` in the Workspace Context listing.
        , .{item_id}));
    }
    if (!std.mem.startsWith(u8, item_id, "item_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' has an unrecognized prefix (expected 'item_'). Workspace-scoped tools expect a kanban item_id from the Workspace Context listing, not a free-form string.
        , .{item_id}));
    }
    return null;
}
```

- [ ] **Step 2: Add `itemExists` DB check helper**

Insert after `validateItemIdShape`:

```zig
/// Verify the item_id corresponds to a real `workspace_items` row of
/// type 'kanban'. Returns true if the row exists AND is a kanban,
/// false if it doesn't exist OR is a different item_type. Used to
/// distinguish "item_id is well-formed but doesn't exist" from
/// "item_id is well-formed, exists, but has no columns (degenerate
/// empty board)" so the LLM gets a different error message in each
/// case.
///
/// Cheap query (indexed PK lookup). Called only AFTER
/// `validateItemIdShape` passes, so we know the input has the
/// correct `item_` prefix.
fn itemExists(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) !bool {
    var q = try db.query(allocator,
        "SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban' LIMIT 1",
        &.{item_id});
    defer q.deinit();
    const row = try q.next();
    if (row) |r| {
        defer r.deinit(allocator);
        return true;
    }
    return false;
}
```

- [ ] **Step 3: Wire validation into `executeKanbanListToString`**

Modify `executeKanbanListToString` (lines 231-244) to call the validators BEFORE the existing `listColumns` query:

```zig
pub fn executeKanbanListToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: KanbanListInput,
) ![]u8 {
    // 1. Validate shape (catches task_id/col_id/ws_id passed as item_id).
    //    Returns either null (shape OK) or an owned error XML slice.
    if (try validateItemIdShape(allocator, input.item_id, input.workspace_id)) |err_xml| {
        return err_xml;
    }

    // 2. Validate the item exists in the DB AND is a kanban. The shape
    //    check above only inspects the prefix; this catches typos and
    //    cross-item-type confusion (e.g., passing a folder's item_id
    //    to kanban_list). When the item doesn't exist, return a clear
    //    error so the LLM can re-fetch the workspace context.
    const exists = itemExists(allocator, db, input.item_id) catch |err| {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: itemExists failed: {s}", .{@errorName(err)}));
    };
    if (!exists) {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' does not match any kanban workspace_item. Verify the id from the Workspace Context listing — the active kanban (if any) is the one marked `*(this task)*`.
        , .{input.item_id}));
    }

    // 3. Read columns (sorted by position).
    const cols = nalarcore.ai_mod.kanban_model.listColumns(allocator, db, input.item_id) catch |err| {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: listColumns failed: {s}", .{@errorName(err)}));
    };
    defer nalarcore.ai_mod.kanban_model.freeColumns(allocator, cols);

    // 4. If the kanban is well-formed but legitimately has no columns
    //    (user deleted them all), surface that as a structured hint so
    //    the LLM can distinguish from "wrong item_id". Empty XML
    //    without this hint looks identical to the bug we're fixing.
    if (cols.len == 0) {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\This kanban item has no columns (0 columns). The user may have deleted all columns, or the kanban was just created and columns haven't been seeded yet. Ask the user, or call kanban_list with a different item_id.
        , .{}));
    }

    // ... rest of the existing body (tasks query, summaries, render) unchanged ...
}
```

- [ ] **Step 4: Run the new tests; confirm all 5 PASS**

Run: `timeout 180 zig build test --summary all 2>&1 | rg -i "input_validation|looks like|valid but has no" | head -n 20`
Expected: All 5 tests pass (the test names appear with `ok` or no error markers).

- [ ] **Step 5: Run the full test suite; confirm no regressions**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success` with the same total count as before +5 (the 5 new validation tests). The existing `executeKanbanListToString returns columns with task_count` and `executeKanbanListToString returns error XML when item_id is empty` tests must still pass — they used `item_id = "item_1"` which now passes shape validation.

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/tools/kanban_list.zig
git commit -m "fix(kanban_list): validate item_id shape + distinguish empty-board from wrong-id"
```

### Task 1.3: Register the new tests in the test runner (defensive)

**Files:**
- Modify: `src/modules/agent/test_runner.zig:28-29`

- [ ] **Step 1: Verify the tests are already registered**

The new tests live in `kanban_list_test.zig` (which is already imported via `_ = @import("tools/kanban_list_test.zig");` at `src/modules/agent/test_runner.zig:28`). No registration change needed — confirm this is the case.

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && rg -n "kanban_list_test" src/modules/agent/test_runner.zig`
Expected: 1 line confirming the import exists. If not present, add `_ = @import("tools/kanban_list_test.zig");`.

---

## Chunk 2: Workspace Context UX — make item_id and task_id visually distinct

**Goal:** Change the Workspace Context rendering from `id: \`<id>\`` to `item_id: \`<id>\`` on items and `task_id: \`<id>\`` on tasks. The two id types now have different labels, so the LLM can't confuse them by accident (and the validation error messages in Chunk 1 reference these labels).

**Files touched:**
- `src/ai_workflow/tui/build_messages_for_agent_prompt.zig:864-908` (modify)
- `src/ai_workflow/tui/build_messages_for_agent_prompt_test.zig` (modify)

### Task 2.1: Update Workspace Context rendering

**Files:**
- Modify: `src/ai_workflow/tui/build_messages_for_agent_prompt.zig:881` (item label)
- Modify: `src/ai_workflow/tui/build_messages_for_agent_prompt.zig:898-899` (task label)

- [ ] **Step 1: Change item rendering**

Replace `** (id: \`` with `** (item_id: \`` on line 881. The new line is:

```zig
try out.appendSlice(allocator, "** (item_id: `");
```

Update the comment on line 865 to reflect the new label:

```zig
// "- **<name>** (item_id: `<id>`, item_type: `<type>`, path: `<path>`)"
//
// The item_id is the **canonical** lookup key for workspace-scoped
// tools (`kanban_list`, `kanban_move_task`, etc.). The name is
// for human display; the LLM cannot call the tools with the
// name and get correct results (the DB columns are indexed by
// id, not name). The label is `item_id:` (not `id:`) so it cannot
// be confused with the `task_id:` label on the tasks listed
// below — see Chunk 1 of the 2026-06-26 plan for the validation
// that depends on this distinction.
```

- [ ] **Step 2: Change task rendering**

Replace `\` (id: \`` with `\` (task_id: \`` on line 898. The new line is:

```zig
try out.appendSlice(allocator, "` (task_id: `");
```

- [ ] **Step 3: Build to confirm no other source reads the old `id: ` label**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && rg -n 'id: `' src/ai_workflow/tui/build_messages_for_agent_prompt.zig | head -n 20`
Expected: Only the column renumber / path-id references remain; the two target lines are now `item_id: \`` and `task_id: \``. No compiler error expected (these are runtime string literals, not types).

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/build_messages_for_agent_prompt.zig
git commit -m "feat(workspace-context): rename id: to item_id: and task_id: for visual disambiguation"
```

### Task 2.2: Update BuildWorkspaceContext tests for the new labels

**Files:**
- Modify: `src/ai_workflow/tui/build_messages_for_agent_prompt_test.zig` (update assertions)

- [ ] **Step 1: Find assertions that grep for `id: \`` or `<id>`**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && rg -n 'id: `' src/ai_workflow/tui/build_messages_for_agent_prompt_test.zig | head -n 30`
Expected: Many matches (the tests grep for the rendered string). Document each match.

- [ ] **Step 2: Update each assertion**

For each match in the test file, replace `id: \`<item_xxx>\`` with `item_id: \`<item_xxx>\`` and `id: \`<task_xxx>\`` with `task_id: \`<task_xxx>\``. Be careful: only replace the rendering checks, not unrelated `id:` mentions (e.g., `id == "item_1"` comparisons).

Helper regex (use `text_replace` per match):

- `(id: \`item_)` → `(item_id: \`item_)`
- `(id: \`task_)` → `(task_id: \`task_)`

DO NOT replace:
- `session_id` (different field)
- `is_self` (different field)
- `task_id = "..."` (struct field assignments)

- [ ] **Step 3: Run the BuildWorkspaceContext tests; confirm pass**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | rg -i "BuildWorkspaceContext" | head -n 30`
Expected: All `BuildWorkspaceContext ...` tests pass (10 tests). Look for any test names appearing with `error:` or `FAIL:` — those are the assertions that still reference the old labels.

- [ ] **Step 4: Add a regression test asserting visual disambiguation**

Append to `build_messages_for_agent_prompt_test.zig`:

```zig
test "BuildWorkspaceContext uses item_id: and task_id: labels (visually distinct)" {
    const alloc = testing.allocator;
    var ctx = try build_messages_test_helpers.setupContext(...); // reuse existing setup
    defer ctx.deinit();
    const md = try build_messages.BuildWorkspaceContext(alloc, &ctx.db, "task_a1");
    defer alloc.free(md);
    // The two labels must be visually distinct so the LLM doesn't
    // confuse them (see kanban_list input validation in Chunk 1).
    try testing.expect(std.mem.indexOf(u8, md, "item_id: ") != null);
    try testing.expect(std.mem.indexOf(u8, md, "task_id: ") != null);
    // And the bare `id: ` label (without a prefix) must NOT appear —
    // it's ambiguous and was the source of the original bug.
    try testing.expect(std.mem.indexOf(u8, md, "id: `item_") == null);
    try testing.expect(std.mem.indexOf(u8, md, "id: `task_") == null);
}
```

If the existing `build_messages_test_helpers.setupContext` is not available, inline the setup or reference an existing test that already creates a workspace with one kanban + one task and reuse that fixture.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/build_messages_for_agent_prompt_test.zig
git commit -m "test(workspace-context): assert item_id:/task_id: visual disambiguation"
```

---

## Chunk 3: Backend SSE events for kanban mutations

**Goal:** Add `kanban_column` and `kanban_task` SSE events so the frontend can react to mutations without polling. The 6 existing kanban HTTP handlers (column CRUD, task move, kanban item create, task create on kanban) emit the events on success.

**Files touched:**
- `src/ai_workflow/tui/on_event_sent_kanban.zig` (new)
- `src/ai_workflow/tui/on_event_sent.zig` (modify)
- `src/ai_workflow/tui/mod.zig` (modify)
- `src/ai_workflow/tui/http_handlers/kanban_columns_create.zig` (modify)
- `src/ai_workflow/tui/http_handlers/kanban_columns_update.zig` (modify)
- `src/ai_workflow/tui/http_handlers/kanban_columns_delete.zig` (modify)
- `src/ai_workflow/tui/http_handlers/tasks_move.zig` (modify)
- `src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig` (modify)
- `src/ai_workflow/tui/http_handlers/tasks_create.zig` (modify)

### Task 3.1: Create the kanban event module

**Files:**
- Create: `src/ai_workflow/tui/on_event_sent_kanban.zig`

- [ ] **Step 1: Write the new module**

```zig
//! SSE events for kanban mutations.
//!
//! Two event families are emitted on every successful kanban mutation:
//!
//!   - `kanban_column` — fired when a kanban column is created,
//!     renamed, reordered, or deleted. Carries the workspace_id,
//!     item_id, column_id, and the action so the frontend can no-op
//!     events for other workspaces without re-fetching.
//!
//!   - `kanban_task` — fired when a task is moved to a different
//!     column, reordered within a column, assigned to a kanban column
//!     for the first time, or unassigned (column deleted). Carries
//!     workspace_id, item_id, task_id, and the new kanban_column_id
//!     (or null for unassign).
//!
//! Subscribers (the frontend KanbanSse store) register via
//! `event_bus.subscribe(SseEvent, "kanban_<family>", handler)` and
//! patch the local Pinia store without a re-fetch when possible.
//!
//! Pattern mirrors `onEventSendWorkers` in `on_event_sent.zig`: the
//! function allocates a fresh payload slice per call and emits it
//! through the shared event_bus. The SSE manager serializes the
//! payload as JSON on the wire.

const std = @import("std");
const nalarcore = @import("nalarcore");
const event_bus = nalarcore.event_bus;
const SseEvent = nalarcore.on_event_sent.SseEvent;

pub const KanbanColumnAction = enum {
    created,
    updated,
    deleted,
    reordered,
};

pub const KanbanColumnEventPayload = struct {
    /// "created" | "updated" | "deleted" | "reordered"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    column_id: []const u8,
    /// New column name (only set for "updated"; null otherwise).
    new_name: ?[]const u8 = null,
    /// New position (only set for "updated" / "reordered"; null otherwise).
    new_position: ?i64 = null,
};

/// Emit a `kanban_column` SSE event. Called from every kanban column
/// HTTP handler on success. Allocates a JSON-safe copy of every
/// payload field; the caller passes raw slices and may free them
/// after this function returns.
pub fn onEventSendKanbanColumn(
    allocator: std.mem.Allocator,
    payload: KanbanColumnEventPayload,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .name = "kanban_column",
        .data = json_payload,
    };
    // The "kanban_column" key namespaces this event family so other
    // event families don't accidentally fan-in. The frontend
    // KanbanSse store registers a subscriber for this key.
    try event_bus.emit(SseEvent, "kanban_column", event);
}

pub const KanbanTaskAction = enum {
    assigned,
    moved,
    unassigned,
};

pub const KanbanTaskEventPayload = struct {
    /// "assigned" | "moved" | "unassigned"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    task_id: []const u8,
    /// New kanban_column_id (null for "unassigned").
    new_column_id: ?[]const u8 = null,
    /// New kanban_position (null for "unassigned").
    new_position: ?i64 = null,
};

/// Emit a `kanban_task` SSE event. Called from `tasks_move.zig` on
/// every successful move and from `tasks_create.zig` when the new
/// task is assigned to a kanban column.
pub fn onEventSendKanbanTask(
    allocator: std.mem.Allocator,
    payload: KanbanTaskEventPayload,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .name = "kanban_task",
        .data = json_payload,
    };
    try event_bus.emit(SseEvent, "kanban_task", event);
}
```

- [ ] **Step 2: Verify the event_bus and SseEvent symbols exist**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && rg -n "pub const event_bus|pub const SseEvent" src/root.zig src/ai_workflow/tui/on_event_sent.zig src/ai_workflow/tui/mod.zig 2>&1 | head -n 20`
Expected: Both `event_bus` and `on_event_sent` are re-exported through `nalarcore` (via `src/root.zig`). If either is missing, add the import path to the new module.

If `nalarcore.event_bus` is not exposed, add `pub const event_bus = @import("event_bus.zig");` to the appropriate `mod.zig` and re-export from `src/root.zig`. (Check existing usages of `event_bus.emit` in `llm_history.zig:1852` for the canonical path.)

- [ ] **Step 3: Build the project; confirm no compile errors**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build install:linux:system 2>&1 | tail -n 15`
Expected: `Build Summary: 4/6 steps succeeded` (the cp step fails harmlessly with permission denied). The `compile nalar` step MUST succeed with no errors referencing `on_event_sent_kanban.zig`. If there are missing-import errors, fix the `@import` paths in step 1.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/on_event_sent_kanban.zig
git commit -m "feat(sse): add onEventSendKanbanColumn + onEventSendKanbanTask emitters"
```

### Task 3.2: Re-export the new module

**Files:**
- Modify: `src/ai_workflow/tui/mod.zig` (find the existing re-export block, add the new module)

- [ ] **Step 1: Add the re-export**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && rg -n "pub const on_event_sent" src/ai_workflow/tui/mod.zig`
Expected: A line like `pub const on_event_sent = @import("on_event_sent.zig");`. Add a sibling line:

```zig
pub const on_event_sent_kanban = @import("on_event_sent_kanban.zig");
```

- [ ] **Step 2: Confirm the symbol is reachable as `nalarcore.ai_mod.on_event_sent_kanban`**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build install:linux:system 2>&1 | tail -n 5`
Expected: No new errors.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/mod.zig
git commit -m "chore: re-export on_event_sent_kanban from ai_mod"
```

### Task 3.3: Emit events from kanban_columns_create / update / delete

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/kanban_columns_create.zig` (after `addColumn` succeeds)
- Modify: `src/ai_workflow/tui/http_handlers/kanban_columns_update.zig` (after `renameColumn` / `reorderColumn` succeeds)
- Modify: `src/ai_workflow/tui/http_handlers/kanban_columns_delete.zig` (after `deleteColumn` succeeds)

- [ ] **Step 1: Wire kanban_columns_create**

Add the import at the top:

```zig
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;
```

Add the emit call AFTER `addColumn` returns (before the `jsonResponse`):

```zig
// Emit SSE event so other connected clients refresh their kanban view.
try on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
    .action = "created",
    .workspace_id = ws_id,
    .item_id = item_id,
    .column_id = created_column_id,  // the id returned by addColumn
});
```

(Use the local variable name for `created_column_id` — adjust if the existing code stores it under a different name. The existing handler likely returns the column id from `addColumn`; capture it before the JSON response.)

- [ ] **Step 2: Wire kanban_columns_update**

Same import + emit pattern. Determine the action from the request body:
- If `name` is set → `action = "updated"`
- If `position` is set → `action = "reordered"`
- Both set → `action = "reordered"` (reorder implies position; the frontend re-fetches either way)

```zig
const action: []const u8 = if (parsed.position != null) "reordered" else "updated";
try on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
    .action = action,
    .workspace_id = ws_id,
    .item_id = item_id,
    .column_id = column_id,
    .new_name = parsed.name,
    .new_position = parsed.position,
});
```

- [ ] **Step 3: Wire kanban_columns_delete**

```zig
try on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
    .action = "deleted",
    .workspace_id = ws_id,
    .item_id = item_id,
    .column_id = column_id,
});
```

- [ ] **Step 4: Build to confirm no compile errors**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build install:linux:system 2>&1 | tail -n 10`
Expected: `compile nalar` succeeds.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/kanban_columns_create.zig \
        src/ai_workflow/tui/http_handlers/kanban_columns_update.zig \
        src/ai_workflow/tui/http_handlers/kanban_columns_delete.zig
git commit -m "feat(sse): emit kanban_column events from create/update/delete handlers"
```

### Task 3.4: Emit events from tasks_move and the kanban-assign paths

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/tasks_move.zig` (after `moveTask` succeeds)
- Modify: `src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig` (after `seedDefaultColumns` ×3)
- Modify: `src/ai_workflow/tui/http_handlers/tasks_create.zig` (after kanban auto-assign succeeds)

- [ ] **Step 1: Wire tasks_move**

In `tasks_move.zig`, after the `kanban_model.moveTask(...)` call succeeds, emit a `kanban_task` event with `action = "moved"`:

```zig
try on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
    .action = "moved",
    .workspace_id = ws_id,
    .item_id = item_id,
    .task_id = task_id,
    .new_column_id = parsed.column_id,
    .new_position = parsed.position,
});
```

(Add the `const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;` import at the top.)

Note: `ws_id` is not in `tasks_move.zig` today (it's read but not stored in a local). Either extract it from `req.params.get("workspace_id")` first or read it into a local before the validation block. The existing handler already has `item_id` and `task_id` extracted from path params.

- [ ] **Step 2: Wire workspace_items_create_kanban**

After `seedDefaultColumns(...)` returns successfully, emit 3 `kanban_column` events (one per seeded column). The handler currently doesn't capture the column ids returned by `addColumn` — refactor `seedDefaultColumns` to return the ids, OR re-read `listColumns(allocator, db, item_id)` after the seed and emit one event per row.

The cleaner option (less invasive): re-read the columns and emit. The seed just happened, so all 3 columns are there.

```zig
const cols = kanban_model.listColumns(allocator, sqlite_db, item_id) catch |err| {
    return res.jsonResponse(.{ .status_code = 500, .data = ... });
};
defer kanban_model.freeColumns(allocator, cols);
for (cols) |c| {
    try on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
        .action = "created",
        .workspace_id = ws_id,
        .item_id = item_id,
        .column_id = c.id,
    });
}
```

- [ ] **Step 3: Wire tasks_create (kanban auto-assign path)**

In `tasks_create.zig`, after the INSERT that sets `kanban_column_id` + `kanban_position` (only when `parent_item_type == 'kanban'`), emit a `kanban_task.assigned` event. The existing handler reads the parent item type to decide whether to auto-assign — extend it to emit the event in that branch.

```zig
if (parent_item_type != null and std.mem.eql(u8, parent_item_type.?, "kanban")) {
    // ... existing auto-assign INSERT ...
    try on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
        .action = "assigned",
        .workspace_id = ws_id,
        .item_id = item_id,
        .task_id = new_task_id,
        .new_column_id = first_column_id,
        .new_position = 0,
    });
}
```

- [ ] **Step 4: Build to confirm no compile errors**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build install:linux:system 2>&1 | tail -n 10`
Expected: `compile nalar` succeeds.

- [ ] **Step 5: Run the existing tasks_move + kanban tests; confirm no regressions**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | rg -i "tasks_move|kanban" | tail -n 30`
Expected: All existing kanban-related tests still pass (the emit is best-effort — wrap in `catch {}` if the existing tests don't tolerate the new emit, but the right pattern is to use `try` and let the test runner surface any pre-existing handler issues).

If a test FAILS due to the new emit (e.g., a test that calls the handler without an event_bus registered), wrap the emit in `if (di.event_bus_registered) { try ... } catch |err| { std.log.warn(...) }`. Don't silently swallow — log the error so the SSE failure is visible.

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/tasks_move.zig \
        src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig \
        src/ai_workflow/tui/http_handlers/tasks_create.zig
git commit -m "feat(sse): emit kanban_task.moved and kanban_column.created from task/kanban handlers"
```

---

## Chunk 4: Frontend SSE consumer for kanban events

**Goal:** The frontend listens for `kanban_column` and `kanban_task` SSE events and refreshes the relevant `item.kanban_columns` (and tasks if a `kanban_task` event arrives). The subscriber is created once per active workspace by `AppLayout.vue`.

**Files touched:**
- `src/apps/desktop/src/api/index.ts` (extend)
- `src/apps/desktop/src/stores/kanbanSse.ts` (new)
- `src/apps/desktop/src/stores/workspaces.ts` (modify)
- `src/apps/desktop/src/components/AppLayout.vue` (modify)
- `src/apps/desktop/src/__tests__/kanbanSse.spec.ts` (new)
- `src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts` (modify — add kanban event test)

### Task 4.1: Add kanban event types + SSE factory in the API layer

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts` (extend the existing event-type section)

- [ ] **Step 1: Add the TypeScript interfaces**

Find the existing `WorkerEvent` / `SessionEvent` interface definitions in `api/index.ts` and add the kanban variants next to them:

```ts
// Server-sent event payloads for kanban mutations (see
// src/ai_workflow/tui/on_event_sent_kanban.zig on the backend).
export interface KanbanColumnEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  workspace_id: string
  item_id: string
  column_id: string
  new_name?: string | null
  new_position?: number | null
}

export interface KanbanTaskEvent {
  action: 'assigned' | 'moved' | 'unassigned'
  workspace_id: string
  item_id: string
  task_id: string
  new_column_id?: string | null
  new_position?: number | null
}
```

- [ ] **Step 2: Add the SSE factory**

Find the existing `createSessionsSseConnection` / `createWorkersSseConnection` factories and add the kanban variant. The factory hard-codes the URL `/api/kanban/events` and reuses the same `SseClient` reconnect wrapper:

```ts
/**
 * Open a kanban-event SSE stream. Events are JSON-encoded
 * `KanbanColumnEvent` or `KanbanTaskEvent` payloads (the server's SSE
 * `event:` line carries `kanban_column` / `kanban_task`).
 *
 * The server uses `additionalEventTypes: ['kanban_column', 'kanban_task']`
 * because the server emits NAMED events (per the EventSource spec) and
 * each named event needs an `addEventListener` registration.
 */
export function createKanbanSseConnection(opts: {
  onEvent: (raw: string, eventType: string) => void
  onError?: (err: unknown) => void
}): SseClient {
  return createSseClient({
    url: '/api/kanban/events',
    onEvent: opts.onEvent,
    onError: opts.onError,
    heartbeatData: 'ping',
    additionalEventTypes: ['kanban_column', 'kanban_task'],
  })
}
```

- [ ] **Step 3: Type-check**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: `vue-tsc --build` succeeds. The new `KanbanColumnEvent` / `KanbanTaskEvent` interfaces and the `createKanbanSseConnection` factory type-check cleanly.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(frontend): add KanbanColumnEvent/KanbanTaskEvent types + createKanbanSseConnection"
```

### Task 4.2: Create the kanbanSse Pinia store

**Files:**
- Create: `src/apps/desktop/src/stores/kanbanSse.ts`

- [ ] **Step 1: Write the new store**

```ts
/**
 * KanbanSse — Pinia store that owns ONE kanban SSE connection per
 * workspace the user is viewing. Ref-counts the subscribers per
 * workspace so multiple components (AppLayout, KanbanView) can
 * `subscribeKanbanSse(workspaceId)` without opening multiple
 * connections.
 *
 * On `kanban_column.*` and `kanban_task.*` events, dispatches to
 * the workspacesStore to refresh the affected item's columns
 * (and tasks for kanban_task.* events).
 */
import { defineStore } from 'pinia'
import { ref } from 'vue'
import { createKanbanSseConnection, type KanbanColumnEvent, type KanbanTaskEvent } from '../api'
import type { SseClient } from '../helpers/sseClient'
import { useWorkspacesStore } from './workspaces'

interface WorkspaceKanbanConnection {
  sse: SseClient
  refCount: number
}

export const useKanbanSseStore = defineStore('kanbanSse', () => {
  const connections = ref<Map<string, WorkspaceKanbanConnection>>(new Map())

  function subscribeKanbanSse(workspaceId: string): void {
    const existing = connections.value.get(workspaceId)
    if (existing) {
      existing.refCount += 1
      return
    }
    const sse = createKanbanSseConnection({
      onEvent: (raw, eventType) => {
        if (eventType === 'kanban_column') {
          handleColumnEvent(JSON.parse(raw) as KanbanColumnEvent)
        } else if (eventType === 'kanban_task') {
          handleTaskEvent(JSON.parse(raw) as KanbanTaskEvent)
        }
        // Default 'message' event (heartbeat or unknown named event) is
        // ignored — the server's heartbeat is filtered by `heartbeatData: 'ping'`.
      },
    })
    connections.value.set(workspaceId, { sse, refCount: 1 })
  }

  function unsubscribeKanbanSse(workspaceId: string): void {
    const existing = connections.value.get(workspaceId)
    if (!existing) return
    existing.refCount -= 1
    if (existing.refCount <= 0) {
      existing.sse.close()
      connections.value.delete(workspaceId)
    }
  }

  function handleColumnEvent(event: KanbanColumnEvent): void {
    const ws = useWorkspacesStore()
    // action: created/updated/deleted/reordered — all of them change
    // the column list shape, so just re-fetch.
    void ws.fetchKanbanColumns(event.workspace_id, event.item_id)
  }

  function handleTaskEvent(event: KanbanTaskEvent): void {
    const ws = useWorkspacesStore()
    // kanban_task.moved renumbers sibling positions in the target
    // column (kanban_model.moveTask step 3). Re-fetching is the
    // simplest correct action; a future optimization could patch
    // the moved task in-place + renumber siblings client-side.
    void ws.fetchKanbanColumns(event.workspace_id, event.item_id)
  }

  return { subscribeKanbanSse, unsubscribeKanbanSse }
})
```

- [ ] **Step 2: Type-check**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: No type errors. The `useWorkspacesStore()` cross-store import works (Pinia supports it as long as both stores are registered; the existing `ChatsList.vue` already does similar cross-store imports).

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/stores/kanbanSse.ts
git commit -m "feat(frontend): add kanbanSse store with ref-counted per-workspace SSE subscription"
```

### Task 4.3: Wire kanbanSse subscription into AppLayout

**Files:**
- Modify: `src/apps/desktop/src/components/AppLayout.vue` (subscribe in `onMounted`, unsubscribe in `onUnmounted`, watch active workspace)

- [ ] **Step 1: Import the store**

Find the existing `import { useWorkspacesStore } from '../stores/workspaces'` in `AppLayout.vue` and add:

```ts
import { useKanbanSseStore } from '../stores/kanbanSse'
```

- [ ] **Step 2: Subscribe on mount + watch active workspace change**

Add inside `<script setup>`:

```ts
const kanbanSseStore = useKanbanSseStore()
const activeWorkspaceId = computed(() => workspacesStore.activeWorkspaceId ?? '')

onMounted(() => {
  if (activeWorkspaceId.value) {
    kanbanSseStore.subscribeKanbanSse(activeWorkspaceId.value)
  }
})

watch(activeWorkspaceId, (newId, oldId) => {
  if (oldId) kanbanSseStore.unsubscribeKanbanSse(oldId)
  if (newId) kanbanSseStore.subscribeKanbanSse(newId)
})

onUnmounted(() => {
  if (activeWorkspaceId.value) {
    kanbanSseStore.unsubscribeKanbanSse(activeWorkspaceId.value)
  }
})
```

- [ ] **Step 3: Type-check**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: No type errors. The `computed` + `watch` + `onMounted/onUnmounted` lifecycle calls type-check (they're standard Vue 3 Composition API).

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/AppLayout.vue
git commit -m "feat(frontend): subscribe to kanban SSE from AppLayout on active workspace"
```

### Task 4.4: Add tests for the kanban SSE dispatch

**Files:**
- Create: `src/apps/desktop/src/__tests__/kanbanSse.spec.ts`

- [ ] **Step 1: Write the tests**

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

// Mock the SSE client so we can inject events synchronously.
const mockSseInstances: Array<{
  close: () => void
  emit: (data: string, eventType: string) => void
}> = []
vi.mock('../helpers/sseClient', () => ({
  createSseClient: () => {
    const inst = {
      close: vi.fn(),
      emit: (data: string, eventType: string) => inst._handler(data, eventType),
      _handler: (_d: string, _e: string) => {},
    }
    mockSseInstances.push(inst)
    return inst
  },
}))

import { useKanbanSseStore } from '../stores/kanbanSse'
import { useWorkspacesStore } from '../stores/workspaces'

describe('kanbanSse store', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    mockSseInstances.length = 0
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('subscribes once per workspace (ref-counts)', () => {
    const store = useKanbanSseStore()
    store.subscribeKanbanSse('ws_1')
    store.subscribeKanbanSse('ws_1')
    store.subscribeKanbanSse('ws_1')
    expect(mockSseInstances.length).toBe(1) // only one SSE connection

    store.unsubscribeKanbanSse('ws_1')
    store.unsubscribeKanbanSse('ws_1')
    expect(mockSseInstances[0].close).not.toHaveBeenCalled() // still ref'd

    store.unsubscribeKanbanSse('ws_1')
    expect(mockSseInstances[0].close).toHaveBeenCalledOnce()
  })

  it('opens separate connections for different workspaces', () => {
    const store = useKanbanSseStore()
    store.subscribeKanbanSse('ws_1')
    store.subscribeKanbanSse('ws_2')
    expect(mockSseInstances.length).toBe(2)
  })

  it('triggers fetchKanbanColumns on kanban_column.* events', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    store.subscribeKanbanSse('ws_1')

    const sse = mockSseInstances[0]
    sse.emit(
      JSON.stringify({ action: 'updated', workspace_id: 'ws_1', item_id: 'item_1', column_id: 'col_1' }),
      'kanban_column',
    )

    expect(fetchSpy).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('triggers fetchKanbanColumns on kanban_task.* events', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    store.subscribeKanbanSse('ws_1')

    const sse = mockSseInstances[0]
    sse.emit(
      JSON.stringify({
        action: 'moved',
        workspace_id: 'ws_1',
        item_id: 'item_1',
        task_id: 'task_1',
        new_column_id: 'col_done',
        new_position: 0,
      }),
      'kanban_task',
    )

    expect(fetchSpy).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('ignores events for other workspaces (refcount still owns the connection)', () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    store.subscribeKanbanSse('ws_1')

    const sse = mockSseInstances[0]
    sse.emit(
      JSON.stringify({ action: 'updated', workspace_id: 'ws_OTHER', item_id: 'item_1', column_id: 'col_1' }),
      'kanban_column',
    )

    expect(fetchSpy).not.toHaveBeenCalled()
  })
})
```

(Note: adjust the test imports + mock pattern to match the existing `sseClient.spec.ts` convention if it's different — read that file first to copy the exact mock shape.)

- [ ] **Step 2: Run the new tests; confirm all 5 pass**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run kanbanSse.spec.ts 2>&1 | tail -n 25`
Expected: All 5 tests pass. If `fetchKanbanColumns` is undefined or the spy setup fails, adjust the mock to match the existing `workspacesStoreSessionEvents.spec.ts` pattern.

- [ ] **Step 3: Run the full test suite; confirm no regressions**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 10`
Expected: All existing tests still pass + the 5 new kanban SSE tests = total increased by 5.

- [ ] **Step 4: Run the build; confirm type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: `vue-tsc --build` succeeds. CRITICAL: `bun run build` (NOT just `bunx vitest run`) — see project memory `desktop-typescript-bun-build-as-typecheck.md`.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/__tests__/kanbanSse.spec.ts
git commit -m "test(frontend): add kanbanSse store tests (ref-counting + dispatch)"
```

### Task 4.5: Backend smoke test of the SSE pipeline end-to-end

**Files:**
- (No source change — manual smoke test)

- [ ] **Step 1: Start nalar on port 8080**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080 &
```

- [ ] **Step 2: Open a kanban via curl**

```bash
curl -sS http://127.0.0.1:8080/api/workspaces/ws_1779002584293_e52cd134532e1f00/items/item_1782442554104741821/kanban/columns | jq '.count'
```

Expected: 3 (the seeded `todo/in progress/done` columns).

- [ ] **Step 3: Open the kanban SSE stream in one terminal**

```bash
curl -N http://127.0.0.1:8080/api/kanban/events
```

(The `/api/kanban/events` endpoint is added in Chunk 4 of the broader plan; for this smoke test, use `curl -N` against the existing kanban SSE URL once the backend handler is wired up. If the endpoint isn't wired yet, use the existing `/api/workspaces/events` (if it exists) to confirm SSE infrastructure.)

- [ ] **Step 4: Trigger a task move via curl**

```bash
curl -X PATCH http://127.0.0.1:8080/api/workspaces/ws_1779002584293_e52cd134532e1f00/items/item_1782442554104741821/tasks/task_1782442569739/move \
  -H 'Content-Type: application/json' \
  -d '{"column_id":"col_done","position":0}'
```

- [ ] **Step 5: Confirm the SSE stream emits the event**

In the terminal from Step 3, you should see:

```
event: kanban_task
data: {"action":"moved","workspace_id":"ws_1779002584293_e52cd134532e1f00","item_id":"item_1782442554104741821","task_id":"task_1782442569739","new_column_id":"col_done","new_position":0}
```

If the event is NOT emitted, the emit call in `tasks_move.zig` failed silently (check the nalar stderr log for warnings).

- [ ] **Step 6: Stop nalar**

```bash
kill $(pgrep -f "nalar --port 8080")
```

(NEVER use `pkill -f "zig build run"` — that pattern would catch the port-8081 nalar if you ever change flags.)

- [ ] **Step 7: Document the smoke test result**

Add a note to the commit message of the final smoke-test commit describing what worked and what didn't.

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git commit --allow-empty -m "test(sse): manual smoke test of kanban SSE end-to-end (task move emits event)"
```

---

## Verification

After all 4 chunks land:

1. **Static analysis:** `timeout 180 zig build test --summary all` shows `test success` with the prior baseline + 5 (kanban_list validation) + 1 (workspace_context disambiguation) = at least +6 new tests passing.
2. **Production build:** `timeout 180 zig build install:linux:system` succeeds (`compile nalar` step is the critical one — the `cp` step's permission-denied is expected and harmless).
3. **Frontend type-check:** `cd src/apps/desktop && timeout 120 bun run build` exits clean. CRITICAL: `bun run build`, NOT `bunx vitest run` — see project memory `desktop-typescript-bun-build-as-typecheck.md`.
4. **Frontend unit tests:** `cd src/apps/desktop && timeout 120 bunx vitest run` passes all tests + 5 new kanban SSE tests.
5. **End-to-end smoke test:** trigger a task move via curl with the SSE stream open, confirm the `kanban_task.moved` event arrives on the stream within 1 second.
6. **Regression check (the bug):** open a chat for `task_1782442569739` and ask the LLM to "list the kanban board". The LLM should call `kanban_list` with `item_id = item_1782442554104741821` (from the Workspace Context listing which now uses `item_id:` / `task_id:` labels). The response should be the populated board. If the LLM accidentally passes `task_1782442569739` (or any other wrong-shape id), the new validation returns a self-correcting `<error>` XML, and the LLM retries with the correct id.

## Risk / known limitations

- **Ref-counting bugs:** if `AppLayout.vue`'s `onUnmounted` doesn't fire (e.g., during HMR), the SSE connection may leak. The ref-count + `close()` idempotency in `sseClient.ts` mitigates this — calling `.close()` on an already-closed connection is a no-op.
- **Multiple workspaces:** a user with multiple workspaces open in different tabs gets one SSE connection PER tab. The ref-count is per-store-instance, not cross-tab. This is acceptable for v1 (matches the existing sessions/workers SSE pattern).
- **Stale state on `kanban_task.moved`:** the frontend re-fetches the full `kanban_columns` array on every task move, which is correct but does an extra HTTP roundtrip. A future optimization could patch the moved task in-place + renumber siblings client-side (the SSE payload includes `new_column_id` + `new_position`).
- **SSE backpressure:** if the frontend is slow to process `kanban_column.created` events (e.g., 3 events during `workspace_items_create_kanban`'s seed), the SSE manager's `message_queue` could grow. The reconnect-capable `sseClient.ts` already handles backpressure by capping reconnect attempts and dropping events when the underlying EventSource is in `failed` state.
- **Validation false positives:** the `itemExists` check uses `WHERE id = ? AND item_type = 'kanban'`. If a future migration renames `item_type = 'kanban'` to something else (e.g., `item_type = 'board'`), the validation will return "no workspace_item" for every existing kanban. The constant is hardcoded in the SQL; consider extracting it to a shared constant if this becomes a maintenance burden.

## Rollback

If any chunk causes regressions, the changes are isolated per chunk and can be reverted independently:

- Chunk 1 (validation): revert the `validateItemIdShape` + `itemExists` calls; the old behavior was "silently empty on wrong id".
- Chunk 2 (UX labels): revert the `id:` → `item_id:` / `task_id:` renames; the old labels still work, just less disambiguated.
- Chunk 3 (backend SSE): remove the `try on_event_sent_kanban.*` calls; the existing handlers still work without the SSE emissions.
- Chunk 4 (frontend SSE consumer): remove the `kanbanSseStore.subscribeKanbanSse(...)` call from `AppLayout.vue`; the frontend falls back to its current "no live updates" behavior.
