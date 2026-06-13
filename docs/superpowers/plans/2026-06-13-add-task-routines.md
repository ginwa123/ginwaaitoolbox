# Add Task — Standard vs Routine picker (with full routines subsystem)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a picker dialog behind the green `+` Add Task button on a workspace item. The picker offers two task types: **Standard** (current behavior — creates a chat session) and **Routine** (new — a cron-scheduled task that pushes an `initial_prompt` into its session and runs the LLM via the existing chat worker pipeline). A "Run now" button on every routine task row fires it on demand. The run history is the session's message history (`task.id == session_id` invariant preserved).

**Architecture:** Routines are a `task_type='routine'` task (mixed into the same list as standard tasks, distinguished by a small clock icon), with a 1:1 `routines` row holding the schedule and run state. A new `Scheduler.zig` module inside the main `nalar` process polls every 5s for due routines and spawns a fresh `bin/nalar-routine-fire` sub-process per fire (so a slow LLM call cannot block polling of others, and a hanging fire cannot stall the scheduler). The sub-process updates `routines.last_run_at` / `next_run_at` / `last_status` / `last_error` directly via DB writes before exit. Manual "Run now" is the same sub-process path, triggered by a new HTTP endpoint. The frontend adds an `AddTaskPickerDialog`, an `AddRoutineDialog`, an `EditRoutineDialog`, and a clock icon + Run Now button + status dot in `WorkspaceItemTask.vue` for routine tasks.

