# Add Task Routines — Chunk 4: Backend HTTP handlers

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the new `task_type='routine'` data model (Chunk 1's migration 044 + `routines` table) over HTTP. Modifies create / update / list handlers to accept and return routine metadata, and adds a new `POST /api/workspaces/:w/items/:i/tasks/:tid/run` endpoint that spawns the `bin/nalar-routine-fire` sub-process (built in Chunk 2) to fire a routine on demand.

**Architecture:** Thin HTTP-concerns front + small use case per handler. The run handler uses the existing `std.process.spawn` fire-and-forget pattern from `src/ai_workflow/tui/notifications.zig:130` and `src/apps/desktop_app/subprocess.zig:237`. Tests are static source-code substring checks matching the project's `task_update_test.zig` and `tasks_list_test.zig` convention.

**Tech Stack:** Zig 0.16 (backend, std.Io.Threaded, std.process.spawn, SQLite via `nalarcore.sqlite.SqliteBackend`), static source-check unit tests.

**Spec:** [`docs/plans/2026-06-13-add-task-routines-design.md`](../plans/2026-06-13-add-task-routines-design.md) (sections "API surface", "Modified endpoints", "New endpoint")

**Depends on:** Chunk 1 (`routines/model.zig`, `routines/cron.zig`). The `bin/nalar-routine-fire` binary built in Chunk 2 is the spawn target but the spawn call itself doesn't require it to exist at compile time.

**Sessions invariant:** `task.id == session.id` for routine tasks. The existing create flow has the frontend create a session with id == task.id before creating the task, so `task.session_id` will equal `task.id` for routine tasks. The run handler returns `task.session_id` (with `task.id` as a defensive fallback).

---

## File structure (this chunk)

### Modified files

| File | Change |
|---|---|
| `src/ai_workflow/tui/http_handlers/task_create.zig` | Accept `task_type` (default 'standard') + routine fields. For routines, validate cron, compute `next_run_at`, insert routine row. |
| `src/ai_workflow/tui/http_handlers/task_update.zig` | Accept routine fields (`schedule`, `initial_prompt`, `enabled`). When `schedule` changes, recompute `next_run_at`. |
| `src/ai_workflow/tui/http_handlers/tasks_list.zig` | Response includes `task_type` and (for routines) inline routine metadata. |
| `src/ai_workflow/tui/llm_history.zig` | `WorkspaceItemTaskInfo` gains `task_type` and `routine: ?RoutineMeta`. New `RoutineMeta` struct. SQL `LEFT JOIN routines` in the lister. |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | `WorkspaceItemTaskResponse` gains `task_type` and `routine`. New `RoutineMetaResponse`. `TaskCreateRequest` / `TaskUpdateRequest` gain routine fields. |
| `src/ai_workflow/tui/http_handlers/mod.zig` | Re-export `routinesRunHandler`. |
| `src/ai_workflow/tui/test_runner.zig` | Register 4 new test files. |
| `src/main.zig` | Register the new `POST /api/workspaces/.../tasks/:tid/run` route. |

### New files

| File | Purpose |
|---|---|
| `src/ai_workflow/tui/http_handlers/routines_run.zig` | `POST /api/workspaces/:w/items/:i/tasks/:tid/run` — manual fire. |
| `src/ai_workflow/tui/http_handlers/routines_run_test.zig` | Static-check tests for the new endpoint. |
| `src/ai_workflow/tui/http_handlers/task_create_routines_test.zig` | Static-check tests for the routine-aware task create. |
| `src/ai_workflow/tui/http_handlers/task_update_routines_test.zig` | Static-check tests for the routine-aware task update. |
| `src/ai_workflow/tui/llm_history_routines_test.zig` | Static-check tests for `WorkspaceItemTaskInfo` + lister JOIN. |

### Test files (modified)

| File | Change |
|---|---|
| `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` | Append 4 contracts for the new `task_type` and `routine` response fields. |

### Note on transactions

SQLite in this project doesn't expose a `BEGIN/COMMIT` API on `SqliteBackend`. The routine INSERT happens right after the task INSERT in the same handler call. If the routine INSERT fails, the task INSERT remains; the design's `ON DELETE CASCADE` covers cleanup. A future chunk can introduce a `db.transaction { ... }` helper if this becomes a correctness issue.

---

## Task 4.1: `task_create.zig` — accept `task_type` and routine fields

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/task_create.zig`
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig`
- Test: `src/ai_workflow/tui/http_handlers/task_create_routines_test.zig`

**Why first:** All other chunk 4 tasks depend on the create path. Without 4.1, no routine task can exist in the DB.

- [ ] **Step 1: Write the failing test**

Create `src/ai_workflow/tui/http_handlers/task_create_routines_test.zig`:

```zig
//! Static regression checks for the routine-aware task create handler.
//! Contract: TaskCreateRequest has task_type + routine fields; handler
//! calls cron.validate, cron.nextFireTime, and INSERT INTO routines.
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_create.zig";
const REQ_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
}

test "TaskCreateRequest has task_type + routine fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, REQ_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "task_type") == null) return error.TaskTypeFieldMissing;
    if (std.mem.indexOf(u8, source, "schedule") == null) return error.RoutineFieldsMissing;
    if (std.mem.indexOf(u8, source, "initial_prompt") == null) return error.RoutineFieldsMissing;
    if (std.mem.indexOf(u8, source, "enabled") == null) return error.RoutineFieldsMissing;
}

test "task_create handler validates the cron expression" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "cron.validate") == null) return error.CronValidateMissing;
}

test "task_create handler computes next_run_at" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "cron.nextFireTime") == null) return error.CronNextFireTimeMissing;
}

test "task_create handler inserts a routines row for routines" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "INSERT INTO routines") == null) return error.RoutineInsertMissing;
}
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: FAIL with `error.TaskTypeFieldMissing`.

- [ ] **Step 3: Write the implementation**

In `src/ai_workflow/tui/http_handlers/http_response.zig`, **replace** the `TaskCreateRequest` struct (lines 36-39) with:

```zig
pub const TaskCreateRequest = struct {
    name: []const u8,
    session_id: ?[]const u8 = null,
    /// Task type. Defaults to 'standard' (preserves the existing flow).
    task_type: []const u8 = "standard",
    /// 5-field cron expression. Required iff task_type='routine'.
    schedule: ?[]const u8 = null,
    /// What the LLM sees on every fire. Required iff task_type='routine'.
    initial_prompt: ?[]const u8 = null,
    /// Whether the routine is active. Defaults to true.
    enabled: bool = true,
};
```

In `src/ai_workflow/tui/http_handlers/task_create.zig`, **replace** the entire file body with:

```zig
const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const model = @import("../routines/model.zig");
const cron = @import("../routines/cron.zig");

/// POST /api/workspaces/:workspace_id/items/:item_id/tasks
///
/// Body: { name, session_id?, task_type? ('standard'|'routine'),
///         schedule?, initial_prompt?, enabled? }. For routines,
/// validates the cron, computes next_run_at via cron.nextFireTime,
/// and inserts a row into `routines` immediately after the task row.
pub fn tasksCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }) });
    }

    const json_body = std.json.parseFromSliceLeaky(http_response.TaskCreateRequest, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    const ts = std.Io.Timestamp.now(ctx.io, .real);
    const task_id = try std.fmt.allocPrint(allocator, "task_{d}", .{@divTrunc(ts.nanoseconds, 1_000_000)});

    // Routine-specific validation + initial next_run_at computation.
    var next_run_at: ?[]const u8 = null;
    const is_routine = std.mem.eql(u8, json_body.task_type, "routine");
    if (is_routine) {
        const schedule = json_body.schedule orelse {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "schedule is required for routine tasks" }) });
        };
        const initial_prompt = json_body.initial_prompt orelse {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "initial_prompt is required for routine tasks" }) });
        };
        cron.validate(schedule) catch {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid cron expression" }) });
        };
        const now_ns: i128 = ts.nanoseconds;
        const next_ns = cron.nextFireTime(schedule, now_ns) catch {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to compute next fire time" }) });
        };
        const next_secs: i64 = @intCast(@divTrunc(next_ns, 1_000_000_000));
        next_run_at = try std.fmt.allocPrint(allocator, "strftime('%Y-%m-%d %H:%M:%S', datetime({d}, 'unixepoch'))", .{next_secs});
    }

    // Insert the task row.
    const task = ai_mod.workspace_item_tasks.createWorkspaceItemTask(
        allocator, sqlite_db, task_id, json_body.name, item_id, json_body.session_id, json_body.task_type,
    ) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create task" }) });
    };
    defer task.deinit(allocator);

    // For routines, insert the routines row in the same handler call.
    if (is_routine) {
        const routine_id = try std.fmt.allocPrint(allocator, "routine_{s}", .{task_id});
        model.insertRoutine(allocator, sqlite_db, .{
            .id = routine_id,
            .task_id = task_id,
            .schedule = json_body.schedule.?,
            .initial_prompt = json_body.initial_prompt.?,
            .enabled = json_body.enabled,
            .next_run_at = next_run_at.?,
        }) catch {
            return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create routine row" }) });
        };
    }

    return res.jsonResponse(.{ .status_code = 201, .data = try http_response.makeWorkspaceItemTaskResponse(allocator, http_response.WorkspaceItemTaskResponse{
        .id = task.id,
        .name = task.name,
        .workspace_item_id = task.workspace_item_id,
        .session_id = task.session_id,
        .task_type = task.task_type,
        .routine = task.routine,
        .created_at = task.created_at,
        .updated_at = task.updated_at,
    }) });
}
```

> **Note:** `createWorkspaceItemTask` with the 7-arg signature is provided by Task 4.5. Implement 4.5 first.

- [ ] **Step 4: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS. All 4 contract tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/task_create.zig src/ai_workflow/tui/http_handlers/http_response.zig src/ai_workflow/tui/http_handlers/task_create_routines_test.zig
git commit -m "feat(routines): task_create accepts task_type + routine fields"
```

