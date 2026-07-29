# [Agent Tool: `create_kanban_task`] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an LLM-callable agent tool `create_kanban_task` that creates a new `workspace_item_tasks` row under an existing kanban `workspace_item`. The tool validates that the parent item has `item_type='kanban'`, auto-assigns the task to the first column at `MAX(kanban_position) + 1` (matching the existing `task_create.zig::createStandardTask` behavior), emits a `kanban_task` SSE event with `action="created"`, and returns the new task's id + assigned column to the LLM. Mirrors the existing `kanban_list` / `kanban_move_task` pattern (read DB directly via `nalarcore.ai_mod.*_model` helpers, never go through HTTP).

**Architecture:**

1. **NEW** `src/modules/agent/tools/create_kanban_task.zig` — defines `CreateKanbanTaskInput` struct, the `create_kanban_task_tool` AgentTool definition, and the `executeCreateKanbanTaskToString(allocator, db, input)` function that returns an XML string for the LLM. Follows the exact same shape as `kanban_list.zig` / `kanban_move_task.zig` (single tool file, single `xmlEscape` helper, `successXml` / `errorXml` / `errorXmlOwned` triplet).

2. **NEW** `src/ai_workflow/tui/agentic_loop/tools_exec_create_kanban_task.zig` — the standard wrapper that parses input via `std.json.parseFromSlice` (NOT `parseFromSliceLeaky`, matching the other `tools_exec_*.zig` files), calls `executeCreateKanbanTaskToString`, wraps the result via `wrapToolOutput`, detects `<error>` substring → returns `ToolExecResult` with `output_allocated = true`.

3. **EDIT** `src/ai_workflow/tui/agentic_loop/tools.zig` — add `pub const execCreateKanbanTask = @import("tools_exec_create_kanban_task.zig").execCreateKanbanTask;` in the existing `tools_exec_*.zig` re-export block.

4. **EDIT** `src/ai_workflow/tui/agentic_loop/tool_registry.zig` — add `const create_kanban_task_mod = nalar_mod.create_kanban_task;` to the imports, and register the tool in `UNIFIED_TOOL_REGISTRY` next to the existing `kanban_list` / `kanban_move_task` entries.

5. **EDIT** `src/modules/agent/tools/mod.zig` — add the `create_kanban_task` re-export so `nalar_mod.create_kanban_task` resolves from `tool_registry.zig`. Verify the existing `pub const kanban_list = ...` pattern and mirror it.

6. **NEW** `src/modules/agent/tools/create_kanban_task_test.zig` — 6-8 tests: tool definition shape (name, description, required fields, schema), `executeCreateKanbanTaskToString` happy path (returns `<kanban_task><success>true</success><task_id>...</task_id><column_id>...</column_id><position>...</position></kanban_task>`), missing workspace_id / item_id / name → `<error>`, parent item is not a kanban → `<error>`, parent has zero columns → `<error>` (no auto-assign possible), parent is a kanban with 3 columns → task is auto-assigned to first column at position MAX+1.

7. **EDIT** `src/modules/agent/tools/test_runner.zig` — register the new `_test.zig` import.

8. **EDIT** `src/ai_workflow/tui/test_runner.zig` — register the new `tools_exec_create_kanban_task.zig` import (via the `tools_exec_*` discovery block if it exists, else add manually next to the other `tools_exec_*` entries).

9. **EDIT** `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` — likely need to add `create_kanban_task` to the default-equipped tool list (verify by reading the file).

**Tech Stack:** Zig 0.16 (project pin), SQLite (via `nalarcore.ai_mod.llm_history.createWorkspaceItemTask` + `nalarcore.ai_mod.kanban_model.listColumns` + `nalarcore.ai_mod.on_event_sent_kanban.onEventSendKanbanTask`), OpenAI-compatible tool-calling schema (the `AgentTool` struct in `schemas.zig`).

**Decisions taken (with rationale):**

1. **Tool name = `create_kanban_task`** — follows the `kanban_*` prefix convention of `kanban_list` / `kanban_move_task`. NOT `create_task` (which would suggest general-purpose task creation, but the tool enforces the parent-is-kanban constraint). The description is explicit: "Use this when the user wants to add a new card/task to a kanban board".

2. **`column_id` is OPTIONAL with auto-assign fallback** — when the LLM omits `column_id`, the tool picks the first column by `position ASC` and appends at `MAX(kanban_position) + 1`. This matches the existing `task_create.zig::createStandardTask` behavior, so both code paths produce identical kanban state. When the LLM supplies `column_id`, the tool verifies the column belongs to the same item, then appends. (Explicit position will be supported later as a future enhancement — YAGNI for now.)

3. **`description` is OPTIONAL** — the existing `createWorkspaceItemTask` model function takes an optional `?[]const u8` description. The tool passes it through.