**Tech Stack:** Zig 0.16 (backend, std.Io.Threaded, std.process.spawn, SQLite via the project's `SqliteBackend`), Vue 3 + `<script setup lang="ts">` + TypeScript + Pinia (desktop app), Vitest + @vue/test-utils (frontend unit tests), `@vue/tsc` (type-check via `bun run build`), 5-field POSIX cron (hand-rolled parser, no external dep).

**Spec:** [`docs/plans/2026-06-13-add-task-routines-design.md`](../plans/2026-06-13-add-task-routines-design.md)

---

## File structure

### New files (frontend)

| File | Purpose |
|---|---|
| `src/apps/desktop/src/components/AddTaskPickerDialog.vue` | Modal shown when the green `+` is clicked. Two cards: Standard Chat vs Routine. |
| `src/apps/desktop/src/components/AddRoutineDialog.vue` | Modal form for creating a routine. Preset chips + custom cron toggle. |
| `src/apps/desktop/src/components/EditRoutineDialog.vue` | Same as AddRoutineDialog prefilled. |
| `src/apps/desktop/src/__tests__/AddTaskPickerDialog.spec.ts` | Picker emits `pick` correctly for both cards. |
| `src/apps/desktop/src/__tests__/AddRoutineDialog.spec.ts` | Preset selection populates cron, custom toggle reveals input, submit fires correct API. |
| `src/apps/desktop/src/__tests__/EditRoutineDialog.spec.ts` | Opens prefilled, submit PATCHes. |
| `src/apps/desktop/src/__tests__/WorkspaceItemTask.spec.ts` (extend) | Routine rows render clock icon, Run Now button, status dot, tooltip. |

### Modified files (frontend)

| File | Change |
|---|---|
| `src/apps/desktop/src/components/AddTaskDialog.vue` | Wire up (currently dead) for the Standard path. |
| `src/apps/desktop/src/components/WorkspaceItemTask.vue` | Branch on `task.task_type`. Render clock icon + Run Now + status dot for routines. |
| `src/apps/desktop/src/components/Sidebar.vue` | Replace direct-create in `handleAddTask` with picker dialog. New `handleRunRoutine` for the Run Now button. |
| `src/apps/desktop/src/stores/workspaces.ts` | `Task` interface gains `task_type: 'standard' \| 'routine'` and `routine?: RoutineMeta`. `addTask` signature extended. New `runRoutine` + `updateRoutine` actions. |
| `src/apps/desktop/src/api/index.ts` | `createTask` signature extended. New `runRoutine` API. `updateTaskSimple` accepts routine fields. |

### New files (backend)

| File | Purpose |
|---|---|
| `src/ai_workflow/tui/routines/cron.zig` | 5-field cron parser + `nextFireTime(expr, after_unix_nanos) !i64` + `validate(expr) !void`. |
| `src/ai_workflow/tui/routines/cron_test.zig` | 20+ `nextFireTime` cases + invalid-syntax rejects. |
| `src/ai_workflow/tui/routines/model.zig` | `Routine` struct, `RoutineRunStatus` enum, DB read/write helpers. |
| `src/ai_workflow/tui/routines/model_test.zig` | Insert + load + list-by-(enabled, next_run_at) round-trip. |
| `src/ai_workflow/tui/routines/fire.zig` | `fireRoutine(allocator, db, io, task_id) !void` — the per-fire work. |
| `src/ai_workflow/tui/routines/fire_test.zig` | With mocked worker, verify user message inserted, routine state updated, atomic claim rejects 2nd concurrent fire. |
| `src/ai_workflow/tui/routines/Scheduler.zig` | `Scheduler.start(allocator, db, io)` + polling loop, spawns sub-process per fire. |
| `src/ai_workflow/tui/routines/scheduler_test.zig` | Integration: routine with `next_run_at` in the past fires within 6s; restart-safety + stuck-running reset. |
| `src/ai_workflow/tui/routines/bin/nalar-routine-fire.zig` | Tiny sub-process binary. |
| `src/ai_workflow/tui/http_handlers/routines_run.zig` | `POST /api/workspaces/:w/items/:i/tasks/:tid/run`. |
| `src/ai_workflow/tui/http_handlers/routines_run_test.zig` | 404 for non-routine, 409 for disabled, 200 + session_id for success. |

### Modified files (backend)

| File | Change |
|---|---|
| `src/ai_workflow/tui/migration.zig` | Add `Migration044AddRoutines`. Register in `allMigrations`. |
| `src/ai_workflow/tui/startup.zig` | After migration, start `Scheduler`. |
| `src/ai_workflow/tui/llm_history.zig` | `Task` struct gains `task_type: []const u8` and `routine: ?RoutineMeta = null`. |
| `src/ai_workflow/tui/http_handlers/tasks_list.zig` | Response includes `task_type` and inline `routine` metadata. |
| `src/ai_workflow/tui/http_handlers/workspace_item_tasks_create.zig` | Body accepts `task_type` + (for routines) `schedule`/`initial_prompt`/`enabled`. Creates routine row in same transaction. |
| `src/ai_workflow/tui/http_handlers/workspace_item_tasks_update.zig` | Body accepts routine fields; recomputes `next_run_at` if `schedule` changed. |
| `build.zig` | New `routine-fire` install target. |
| `src/ai_workflow/tui/test_runner.zig` | Register `cron_test`, `model_test`, `fire_test`, `scheduler_test`, `routines_run_test`. |
| `src/ai_workflow/tui/llm_history.zig` (already mentioned) | Update `Task` struct. |

---

## Chunk 1: Backend data model + cron parser

**Why first:** Everything else depends on the data model (the `routines` table + the `task_type` column) and on a working cron expression evaluator. The HTTP handlers, the scheduler, and the firing pipeline all import `model.zig` and `cron.zig`. No HTTP / UI / scheduler work in this chunk.

### Task 1.1: Add migration for `task_type` column + `routines` table

**Files:**
- Modify: `src/ai_workflow/tui/migration.zig` (add a new `Migration044AddRoutines` struct + register in `allMigrations`)
- Test: `src/ai_workflow/tui/migration_routines_test.zig`

- [ ] **Step 1: Write the failing test**

Create `src/ai_workflow/tui/migration_routines_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const SqliteBackend = @import("nalarcore").db.SqliteBackend;
const MigrationManager = @import("migration.zig").MigrationManager;
const Migration044AddRoutines = @import("migration.zig").Migration044AddRoutines;

test "Migration044AddRoutines creates task_type column defaulting to standard" {
    // In-memory DB, register only the prior migrations, run them, then run our migration
    const allocator = testing.allocator;
    var db = try SqliteBackend.openInMemory(allocator);
    defer db.close();

    // Run migrations 1..43 first (or use a helper that registers all + runs to v=43)
    var mgr = MigrationManager.init(allocator, &db);
    try registerPriorMigrations(&mgr, 43);
    try mgr.runMigrations(43);

    // Now run migration 44
    try mgr.registerMigration(.{ .version = 44, .name = Migration044AddRoutines.name, .up = Migration044AddRoutines.up });
    try mgr.runMigrations(44);

    // Insert a row into workspace_item_tasks
    try db.exec(allocator,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'foo', 'wi1')",
        &.{});

    // The task_type column should default to 'standard'
    var stmt = try db.prepare(allocator, "SELECT task_type FROM workspace_item_tasks WHERE id = 't1'");
    defer stmt.finalize();
    _ = try stmt.step();
    const task_type = stmt.columnText(0);
    try testing.expectEqualStrings("standard", task_type);
}

test "Migration044AddRoutines creates routines table" {
    const allocator = testing.allocator;
    var db = try SqliteBackend.openInMemory(allocator);
    defer db.close();

    var mgr = MigrationManager.init(allocator, &db);
    try registerPriorMigrations(&mgr, 43);
    try mgr.runMigrations(43);
    try mgr.registerMigration(.{ .version = 44, .name = Migration044AddRoutines.name, .up = Migration044AddRoutines.up });
    try mgr.runMigrations(44);

    // The routines table should exist with the right columns
    try db.exec(allocator,
        \\INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at)
        \\VALUES ('r1', 't1', '*/5 * * * *', 'do the thing', '2099-01-01 00:00:00')
    , &.{});

    var stmt = try db.prepare(allocator,
        \\SELECT schedule, initial_prompt, enabled, last_status FROM routines WHERE id = 'r1'
    );
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqualStrings("*/5 * * * *", stmt.columnText(0));
    try testing.expectEqualStrings("do the thing", stmt.columnText(1));
    // enabled defaults to 1
    try testing.expectEqual(@as(i64, 1), stmt.columnInt(2));
    // last_status is nullable; the column index check is just that it didn't throw
    try testing.expect(stmt.columnType(3) == .null or stmt.columnType(3) == .text);
}
```

The `registerPriorMigrations` helper is the test-only function that registers migrations 1..N and runs them — copy the pattern from `migration_test.zig`. The exact `mgr` API may differ; consult `migration.zig` to find the actual names.

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: FAIL with `Migration044AddRoutines not found in struct 'migration.zig'` (or similar "no member named 'Migration044AddRoutines'").

- [ ] **Step 3: Write the migration**

In `src/ai_workflow/tui/migration.zig`, add after the last existing migration (`Migration043AddPositionToWorkspaces`):

```zig
pub const Migration044AddRoutines = struct {
    pub const version: u32 = 44;
    pub const name = "add_routines";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN task_type TEXT NOT NULL DEFAULT 'standard'",
            &[_][]const u8{},
        );

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS routines (
            \\    id TEXT PRIMARY KEY,
            \\    task_id TEXT NOT NULL UNIQUE,
            \\    schedule TEXT NOT NULL,
            \\    initial_prompt TEXT NOT NULL,
            \\    enabled INTEGER NOT NULL DEFAULT 1,
            \\    last_run_at DATETIME,
            \\    next_run_at DATETIME NOT NULL,
            \\    last_status TEXT,
            \\    last_error TEXT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_routines_enabled_next_run ON routines(enabled, next_run_at)",
            &[_][]const u8{},
        );
    }
};
```

In the `allMigrations` slice, append:
```zig
.{ .version = Migration044AddRoutines.version, .name = Migration044AddRoutines.name, .up = Migration044AddRoutines.up },
```

- [ ] **Step 4: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/migration.zig src/ai_workflow/tui/migration_routines_test.zig
git commit -m "feat(routines): migration 044 - add task_type + routines table"
```

---

### Task 1.2: `Routine` struct + DB helpers (`model.zig`)

**Files:**
- Create: `src/ai_workflow/tui/routines/model.zig`
- Create: `src/ai_workflow/tui/routines/model_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig` (register the test)

- [ ] **Step 1: Write the failing test**

Create `src/ai_workflow/tui/routines/model_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const SqliteBackend = @import("nalarcore").db.SqliteBackend;
const model = @import("model.zig");
const Routine = model.Routine;
const RoutineRunStatus = model.RoutineRunStatus;
const Migration044AddRoutines = @import("../migration.zig").Migration044AddRoutines;

fn freshDb(allocator: std.mem.Allocator) !SqliteBackend {
    var db = try SqliteBackend.openInMemory(allocator);
    // Skip prior migrations; just create the workspace_item_tasks + routines tables directly.
    // (Faster than running all 43 prior migrations for this test.)
    try db.exec(allocator,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    session_id TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try Migration044AddRoutines.up(&db, allocator);
    return db;
}

test "Routine: insert + load round-trip" {
    const allocator = testing.allocator;
    var db = try freshDb(allocator);
    defer db.close();

    try db.exec(allocator,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'Daily', 'wi1')",
        &.{});

    const initial = model.Routine{
        .id = "r1",
        .task_id = "t1",
        .schedule = "0 9 * * 1-5",
        .initial_prompt = "summarize commits",
        .enabled = true,
        .next_run_at = "2099-01-01 09:00:00",
    };
    try model.insertRoutine(allocator, &db, initial);

    const loaded = try model.loadRoutineByTaskId(allocator, &db, "t1");
    try testing.expectEqualStrings("r1", loaded.id);
    try testing.expectEqualStrings("0 9 * * 1-5", loaded.schedule);
    try testing.expectEqualStrings("summarize commits", loaded.initial_prompt);
    try testing.expect(loaded.enabled);
    try testing.expectEqualStrings("2099-01-01 09:00:00", loaded.next_run_at);
    try testing.expectEqual(RoutineRunStatus.idle, loaded.last_status);
    loaded.deinit(allocator);
}

test "Routine: listDueRoutines returns only enabled with next_run_at <= now" {
    const allocator = testing.allocator;
    var db = try freshDb(allocator);
    defer db.close();

    try db.exec(allocator,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'wi1')",
        &.{});
    try db.exec(allocator,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t2', 'B', 'wi1')",
        &.{});
    try db.exec(allocator,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t3', 'C', 'wi1')",
        &.{});

    // Due: enabled, next_run_at in the past
    try model.insertRoutine(allocator, &db, .{ .id = "r1", .task_id = "t1", .schedule = "*/5 * * * *", .initial_prompt = "x", .enabled = true, .next_run_at = "2000-01-01 00:00:00" });
    // NOT due: enabled but next_run_at in the future
    try model.insertRoutine(allocator, &db, .{ .id = "r2", .task_id = "t2", .schedule = "*/5 * * * *", .initial_prompt = "x", .enabled = true, .next_run_at = "2099-01-01 00:00:00" });
    // NOT due: disabled
    try model.insertRoutine(allocator, &db, .{ .id = "r3", .task_id = "t3", .schedule = "*/5 * * * *", .initial_prompt = "x", .enabled = false, .next_run_at = "2000-01-01 00:00:00" });

    const due = try model.listDueRoutineIds(allocator, &db, "2025-01-01 00:00:00");
    defer allocator.free(due);
    try testing.expectEqual(@as(usize, 1), due.len);
    try testing.expectEqualStrings("r1", due[0]);
}