---

## Task 4.2: `task_update.zig` — accept routine fields + recompute `next_run_at`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/task_update.zig`
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig` (extend `TaskUpdateRequest`)
- Test: `src/ai_workflow/tui/http_handlers/task_update_routines_test.zig`

- [ ] **Step 1: Write the failing test**

Create `src/ai_workflow/tui/http_handlers/task_update_routines_test.zig`:

```zig
//! Static regression checks for the routine-aware task update handler.
//! Contract: TaskUpdateRequest has routine fields; handler validates
//! schedule, recomputes next_run_at, writes to routines table.
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_update.zig";
const REQ_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
}

test "TaskUpdateRequest has routine fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, REQ_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "schedule") == null) return error.RoutineUpdateFieldsMissing;
    if (std.mem.indexOf(u8, source, "initial_prompt") == null) return error.RoutineUpdateFieldsMissing;
    if (std.mem.indexOf(u8, source, "enabled") == null) return error.RoutineUpdateFieldsMissing;
}

test "task_update handler validates the schedule" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "cron.validate") == null) return error.CronValidateMissing;
}

test "task_update handler recomputes next_run_at on schedule change" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "cron.nextFireTime") == null) return error.CronRecomputeMissing;
}

test "task_update handler writes to the routines table" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    const has_routine_write = std.mem.indexOf(u8, source, "routines") != null and
        (std.mem.indexOf(u8, source, "UPDATE routines") != null or
         std.mem.indexOf(u8, source, "INSERT OR REPLACE INTO routines") != null or
         std.mem.indexOf(u8, source, "updateRoutine") != null);
    if (!has_routine_write) return error.RoutineUpdateMissing;
}
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: FAIL with `error.RoutineUpdateFieldsMissing`.