4. **`item_id` MUST have `item_type='kanban'`** — validated up front. This prevents the LLM from accidentally creating a task under a folder/chat/design parent (which would silently succeed at the DB layer but never render in the kanban UI). Returns `<error>` with a structured hint pointing at the canonical parent id source.

5. **No HTTP round-trip** — mirrors the existing `kanban_list` / `kanban_move_task` convention. Reads/writes DB directly via `nalarcore.ai_mod.*` helpers. The HTTP handler `task_create.zig` remains the user-facing path (frontend dialog) — the agent tool is an alternative path with identical DB-side effects.

## Global Constraints

- **Cross-platform** — every step must work on Linux, macOS, AND Windows. No `std.posix.*` direct calls; use `nalarcore.helpers.*` wrappers.
- **Zig 0.16 stdlib** — follow the existing patterns in `kanban_list.zig` (line 142-176 for `listKanbanTasks` SQLite usage). `db.query` returns a `Rows` struct; `.deinit()` is mandatory. `parseFromSlice` (not `Leaky`) is correct here because `tools_exec_*.zig` files own their parse + deinit lifetime.
- **TDD** — every implementation step is preceded by a failing test step.
- **Static-contract tests for tool surface** — the project convention for agent tools is to assert `tool_def.function.name`, `tool_def.function.description`, and `required` field via `std.mem.indexOf` on the source file. Reuse the pattern from `kanban_list_test.zig` / `kanban_move_task_test.zig`.
- **Behavioral tests for `executeCreateKanbanTaskToString`** — use `std.testing.allocator` + `setupDb()` helper (mirrors `is_session_kanban.zig::setupDb`). Seed `workspace_items` + `kanban_columns` + `workspace_item_tasks` tables, call the function, assert on the returned XML.
- **No frontend changes** — the agent tool is a backend-only feature. The existing `AddTask` UI flow is unchanged.
- **Verification before completion** — `zig build test --summary all` + `zig build install:linux:system` + `rm -rf zig-out/bin && zig build` must all pass before any task is marked complete.
- **End-to-end smoke** — final task includes a curl-based smoke test against port 8080 (NEVER 8081) to verify the tool fires via the agent loop and creates the task row in the DB.

## File Touch Map

| File | Action | Lines changed (est.) |
|---|---|---|
| `src/modules/agent/tools/create_kanban_task.zig` | NEW | ~350 |
| `src/modules/agent/tools/create_kanban_task_test.zig` | NEW | ~250 |
| `src/ai_workflow/tui/agentic_loop/tools_exec_create_kanban_task.zig` | NEW | ~55 |
| `src/ai_workflow/tui/agentic_loop/tools.zig` | EDIT | +1 |
| `src/ai_workflow/tui/agentic_loop/tool_registry.zig` | EDIT | +2 (import + registry entry) |
| `src/modules/agent/tools/mod.zig` | EDIT | +1 |
| `src/modules/agent/tools/test_runner.zig` | EDIT | +1 |
| `src/ai_workflow/tui/test_runner.zig` | EDIT | +1 |
| `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` | EDIT (verify) | +1 |

Total: ~9 files, +5 / -0 net. No DB migrations, no frontend changes, no new dependencies.

---

## Tasks

### Task 1 — Static-contract tests for the tool definition (RED)

**Goal:** Lock the wire shape (tool name, description, schema, required fields) before any code lands. The tests fail because the file doesn't exist yet.

**File:** `src/modules/agent/tools/create_kanban_task_test.zig`