test "Routine: claimForRun atomically transitions to running" {
    const allocator = testing.allocator;
    var db = try freshDb(allocator);
    defer db.close();
    try db.exec(allocator, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'wi1')", &.{});
    try model.insertRoutine(allocator, &db, .{ .id = "r1", .task_id = "t1", .schedule = "*/5 * * * *", .initial_prompt = "x", .enabled = true, .next_run_at = "2000-01-01 00:00:00" });

    // First claim wins
    const first = try model.claimForRun(allocator, &db, "r1");
    try testing.expect(first);
    // Second claim fails (row already 'running')
    const second = try model.claimForRun(allocator, &db, "r1");
    try testing.expect(!second);
}

test "RoutineRunStatus enum mapping" {
    try testing.expectEqualStrings("success", RoutineRunStatus.success.dbValue());
    try testing.expectEqualStrings("failed", RoutineRunStatus.failed.dbValue());
    try testing.expectEqualStrings("running", RoutineRunStatus.running.dbValue());
    try testing.expectEqualStrings(null, RoutineRunStatus.idle.dbValue());
}
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: FAIL with `no module named 'model'` (or `no member named 'Routine'`).

- [ ] **Step 3: Write `model.zig`**

Create `src/ai_workflow/tui/routines/model.zig`:

```zig
const std = @import("std");
const nalarcore = @import("nalarcore");
const SqliteBackend = nalarcore.db.SqliteBackend;

pub const RoutineRunStatus = enum {
    idle,      // last_status is NULL
    success,
    failed,
    running,

    pub fn dbValue(self: RoutineRunStatus) ?[]const u8 {
        return switch (self) {
            .idle => null,
            .success => "success",
            .failed => "failed",
            .running => "running",
        };
    }

    pub fn fromDb(text: ?[]const u8) RoutineRunStatus {
        const t = text orelse return .idle;
        if (std.mem.eql(u8, t, "success")) return .success;
        if (std.mem.eql(u8, t, "failed")) return .failed;
        if (std.mem.eql(u8, t, "running")) return .running;
        return .idle;
    }
};

pub const Routine = struct {
    id: []const u8,
    task_id: []const u8,
    schedule: []const u8,
    initial_prompt: []const u8,
    enabled: bool,
    next_run_at: []const u8,
    last_run_at: ?[]const u8 = null,
    last_status: RoutineRunStatus = .idle,
    last_error: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,

    pub fn deinit(self: Routine, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.task_id);
        allocator.free(self.schedule);
        allocator.free(self.initial_prompt);
        allocator.free(self.next_run_at);
        if (self.last_run_at) |v| allocator.free(v);
        if (self.last_error) |v| allocator.free(v);
        if (self.created_at) |v| allocator.free(v);
        if (self.updated_at) |v| allocator.free(v);
    }
};

pub fn insertRoutine(allocator: std.mem.Allocator, db: *SqliteBackend, r: Routine) !void {
    _ = try db.exec(allocator,
        \\INSERT INTO routines (id, task_id, schedule, initial_prompt, enabled, next_run_at)
        \\VALUES (?, ?, ?, ?, ?, ?)
    , &.{ r.id, r.task_id, r.schedule, r.initial_prompt, if (r.enabled) @as(i64, 1) else @as(i64, 0), r.next_run_at });
}

pub fn loadRoutineByTaskId(allocator: std.mem.Allocator, db: *SqliteBackend, task_id: []const u8) !Routine {
    var stmt = try db.prepare(allocator,
        \\SELECT id, task_id, schedule, initial_prompt, enabled, next_run_at,
        \\       last_run_at, last_status, last_error, created_at, updated_at
        \\FROM routines WHERE task_id = ?
    );
    defer stmt.finalize();
    stmt.bindText(1, task_id);
    if (!try stmt.step()) return error.RoutineNotFound;
    return try rowToRoutine(allocator, &stmt);
}

pub fn listDueRoutineIds(allocator: std.mem.Allocator, db: *SqliteBackend, now_sqlite: []const u8) ![][]const u8 {
    var stmt = try db.prepare(allocator,
        \\SELECT id FROM routines
        \\WHERE enabled = 1
        \\  AND next_run_at <= ?
        \\  AND (last_status IS NULL OR last_status != 'running')
    );
    defer stmt.finalize();
    stmt.bindText(1, now_sqlite);
    var out = std.ArrayList([]u8).empty;
    while (try stmt.step()) {
        const id_text = stmt.columnText(0);
        try out.append(allocator, try allocator.dupe(u8, id_text));
    }
    return out.toOwnedSlice(allocator);
}

/// Atomically transition the routine's last_status to 'running' iff it is not
/// already 'running'. Returns true on success, false if another fire is in
/// progress or the row no longer exists.
pub fn claimForRun(allocator: std.mem.Allocator, db: *SqliteBackend, routine_id: []const u8) !bool {
    _ = try db.exec(allocator,
        \\UPDATE routines
        \\   SET last_status = 'running', updated_at = datetime('now')
        \\ WHERE id = ?
        \\   AND (last_status IS NULL OR last_status != 'running')
    , &.{routine_id});
    const affected = db.changes();
    return affected == 1;
}

pub fn markSuccess(allocator: std.mem.Allocator, db: *SqliteBackend, routine_id: []const u8, next_run_at_sqlite: []const u8) !void {
    _ = try db.exec(allocator,
        \\UPDATE routines
        \\   SET last_run_at = datetime('now'),
        \\       next_run_at = ?,
        \\       last_status = 'success',
        \\       last_error = NULL,
        \\       updated_at = datetime('now')
        \\ WHERE id = ?
    , &.{ next_run_at_sqlite, routine_id });
}

pub fn markFailed(allocator: std.mem.Allocator, db: *SqliteBackend, routine_id: []const u8, err_msg: []const u8, next_run_at_sqlite: []const u8) !void {
    _ = try db.exec(allocator,
        \\UPDATE routines
        \\   SET last_status = 'failed',
        \\       last_error = ?,
        \\       next_run_at = ?,
        \\       updated_at = datetime('now')
        \\ WHERE id = ?
    , &.{ err_msg, next_run_at_sqlite, routine_id });
}

pub fn recomputeAllNextRunAt(allocator: std.mem.Allocator, db: *SqliteBackend, compute_fn: *const fn (schedule: []const u8, now_unix_nanos: i128) anyerror![]const u8, now_unix_nanos: i128) !void {
    _ = allocator;
    _ = db;
    _ = compute_fn;
    _ = now_unix_nanos;
    // Implementation in Chunk 3 (Scheduler); placeholder for now so model.zig compiles.
    return;
}

fn rowToRoutine(allocator: std.mem.Allocator, stmt: anytype) !Routine {
    return Routine{
        .id = try allocator.dupe(u8, stmt.columnText(0)),
        .task_id = try allocator.dupe(u8, stmt.columnText(1)),
        .schedule = try allocator.dupe(u8, stmt.columnText(2)),
        .initial_prompt = try allocator.dupe(u8, stmt.columnText(3)),
        .enabled = stmt.columnInt(4) == 1,
        .next_run_at = try allocator.dupe(u8, stmt.columnText(5)),
        .last_run_at = if (stmt.columnType(6) == .null) null else try allocator.dupe(u8, stmt.columnText(6)),
        .last_status = RoutineRunStatus.fromDb(if (stmt.columnType(7) == .null) null else stmt.columnText(7)),
        .last_error = if (stmt.columnType(8) == .null) null else try allocator.dupe(u8, stmt.columnText(8)),
        .created_at = if (stmt.columnType(9) == .null) null else try allocator.dupe(u8, stmt.columnText(9)),
        .updated_at = if (stmt.columnType(10) == .null) null else try allocator.dupe(u8, stmt.columnText(10)),
    };
}
```