- [ ] **Step 3: Write the implementation**

In `src/ai_workflow/tui/http_handlers/http_response.zig`, **replace** the `TaskUpdateRequest` struct (lines 41-44) with:

```zig
pub const TaskUpdateRequest = struct {
    name: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
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

In `src/ai_workflow/tui/http_handlers/task_update.zig`, **replace** the entire file body with:

```zig
const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const llm_history = nalarcore.llm_history;
const cron = @import("../routines/cron.zig");

/// PUT /api/workspaces/tasks/:task_id - Update task by ID only.
pub fn tasksUpdateByIdHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }) });
    }

    const json_body = std.json.parseFromSliceLeaky(http_response.TaskUpdateRequest, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    // Routine fields (if any) — recompute next_run_at on schedule change.
    if (json_body.schedule != null or json_body.initial_prompt != null or json_body.enabled != null) {
        var next_run_arg: ?[]u8 = null;
        if (json_body.schedule) |schedule| {
            cron.validate(schedule) catch {
                return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid cron expression" }) });
            };
            const now = std.Io.Timestamp.now(ctx.io, .real);
            const next_ns = try cron.nextFireTime(schedule, now.nanoseconds);
            const next_secs: i64 = @intCast(@divTrunc(next_ns, 1_000_000_000));
            next_run_arg = try std.fmt.allocPrint(allocator,
                "strftime('%Y-%m-%d %H:%M:%S', datetime({d}, 'unixepoch'))", .{next_secs});
        }
        defer if (next_run_arg) |nr| allocator.free(nr);

        var set_parts = std.ArrayList([]const u8).empty;
        defer set_parts.deinit(allocator);
        var values = std.ArrayList([]const u8).empty;
        defer values.deinit(allocator);

        if (json_body.schedule) |s| { try set_parts.append(allocator, "schedule = ?"); try values.append(allocator, s); }
        if (json_body.initial_prompt) |p| { try set_parts.append(allocator, "initial_prompt = ?"); try values.append(allocator, p); }
        if (json_body.enabled) |e| {
            try set_parts.append(allocator, "enabled = ?");
            try values.append(allocator, if (e) "1" else "0");
        }
        if (next_run_arg) |nr| { try set_parts.append(allocator, "next_run_at = ?"); try values.append(allocator, nr); }
        try set_parts.append(allocator, "updated_at = datetime('now')");
        try values.append(allocator, task_id);

        const set_clause = try std.mem.join(allocator, ", ", set_parts.items);
        defer allocator.free(set_clause);
        const sql = try std.fmt.allocPrint(allocator, "UPDATE routines SET {s} WHERE task_id = ?", .{set_clause});
        defer allocator.free(sql);

        sqlite_db.exec(allocator, sql, values.items) catch {
            return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update routine" }) });
        };
    }

    // Standard branches (unchanged from the existing handler).
    if (json_body.name) |n| {
        llm_history.updateTaskName(allocator, sqlite_db, task_id, n) catch {
            return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update task" }) });
        };
    }
    if (json_body.session_id) |sid| {
        ai_mod.workspace_item_tasks.updateWorkspaceItemTask(allocator, sqlite_db, task_id, null, sid) catch {
            return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update task" }) });
        };
    }

    return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"id\":\"{s}\"}}", .{task_id}) });
}

