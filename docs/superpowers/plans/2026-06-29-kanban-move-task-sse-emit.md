# Kanban Move Task — SSE Event Not Emitted on LLM Tool Path

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the AI agent invokes the `kanban_move_task` tool, emit a `kanban_task` SSE event so connected KanbanView clients refresh their cards. Today the LLM tool moves the row in the DB but the SSE event is **never published**, so the frontend SSE stream shows only `event: connected` + `data: ping` heartbeats — no `kanban_task` events.

**Architecture:** One surgical change in the LLM tool — mirror the existing emit call in the HTTP handler `tasks_move.zig:105-117`. No new modules, no schema changes, no frontend changes.

**Spec / context:**
- User report (2026-06-29): Screenshot of DevTools Network → EventStream on `/api/kanban/events`. The stream shows:
  - `event: connected` / `data: {"connected": true}` (one-time)
  - `data: ping` (heartbeats)
  - **No `kanban_task` events**, even after invoking `kanban_move_task` from the chat.
- Related (but NOT the fix): `docs/superpowers/plans/2026-06-27-kanban-sse-auto-move.md` is a separate frontend plan for the case where events DO arrive but the handler ignores task events. **That plan only becomes reachable once this plan's SSE emit is wired.** Both plans are still needed; this one is the upstream prerequisite.
- Task: `move-task-in-progress-test` (workspace `ws_1779002584293_e52cd134532e1f00`, kanban board item `item_1782442554104741821`).

---

## Context

### Root cause

**The LLM tool `kanban_move_task` at `src/modules/agent/tools/kanban_move_task.zig:318-327` calls `kanban_model.moveTask` but does NOT call `onEventSendKanbanTask`.** Compare with the parallel HTTP handler at `src/ai_workflow/tui/http_handlers/tasks_move.zig:92-117`, which calls BOTH:

```zig
// tasks_move.zig:92-117 (HTTP handler — EMITS the event ✅)
kanban_model.moveTask(allocator, sqlite_db, item_id, task_id, parsed.column_id, parsed.position) catch {
    return res.jsonResponse(.{ .status_code = 500, ... });
};

on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
    .action = "moved",
    .workspace_id = ws_id,
    .item_id = item_id,
    .task_id = task_id,
    .new_column_id = parsed.column_id,
    .new_position = parsed.position,
}) catch |err| {
    std.log.warn("tasks_move: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
};
```

vs.

```zig
// kanban_move_task.zig:316-327 (LLM tool — DOES NOT EMIT ❌)
nalarcore.ai_mod.kanban_model.moveTask(
    allocator, db,
    input.item_id, input.task_id,
    target_column_id, position,
) catch |err| {
    return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: moveTask failed: {s}", .{@errorName(err)}));
};
// ← NO onEventSendKanbanTask call here
```

The LLM tool was added in a follow-up commit to the SSE PR #38, and the SSE emit step was simply forgotten.

### Why this was never caught

- The HTTP path (`PATCH /api/.../tasks/:task_id/move`) emits correctly. Drag-and-drop in the open KanbanView works because the frontend optimistically updates locally and the HTTP handler emits the broadcast for sibling tabs.
- The LLM tool path runs through the AI agent's tool dispatcher. The only verification we had was that the DB row changed — verified by reading the column id back after `moveTask` succeeded (line 332). The SSE emission is a side-effect that wasn't tested.
- A static source-check test in `kanban_events_sse_test.zig` asserts the HTTP handler subscribes to `"kanban_task"`, but no equivalent check exists for the LLM tool. This plan adds one.

### What's already in place

- `src/ai_workflow/tui/on_event_sent_kanban.zig:131-150` — `onEventSendKanbanTask` is fully implemented. Takes an allocator and a `KanbanTaskEventPayload`. Self-contained: calls `nalarcore.getSingleton()` internally to fetch the `event_bus`. No state plumbing needed at the call site.
- `nalarcore.ai_mod.on_event_sent_kanban` is re-exported from `src/ai_workflow/tui/mod.zig:9`. The LLM tool already imports `nalarcore` at line 4, so the call site is one import line away.
- `event_bus.emit` is a no-op when no subscriber is registered (`on_event_sent_kanban.zig:103,148`), so the existing tests that don't stand up an SSE server still pass.

### What this plan does NOT change