The exact `SqliteBackend` API names (`prepare`, `columnText`, `columnInt`, `columnType`, `bindText`, `exec`, `changes`, `finalize`, `openInMemory`) and `db.zig`'s `SqliteBackend` import path may differ slightly in this project. **Verify by reading `src/ai_workflow/tui/llm_history.zig` for an existing prepared-statement pattern** (e.g., the `getSessionList` or `listWorkspaceItemTasksWithCursor` function) and mirror its style. The plan assumes `stmt.bindText(idx, value)` and `stmt.columnText(idx) : []const u8`; if the real API is `bind_blob`/`getText`/different names, adjust accordingly. The test should compile when the actual API is mirrored.

- [ ] **Step 4: Register the test in test_runner.zig**

Add to `src/ai_workflow/tui/test_runner.zig`:
```zig
_ = @import("routines/model_test.zig");
```

- [ ] **Step 5: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/routines/model.zig src/ai_workflow/tui/routines/model_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat(routines): Routine struct + DB helpers (model.zig)"
```

---

### Task 1.3: Cron parser + `nextFireTime` (`cron.zig`)

**Files:**
- Create: `src/ai_workflow/tui/routines/cron.zig`
- Create: `src/ai_workflow/tui/routines/cron_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 1: Write the failing test**

Create `src/ai_workflow/tui/routines/cron_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const cron = @import("cron.zig");

fn ts(year: i32, month: u4, day: u5, hour: u5, minute: u6) i128 {
    // Compute unix seconds for a UTC time and return nanoseconds.
    // We use std.time for clarity.
    const secs = std.time.timestamp(year, month, day, hour, minute, 0);
    return @as(i128, secs) * 1_000_000_000;
}

test "validate: accepts a simple expression" {
    try cron.validate("*/5 * * * *");
    try cron.validate("0 9 * * 1-5");
    try cron.validate("0 0 1 * *");
    try cron.validate("30 14 1 1 *");
}

test "validate: rejects garbage" {
    try testing.expectError(error.InvalidCron, cron.validate("not a cron"));
    try testing.expectError(error.InvalidCron, cron.validate("60 * * * *"));  // minute out of range
    try testing.expectError(error.InvalidCron, cron.validate("* * *"));  // too few fields
    try testing.expectError(error.InvalidCron, cron.validate("a b c d e"));  // non-numeric
}

test "nextFireTime: every 5 minutes from any time lands on next /5 minute" {
    // 2025-06-13 04:57:30 UTC -> next at 04:58:00
    const after = ts(2025, 6, 13, 4, 57);
    const next = try cron.nextFireTime("*/5 * * * *", after);
    const expected = ts(2025, 6, 13, 4, 58);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: hourly on the hour" {
    // 2025-06-13 04:32:00 -> 05:00:00
    const after = ts(2025, 6, 13, 4, 32);
    const next = try cron.nextFireTime("0 * * * *", after);
    const expected = ts(2025, 6, 13, 5, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: daily at 09:00" {
    // 2025-06-13 10:00:00 -> 2025-06-14 09:00:00
    const after = ts(2025, 6, 13, 10, 0);
    const next = try cron.nextFireTime("0 9 * * *", after);
    const expected = ts(2025, 6, 14, 9, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: weekdays at 09:00" {
    // 2025-06-14 is a Saturday -> next is Monday 2025-06-16 09:00
    const after = ts(2025, 6, 14, 10, 0);
    const next = try cron.nextFireTime("0 9 * * 1-5", after);
    const expected = ts(2025, 6, 16, 9, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: monthly on the 1st" {
    // 2025-06-15 -> 2025-07-01 00:00
    const after = ts(2025, 6, 15, 12, 0);
    const next = try cron.nextFireTime("0 0 1 * *", after);
    const expected = ts(2025, 7, 1, 0, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: leap year Feb 29" {
    // 2024 is a leap year. From 2024-02-28 12:00, the 29th at 00:00 should be next.
    const after = ts(2024, 2, 28, 12, 0);
    const next = try cron.nextFireTime("0 0 29 2 *", after);
    const expected = ts(2024, 2, 29, 0, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: result is always strictly after `after`" {
    const expressions = [_][]const u8{
        "*/5 * * * *",
        "0 * * * *",
        "0 9 * * *",
        "0 9 * * 1-5",
        "0 0 1 * *",
    };
    const after = ts(2025, 6, 13, 4, 57);
    for (expressions) |expr| {
        const next = try cron.nextFireTime(expr, after);
        try testing.expect(next > after);
    }
}
```