/// PUT /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id
/// (Same body as tasksUpdateByIdHandler; the routine-fields branch
/// is identical. Delegated to keep the router registrations simple.)
pub fn tasksUpdateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    return tasksUpdateByIdHandler(ctx, req, res);
}
```
```

- [ ] **Step 4: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/task_update.zig src/ai_workflow/tui/http_handlers/http_response.zig src/ai_workflow/tui/http_handlers/task_update_routines_test.zig
git commit -m "feat(routines): task_update accepts routine fields, recomputes next_run_at"
```

---

## Task 4.3: `tasks_list.zig` — include `task_type` and inline `routine` in the response

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/tasks_list.zig` (pass new fields to the response struct)
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig` (extend `WorkspaceItemTaskResponse` with `task_type` and `routine`)
- Modify: `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` (append 2 new contract tests)

**Why third:** The list response needs to expose `task_type` and `routine` metadata so the frontend `WorkspaceItemTask.vue` (Chunk 7) can branch on `task_type === 'routine'` to render the clock icon + Run Now button.

> **Note:** The actual struct change to `WorkspaceItemTaskInfo` is in **Task 4.5** (the lister SQL JOIN). This task is a pure handler-level change.

- [ ] **Step 1: Write the failing test**

**Append** to the existing `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` (which already has 12 contract tests):

```zig
// ─── Contracts 13-14: routine-aware response shape ────────────────────

test "WorkspaceItemTaskResponse has task_type + routine fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESPONSE_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "task_type") == null) return error.TaskTypeFieldMissing;
    if (std.mem.indexOf(u8, source, "routine") == null) return error.RoutineFieldMissing;
}

test "tasks_list handler threads task_type + routine into the response" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "task_type") == null) return error.TaskTypeNotThreaded;
    if (std.mem.indexOf(u8, source, ".routine") == null) return error.RoutineNotThreaded;
}
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: FAIL with `error.TaskTypeFieldMissing`. The existing 12 tests still pass.

- [ ] **Step 3: Write the implementation**

In `src/ai_workflow/tui/http_handlers/http_response.zig`, **add** a new `RoutineMetaResponse` struct next to the existing `WorkspaceItemTaskResponse` (around line 245):

```zig
/// Wire shape for the inline `routine` field on `WorkspaceItemTaskResponse`.
/// Mirrors the API response in the design doc.
pub const RoutineMetaResponse = struct {
    schedule: []const u8,
    initial_prompt: []const u8,
    enabled: bool,
    last_run_at: ?[]const u8 = null,
    next_run_at: []const u8,
    last_status: ?[]const u8 = null, // "success" | "failed" | "running" | null
    last_error: ?[]const u8 = null,
};
```

**Replace** the `WorkspaceItemTaskResponse` definition (line 245) with:

```zig
pub const WorkspaceItemTaskResponse = struct {
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    session_id: ?[]const u8 = null,
    /// Task type. Always present; 'standard' for legacy rows.
    task_type: []const u8 = "standard",
    /// Inline routine metadata. Present iff task_type === 'routine'.
    routine: ?RoutineMetaResponse = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};
```

In `src/ai_workflow/tui/http_handlers/tasks_list.zig`, **update** the `for` loop that builds the response (lines 89-98) to thread the new fields:

```zig
for (result.tasks) |task| {
    try task_responses.append(allocator, http_response.WorkspaceItemTaskResponse{
        .id = task.id,
        .name = task.name,
        .workspace_item_id = task.workspace_item_id,
        .session_id = task.session_id,
        .task_type = task.task_type,
        .routine = if (task.routine) |r| http_response.RoutineMetaResponse{
            .schedule = r.schedule,
            .initial_prompt = r.initial_prompt,
            .enabled = r.enabled,
            .last_run_at = r.last_run_at,
            .next_run_at = r.next_run_at,
            .last_status = switch (r.last_status) {
                .idle => null,
                .success => "success",
                .failed => "failed",
                .running => "running",
            },
            .last_error = r.last_error,
        } else null,
        .created_at = task.created_at,
        .updated_at = task.updated_at,
    });
}
```