- No change to the SSE handler (`kanban_events_sse.zig`) — it already subscribes to `"kanban_task"` correctly.
- No change to the frontend — the existing frontend plan (`2026-06-27-kanban-sse-auto-move.md`) is the separate task that wires `kanban_task.*` events to `fetchKanbanTasks`. This plan's emit makes that plan's frontend work actually fire.
- No change to `kanban_model.moveTask` — the model is pure DB. The SSE emit is the caller's responsibility (matching the existing pattern).
- No new module — the LLM tool imports `nalarcore.ai_mod.on_event_sent_kanban` directly.

### Out of scope

- `kanban_create_column`, `kanban_update_column`, `kanban_delete_column` SSE emit checks — those LLM tools are also missing SSE emits (they all call `kanban_model.*` without emitting). This plan is intentionally narrow (move task only) because the bug report is move-specific. A follow-up plan can cover the column-emit parity.
- Switching the LLM tool path through the same HTTP handler (would unify the two paths). Out of scope — the HTTP handler is an HTTP-shaped function; it expects `req`/`res` and returns an HTTP response, which the tool dispatcher doesn't have. The current parallel paths are intentional.

---

## Defaults locked by this plan

1. **Where the emit goes:** inside `executeKanbanMoveTaskToString` (the LLM tool's entry point), immediately after the successful `kanban_model.moveTask` call. NOT inside `kanban_model.moveTask` (model stays pure).
2. **Emit policy:** fire on success only. Do NOT emit on validation errors (missing field, column not found, TaskNotFound) — no row was moved, no client should refresh.
3. **Failure handling:** SSE emit errors are non-fatal — log at warn level, return the success XML to the LLM. This mirrors `tasks_move.zig:112-117` exactly.
4. **Action string:** `"moved"`. Matches the frontend's `KanbanTaskEvent` union (`docs/superpowers/plans/2026-06-27-kanban-sse-auto-move.md:434-440`).
5. **Payload shape:** match the HTTP handler's payload verbatim: `action`, `workspace_id`, `item_id`, `task_id`, `new_column_id`, `new_position`. No new fields.
6. **`new_column_id` semantics:** the resolved column id (after the `target_column_name` → `target_column_id` fallback in lines 248-271). The variable is in scope at the emit site as `target_column_id`.
7. **`new_position` semantics:** the resolved position (after the `position` → `MAX+1` fallback in lines 303-312). The variable is in scope at the emit site as `position`.

---

## Chunk 1: Emit the SSE event from `kanban_move_task.zig`

**Goal:** When `executeKanbanMoveTaskToString` succeeds, publish a `kanban_task` event with action `"moved"` to the global `event_bus` so the frontend SSE handler (`kanban_events_sse.zig:86-90`) fans it out to connected clients.

**Files touched:**
- `src/modules/agent/tools/kanban_move_task.zig` (modify — add one emit call + one log statement)
- `src/modules/agent/tools/kanban_move_task_test.zig` (modify — add a static regression test)

### Task 1.1: Add the SSE emit

**Files:**
- Modify: `src/modules/agent/tools/kanban_move_task.zig:316-327` (after the successful `kanban_model.moveTask` call)

- [ ] **Step 1: Insert the emit call**

Replace the current `kanban_model.moveTask` block (lines 316-327):

```zig
    // 3. Call kanban_model.moveTask — this handles the sibling
    //    renumber atomically.
    nalarcore.ai_mod.kanban_model.moveTask(
        allocator,
        db,
        input.item_id,
        input.task_id,
        target_column_id,
        position,
    ) catch |err| {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: moveTask failed: {s}", .{@errorName(err)}));
    };
```

with the version that ALSO emits the SSE event on success:

```zig
    // 3. Call kanban_model.moveTask — this handles the sibling
    //    renumber atomically.
    nalarcore.ai_mod.kanban_model.moveTask(
        allocator,
        db,
        input.item_id,
        input.task_id,
        target_column_id,
        position,
    ) catch |err| {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: moveTask failed: {s}", .{@errorName(err)}));
    };

    // 3a. Emit the `kanban_task` SSE event so connected KanbanView
    //     clients refresh their board. Mirrors the emit in
    //     `tasks_move.zig:105-117` (the HTTP drag-and-drop path) —
    //     same payload shape, same non-fatal failure semantics.
    //     The `target_column_id` and `position` here are the
    //     resolved values (after the target_column_name → id
    //     fallback at line 248 and the position-null →
    //     MAX+1 fallback at line 303). The frontend's SSE
    //     handler (kanban_events_sse.zig) fans this out to
    //     every connected client; the workspacesStore filters
    //     by workspace_id.
    //
    //     Bug history (2026-06-29): this emit was missing on the
    //     LLM tool path. Drag-and-drop worked (HTTP handler
    //     emits), AI-agent moves did not. Adding this single
    //     call closes the gap.
    nalarcore.ai_mod.on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
        .action = "moved",
        .workspace_id = input.workspace_id,
        .item_id = input.item_id,
        .task_id = input.task_id,
        .new_column_id = target_column_id,
        .new_position = position,
    }) catch |err| {
        // Non-fatal: the LLM still gets the success XML; the
        // card auto-refresh just won't fire on sibling tabs.
        // The next kanban mutation will re-emit and catch up.
        std.log.warn("kanban_move_task: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
    };
```

The new code is a pure addition — no existing line changes. `target_column_id` and `position` are already in scope at line 318 (see lines 248 and 303).

- [ ] **Step 2: Confirm the import path**

`src/modules/agent/tools/kanban_move_task.zig:4` already has:

```zig
const nalarcore = @import("nalarcore");
```

So `nalarcore.ai_mod.on_event_sent_kanban` is reachable directly. The `on_event_sent_kanban` module is re-exported from `src/ai_workflow/tui/mod.zig:9`:

```zig
pub const on_event_sent_kanban = @import("on_event_sent_kanban.zig");
```

No new imports needed.

- [ ] **Step 3: Run the existing tool tests; confirm no regressions**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

Expected: Same pass count as before (the new emit is wrapped in `catch |err| { std.log.warn(...); }`, so any failure is non-fatal and the success XML is still returned to the LLM). The static-contract tests in `kanban_move_task_test.zig` should still pass because they assert on the XML shape (which is unchanged).

- [ ] **Step 4: Run the install build; confirm compile success**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 240 zig build install:linux:system 2>&1 | tail -n 10
```

Expected: 4/6 steps succeed (the cp-to-`/usr/local/bin/nalar` step fails harmlessly with permission denied). Crucially: **no compile errors in `kanban_move_task.zig` or its dependencies**.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/tools/kanban_move_task.zig
git commit -m "fix(kanban-move-task): emit kanban_task SSE event on LLM tool path"
```

### Task 1.2: Add a static regression test

**Goal:** Lock in the fix so future refactors of `kanban_move_task.zig` can't silently remove the SSE emit again. The existing project pattern for "this file MUST call function X" is a static source-check test (see `kanban_events_sse_test.zig` for the closest analogue).

**Files:**
- Modify: `src/modules/agent/tools/kanban_move_task_test.zig` (add a new test at the end of the "Static source-check tests" block, around line 116)

- [ ] **Step 1: Add the test**

Insert after the `kanban_move_task description explains recovery on error` test (after line 116):

```zig
test "kanban_move_task.zig emits a kanban_task SSE event on success" {
    // Regression guard (2026-06-29): the LLM tool used to call
    // kanban_model.moveTask without emitting the SSE event, so the
    // /api/kanban/events stream never saw a kanban_task event when
    // the AI agent moved a task. This test fails if anyone removes
    // the emit call (e.g., a future refactor that bypasses
    // executeKanbanMoveTaskToString and inlines moveTask directly).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    // 1. Must import on_event_sent_kanban via nalarcore.
    if (!contains(source, "nalarcore.ai_mod.on_event_sent_kanban")) {
        std.debug.print(
            "!! kanban_move_task.zig does not reference nalarcore.ai_mod.on_event_sent_kanban !!\n" ++
            "   The SSE emit on the LLM tool path is missing.\n" ++
            "   See docs/superpowers/plans/2026-06-29-kanban-move-task-sse-emit.md\n",
            .{},
        );
        return error.OnEventSentKanbanImportMissing;
    }

    // 2. Must call onEventSendKanbanTask (the actual emit function).
    if (!contains(source, "onEventSendKanbanTask")) {
        std.debug.print(
            "!! kanban_move_task.zig does not call onEventSendKanbanTask !!\n" ++
            "   Add the emit call after the successful kanban_model.moveTask call.\n",
            .{},
        );
        return error.OnEventSendKanbanTaskCallMissing;
    }

    // 3. Must use the "moved" action string (matches the frontend's
    //    KanbanTaskEvent union and the HTTP handler at tasks_move.zig:106).
    if (!contains(source, ".action = \"moved\"")) {
        std.debug.print(
            "!! kanban_move_task.zig SSE emit is missing the '.action = \"moved\"' literal !!\n" ++
            "   The frontend's KanbanTaskEvent union expects action: 'moved'.\n",
            .{},
        );
        return error.MovedActionMissing;
    }

    // 4. Must include the post-move emit AFTER the moveTask call
    //    (defensive: catches the case where someone moves the emit
    //    above the moveTask, which would emit a phantom event for
    //    a move that subsequently failed). The two-line check is:
    //    kanban_model.moveTask appears BEFORE onEventSendKanbanTask
    //    in the file.
    const moveTask_offset = std.mem.indexOf(u8, source, "kanban_model.moveTask") orelse return error.MoveTaskCallMissing;
    const emit_offset = std.mem.indexOf(u8, source, "onEventSendKanbanTask") orelse return error.OnEventSendKanbanTaskCallMissing;
    if (moveTask_offset >= emit_offset) {
        std.debug.print(
            "!! kanban_move_task.zig calls onEventSendKanbanTask BEFORE kanban_model.moveTask !!\n" ++
            "   The emit must happen AFTER a successful move, not before.\n",
            .{},
        );
        return error.EmitBeforeMove;
    }
}
```

This test would have caught the bug. It asserts:
1. The module is reachable via `nalarcore.ai_mod.on_event_sent_kanban`.
2. The `onEventSendKanbanTask` function is called.
3. The action literal is `"moved"` (not `"assigned"`, `"updated"`, etc.).
4. The call order is `kanban_model.moveTask` → `onEventSendKanbanTask` (not the reverse — emitting before the move would publish phantom events on failure).

- [ ] **Step 2: Run the new test in isolation; confirm it passes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

Expected: The new test passes. If it fails, the most likely cause is that the `contains` substrings don't match the actual file — re-read the file and adjust the substrings (the goal is exact literal substring matches, not patterns).

- [ ] **Step 3: Verify the test FAILS when the emit is removed (red-green)**

To prove the test catches regressions, temporarily remove the emit call:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git stash --keep-index src/modules/agent/tools/kanban_move_task.zig
# (Or manually delete the emit block.)
timeout 180 zig build test --summary all 2>&1 | grep -E "kanban_move_task.zig emits|EmitBeforeMove|OnEventSendKanbanTaskCallMissing|MovedActionMissing|OnEventSentKanbanImportMissing"
```

Expected: The test FAILS with one of the error names listed. Restore the file:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git stash pop
```

If the stash pop conflicts (because the test file also changed), restore manually:

```bash
git checkout src/modules/agent/tools/kanban_move_task.zig
```

Re-run the tests to confirm they're green again.

- [ ] **Step 4: Commit the test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/tools/kanban_move_task_test.zig
git commit -m "test(kanban-move-task): static regression test for SSE emit on success"
```

---

## Chunk 2: End-to-end smoke test

**Goal:** Confirm the SSE event arrives on the wire when the LLM tool runs. This is the manual verification that proves the fix works against a real `nalar` instance.

### Task 2.1: Spin up nalar on port 8080

- [ ] **Step 1: Build the binary (if not already built)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```

Expected: `Build Summary: 4/6 steps succeeded`. The cp step fails with permission denied (expected — `/usr/local/bin/nalar` requires root). The binary at `zig-out/bin/nalar` is built.

- [ ] **Step 2: Start nalar on port 8080 (NOT 8081 — see Mandatory rules)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080 &
echo "PID: $!"
sleep 2
```

Expected: nalar starts on port 8080. The 8081 instance is untouched.

### Task 2.2: Smoke test the SSE event arrival

- [ ] **Step 1: Open the SSE stream in one terminal**

```bash
curl -N http://127.0.0.1:8080/api/kanban/events
```

Expected: The connection stays open; the server emits `event: connected\ndata: {...}\n\n` immediately, then `data: ping` heartbeats every ~5s.

- [ ] **Step 2: Trigger a task move via the LLM tool**

From the nalar_desktop chat UI (port 8080), open the `kanban sprint 1` chat and send:

> "Move the move-task-in-progress-test task from todo to in progress"

The AI agent will call `kanban_list` to discover the task/column ids, then call `kanban_move_task` to perform the move.

- [ ] **Step 3: Confirm the SSE event arrives**

In the curl terminal from Step 1, you should see within 1 second of the LLM tool running:

```
event: kanban_task
data: {"action":"moved","workspace_id":"ws_...","item_id":"item_...","task_id":"task_...","new_column_id":"col_...","new_position":0}
```

Before the fix, this line NEVER appears (only `data: ping`). After the fix, it appears once per move.

- [ ] **Step 4: Stop nalar**

```bash
kill $(pgrep -f "nalar --port 8080")
```

(NEVER `pkill -f "zig build run"` — would also kill the 8081 instance.)

- [ ] **Step 5: Document the smoke test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git commit --allow-empty -m "test(kanban-sse): smoke test confirms kanban_task event on LLM tool path"
```

---

## Verification

After both chunks land:

1. **Backend unit tests:** `timeout 180 zig build test --summary all` passes all existing tests + 1 new test in `kanban_move_task_test.zig`. The new test asserts the SSE emit is wired correctly.
2. **Backend compile:** `timeout 240 zig build install:linux:system` succeeds (no new compile errors; the `on_event_sent_kanban` import path is reachable from the tool's `nalarcore` import).
3. **End-to-end smoke test:** An LLM-initiated `kanban_move_task` call emits a `kanban_task` SSE event that arrives on the `/api/kanban/events` stream within 1 second. The event payload includes `action: "moved"` and the resolved `new_column_id` + `new_position`.
4. **No regressions on the HTTP path:** drag-and-drop in KanbanView (which goes through `tasks_move.zig`) continues to emit `kanban_task` events. No code in `tasks_move.zig` was changed.

---

## Risk / known limitations

- **No `kanban_create_column` / `kanban_update_column` / `kanban_delete_column` parity:** those three LLM tools (if they exist; verify before claiming) have the same "no SSE emit on LLM path" bug. This plan is narrow (move task only) because that's the reported bug. A follow-up plan can extend the same fix to those tools. To verify whether they have the bug, search for `kanban_create_column`, `kanban_update_column`, `kanban_delete_column` in `src/modules/agent/tools/` and check if they call `on_event_sent_kanban`.
- **Test only covers the success path:** the static source-check test doesn't validate that the emit is NOT called on error. The implementation correctly wraps the emit after the successful `moveTask` call, so this is enforced structurally. A future behavioral test (subscribing to event_bus + running the tool against an in-memory DB) could close the gap, but the static check is sufficient for v1.
- **Failure during emit is silent:** if `event_bus.emit` fails (e.g., singleton not initialized), the LLM still gets the success XML. The card won't auto-refresh on sibling tabs. Acceptable for v1; a future enhancement could escalate to a `std.log.err` (not just warn) for repeated failures, or surface to the LLM via the response XML.
- **No client-side filter for stale workspace_id:** the SSE event carries the chat's workspace_id; clients filter at the kanbanSse store level. If the LLM tool is invoked with an empty `workspace_id` (which it shouldn't be — the input validation at line 237 catches that), the event still fires but with `workspace_id=""`. All clients would then drop it. Not a regression; same behavior as the HTTP handler.

---

## Rollback

- **Chunk 1 (emit call):** revert the `onEventSendKanbanTask` block in `executeKanbanMoveTaskToString`. The static regression test will fail on the next `zig build test` run (so the rollback is auto-detected). The LLM tool still moves tasks correctly in the DB; only the SSE broadcast is lost.
- **Chunk 1 (test):** revert the test addition. No production behavior change.
- **Chunk 2 (smoke test):** no source changes — no rollback needed.

---

## Files to create / modify

| File | Change |
|---|---|
| `src/modules/agent/tools/kanban_move_task.zig` | Add `onEventSendKanbanTask` call after successful `kanban_model.moveTask` (Chunk 1, ~20 lines including comment) |
| `src/modules/agent/tools/kanban_move_task_test.zig` | Add static regression test asserting the emit is wired (Chunk 1, ~50 lines) |

**Total LOC estimate:**
- New code: ~20 lines (emit call + comment)
- New tests: ~50 lines (1 static regression test with 4 assertions)
- Modified code: 0 lines (pure addition)

**Related follow-up plans (NOT in this PR):**
- `docs/superpowers/plans/2026-06-27-kanban-sse-auto-move.md` — frontend wiring (`fetchKanbanTasks` action + SSE event dispatcher). Becomes reachable after this fix lands.
- (Future) `docs/superpowers/plans/2026-06-29-kanban-column-tools-sse-emit.md` — same fix for `kanban_create_column` / `kanban_update_column` / `kanban_delete_column` LLM tools (if they exist and have the same bug).