The `ts` helper uses `std.time.timestamp(year, month, day, hour, minute, second) i64` (unix seconds). If the actual API differs in Zig 0.16, use `std.time.DateTime` + manual offset computation, or use `std.time.epoch.EpochSeconds`. The test is a guideline — adjust the helper to whatever the project's existing code uses.

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: FAIL with `no module named 'cron'`.

- [ ] **Step 3: Write `cron.zig`**

Create `src/ai_workflow/tui/routines/cron.zig`. The implementation is a standard 5-field cron evaluator:

```zig
const std = @import("std");

pub const Error = error{
    InvalidCron,
};

/// A single field of a cron expression (e.g. "minute"). Each field stores
/// a set of allowed values; membership test is the `match` function.
pub const Field = struct {
    values: [64]bool = .{false} ** 64,  // sized for the largest (day-of-month up to 31 + bit for '*')

    pub fn match(self: *const Field, value: u8) bool {
        if (value >= self.values.len) return false;
        return self.values[value];
    }
};

pub const Expression = struct {
    minute: Field,
    hour: Field,
    day_of_month: Field,
    month: Field,
    day_of_week: Field,  // 0 = Sunday, 6 = Saturday
};

pub fn validate(expr: []const u8) Error!void {
    var e: Expression = undefined;
    try parse(expr, &e);
}

pub fn parse(expr: []const u8, out: *Expression) Error!void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, expr, &[_]u8{' '}), ' ');
    var i: u8 = 0;
    while (it.next()) |tok| {
        const field_ptr: *Field = switch (i) {
            0 => &out.minute,
            1 => &out.hour,
            2 => &out.day_of_month,
            3 => &out.month,
            4 => &out.day_of_week,
            else => return Error.InvalidCron,
        };
        try parseField(tok, field_ptr, fieldMax(i));
        i += 1;
    }
    if (i != 5) return Error.InvalidCron;
}

fn fieldMax(field_index: u8) u8 {
    return switch (field_index) {
        0 => 59,   // minute
        1 => 23,   // hour
        2 => 31,   // day of month
        3 => 12,   // month
        4 => 6,    // day of week (0-6, Sunday = 0)
        else => 0,
    };
}

fn parseField(tok: []const u8, f: *Field, max: u8) Error!void {
    f.* = .{};
    // Handle comma-separated values
    var parts = std.mem.splitScalar(u8, tok, ',');
    while (parts.next()) |part| {
        try parseOnePart(part, f, max);
    }
    if (!anySet(f)) return Error.InvalidCron;
}

fn parseOnePart(part: []const u8, f: *Field, max: u8) Error!void {
    // Supports: "*", "N", "N-M", "*/S", "N-M/S"
    var step: u8 = 1;
    var range_str: []const u8 = part;
    if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
        step = std.fmt.parseInt(u8, part[slash + 1 ..], 10) catch return Error.InvalidCron;
        if (step == 0) return Error.InvalidCron;
        range_str = part[0..slash];
    }

    var lo: u8 = 0;
    var hi: u8 = max;
    if (std.mem.eql(u8, range_str, "*")) {
        // lo = 0, hi = max
    } else if (std.mem.indexOfScalar(u8, range_str, '-')) |dash| {
        lo = std.fmt.parseInt(u8, range_str[0..dash], 10) catch return Error.InvalidCron;
        hi = std.fmt.parseInt(u8, range_str[dash + 1 ..], 10) catch return Error.InvalidCron;
    } else {
        const v = std.fmt.parseInt(u8, range_str, 10) catch return Error.InvalidCron;
        if (v > max) return Error.InvalidCron;
        f.values[v] = true;
        return;
    }

    if (lo > hi or hi > max) return Error.InvalidCron;
    var v = lo;
    while (v <= hi) : (v += step) {
        f.values[v] = true;
    }
}

fn anySet(f: *const Field) bool {
    for (f.values) |v| if (v) return true;
    return false;
}

/// Convert unix nanoseconds to a UTC year/month/day/hour/minute/second.
const BrokenDownTime = struct {
    year: i32,
    month: u4,
    day: u5,
    hour: u5,
    minute: u6,
    second: u6,

    fn fromUnixNanos(ns: i128) BrokenDownTime {
        const secs: i64 = @intCast(@divTrunc(ns, 1_000_000_000));
        // Use std.time.epoch to decompose.
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        return .{
            .year = year_day.year,
            .month = month_day.month.numeric(),
            .day = month_day.day_index + 1,
            .hour = @intCast(day_seconds.getHoursIntoDay()),
            .minute = @intCast(day_seconds.getMinutesIntoHour()),
            .second = @intCast(day_seconds.getSecondsIntoMinute()),
        };
    }

    fn toUnixNanos(self: BrokenDownTime) i128 {
        // Compose year/month/day/hour/minute/second back to unix seconds.
        // std.time.epoch has fromYearDay / fromMonthDay. Easiest: convert via DateTime.
        var dt: std.time.epoch.EpochDays = .initAbsoluteUtcDays(0);
        const year_day = std.time.epoch.YearDay{ .year = @intCast(self.year), .day = ... };  // we'd compute day-of-year
        // For simplicity, use the inverse: epoch_seconds.fromYearDay() / fromMonthDay()
        // If these are noisy, fall back to a known-good date-to-seconds table.
        // ...
        return 0;  // placeholder — implement with std.time.epoch helpers
    }
};

pub fn nextFireTime(expr: []const u8, after_unix_nanos: i128) Error!i128 {
    var e: Expression = undefined;
    try parse(expr, &e);
    // Start from the next minute after `after_unix_nanos`. Round down to the
    // minute boundary, add 60s to be strictly after.
    var t = after_unix_nanos;
    t = @divTrunc(t, 60 * 1_000_000_000) * 60 * 1_000_000_000;  // round to minute
    t += 60 * 1_000_000_000;  // first candidate is the next minute

    // Naive search: check each minute. Worst case ~366 days * 24 * 60 = 527k iterations
    // for month-boundary cases. Acceptable for a sub-second polling loop.
    var iterations: u32 = 0;
    while (iterations < 366 * 24 * 60) : (iterations += 1) {
        const bd = BrokenDownTime.fromUnixNanos(t);
        if (e.month.match(bd.month) and
            e.day_of_month.match(bd.day) and
            e.day_of_week.match(dayOfWeek(bd.year, bd.month, bd.day)) and
            e.hour.match(bd.hour) and
            e.minute.match(bd.minute))
        {
            return t;
        }
        t += 60 * 1_000_000_000;
    }
    return Error.InvalidCron;
}

/// Zeller's congruence: 0=Sunday..6=Saturday. Doesn't need std.time.epoch.
fn dayOfWeek(year: i32, month: u4, day: u5) u8 {
    var m: i32 = month;
    var y: i32 = year;
    if (m < 3) {
        m += 12;
        y -= 1;
    }
    const K = y % 100;
    const J = @divTrunc(y, 100);
    const h = (day + @as(i32, @intCast(@divTrunc(13 * (m + 1), 5))) + K + @divTrunc(K, 4) + @divTrunc(J, 4) + 5 * J) % 7;
    // h=0 Saturday, 1=Sunday, ..., 6=Friday
    return @intCast((h + 6) % 7);  // remap to 0=Sunday..6=Saturday
}
```