- [ ] **Step 4: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS. 12 existing + 2 new = 14 tests passing.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/tasks_list.zig src/ai_workflow/tui/http_handlers/http_response.zig src/ai_workflow/tui/http_handlers/tasks_list_test.zig
git commit -m "feat(routines): tasks_list response includes task_type + routine metadata"
```

---

## Task 4.4: New `routines_run.zig` handler — `POST /api/workspaces/:w/items/:i/tasks/:tid/run`

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/routines_run.zig`
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig` (re-export)
- Modify: `src/main.zig` (register the route)

**Why fourth:** User-facing "Run now" action. Depends on Tasks 4.1-4.3 (routine tasks must exist) and on `routines/model.zig` from Chunk 1.

> **TDD note:** New endpoint — no existing tests to mirror. We follow the (4.4, 4.6) pair pattern: 4.4 implements the handler, 4.6 verifies via static checks. Any regression in 4.4's contract is caught by 4.6's tests.

- [ ] **Step 1: Write the handler**

Create `src/ai_workflow/tui/http_handlers/routines_run.zig`:

```zig
const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const llm_history = nalarcore.llm_history;
const model = @import("../routines/model.zig");

/// POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/run
///
/// Body: empty.
///
/// Manually fires a routine task. Same code path the Scheduler uses:
/// spawn `bin/nalar-routine-fire --id <task_id>` fire-and-forget and
/// return immediately. Returns 200 + session_id on success; 404 if the
/// task is not a routine; 409 if disabled or already running; 500 on
/// internal errors. The "task.id == session.id" invariant is set by
/// the frontend at create time.
pub fn routinesRunHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    // 1. Load the task (404 if missing), 2. confirm routine (404 if not),
    // 3. load routine row (404 if data inconsistency), 4. check enabled
    // (409 if disabled), 5. atomic claim (409 if in-flight).
    const task_opt = llm_history.getWorkspaceItemTask(allocator, sqlite_db, task_id) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to load task" }) });
    };
    const task = task_opt orelse {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Task not found" }) });
    };
    defer task.deinit(allocator);

    if (!std.mem.eql(u8, task.task_type, "routine")) {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Task is not a routine" }) });
    }

    const routine = model.loadRoutineByTaskId(allocator, sqlite_db, task_id) catch {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Routine not found for task" }) });
    };
    defer routine.deinit(allocator);

    if (!routine.enabled) {
        return res.jsonResponse(.{ .status_code = 409, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Routine is disabled" }) });
    }

    const claimed = try model.claimForRun(allocator, sqlite_db, routine.id);
    if (!claimed) {
        return res.jsonResponse(.{ .status_code = 409, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Routine is already running" }) });
    }

    // 6. Spawn the sub-process fire-and-forget. If spawn fails we reset
    //    to 'failed' so the scheduler doesn't skip it. See
    //    notifications.zig:130 for the working fire-and-forget pattern.
    const argv_buf = [_][]const u8{
        "nalar-routine-fire",
        "--id",
        routine.id,
    };
    const child = std.process.spawn(ctx.io, .{
        .argv = &argv_buf,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        model.markFailed(allocator, sqlite_db, routine.id, "spawn failed", routine.next_run_at) catch {};
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to spawn sub-process" }) });
    };
    // Touch child.id to silence the unused-warning (fire-and-forget —
    // the OS reaps the child).
    if (child.id == null) {
        model.markFailed(allocator, sqlite_db, routine.id, "spawn returned null id", routine.next_run_at) catch {};
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Spawn returned no process id" }) });
    }

    // 7. Return 200 with the routine's session_id.
    const session_id = task.session_id orelse task.id;
    return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"session_id\":\"{s}\"}}", .{session_id}) });
}
```

In `src/ai_workflow/tui/http_handlers/mod.zig`, **add** a re-export after the existing `tasksDeleteHandler` (around line 55):

```zig
// Routines API handlers
pub const routinesRunHandler = @import("routines_run.zig").routinesRunHandler;
```

In `src/main.zig`, **add** the route after the existing `tasksDeleteHandler` (around line 300):

```zig
try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/run", ai_mod.http_handlers.routinesRunHandler);
```

> **Note on `std.process.spawn`:** Zig 0.16's API takes `io: std.Io` as the first arg (we pass `ctx.io`); the result is a `Child` struct. We bind the result, touch `.id` to silence the "unused" warning, and intentionally do NOT call `child.wait(io)` — the OS reaps the child. See `zig-0.16-process-spawn-api.md` in the project's global memory.

- [ ] **Step 2: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: All existing tests pass. (Task 4.6 registers the static-check tests for this handler; the implementation is already complete.)

- [ ] **Step 3: (no additional code — handler is implemented in Step 1)**

- [ ] **Step 4: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/routines_run.zig src/ai_workflow/tui/http_handlers/mod.zig src/main.zig
git commit -m "feat(routines): POST /run endpoint for manual routine fire"
```

---

## Task 4.5: `llm_history.zig` — extend `WorkspaceItemTaskInfo` with `task_type` and `routine`

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig` (struct + 4 constructors + lister SQL JOIN)

**Why fifth:** The HTTP handlers in Tasks 4.1-4.4 all read `task.task_type` and `task.routine`. The struct fields and the SQL lister need to exist for the handler code to compile. This is the foundation.

> **Note on coupling:** Task 4.1's implementation calls `createWorkspaceItemTask(allocator, db, task_id, name, item_id, session_id, task_type)` with a 7-arg signature. That signature change is provided by this task (4.5). **Implement 4.5 first** to keep the tree green.

- [ ] **Step 1: Write the failing test**

Create `src/ai_workflow/tui/llm_history_routines_test.zig`:

```zig
//! Static regression checks for the routine-aware task struct in
//! `llm_history.zig`. The `WorkspaceItemTaskInfo` struct must gain
//! `task_type` + `routine` fields and a new `RoutineMeta` struct.
//! The lister must LEFT JOIN routines.
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md

const std = @import("std");
const testing = std.testing;

const LLM_HISTORY_PATH = "src/ai_workflow/tui/llm_history.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
}