- [ ] **Step 1.1** — Create the test file at `src/modules/agent/tools/create_kanban_task_test.zig` with the imports + `readSource` helper (mirror the pattern at the top of `kanban_list_test.zig` lines 1-40).
- [ ] **Step 1.2** — Add test `create_kanban_task tool is named "create_kanban_task"`: reads `src/modules/agent/tools/create_kanban_task.zig`, asserts `.name = "create_kanban_task"` substring. Expected: fails (file doesn't exist).
- [ ] **Step 1.3** — Add test `create_kanban_task tool description mentions kanban and chat session`: asserts the description string contains both "kanban" and "session" (or "task"). Expected: fails.
- [ ] **Step 1.4** — Add test `create_kanban_task tool requires workspace_id + item_id + name`: asserts `required = &.{ "workspace_id", "item_id", "name" }`. Expected: fails.
- [ ] **Step 1.5** — Add test `create_kanban_task tool description says column_id is optional`: asserts the description explicitly notes "Optional: column_id". Expected: fails.
- [ ] **Step 1.6** — Add test `create_kanban_task tool description points to the Workspace Context for ids`: asserts the description includes the canonical "## Workspace Context" hint. Expected: fails.
- [ ] **Step 1.7** — Run `timeout 180 zig build test --summary all 2>&1 | grep -E "create_kanban_task"` and confirm 0 tests pass. The 5 tests above are RED.
- [ ] **Step 1.8** — Commit: `git add src/modules/agent/tools/create_kanban_task_test.zig && git commit -m "test(create_kanban_task): red — static-contract tests for tool surface"`.

### Task 2 — Implement the tool definition (GREEN)

**Goal:** Make the static-contract tests pass.

**File:** `src/modules/agent/tools/create_kanban_task.zig`

- [ ] **Step 2.1** — Create the file at `src/modules/agent/tools/create_kanban_task.zig`. Add the standard preamble: `const std = @import("std"); const schemas = @import("schemas.zig"); const AgentTool = schemas.AgentTool; const nalarcore = @import("nalarcore"); const sqlite = nalarcore.sqlite;`.
- [ ] **Step 2.2** — Add the file-level doc comment (10-15 lines) explaining the tool's purpose, the auto-assign behavior, and the `item_type='kanban'` validation. Reference the parallel HTTP handler `task_create.zig::createStandardTask`.
- [ ] **Step 2.3** — Add `pub const CreateKanbanTaskInput = struct { workspace_id: []const u8 = "", item_id: []const u8 = "", name: []const u8 = "", description: ?[]const u8 = null, column_id: ?[]const u8 = null };` with the same default-empty pattern as `KanbanListInput`.
- [ ] **Step 2.4** — Add `pub const create_kanban_task_tool = AgentTool{ .type = "function", .function = .{ .name = "create_kanban_task", .description = "...", .parameters = .{ ... } } };` — the description MUST include: (a) the word "kanban" and "task/card", (b) "Optional: column_id" (Step 1.5 substring), (c) the "## Workspace Context" hint (Step 1.6 substring), (d) the canonical id-shape hint (matches `set_design_page.zig`'s `validateItemIdShape` pattern). The `required` array MUST be `&.{ "workspace_id", "item_id", "name" }`.
- [ ] **Step 2.5** — Run `timeout 180 zig build test --summary all 2>&1 | grep -E "create_kanban_task"` and confirm all 5 static-contract tests pass. GREEN.
- [ ] **Step 2.6** — Commit: `git add src/modules/agent/tools/create_kanban_task.zig && git commit -m "feat(create_kanban_task): add tool definition with required schema"`.

### Task 3 — Behavioral tests for `executeCreateKanbanTaskToString` (RED)

**Goal:** Lock the happy-path + error-path semantics before the implementation lands.

**File:** `src/modules/agent/tools/create_kanban_task_test.zig` (continued)

- [ ] **Step 3.1** — Add a `setupDb()` helper at the top of the test file (mirror `is_session_kanban.zig::setupDb`, lines 34-45). Returns `struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded }`.
- [ ] **Step 3.2** — Add a `seedKanbanSchema(alloc, db, item_id, with_columns)` helper that creates the 3 tables (`workspace_items`, `kanban_columns`, `workspace_item_tasks`) and inserts a kanban `workspace_items` row. When `with_columns=true`, also inserts 3 kanban columns: todo / in progress / done with positions 0/1/2.
- [ ] **Step 3.3** — Add test `executeCreateKanbanTaskToString returns success XML on happy path`: seed a kanban with 3 columns, call `executeCreateKanbanTaskToString(alloc, db, .{ .workspace_id = "ws_1", .item_id = "item_k1", .name = "new task" })`, assert the returned XML contains `<kanban_task><success>true</success><task_id>`, `<column_id>col_`, `<position>`, and `</kanban_task>`. Also assert a row was inserted into `workspace_item_tasks` (use `db.query` to verify `count(*) == 1` and the row's `kanban_column_id` is the first column id).
- [ ] **Step 3.4** — Add test `executeCreateKanbanTaskToString appends at MAX(kanban_position) + 1`: seed 3 columns and 2 existing tasks in column 1 (positions 0, 1), call the tool, assert the new task's `kanban_position == 2` in the response XML AND in the DB.
- [ ] **Step 3.5** — Add test `executeCreateKanbanTaskToString returns error when workspace_id is empty`: assert the returned XML contains `<error>workspace_id is required`.
- [ ] **Step 3.6** — Add test `executeCreateKanbanTaskToString returns error when item_id is empty`: assert the returned XML contains `<error>item_id is required`.
- [ ] **Step 3.7** — Add test `executeCreateKanbanTaskToString returns error when name is empty or whitespace-only`: assert the returned XML contains `<error>name is required` (test both `""` and `"   \t\n"`).
- [ ] **Step 3.8** — Add test `executeCreateKanbanTaskToString returns error when parent item_type is not kanban`: seed an `item_type='chat'` workspace_item, call the tool, assert the XML contains `<error>` AND the substring `item_type` or `kanban` (catches the structural error shape).
- [ ] **Step 3.9** — Add test `executeCreateKanbanTaskToString returns error when kanban has zero columns`: seed a kanban item but no `kanban_columns` rows, call the tool, assert the XML contains `<error>` and a hint about "no columns". (Catches the case where the kanban-create failed midway through column seeding.)
- [ ] **Step 3.10** — Add test `executeCreateKanbanTaskToString honors explicit column_id`: seed 3 columns, pass `.column_id = "col_2"`, assert the response XML shows `column_id == "col_2"` AND the DB row's `kanban_column_id == "col_2"`. (Catches the column-id resolution path.)
- [ ] **Step 3.11** — Add test `executeCreateKanbanTaskToString rejects column_id that doesn't belong to the item`: seed 3 columns under `item_k1`, pass `.column_id = "col_other"` (inserted under a different item), assert the XML contains `<error>`.
- [ ] **Step 3.12** — Run `timeout 180 zig build test --summary all 2>&1 | grep -E "create_kanban_task"` and confirm: 5 static-contract tests still pass; 9 behavioral tests fail (functions don't exist). RED.
- [ ] **Step 3.13** — Commit: `git add src/modules/agent/tools/create_kanban_task_test.zig && git commit -m "test(create_kanban_task): red — behavioral tests for executeCreateKanbanTaskToString"`.

### Task 4 — Implement `executeCreateKanbanTaskToString` (GREEN)

**Goal:** Make all 9 behavioral tests pass.

**File:** `src/modules/agent/tools/create_kanban_task.zig` (continued)

- [ ] **Step 4.1** — Add the `xmlEscape` helper (mirror `kanban_list.zig:115-131` exactly).
- [ ] **Step 4.2** — Add the `errorXml(allocator, error_msg)` and `errorXmlOwned(allocator, error_msg)` helpers (mirror `kanban_move_task.zig:420-454`). The XML shape is `<kanban_task><success>false</success><error>...</error></kanban_task>`.
- [ ] **Step 4.3** — Add the `successXml(allocator, task_id, name, column_id, position)` helper. XML shape: `<kanban_task><success>true</success><task_id>...</task_id><name>...</name><column_id>...</column_id><position>...</position></kanban_task>`.
- [ ] **Step 4.4** — Add the `validateItemTypeIsKanban(allocator, db, item_id)` helper: `SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban'`. Returns null on success, or an error XML string when the parent isn't a kanban (or doesn't exist). The error message includes the canonical id-shape hint (mirror `set_design_page.zig::validateItemIdShape:181-185` — "has an unrecognized prefix (expected 'item_')" pattern).
- [ ] **Step 4.5** — Add the `resolveTargetColumnId(allocator, db, item_id, input_column_id)` helper: when `input_column_id == null`, query `SELECT id FROM kanban_columns WHERE workspace_item_id = ? ORDER BY position ASC LIMIT 1` and return the id. When `input_column_id != null`, query `SELECT id FROM kanban_columns WHERE id = ? AND workspace_item_id = ?` and return the id (or error XML if the column doesn't belong to the item). Returns `?[]u8` (heap-owned, caller frees) so the caller can defer-free the allocation across the DB calls.
- [ ] **Step 4.6** — Add the `computeNextPosition(allocator, db, column_id)` helper: query `SELECT COALESCE(MAX(kanban_position), -1) + 1 FROM workspace_item_tasks WHERE kanban_column_id = ?`. Returns the next position as `i64`. Falls back to `0` on any DB error (best-effort, the existing `task_create.zig::createStandardTask` uses the same pattern).
- [ ] **Step 4.7** — Implement `executeCreateKanbanTaskToString(allocator, db, input)`:
  1. Validate `workspace_id`, `item_id`, `name` (non-empty after `std.mem.trim(u8, input.name, " \t\n\r")`).
  2. Call `validateItemTypeIsKanban`. On error, return the error XML.
  3. Generate the task id: `task_{unix_nanos}` via `helpers.unixTimestampNanos()` (same pattern as `workspace_items_create_kanban.zig:136-138`).
  4. Call `createWorkspaceItemTask(allocator, db, task_id, trimmed_name, item_id, "standard", input.description)` from `nalarcore.ai_mod.llm_history`.
  5. Call `resolveTargetColumnId` to get the target column id (auto-assign to first column, or honor the explicit one). On error, return the error XML.
  6. Call `computeNextPosition` for the target column.
  7. `UPDATE workspace_item_tasks SET kanban_column_id = ?, kanban_position = ? WHERE id = ?` to assign the kanban fields. Log + continue on error (matches `task_create.zig:408-410` non-fatal pattern).
  8. Emit the SSE event via `nalarcore.ai_mod.on_event_sent_kanban.onEventSendKanbanTask(allocator, .{ .action = "created", .workspace_id, .item_id, .task_id, .new_column_id = target_column_id, .new_position = computed_position })`. Fire-and-forget — log on error (matches `kanban_move_task.zig:344-356` pattern).
  9. Return `successXml(allocator, task_id, trimmed_name, target_column_id, computed_position)`.
- [ ] **Step 4.8** — Run `timeout 180 zig build test --summary all 2>&1 | grep -E "create_kanban_task"` and confirm all 14 tests pass (5 static-contract + 9 behavioral). GREEN.
- [ ] **Step 4.9** — Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5` and confirm the build succeeds (catches lazy-analysis errors `zig build test` misses — see `~/.config/nalar/memories/zig-build-and-test.md`).
- [ ] **Step 4.10** — Commit: `git add src/modules/agent/tools/create_kanban_task.zig && git commit -m "feat(create_kanban_task): implement executeCreateKanbanTaskToString"`.

### Task 5 — Wire up the tool exec wrapper (RED then GREEN)

**Goal:** Add the `tools_exec_create_kanban_task.zig` file that parses the LLM's tool-call arguments and returns the wrapped output.

**File:** `src/ai_workflow/tui/agentic_loop/tools_exec_create_kanban_task.zig`

- [ ] **Step 5.1** — Create the file with the standard preamble (mirror `tools_exec_kanban_list.zig:1-9` exactly):
  ```
  const std = @import("std");
  const mod = @import("mod.zig");
  const nalarcore = mod.nalarcore;
  const tools = mod.tools;
  const ToolExecContext = tools.ToolExecContext;
  const ToolExecResult = tools.ToolExecResult;
  const agent = nalarcore.agent;
  const create_kanban_task_mod = nalarcore.create_kanban_task;
  const wrapToolOutput = tools.wrapToolOutput;
  ```
- [ ] **Step 5.2** — Implement `execCreateKanbanTask(ctx, tc)` — mirror `tools_exec_kanban_list.zig:11-50` exactly:
  1. Parse `tc.function.arguments` via `std.json.parseFromSlice(CreateKanbanTaskInput, ctx.allocator, ..., .{ .allocate = .alloc_always, .ignore_unknown_fields = true })`. On parse error, return `ToolExecResult` with `wrapToolOutput(..., "create_kanban_task", ..., false, "parse input failed: {error_name}", "")`.
  2. `defer parsed.deinit()`.
  3. Call `create_kanban_task_mod.executeCreateKanbanTaskToString(ctx.allocator, ctx.db, parsed.value)`. On error, return `ToolExecResult` with `wrapToolOutput(..., "create_kanban_task", ..., false, "create_kanban_task failed: {error_name}", "")`.
  4. `defer ctx.allocator.free(inner)`.
  5. Detect `<error>` substring (mirror lines 41-47). If found, return `ToolExecResult` with `wrapToolOutput(..., "create_kanban_task", ..., false, error_msg, inner)`.
  6. Otherwise return `ToolExecResult` with `wrapToolOutput(..., "create_kanban_task", ..., true, null, inner)`.
  - [ ] **Step 5.3** — Add `pub const execCreateKanbanTask = execCreateKanbanTask;` at the end of the file (or directly make the function `pub` — match the existing pattern; check `tools_exec_kanban_list.zig:11`).
  - [ ] **Step 5.4** — Run `timeout 180 zig build test --summary all 2>&1 | grep -E "execCreateKanbanTask\|tools_exec_create_kanban_task"` — expect: no tests yet (file isn't registered). RED is implicit.
  - [ ] **Step 5.5** — Commit: `git add src/ai_workflow/tui/agentic_loop/tools_exec_create_kanban_task.zig && git commit -m "feat(create_kanban_task): add tools_exec wrapper"`.

### Task 6 — Register the tool in `tools.zig` + `tool_registry.zig` + `mod.zig` + test runners

**Goal:** Make `execCreateKanbanTask` reachable from the LLM tool-calling dispatcher.

**Files:** `src/ai_workflow/tui/agentic_loop/tools.zig`, `src/ai_workflow/tui/agentic_loop/tool_registry.zig`, `src/modules/agent/tools/mod.zig`, `src/modules/agent/tools/test_runner.zig`, `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 6.1** — `src/modules/agent/tools/mod.zig`: add `pub const create_kanban_task = @import("create_kanban_task.zig");` next to the existing `pub const kanban_list = @import("kanban_list.zig");` entry.
- [ ] **Step 6.2** — `src/modules/agent/tools/test_runner.zig`: add `_ = @import("create_kanban_task_test.zig");` next to the existing `kanban_list_test.zig` import.
- [ ] **Step 6.3** — `src/ai_workflow/tui/test_runner.zig`: add `_ = @import("agentic_loop/tools_exec_create_kanban_task.zig");` next to the existing `tools_exec_kanban_list.zig` import.
- [ ] **Step 6.4** — `src/ai_workflow/tui/agentic_loop/tools.zig`: add `pub const execCreateKanbanTask = @import("tools_exec_create_kanban_task.zig").execCreateKanbanTask;` next to the existing `pub const execKanbanList = ...` entry.
- [ ] **Step 6.5** — `src/ai_workflow/tui/agentic_loop/tool_registry.zig`: add `const create_kanban_task_mod = nalar_mod.create_kanban_task;` to the imports block (next to the existing `kanban_list_mod` import), then add the registry entry in `UNIFIED_TOOL_REGISTRY`:
  ```
  .{ .name = "create_kanban_task", .exec = agentic_loop_mod.tools.execCreateKanbanTask, .tool_def = create_kanban_task_mod.create_kanban_task_tool },
  ```
  Place it directly after the `kanban_move_task` entry so the kanban_* tools stay grouped.
- [ ] **Step 6.6** — Verify `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` — read the file and check whether tool names are listed for default-equipping. If `create_kanban_task` should be in the default kit (it should — the existing `kanban_list` and `kanban_move_task` are), add it next to those entries. If the file uses a different mechanism (e.g. wildcard-equipping all kanban_* tools), no change is needed.
- [ ] **Step 6.7** — Run `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — expect: all 14 create_kanban_task tests pass; no regressions.
- [ ] **Step 6.8** — Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5` — expect: clean build. This catches any missing export.
- [ ] **Step 6.9** — Commit: `git add -u && git commit -m "feat(create_kanban_task): register tool in registry, tools.zig, and test runners"`.

### Task 7 — Add a static-contract test that asserts the tool is registered

**Goal:** Pin the registration contract — a future refactor that drops the entry from `UNIFIED_TOOL_REGISTRY` would silently disable the tool.

**File:** `src/ai_workflow/tui/agentic_loop/tools_exec_create_kanban_task.zig` (new test file or extend `tools_exec_kanban_list_test.zig` pattern)

- [ ] **Step 7.1** — Read `src/ai_workflow/tui/agentic_loop/tool_registry_test.zig` (if it exists) or `tools_exec_kanban_list_test.zig` for the existing pattern. Mirror it.
- [ ] **Step 7.2** — Add test `tool_registry registers create_kanban_task`: reads `tool_registry.zig` source, asserts the substring `name = "create_kanban_task"` appears AND the substring `execCreateKanbanTask` appears. This catches both missing registry entries and broken import wiring.
- [ ] **Step 7.3** — Add test `tool_registry groups create_kanban_task with other kanban tools`: asserts the line `.name = "create_kanban_task"` is within ~10 lines of `.name = "kanban_move_task"` (the grouping convention).
- [ ] **Step 7.4** — Run `timeout 180 zig build test --summary all 2>&1 | grep -E "create_kanban_task\|tool_registry"` — expect both new tests pass.
- [ ] **Step 7.5** — Commit: `git add -u && git commit -m "test(create_kanban_task): pin tool registry contract"`.

### Task 8 — Frontend verification: existing `addWorkspaceItem` (task) flow is unchanged

**Goal:** Confirm that the agent tool does NOT regress the user's existing UI for creating tasks (the drag-and-drop, sidebar Add Task dialog, etc.). This is a non-code verification step.

- [ ] **Step 8.1** — Read `src/apps/desktop/src/stores/workspaces.ts` around the `addWorkspaceItem` function (or its `addTask` equivalent) and confirm it still calls `api.createTask` (NOT the new `create_kanban_task` tool). Expected: no changes needed.
- [ ] **Step 8.2** — Run `cd src/apps/desktop && timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build` and confirm no TypeScript errors (the change is backend-only so this should be a no-op, but verify).
- [ ] **Step 8.3** — Run `cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 5` and confirm frontend tests still pass (1483/1483 expected — same as `docs/SPEC.md` baseline).
- [ ] **Step 8.4** — No commit needed (verification only). If any frontend test fails, the change is incidental — investigate and fix before proceeding.

### Task 9 — End-to-end smoke test against port 8080

**Goal:** Verify the agent tool fires in the live binary via the agent loop.

- [ ] **Step 9.1** — Build the binary: `rm -rf zig-out/bin && timeout 360 zig build` (full rebuild per project memory `zig-build-and-test.md`). Confirm exit code 0.
- [ ] **Step 9.2** — Start the binary on port 8080 (NEVER 8081 — the user's dev server is on 8081):
  ```
  rm -rf /tmp/nalar-ckt-smoke && mkdir -p /tmp/nalar-ckt-smoke
  env -i HOME=/tmp/nalar-ckt-smoke PATH=$PATH \
    nohup ./zig-out/bin/nalarcore-linux-x86_64 --port 8080 \
    >/tmp/nalar-ckt-smoke.log 2>&1 &
  disown
  sleep 4
  ```
  Confirm: `ss -tln | grep 8080` shows the port is listening.
- [ ] **Step 9.3** — Create a workspace + a kanban item via HTTP (use the existing `POST /api/workspaces` and `POST /api/workspaces/:wid/items/kanban` endpoints — copy the wire shape from `tests/functional/kanban_lifecycle_test.py:_create_kanban`):
  ```
  WS=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces -H 'content-type: application/json' -d '{"name":"smoke"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
  ITEM=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/kanban" -H 'content-type: application/json' -d '{"name":"Test Sprint","path":"/tmp"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["item"]["id"])')
  ```
- [ ] **Step 9.4** — Find or create a chat session bound to this workspace (`POST /api/workspaces/:wsId/items/:itemId/tasks` with `{"name":"smoke chat","task_type":"standard"}`). Note the task id (which doubles as session_id per Migration 052).
- [ ] **Step 9.5** — Send an LLM message via the SSE stream that triggers the agent to call `create_kanban_task`. Use `POST /api/llm/session/<sid>/messages` with body `{"role":"user","content":"Please add a task called 'do the thing' to the kanban."}` and follow the SSE stream. The agent should call `create_kanban_task` (verify by tail-ing the server log for `[tool_call] name=create_kanban_task`).
- [ ] **Step 9.6** — Verify the task was created by querying the kanban's tasks: `curl -sS http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/tasks | python3 -m json.tool`. Expect: a new task named `do the thing` with `kanban_column_id` set to the first column's id and `kanban_position` >= 0.
- [ ] **Step 9.7** — Tear down: `pkill -f nalarcore-linux-x86_64` (only the port 8080 one — verify `ss -tln | grep 8081` shows the user's dev server still alive).
- [ ] **Step 9.8** — Commit (no code change in this task — only a smoke-test shell script `scripts/smoke_create_kanban_task.sh` if you want it persistent): `git add scripts/smoke_create_kanban_task.sh && git commit -m "test(create_kanban_task): end-to-end smoke script"` (only if Step 9.8 produced a file).

### Task 10 — Final verification + memory update

**Goal:** Confirm all changes pass the project's full pre-commit checklist (per `AGENTS.md`).

- [ ] **Step 10.1** — Run the project's full verification suite:
  ```
  timeout 180 zig build test --summary all 2>&1 | tail -n 5
  timeout 180 zig build install:linux:system 2>&1 | tail -n 5
  rm -rf zig-out/bin
  timeout 360 zig build 2>&1 | tail -n 5
  ```
  Expected: clean build, all tests pass (existing 1876 + new 16-18 = ~1894 total).
- [ ] **Step 10.2** — Cross-compile smoke for Windows + macOS:
  ```
  cat > /tmp/test_ckt_mod.zig <<'EOF'
  const m = @import("create_kanban_task");
  pub fn main() !void { _ = m.create_kanban_task_tool; }
  EOF
  zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
    --dep create_kanban_task \
    -Mroot=/tmp/test_ckt_mod.zig \
    -Mcreate_kanban_task=src/modules/agent/tools/create_kanban_task.zig
  zig build-obj -fno-emit-bin -target aarch64-macos -lc \
    --dep create_kanban_task \
    -Mroot=/tmp/test_ckt_mod.zig \
    -Mcreate_kanban_task=src/modules/agent/tools/create_kanban_task.zig
  ```
  Expected: both exits 0 (per project memory `zig-cross-platform.md` §"Cross-compile verification technique").
- [ ] **Step 10.3** — Update `~/.config/nalar/memories/nalar-data-and-routines.md` (or create `nalar-agent-tool-creation-pattern.md`) with the new pattern: "agent tool that creates a child resource of a workspace_item (kanban task, design element, etc.) — wrap existing model helpers + add a `create_*` tool with the same input shape as the HTTP handler's body, register in tool_registry.zig, emit the appropriate SSE event". This documents the pattern for future tools (`create_design_page` is next).
- [ ] **Step 10.4** — Run `cd src/apps/desktop && timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build` to confirm no incidental frontend regression.
- [ ] **Step 10.5** — Run `cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 5` to confirm 1483/1483 frontend tests still pass.
- [ ] **Step 10.6** — Push the branch: `git push origin <branch-name>`. Confirm CI passes (per `docs/ci.md` — the `[self-hosted, Linux, X64]` + `[self-hosted, macOS, ARM64]` matrix cells).
- [ ] **Step 10.7** — Open a PR with the standard summary. Reference this plan file in the PR description. Mark the kanban task as `merged` via `kanban_move_task(target_column_id=col_1d40fb0ea07f0000)`.

---

## Pitfalls (project-wide gotchas to remember while implementing)

1. **`std.json.parseFromSlice` vs `parseFromSliceLeaky`** — the `tools_exec_*.zig` files use `parseFromSlice` (NOT `Leaky`) because they own the parse + deinit lifetime (ToolExecContext.allocator is a per-request arena; both `parsed.deinit()` and the inner XML need to be freed before the tool returns). HTTP handlers use `parseFromSliceLeaky` because the per-request arena reaps everything.

2. **`ctx.allocator.free(inner)` before return** — `executeCreateKanbanTaskToString` allocates an XML string on `ctx.allocator`. The exec wrapper MUST `defer ctx.allocator.free(inner)` BEFORE calling `wrapToolOutput` (which would COPY the slice into the wrapped output, but the arena can still reclaim the original).

3. **`db.query` returns a `Rows` struct with `deinit()`** — every `db.query` call MUST be paired with `defer q.deinit()`. Missing this leaks the prepared statement + cursor (per `~/.config/nalar/memories/zig-sqlite-patterns.md`).

4. **`defer allocator.free(task.deinit_task_struct)` is NOT how this works** — `WorkspaceItemTaskInfo.deinit` frees its individual fields. The HTTP handler doc at `task_create.zig:362-370` warns about a use-after-free trap: do NOT `defer task.deinit(allocator)` here because the handler BORROWS the slices from the arena. For our tool, the rule is the same — `executeCreateKanbanTaskToString` returns a fresh `successXml` slice; the `task` struct from `createWorkspaceItemTask` is borrowed from the arena and does NOT need explicit free (the arena reaps it).

5. **`db.exec` binds empty `[]const u8` as NULL** — see `~/.config/nalar/memories/zig-sqlite-patterns.md` §"`SqliteBackend.exec` binds empty `[]const u8` as SQL NULL". For the description field, use the `createWorkspaceItemTask` helper (which already handles the NULL/empty distinction via the SQL builder pattern) instead of hand-rolling an `INSERT`.

6. **`helpers.unixTimestampNanos()` is the cross-platform way to generate ids** — `std.Io.Clock.now` requires an `io` parameter, and `std.c.clock_gettime` doesn't compile on Windows. Use `helpers.unixTimestampNanos()` (per `workspace_items_create_kanban.zig:136-138`).

7. **SSE emit is fire-and-forget** — `on_event_sent_kanban.onEventSendKanbanTask` can fail; log + continue (matches `kanban_move_task.zig:344-356` and `task_create.zig:430-432` patterns). A failed SSE emit should NOT fail the create.

8. **`wrapToolOutput` 5-arg signature** — `(allocator, tool_name, arguments, success, error_msg, inner_data)`. `success=true` requires `error_msg=null`; `success=false` requires `error_msg` to be non-null. The existing `tools_exec_kanban_list.zig:49` is the canonical reference.

9. **`UNIFIED_TOOL_REGISTRY` placement** — keep kanban tools grouped. Place `create_kanban_task` directly after `kanban_move_task` so the registry reads `kanban_list → kanban_move_task → create_kanban_task`.

10. **Tool definition description MUST mention "kanban" + "task/card"** — the LLM uses the description to decide WHEN to call the tool. Per `set_design_page.zig:51-60` and `kanban_list.zig:81-87`, the description is the primary signal.

## Verification

- [ ] `zig build test --summary all` — passes, ~1894 tests (was 1876 + 16-18 new)
- [ ] `zig build install:linux:system` — clean
- [ ] `rm -rf zig-out/bin && zig build` — clean full rebuild
- [ ] `zig build-obj -fno-emit-bin -target x86_64-windows-gnu ...` — exit 0
- [ ] `zig build-obj -fno-emit-bin -target aarch64-macos ...` — exit 0
- [ ] `cd src/apps/desktop && node node_modules/vue-tsc/bin/vue-tsc.js --build` — exit 0
- [ ] `cd src/apps/desktop && bunx vitest run` — 1483/1483 pass
- [ ] End-to-end smoke (Task 9) — task appears in kanban via agent tool call
- [ ] Live binary does NOT crash on `/api/health` (no regression in the bootstrap path)
- [ ] CI green on `[self-hosted, Linux, X64]` + `[self-hosted, macOS, ARM64]` cells

## Reference

- Plan: this file (`docs/superpowers/plans/2026-07-29-create-kanban-task-tool.md`)
- Parallel HTTP handler: `src/ai_workflow/tui/http_handlers/task_create.zig::createStandardTask` (lines 337-503)
- Model helper: `nalarcore.ai_mod.llm_history.createWorkspaceItemTask` (`src/ai_workflow/tui/llm_history.zig:3339-3425`)
- Pattern references: `src/modules/agent/tools/kanban_list.zig`, `src/modules/agent/tools/kanban_move_task.zig`, `src/modules/agent/tools/set_design_page.zig`
- Tool registry: `src/ai_workflow/tui/agentic_loop/tool_registry.zig::UNIFIED_TOOL_REGISTRY`
- Memory: `~/.config/nalar/memories/zig-build-and-test.md` (lazy analysis), `~/.config/nalar/memories/zig-sqlite-patterns.md` (empty-slice NULL), `~/.config/nalar/memories/zig-cross-platform.md` (cross-compile verification), `~/.config/nalar/memories/nalar-backend-architecture.md` (HTTP handler patterns)