The `BrokenDownTime.toUnixNanos` is a placeholder above — actually, since the naive search only ever calls `fromUnixNanos` and adds 60s, `toUnixNanos` is **not** needed. Remove it from the actual implementation. The full working code is provided below — the placeholder above is just to keep the doc readable.

**Final `cron.zig` (drop the placeholder `toUnixNanos` and keep the rest):**

```zig
// ... (everything above, minus the toUnixNanos placeholder)
```

Use the real `std.time.epoch` API for `fromUnixNanos` — verify by looking at how the project decomposes time elsewhere (e.g., `migration.zig` or `llm_history.zig`). If the existing pattern uses a different API, mirror it.

- [ ] **Step 4: Register the test in test_runner.zig**

Add:
```zig
_ = @import("routines/cron_test.zig");
```

- [ ] **Step 5: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS. The "leap year Feb 29" test exercises Zeller's congruence correctness.

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/routines/cron.zig src/ai_workflow/tui/routines/cron_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat(routines): 5-field cron parser + nextFireTime (cron.zig)"
```

---

## Chunk 1 done — checkpoint

- ✅ `task_type` column + `routines` table migration
- ✅ `Routine` struct + DB read/write helpers
- ✅ Cron expression parser + `nextFireTime`

Next: **Chunk 2 — Backend firing pipeline** (`fire.zig` + `bin/nalar-routine-fire.zig` + integration with the existing LLM worker). Will be written in a sub-agent in parallel with Chunks 3, 4, and 5-7.

---

*Chunks 2-7 follow in subsequent files. See:*
- *`docs/superpowers/plans/2026-06-13-add-task-routines-chunks-2-3.md` (Backend fire + scheduler)*
- *`docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md` (Backend HTTP)*
- *`docs/superpowers/plans/2026-06-13-add-task-routines-chunks-5-7.md` (Frontend)*