test "WorkspaceItemTaskInfo has task_type + routine fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    const struct_sig = "pub const WorkspaceItemTaskInfo = struct";
    const sig_idx = std.mem.indexOf(u8, source, struct_sig) orelse
        return error.WorkspaceItemTaskInfoNotFound;
    const after_sig = sig_idx + struct_sig.len;
    const end_marker = std.mem.indexOfPos(u8, source, after_sig, "};") orelse source.len;
    const body = source[after_sig..end_marker];

    if (std.mem.indexOf(u8, body, "task_type") == null) return error.TaskTypeFieldMissing;
    if (std.mem.indexOf(u8, body, "routine") == null) return error.RoutineFieldMissing;
}

test "RoutineMeta struct exists in llm_history" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub const RoutineMeta = struct") == null) return error.RoutineMetaMissing;
}

test "listWorkspaceItemTasksWithCursor SQL joins the routines table" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    const fn_sig = "pub fn listWorkspaceItemTasksWithCursor(";
    const sig_idx = std.mem.indexOf(u8, source, fn_sig) orelse return error.ListFnNotFound;
    const after_sig = sig_idx + fn_sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    const body = source[after_sig..next_pub_fn];

    if (std.mem.indexOf(u8, body, "LEFT JOIN routines") == null) return error.JoinMissing;
}
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: FAIL with `error.TaskTypeFieldMissing`.

- [ ] **Step 3: Write the implementation**

In `src/ai_workflow/tui/llm_history.zig`, **add** the import for the routines model (if not already present at the top of the file):

```zig
const model = @import("routines/model.zig");
```

**Add** the new `RoutineMeta` struct just above `WorkspaceItemTaskInfo` (around line 2247):

```zig
/// Inline routine metadata embedded in `WorkspaceItemTaskInfo`.
/// Mirrors the API response shape. Populated by the LEFT JOIN in
/// the listers; null for standard tasks.
pub const RoutineMeta = struct {
    schedule: []const u8,
    initial_prompt: []const u8,
    enabled: bool,
    last_run_at: ?[]const u8 = null,
    next_run_at: []const u8,
    last_status: model.RoutineRunStatus = .idle,
    last_error: ?[]const u8 = null,
};
```

> **Import-cycle note:** If importing `routines/model.zig` causes a cycle, inline the `RoutineRunStatus` enum here instead.

**Replace** the `WorkspaceItemTaskInfo` struct (line 2248) with:

```zig
pub const WorkspaceItemTaskInfo = struct {
    id: []u8,
    name: []u8,
    workspace_item_id: []u8,
    session_id: ?[]u8 = null,
    /// Task type. 'standard' for legacy rows; 'routine' for routine tasks.
    /// Every constructor explicitly allocates this so deinit can free it.
    task_type: []u8 = &.{},
    /// Inline routine metadata. Populated for routine tasks only.
    routine: ?RoutineMeta = null,
    created_at: ?[]u8 = null,
    updated_at: ?[]u8 = null,

    pub fn deinit(self: WorkspaceItemTaskInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.workspace_item_id);
        if (self.session_id) |s| allocator.free(s);
        if (self.task_type.len > 0) allocator.free(self.task_type);
        if (self.created_at) |ca| allocator.free(ca);
        if (self.updated_at) |ua| allocator.free(ua);
    }
};
```

**Modify** the 4 `WorkspaceItemTaskInfo` constructors:

1. **`createWorkspaceItemTask`** (line 2267) — extend signature to accept `task_type: []const u8`, INSERT it, populate the struct.

```zig
pub fn createWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    session_id: ?[]const u8,
    task_type: []const u8, // NEW
) !WorkspaceItemTaskInfo {
    if (!std.mem.eql(u8, task_type, "standard") and !std.mem.eql(u8, task_type, "routine")) {
        return error.InvalidTaskType;
    }

    const sql = if (session_id) |_|
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id, task_type) VALUES (?, ?, ?, ?, ?)"
    else
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) VALUES (?, ?, ?, ?)";

    if (session_id) |sid| {
        try db.exec(allocator, sql, &.{ id, name, workspace_item_id, sid, task_type });
    } else {
        try db.exec(allocator, sql, &.{ id, name, workspace_item_id, task_type });
    }

    return WorkspaceItemTaskInfo{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .workspace_item_id = try allocator.dupe(u8, workspace_item_id),
        .session_id = if (session_id) |s| try allocator.dupe(u8, s) else null,
        .task_type = try allocator.dupe(u8, task_type),
        .routine = null,
    };
}
```

> **Backwards-compat note:** Making the new arg `?[]const u8` (null → "standard") is acceptable if other call sites exist.

2. **`getWorkspaceItemTask`** (line 2292) — extend SQL to also `SELECT task_type`, populate the field, leave `routine` null.

```zig
pub fn getWorkspaceItemTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !?WorkspaceItemTaskInfo {
    const sql = "SELECT id, name, workspace_item_id, session_id, created_at, updated_at, task_type FROM workspace_item_tasks WHERE id = ?";

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            .session_id = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .task_type = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else try allocator.dupe(u8, "standard"),
            .routine = null, // single-row fetch path; routine loaded on demand
        };
        row.deinit(allocator);
        return task;
    }

    return null;
}
```

3. **`listWorkspaceItemTasks`** (line 2368) — extend SQL to LEFT JOIN `routines`, populate both `task_type` and `routine`.

```zig
pub fn listWorkspaceItemTasks(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]WorkspaceItemTaskInfo {
    const sql =
        \\SELECT t.id, t.name, t.workspace_item_id, t.session_id, t.created_at, t.updated_at, t.task_type,
        \\       r.schedule, r.initial_prompt, r.enabled, r.last_run_at, r.next_run_at, r.last_status, r.last_error
        \\FROM workspace_item_tasks t LEFT JOIN routines r ON r.task_id = t.id
        \\WHERE t.workspace_item_id = ? ORDER BY t.created_at DESC
    ;

    var rows = try db.query(allocator, sql, &.{workspace_item_id});
    defer rows.deinit();

    var tasks = std.ArrayList(WorkspaceItemTaskInfo).empty;
    errdefer {
        for (tasks.items) |task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    while (try rows.next()) |row| {
        // Row indices 0-5: task core; 6: task_type; 7-13: routine fields.
        // routine.schedule is NOT NULL, so its presence discriminates
        // joined routine rows from standard tasks.
        const task_type = if (row.values[6].len > 0)
            try allocator.dupe(u8, row.values[6])
        else
            try allocator.dupe(u8, "standard");
        const has_routine = row.values[7].len > 0;
        const routine_meta: ?RoutineMeta = if (has_routine) blk: {
            const v = row.values[12];
            const last_status: model.RoutineRunStatus =
                if (v.len == 0) .idle
                else if (std.mem.eql(u8, v, "success")) .success
                else if (std.mem.eql(u8, v, "failed")) .failed
                else if (std.mem.eql(u8, v, "running")) .running
                else .idle;
            break :blk RoutineMeta{
                .schedule = try allocator.dupe(u8, row.values[7]),
                .initial_prompt = try allocator.dupe(u8, row.values[8]),
                .enabled = std.mem.eql(u8, row.values[9], "1"),
                .last_run_at = if (row.values[10].len > 0) try allocator.dupe(u8, row.values[10]) else null,
                .next_run_at = try allocator.dupe(u8, row.values[11]),
                .last_status = last_status,
                .last_error = if (row.values[13].len > 0) try allocator.dupe(u8, row.values[13]) else null,
            };
        } else null;

        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            .session_id = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .task_type = task_type,
            .routine = routine_meta,
        };
        try tasks.append(allocator, task);
        row.deinit(allocator);
    }

    return try tasks.toOwnedSlice(allocator);
}
```

4. **`listWorkspaceItemTasksWithCursor`** (line 2416) — same SQL JOIN change. The pagination logic, cursor handling, and ORDER BY are unchanged. The exact edit mirrors `listWorkspaceItemTasks` above.

- [ ] **Step 4: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS. All existing tests + the 3 new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/llm_history.zig src/ai_workflow/tui/llm_history_routines_test.zig
git commit -m "feat(routines): WorkspaceItemTaskInfo gains task_type + routine metadata"
```

---

## Task 4.6: `routines_run_test.zig` — static-check tests for the new run endpoint

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/routines_run_test.zig`

- [ ] **Step 1: Write the failing test**

Create `src/ai_workflow/tui/http_handlers/routines_run_test.zig`:

```zig
//! Static regression checks for the routines_run handler. The
//! new POST /run endpoint spawns `bin/nalar-routine-fire` fire-and-
//! forget. Contract branches: 404 not-a-routine, 409 disabled,
//! 409 already-running, 200 + session_id on success.
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/routines_run.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
}

test "routines_run handler loads the task and checks task_type" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "getWorkspaceItemTask") == null) return error.TaskTypeCheckMissing;
    if (std.mem.indexOf(u8, source, "task_type") == null) return error.TaskTypeCheckMissing;
}

test "routines_run handler loads the routine row" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "loadRoutineByTaskId") == null) return error.RoutineLoadMissing;
}

test "routines_run handler checks routine.enabled (409 for disabled)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, ".enabled") == null) return error.EnabledCheckMissing;
}

test "routines_run handler calls claimForRun (409 for in-flight)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "claimForRun") == null) return error.ClaimForRunMissing;
}

test "routines_run handler spawns nalar-routine-fire with --id" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    const has_binary = std.mem.indexOf(u8, source, "nalar-routine-fire") != null;
    const has_id_flag = std.mem.indexOf(u8, source, "--id") != null;
    const has_spawn = std.mem.indexOf(u8, source, "std.process.spawn") != null or
        std.mem.indexOf(u8, source, "process.spawn") != null;
    if (!has_binary or !has_id_flag or !has_spawn) return error.SpawnArgsMissing;
}

test "routines_run handler returns 200 with session_id JSON" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "session_id") == null) return error.SessionIdResponseMissing;
}
```

- [ ] **Step 2: Run the test, verify it PASSES**

The handler (Task 4.4) is already implemented. The static-check tests assert substrings present in the handler source.

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS. All 6 contract tests pass.

- [ ] **Step 3: (no additional code — tests verify the existing handler)**

- [ ] **Step 4: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/routines_run_test.zig
git commit -m "test(routines): routines_run handler static-check tests"
```

---

## Task 4.7: Extend `tasks_list_test.zig` with the new response contract tests

> **Note:** This task is fully covered by the test code in **Task 4.3** (which appends contracts 13-14 to `tasks_list_test.zig`). No separate work is required here.

If the implementer prefers to keep the test-file changes in a dedicated commit, split Task 4.3 as follows:

- **Task 4.3:** Modify `http_response.zig` + `tasks_list.zig`. The existing 12 tests pass; the 2 new tests in `tasks_list_test.zig` are NOT yet added.
- **Task 4.7:** Append contracts 13-14 to `tasks_list_test.zig`. The test file modification is its own commit.

In that case, the test-first pattern for Task 4.7 is:

- [ ] **Step 1: Append contracts 13-14** to `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` (the test code from Task 4.3 Step 1).

- [ ] **Step 2: Run the test, verify it PASSES** (handler code from Task 4.3 is already in place).

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS. 12 existing + 2 new = 14 tests passing.

- [ ] **Step 3: (no additional code)**

- [ ] **Step 4: Run the test, verify it PASSES** (same command as Step 2).

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/tasks_list_test.zig
git commit -m "test(routines): tasks_list response contract tests for task_type + routine"
```

If the implementer chose to keep Task 4.3 + 4.7 in a single commit (the default), skip this task and rely on the Task 4.3 commit.

---

## Task 4.8: Register the new tests in `test_runner.zig`

**Files:**
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 1: Add the imports**

In `src/ai_workflow/tui/test_runner.zig`, **add** these lines inside the `test { ... }` block (after the existing `tasks_list_test.zig` import on line 15):

```zig
    _ = @import("http_handlers/routines_run_test.zig");
    _ = @import("http_handlers/task_create_routines_test.zig");
    _ = @import("http_handlers/task_update_routines_test.zig");
    _ = @import("llm_history_routines_test.zig");
```

- [ ] **Step 2: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS. The new test files are discovered and all their static-check tests run.

- [ ] **Step 3: (no additional code — registration only)**

- [ ] **Step 4: Run the test, verify it PASSES** (same command as Step 2). Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/test_runner.zig
git commit -m "test(routines): register new routine-aware HTTP + struct tests"
```

---

## Chunk 4 done — checkpoint

- ✅ `task_create.zig` accepts `task_type` and routine fields; validates cron; inserts routine row
- ✅ `task_update.zig` accepts routine fields; recomputes `next_run_at` on schedule change
- ✅ `tasks_list.zig` returns `task_type` + inline `routine` metadata
- ✅ New `routines_run.zig` `POST /run` endpoint with full 404/409/200 contract
- ✅ `WorkspaceItemTaskInfo` gains `task_type` + `routine: ?RoutineMeta`; lister LEFT JOINs `routines`
- ✅ 4 new test files + 1 modified, all registered in `test_runner.zig`
- ✅ Route `POST /api/workspaces/:w/items/:i/tasks/:tid/run` registered in `main.zig`

**Next:** **Chunk 5-7 — Frontend** (`AddTaskPickerDialog`, `AddRoutineDialog`, `EditRoutineDialog`, `WorkspaceItemTask.vue` clock icon + Run Now + status dot, `Sidebar.vue` picker wiring, `api/index.ts` + `stores/workspaces.ts` updates). Will be written in a sub-agent.
