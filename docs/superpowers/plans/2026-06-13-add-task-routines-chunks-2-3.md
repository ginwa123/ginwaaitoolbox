# Add Task Routines — Chunks 2 & 3: Backend fire pipeline + scheduler

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Context:** This file covers Chunks 2 and 3 of the larger `Add Task Routines` plan. Read [`docs/superpowers/plans/2026-06-13-add-task-routines.md`](2026-06-13-add-task-routines.md) for the file structure, the spec at [`docs/plans/2026-06-13-add-task-routines-design.md`](../plans/2026-06-13-add-task-routines-design.md), and Chunk 1 (data model + cron parser) which is already implemented. Do NOT touch Chunk 1 code; this file is self-contained and implementable from cold-start.

**Goal:** Wire the routine fire pipeline (`fire.zig` + `bin/nalar-routine-fire` sub-process binary) and the in-process polling scheduler (`Scheduler.zig` + `startup.zig` wiring). At the end, a routine with `next_run_at` in the past is fired automatically by the scheduler, pushes a `🔁 Routine fire — <name> — <timestamp>` user message into its session, invokes the existing LLM worker pipeline, and updates `last_status` / `next_run_at` / `last_error`.

**Architecture (see design doc §3, §4 for full details):**
- Per-fire work runs in a fresh sub-process `bin/nalar-routine-fire --id <id>`. One process per fire — slow LLM calls (minutes) can't block the scheduler's polling.
- Scheduler is a 5s polling loop in the main `nalar` process. Each tick: (1) reset stuck `running` rows, (2) recompute `next_run_at` for due routines, (3) list due ids, (4) `std.process.spawn` `bin/nalar-routine-fire --id <id>` per id (fire-and-forget — no `child.wait`).
- Restart safety: on `Scheduler.start`, do stuck-row reset + due-`next_run_at` recompute BEFORE the first poll.
- `fireRoutine(allocator, db, io, task_id)` (called by the sub-process) loads the routine, atomically claims the row, pushes a user-style 🔁 message, then `event_bus.emit(ai_workflow.RunParamsNew, "ai_worker_flow", params)` — the same event `session_create.zig:184` emits, picked up by `CallbackAiWorkerFlow.callback` (subscribed in `src/main.zig:306`).
- `next_run_at` is computed via `cron.nextFireTime(schedule, now_unix_nanos)`, then formatted to `YYYY-MM-DD HH:MM:SS` (SQLite's `DATETIME`).

**Key existing files referenced:**
- `src/ai_workflow/tui/workflow.zig` — `runAgenticMultiStepnew(di, params)` is the LLM worker, called by `CallbackAiWorkerFlow.callback`.
- `src/ai_workflow/tui/http_handlers/session_create.zig:184` — canonical example of `RunParamsNew` emit.
- `src/ai_workflow/tui/notifications.zig:130-147` — canonical example of `std.process.spawn` fire-and-forget.
- `src/ai_workflow/tui/llm_history.zig:899` — `SaveMessageInput` struct; use `llm_history.saveMessage` to insert the 🔁 user-style message.
- `src/ai_workflow/tui/routines/model.zig` (Chunk 1) — `Routine`, `RoutineRunStatus`, `insertRoutine`, `loadRoutineByTaskId`, `listDueRoutineIds`, `claimForRun`, `markSuccess`, `markFailed`.
- `src/ai_workflow/tui/routines/cron.zig` (Chunk 1) — `nextFireTime(expr, after_unix_nanos) !i128`.

---

## File changes

### New files
- `src/ai_workflow/tui/routines/fire.zig` — `fireRoutine(allocator, db, io, task_id) !void`.
- `src/ai_workflow/tui/routines/fire_test.zig` — tests (env-var `ROUTINE_FIRE_TEST_SKIP_LLM=1` skips the LLM emit).
- `src/ai_workflow/tui/routines/Scheduler.zig` — `Scheduler.start(allocator, db, io) !void` polling loop + helpers.
- `src/ai_workflow/tui/routines/scheduler_test.zig` — unit + integration tests.
- `src/ai_workflow/tui/routines/bin/nalar-routine-fire.zig` — sub-process entry point.
- `src/ai_workflow/tui/routines/mod.zig` — re-exports.

### Modified files
- `src/ai_workflow/tui/mod.zig` — add `pub const routines = @import("routines/mod.zig");`.
- `src/ai_workflow/tui/test_runner.zig` — register `fire_test.zig`, `scheduler_test.zig`.
- `src/ai_workflow/tui/startup.zig` — `pub fn start(...)` spawns the scheduler on a new thread.
- `src/main.zig` — call `startup.start(...)` after migrations.
- `build.zig` — new `install:routine-fire` build step.
- `src/ai_workflow/tui/routines/model.zig` — replace the Chunk 1 placeholder `recomputeAllNextRunAt` (Task 3.4).

---

## Chunk 2: Backend firing pipeline (`fire.zig` + sub-process binary)

**How the LLM gets invoked:** `fireRoutine` does NOT call `runAgenticMultiStepnew` directly. It `event_bus.emit(ai_workflow.RunParamsNew, "ai_worker_flow", params)` — exactly what `session_create.zig:184` does. The `CallbackAiWorkerFlow.callback` subscription in `main.zig:306` picks it up on a worker thread. `task.id == session_id` is the codebase invariant.

**Mock for tests:** Tests set env var `ROUTINE_FIRE_TEST_SKIP_LLM=1`; the fire pipeline returns `error.FakeLLMSuccess` (a sentinel) so the test can assert on the user-message + state-mutation paths without invoking an LLM.

### Task 2.1: `fire.zig` — the per-fire work

**Files:**
- Create: `src/ai_workflow/tui/routines/fire.zig`
- Create: `src/ai_workflow/tui/routines/fire_test.zig`
- Create: `src/ai_workflow/tui/routines/mod.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 1: Write the failing test**

Create `src/ai_workflow/tui/routines/fire_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const SqliteBackend = @import("nalarcore").db.SqliteBackend;
const model = @import("model.zig");
const fire = @import("fire.zig");
const Migration044AddRoutines = @import("../migration.zig").Migration044AddRoutines;

fn freshDb(allocator: std.mem.Allocator) !SqliteBackend {
    var db = try SqliteBackend.openInMemory(allocator);
    try db.exec(allocator, "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL, session_id TEXT)", &.{});
    try db.exec(allocator, "CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, model TEXT, response_content TEXT, finish_reason TEXT, role TEXT, tool_calls_json TEXT, tool_call_id TEXT, reasoning_content TEXT, is_feed_to_llm INTEGER DEFAULT 1, agent TEXT, loop_index INTEGER DEFAULT 0, temperature REAL DEFAULT 0.0, is_thinking INTEGER DEFAULT 0, created_at TEXT, parent_session_id TEXT, parent_id TEXT, prompt_tokens INTEGER DEFAULT 0, completion_tokens INTEGER DEFAULT 0, total_tokens INTEGER DEFAULT 0, is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, tool_name TEXT, diffview_before TEXT, diffview_after TEXT, image_url TEXT)", &.{});
    try db.exec(allocator, "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT, status TEXT, cwd TEXT, selected_profile_model TEXT, created_at TEXT, updated_at TEXT)", &.{});
    try Migration044AddRoutines.up(&db, allocator);
    return db;
}

fn withSkipLlmEnv(allocator: std.mem.Allocator, value: []const u8, body: *const fn () anyerror!void) anyerror!void {
    const env = "ROUTINE_FIRE_TEST_SKIP_LLM";
    const prev = std.process.getEnvVar(allocator, env) catch null;
    defer if (prev) |p| { std.process.setEnvVar(allocator, env, p) catch {}; allocator.free(p); };
    try std.process.setEnvVar(allocator, env, value);
    try body();
}

test "fireRoutine inserts a user-style 🔁 message into the session" {
    const allocator = testing.allocator;
    try withSkipLlmEnv(allocator, "1", struct {
        fn run() !void {
            const alloc = testing.allocator;
            var db = try freshDb(alloc);
            defer db.close();
            try db.exec(alloc,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id) VALUES ('t1', 'Daily', 'wi1', 't1')",
                &.{});
            try model.insertRoutine(alloc, &db, .{
                .id = "r1", .task_id = "t1", .schedule = "0 9 * * *",
                .initial_prompt = "summarize commits", .enabled = true,
                .next_run_at = "2000-01-01 00:00:00",
            });
            const err = fire.fireRoutine(alloc, &db, std.testing.io, "t1") catch |e| e;
            try testing.expectEqual(fire.FireError.FakeLLMSuccess, err);

            var stmt = try db.prepare(alloc,
                "SELECT response_content, role FROM llm_history WHERE session_id = 't1'");
            defer stmt.finalize();
            _ = try stmt.step();
            const content = try alloc.dupe(u8, stmt.columnText(0));
            defer alloc.free(content);
            try testing.expect(std.mem.indexOf(u8, content, "🔁") != null);
            try testing.expect(std.mem.indexOf(u8, content, "summarize commits") != null);
            try testing.expectEqualStrings("user", stmt.columnText(1));
        }
    }.run);
}

test "fireRoutine rejects a second concurrent fire (atomic claim)" {
    const allocator = testing.allocator;
    try withSkipLlmEnv(allocator, "1", struct {
        fn run() !void {
            const alloc = testing.allocator;
            var db = try freshDb(alloc);
            defer db.close();
            try db.exec(alloc,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id) VALUES ('t1', 'A', 'wi1', 't1')", &.{});
            try model.insertRoutine(alloc, &db, .{
                .id = "r1", .task_id = "t1", .schedule = "*/5 * * * *",
                .initial_prompt = "x", .enabled = true, .next_run_at = "2000-01-01 00:00:00",
            });
            try db.exec(alloc, "UPDATE routines SET last_status = 'running' WHERE id = 'r1'", &.{});
            const err = fire.fireRoutine(alloc, &db, std.testing.io, "t1") catch |e| e;
            try testing.expectEqual(fire.FireError.AlreadyRunning, err);

            var stmt = try db.prepare(alloc, "SELECT COUNT(*) FROM llm_history WHERE session_id = 't1'");
            defer stmt.finalize();
            _ = try stmt.step();
            try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
        }
    }.run);
}

test "fireRoutine on a non-routine task returns NotARoutine" {
    const allocator = testing.allocator;
    var db = try freshDb(allocator);
    defer db.close();
    try db.exec(allocator, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id) VALUES ('t1', 'A', 'wi1', 't1')", &.{});
    const err = fire.fireRoutine(allocator, &db, std.testing.io, "t1") catch |e| e;
    try testing.expectEqual(fire.FireError.NotARoutine, err);
}

test "fireRoutine on a disabled routine returns Disabled" {
    const allocator = testing.allocator;
    var db = try freshDb(allocator);
    defer db.close();
    try db.exec(allocator, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id) VALUES ('t1', 'A', 'wi1', 't1')", &.{});
    try model.insertRoutine(allocator, &db, .{
        .id = "r1", .task_id = "t1", .schedule = "*/5 * * * *",
        .initial_prompt = "x", .enabled = false, .next_run_at = "2000-01-01 00:00:00",
    });
    const err = fire.fireRoutine(allocator, &db, std.testing.io, "t1") catch |e| e;
    try testing.expectEqual(fire.FireError.Disabled, err);
}
```

Create `src/ai_workflow/tui/routines/mod.zig`:

```zig
pub const model = @import("model.zig");
pub const cron = @import("cron.zig");
pub const fire = @import("fire.zig");
pub const Scheduler = @import("Scheduler.zig");
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: FAIL with `no module named 'fire'`.

- [ ] **Step 3: Write the implementation**

Create `src/ai_workflow/tui/routines/fire.zig`:

```zig
const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const model = @import("model.zig");
const Routine = model.Routine;
const cron = @import("cron.zig");

pub const FireError = error{
    NotARoutine,
    Disabled,
    AlreadyRunning,
    /// Test-only sentinel. Never returned in production.
    FakeLLMSuccess,
};

pub fn fireRoutine(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    task_id: []const u8,
) (FireError || std.mem.Allocator.Error || error{ RoutineNotFound, InvalidCron })!void {
    // 1) Load + disabled check.
    const routine = model.loadRoutineByTaskId(allocator, db, task_id) catch |err| switch (err) {
        error.RoutineNotFound => return FireError.NotARoutine,
        else => return err,
    };
    defer routine.deinit(allocator);
    if (!routine.enabled) return FireError.Disabled;

    // 2) Atomic claim.
    if (!try model.claimForRun(allocator, db, routine.id)) return FireError.AlreadyRunning;

    // 3) Push a user-style 🔁 message.
    const now = std.Io.Timestamp.now(io, .real);
    const now_unix_nanos: i128 = @intCast(now.nanoseconds);
    const message_content = try buildFireMessageContent(allocator, routine, now_unix_nanos);
    defer allocator.free(message_content);

    var model_name: []const u8 = "agentic-coding";
    if (nalarcore.getSingleton()) |di| {
        model_name = nalarcore.getLlmConfig(di).model;
    }

    try nalarcore.llm_history.saveMessage(allocator, io, db, .{
        .session_id = task_id, .model = model_name, .cwd = "",
        .content = message_content, .reasoning_content = null,
        .role = "user", .finish_reason = "null",
        .tool_calls = null, .tool_call_id = null, .agent_name = "Agent",
        .loop_index = 0, .temperature = 0.0, .is_thinking = false,
        .is_input = true, .is_output = false,
        .parent_id = task_id, .parent_session_id = task_id,
    });

    // 4) Test-mode short-circuit.
    if (std.process.getEnvVar(allocator, "ROUTINE_FIRE_TEST_SKIP_LLM")) |_| {
        return FireError.FakeLLMSuccess;
    } else |_| {}

    // 5) Emit ai_worker_flow so CallbackAiWorkerFlow runs the LLM.
    const di = nalarcore.getSingleton() catch {
        try markFailedWithNextRun(allocator, db, routine, io, "no singleton");
        return;
    };
    const event_bus = di.event_bus;
    const heap_sid = try di.allocator.dupe(u8, task_id);
    errdefer di.allocator.free(heap_sid);
    const heap_msg = try di.allocator.dupe(u8, message_content);
    errdefer di.allocator.free(heap_msg);
    const heap_empty = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(heap_empty);

    event_bus.emit(nalarcore.ai_workflow.RunParamsNew, "ai_worker_flow", .{
        .parent_session_id = heap_sid, .session_id = heap_sid,
        .message = heap_msg, .cwd = heap_empty, .body = heap_empty,
        .allowed_tools = heap_empty, .is_sub_agent = false,
        .image_urls = heap_empty, .selected_profile_model = heap_empty,
    });

    // 6) Mark success and advance. v1: worker errors are not rolled back.
    _ = try markSuccessWithNextRun(allocator, db, routine, io);
}

fn buildFireMessageContent(allocator: std.mem.Allocator, routine: Routine, now_unix_nanos: i128) ![]u8 {
    const stamp = try formatSqliteDatetime(allocator, now_unix_nanos);
    defer allocator.free(stamp);
    return std.fmt.allocPrint(allocator,
        "🔁 Routine fire — {s} — {s}\n\n{s}",
        .{ routine.schedule, stamp, routine.initial_prompt });
}

const BrokenDownTime = struct {
    year: i32, month: u4, day: u5,
    hour: u5, minute: u6, second: u6,
};

fn brokenDownFromUnixNanos(ns: i128) BrokenDownTime {
    const secs: i64 = @intCast(@divTrunc(ns, std.time.ns_per_s));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year, .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hour = @intCast(day_seconds.getHoursIntoDay()),
        .minute = @intCast(day_seconds.getMinutesIntoHour()),
        .second = @intCast(day_seconds.getSecondsIntoMinute()),
    };
}

fn formatSqliteDatetime(allocator: std.mem.Allocator, unix_nanos: i128) ![]u8 {
    const bd = brokenDownFromUnixNanos(unix_nanos);
    return std.fmt.allocPrint(allocator,
        "{d:04}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}",
        .{ bd.year, bd.month, bd.day, bd.hour, bd.minute, bd.second });
}

fn markSuccessWithNextRun(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, routine: Routine, io: std.Io) !void {
    const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const next_ns = try cron.nextFireTime(routine.schedule, now_ns);
    const next_sqlite = try formatSqliteDatetime(allocator, next_ns);
    defer allocator.free(next_sqlite);
    try model.markSuccess(allocator, db, routine.id, next_sqlite);
}

fn markFailedWithNextRun(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, routine: Routine, io: std.Io, err_msg: []const u8) !void {
    const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const next_ns = try cron.nextFireTime(routine.schedule, now_ns);
    const next_sqlite = try formatSqliteDatetime(allocator, next_ns);
    defer allocator.free(next_sqlite);
    try model.markFailed(allocator, db, routine.id, err_msg, next_sqlite);
}
```

- [ ] **Step 4: Register the test, then run it**

Add to `src/ai_workflow/tui/test_runner.zig`:
```zig
_ = @import("routines/fire_test.zig");
```

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS (4 tests in fire_test.zig pass; the `AlreadyRunning` test depends on `claimForRun` from Chunk 1's `model.zig`).

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/routines/fire.zig src/ai_workflow/tui/routines/fire_test.zig src/ai_workflow/tui/routines/mod.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat(routines): fire.zig - per-fire pipeline (claim, 🔁 message, LLM emit)"
```

---

### Task 2.2: `bin/nalar-routine-fire.zig` — sub-process entry point
**Files:** Create: `src/ai_workflow/tui/routines/bin/nalar-routine-fire.zig`

- [ ] **Step 1: Write the entry point**

No test for the binary itself — the integration is verified in Task 3.3 (scheduler_test). The sub-process is a thin wrapper: parse `--id` / `--db`, open DB, call `fire.fireRoutine`, exit 0 on success / 1 on error.

Create `src/ai_workflow/tui/routines/bin/nalar-routine-fire.zig`:

```zig
const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const fire = @import("../fire.zig");

/// Sub-process entry point: `nalar-routine-fire --id <routine_id> [--db <path>]`.
///
/// Loads the DB (path from `--db` or `~/.config/nalar/agent.db`),
/// calls `fire.fireRoutine`, exits 0 on success / 1 on failure.
/// The scheduler spawns this binary per-fire via `std.process.spawn`
/// (fire-and-forget, no `child.wait`).
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const environment = init.environ_map;

    var routine_id: []const u8 = "";
    var db_path_override: ?[]const u8 = null;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--id")) {
            routine_id = args_iter.next() orelse {
                std.log.err("--id requires a value", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--db")) {
            db_path_override = args_iter.next() orelse {
                std.log.err("--db requires a value", .{});
                std.process.exit(1);
            };
        }
    }

    if (routine_id.len == 0) {
        std.log.err("Usage: nalar-routine-fire --id <routine_id> [--db <path>]", .{});
        std.process.exit(1);
    }

    const db_path = db_path_override orelse blk: {
        const home = environment.get("HOME") orelse {
            std.log.err("HOME env var not set", .{});
            std.process.exit(1);
        };
        break :blk try std.fs.path.join(allocator, &.{ home, ".config", "nalar", "agent.db" });
    };
    defer if (db_path_override == null) allocator.free(db_path);

    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, db_path);

    fire.fireRoutine(allocator, &db, io, routine_id) catch |err| {
        if (err == fire.FireError.FakeLLMSuccess) std.process.exit(0);
        std.log.err("fireRoutine failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(0);
}
```

- [ ] **Step 2: Verify the build is wired (done in Task 2.4)** — `zig build test` should still pass.

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/routines/bin/nalar-routine-fire.zig
git commit -m "feat(routines): sub-process entry point (nalar-routine-fire.zig)"
```

---

### Task 2.3: Integration test for the full fire path (success state)
**Files:** Modify: `src/ai_workflow/tui/routines/fire_test.zig` (add one more test)

- [ ] **Step 1: Write the test**

Append to `src/ai_workflow/tui/routines/fire_test.zig`:

```zig
test "fireRoutine (skip-LLM mode) marks routine success and advances next_run_at" {
    const allocator = testing.allocator;
    try withSkipLlmEnv(allocator, "1", struct {
        fn run() !void {
            const alloc = testing.allocator;
            var db = try freshDb(alloc);
            defer db.close();
            try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id) VALUES ('t1', 'A', 'wi1', 't1')", &.{});
            try model.insertRoutine(alloc, &db, .{ .id = "r1", .task_id = "t1", .schedule = "0 9 * * *", .initial_prompt = "summarize commits", .enabled = true, .next_run_at = "2000-01-01 09:00:00" });

            const err = fire.fireRoutine(alloc, &db, std.testing.io, "t1") catch |e| e;
            try testing.expectEqual(fire.FireError.FakeLLMSuccess, err);

            var stmt = try db.prepare(alloc, "SELECT last_status, last_error, next_run_at FROM routines WHERE id = 'r1'");
            defer stmt.finalize();
            _ = try stmt.step();
            try testing.expectEqualStrings("success", stmt.columnText(0));
            try testing.expectEqualStrings("", stmt.columnText(1));
            const next_run_at = try alloc.dupe(u8, stmt.columnText(2));
            defer alloc.free(next_run_at);
            // 21st century, at 09:00:00.
            try testing.expect(std.mem.startsWith(u8, next_run_at, "20"));
            try testing.expect(std.mem.indexOf(u8, next_run_at, " 09:00:00") != null);
        }
    }.run);
}
```

- [ ] **Step 2: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS — Task 2.1's implementation already calls `markSuccessWithNextRun` on the FakeLLMSuccess path.

- [ ] **Step 3: No new implementation needed.**

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/routines/fire_test.zig
git commit -m "test(routines): fireRoutine success-path updates last_status + next_run_at"
```

---

### Task 2.4: `build.zig` — `routine-fire` install target
**Files:** Modify: `build.zig`

- [ ] **Step 1: Add the build target**

In `build.zig`, after the `linux_system_step` block (around line 343), add:

```zig
// ============================================================
// nalar-routine-fire sub-process (per-fire worker binary)
// ============================================================
const routine_fire_exe = b.addExecutable(.{
    .name = "nalar-routine-fire",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/ai_workflow/tui/routines/bin/nalar-routine-fire.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nalarcore", .module = mod },
        },
    }),
});
routine_fire_exe.root_module.linkSystemLibrary("sqlite3", .{});
routine_fire_exe.root_module.linkSystemLibrary("ssl", .{});
routine_fire_exe.root_module.linkSystemLibrary("crypto", .{});
routine_fire_exe.root_module.linkSystemLibrary("c", .{});
const install_routine_fire = b.addInstallArtifact(routine_fire_exe, .{});
const routine_fire_step = b.step("install:routine-fire", "Build the nalar-routine-fire sub-process binary");
routine_fire_step.dependOn(&install_routine_fire.step);

// Also install as part of the default linux step so the scheduler finds it.
linux_step.dependOn(&install_routine_fire.step);
```

- [ ] **Step 2: Run the build, verify it succeeds**

Run: `timeout 180 zig build install:routine-fire 2>&1 | tail -n 30`
Expected: build succeeds. Verify: `ls -la zig-out/bin/nalar-routine-fire` (regular file, executable bit set).

- [ ] **Step 3: Smoke-test the binary**

```bash
timeout 5 ./zig-out/bin/nalar-routine-fire 2>&1 | head -n 5  # exit 1, "Usage: ..."
timeout 5 ./zig-out/bin/nalar-routine-fire --id nonexistent 2>&1 | head -n 5  # exit 1, "fireRoutine failed: NotARoutine"
```

- [ ] **Step 4: Run all tests, verify nothing broke**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS (same pass count as before).

- [ ] **Step 5: Commit**

```bash
git add build.zig
git commit -m "build(routines): install:routine-fire target produces nalar-routine-fire"
```

---

## Chunk 3: Scheduler (`Scheduler.zig` + startup integration)

Without the scheduler, due routines have no way to fire — data model + fire pipeline are in place, but nothing invokes them. The scheduler is the missing link.

**Why polling, not event-bus wakeup:** Cron is minute-granular; 5s polling is invisible drift. A wakeup-based design would need an in-process timer per routine — added complexity for no observable benefit.

**Why the scheduler is in the main process:** The schedule and the LLM run state are co-located in the same DB. Putting the scheduler in the main process is simpler and avoids a second long-running process.

**Fire-and-forget vs `child.wait`:** Same pattern as `notifications.zig:130`. A slow LLM call in one routine cannot block polling of others. The sub-process writes `last_status` directly to the DB before exiting.

### Task 3.1: `Scheduler.zig` — polling loop

**Files:**
- Create: `src/ai_workflow/tui/routines/Scheduler.zig`
- Create: `src/ai_workflow/tui/routines/scheduler_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 1: Write the failing test (unit tests for the helpers)**
Create `src/ai_workflow/tui/routines/scheduler_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const SqliteBackend = @import("nalarcore").db.SqliteBackend;
const model = @import("model.zig");
const Scheduler = @import("Scheduler.zig");
const Migration044AddRoutines = @import("../migration.zig").Migration044AddRoutines;

fn freshDb(allocator: std.mem.Allocator) !SqliteBackend {
    var db = try SqliteBackend.openInMemory(allocator);
    try db.exec(allocator, "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)", &.{});
    try Migration044AddRoutines.up(&db, allocator);
    return db;
}

test "Scheduler.resetStuckRunning marks running rows as failed" {
    const allocator = testing.allocator;
    var db = try freshDb(allocator);
    defer db.close();
    try db.exec(allocator, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'wi1')", &.{});
    try model.insertRoutine(allocator, &db, .{
        .id = "r1", .task_id = "t1", .schedule = "*/5 * * * *",
        .initial_prompt = "x", .enabled = true, .next_run_at = "2099-01-01 00:00:00",
    });
    try db.exec(allocator, "UPDATE routines SET last_status = 'running' WHERE id = 'r1'", &.{});
    try Scheduler.resetStuckRunning(allocator, &db);

    var stmt = try db.prepare(allocator, "SELECT last_status, last_error FROM routines WHERE id = 'r1'");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqualStrings("failed", stmt.columnText(0));
    try testing.expectEqualStrings("process killed (restart detected)", stmt.columnText(1));
}

test "Scheduler.recomputeDueNextRunAt advances rows in the past" {
    const allocator = testing.allocator;
    var db = try freshDb(allocator);
    defer db.close();
    try db.exec(allocator, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'wi1')", &.{});
    try model.insertRoutine(allocator, &db, .{
        .id = "r1", .task_id = "t1", .schedule = "0 9 * * *",
        .initial_prompt = "x", .enabled = true, .next_run_at = "2000-01-01 00:00:00",
    });
    try Scheduler.recomputeDueNextRunAt(allocator, &db, std.testing.io);

    var stmt = try db.prepare(allocator, "SELECT next_run_at FROM routines WHERE id = 'r1'");
    defer stmt.finalize();
    _ = try stmt.step();
    const next = try allocator.dupe(u8, stmt.columnText(0));
    defer allocator.free(next);
    try testing.expect(std.mem.indexOf(u8, next, " 09:00:00") != null);
    try testing.expect(std.mem.indexOf(u8, next, "2000-") == null);
}
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: FAIL with `no module named 'Scheduler'`.

- [ ] **Step 3: Write `Scheduler.zig`**

Create `src/ai_workflow/tui/routines/Scheduler.zig`:

```zig
const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const model = @import("model.zig");
const cron = @import("cron.zig");

const TICK_INTERVAL_NS: i128 = 5 * std.time.ns_per_s;

/// Reset any `running` rows to `failed` with a "process killed" error.
/// Called once at startup to recover from a previous process crash.
pub fn resetStuckRunning(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) !void {
    const err_msg = "process killed (restart detected)";
    const copy = try allocator.dupe(u8, err_msg);
    defer allocator.free(copy);
    _ = try db.exec(allocator,
        \\UPDATE routines
        \\   SET last_status = 'failed', last_error = ?, updated_at = datetime('now')
        \\ WHERE last_status = 'running'
    , &.{copy});
}

/// Recompute `next_run_at` for every enabled routine. Called once at
/// startup so routines that were due during downtime fire within 5s of boot.
pub fn recomputeDueNextRunAt(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    io: std.Io,
) !void {
    var stmt = try db.prepare(allocator, "SELECT id, schedule FROM routines WHERE enabled = 1");
    defer stmt.finalize();

    const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);

    var to_update: std.ArrayList(struct { id: []u8, next_sqlite: []u8 }) = .empty;
    defer {
        for (to_update.items) |item| {
            allocator.free(item.id);
            allocator.free(item.next_sqlite);
        }
        to_update.deinit(allocator);
    }

    while (try stmt.step()) {
        const next_ns = try cron.nextFireTime(stmt.columnText(1), now_ns);
        const bd = brokenDownFromUnixNanos(next_ns);
        const next_sqlite = try std.fmt.allocPrint(allocator,
            "{d:04}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}",
            .{ bd.year, bd.month, bd.day, bd.hour, bd.minute, bd.second });
        const id_dup = try allocator.dupe(u8, stmt.columnText(0));
        try to_update.append(allocator, .{ .id = id_dup, .next_sqlite = next_sqlite });
    }

    for (to_update.items) |item| {
        _ = try db.exec(allocator,
            "UPDATE routines SET next_run_at = ?, updated_at = datetime('now') WHERE id = ?",
            &.{ item.next_sqlite, item.id });
    }
}

const BrokenDownTime = struct {
    year: i32, month: u4, day: u5,
    hour: u5, minute: u6, second: u6,
};

fn brokenDownFromUnixNanos(ns: i128) BrokenDownTime {
    const secs: i64 = @intCast(@divTrunc(ns, std.time.ns_per_s));
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

/// Spawn one `nalar-routine-fire --id <id>` sub-process per due id.
/// Fire-and-forget: do NOT call child.wait.
fn spawnDueRoutines(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, io: std.Io) !usize {
    const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const bd = brokenDownFromUnixNanos(now_ns);
    const now_sqlite = try std.fmt.allocPrint(allocator,
        "{d:04}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}",
        .{ bd.year, bd.month, bd.day, bd.hour, bd.minute, bd.second });
    defer allocator.free(now_sqlite);

    const due_ids = try model.listDueRoutineIds(allocator, db, now_sqlite);
    defer {
        for (due_ids) |id| allocator.free(id);
        allocator.free(due_ids);
    }

    var spawned: usize = 0;
    for (due_ids) |id| {
        const argv = try allocator.dupe([]const u8, &.{ "nalar-routine-fire", "--id", id });
        defer allocator.free(argv);

        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            std.log.warn("scheduler: failed to spawn nalar-routine-fire: {s}", .{@errorName(err)});
            continue;
        };
        if (child.id == null) continue;
        spawned += 1;
    }
    return spawned;
}

/// The polling loop. Runs forever (no cancel signal in v1).
pub fn start(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, io: std.Io) !void {
    // Restart safety: do these once at startup.
    resetStuckRunning(allocator, db) catch |err| {
        std.log.warn("scheduler: resetStuckRunning failed: {s}", .{@errorName(err)});
    };
    recomputeDueNextRunAt(allocator, db, io) catch |err| {
        std.log.warn("scheduler: recomputeDueNextRunAt failed: {s}", .{@errorName(err)});
    };

    while (true) {
        _ = spawnDueRoutines(allocator, db, io) catch |err| {
            std.log.warn("scheduler: spawnDueRoutines failed: {s}", .{@errorName(err)});
        };
        try std.Io.sleep(io, .{ .nanoseconds = TICK_INTERVAL_NS }, .real);
    }
}
```

- [ ] **Step 4: Register the test in test_runner.zig**

Add to `src/ai_workflow/tui/test_runner.zig`:
```zig
_ = @import("routines/scheduler_test.zig");
```

- [ ] **Step 5: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/routines/Scheduler.zig src/ai_workflow/tui/routines/scheduler_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat(routines): Scheduler.zig - polling loop with restart-safety"
```

---

### Task 3.2: `startup.zig` modification — spawn the scheduler on a new thread

**Files:**
- Modify: `src/ai_workflow/tui/startup.zig` (currently a 0-byte stub)
- Modify: `src/main.zig` (call the new `startup.start`)

- [ ] **Step 1: Write the new `startup.zig`**

Replace the contents of `src/ai_workflow/tui/startup.zig` with:

```zig
//! Process-startup wiring: things that need to run after the singleton
//! is initialized but before (or alongside) the HTTP server binding.

const std = @import("std");
const nalarcore = @import("nalarcore");
const Scheduler = @import("routines/Scheduler.zig");

/// Start the routine scheduler on a fresh OS thread. The thread
/// runs `Scheduler.start(...)` until the process exits.
pub fn start(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    io: std.Io,
) !void {
    const thread = try std.Thread.spawn(.{}, schedulerThreadMain, .{ allocator, db, io });
    thread.detach();
}

fn schedulerThreadMain(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    io: std.Io,
) void {
    Scheduler.start(allocator, db, io) catch |err| {
        std.log.err("scheduler thread crashed: {s}", .{@errorName(err)});
    };
}
```

- [ ] **Step 2: Call it from `main.zig`**

In `src/main.zig`, after `try migrationManager.runMigrations();` (around line 50) and before `const tmp_path = ...`, add:

```zig
    // Start the routine scheduler on a background thread. dbSqlite
    // is in scope (declared ~line 43).
    ai_mod.startup.start(allocator, &dbSqlite, io) catch |err| {
        std.log.err("Failed to start routine scheduler: {s}", .{@errorName(err)});
    };
```

- [ ] **Step 3: Verify the build still succeeds**

Run: `timeout 180 zig build test 2>&1 | tail -n 30`
Expected: PASS.

Run: `timeout 180 zig build 2>&1 | tail -n 30`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/startup.zig src/main.zig
git commit -m "feat(routines): startup.zig spawns Scheduler on a background thread"
```

---

### Task 3.3: `scheduler_test.zig` — integration test (real sub-process spawn)
**Files:** Modify: `src/ai_workflow/tui/routines/scheduler_test.zig` (add the integration test)

- [ ] **Step 1: Write the failing test**

Append to `scheduler_test.zig`:

```zig
test "Scheduler: routine with next_run_at in the past fires within 6s" {
    const skip_llm_env = "ROUTINE_FIRE_TEST_SKIP_LLM";
    const prev = std.process.getEnvVar(testing.allocator, skip_llm_env) catch null;
    defer if (prev) |p| { std.process.setEnvVar(testing.allocator, skip_llm_env, p) catch {}; testing.allocator.free(p); };
    try std.process.setEnvVar(testing.allocator, skip_llm_env, "1");

    // Put nalar-routine-fire on PATH.
    const path_env = "PATH";
    const prev_path = std.process.getEnvVar(testing.allocator, path_env) catch null;
    defer if (prev_path) |p| { std.process.setEnvVar(testing.allocator, path_env, p) catch {}; testing.allocator.free(p); };
    const new_path = try std.fmt.allocPrint(testing.allocator, "{s}:{s}", .{ prev_path orelse "", "zig-out/bin" });
    defer testing.allocator.free(new_path);
    try std.process.setEnvVar(testing.allocator, path_env, new_path);

    // File-backed DB so the sub-process can open it. Verify WAL is on
    // in SqliteBackend.init; add `PRAGMA journal_mode=WAL` here if not.
    const tmp_db = try testing.tmpDir(.{});
    defer tmp_db.cleanup();
    const db_path = try tmp_db.dir.realPathAlloc(testing.allocator, "agent.db");
    defer testing.allocator.free(db_path);

    {
        var db: SqliteBackend = .{};
        defer db.deinit();
        try db.init(std.testing.io, db_path);
        try db.exec(testing.allocator, "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL, session_id TEXT)", &.{});
        try db.exec(testing.allocator, "CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, model TEXT, response_content TEXT, finish_reason TEXT, role TEXT, tool_calls_json TEXT, tool_call_id TEXT, reasoning_content TEXT, is_feed_to_llm INTEGER DEFAULT 1, agent TEXT, loop_index INTEGER, temperature REAL, is_thinking INTEGER, created_at TEXT, parent_session_id TEXT, parent_id TEXT, prompt_tokens INTEGER, completion_tokens INTEGER, total_tokens INTEGER, is_input INTEGER, is_output INTEGER, tool_name TEXT, diffview_before TEXT, diffview_after TEXT, image_url TEXT)", &.{});
        try db.exec(testing.allocator, "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT, status TEXT, cwd TEXT, selected_profile_model TEXT, created_at TEXT, updated_at TEXT)", &.{});
        try Migration044AddRoutines.up(&db, testing.allocator);
        try db.exec(testing.allocator, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id) VALUES ('t1', 'A', 'wi1', 't1')", &.{});
        try model.insertRoutine(testing.allocator, &db, .{ .id = "r1", .task_id = "t1", .schedule = "*/5 * * * *", .initial_prompt = "ping", .enabled = true, .next_run_at = "2000-01-01 00:00:00" });
    }

    var db_thread: SqliteBackend = .{};
    defer db_thread.deinit();
    try db_thread.init(std.testing.io, db_path);
    const thread = try std.Thread.spawn(.{}, Scheduler.start, .{ testing.allocator, &db_thread, std.testing.io });
    thread.detach();

    // Poll for up to 8s for the routine's last_status to change.
    var found = false;
    var iter: u32 = 0;
    while (iter < 80) : (iter += 1) {
        try std.Io.sleep(std.testing.io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .real);
        var db_check: SqliteBackend = .{};
        defer db_check.deinit();
        try db_check.init(std.testing.io, db_path);
        var stmt = try db_check.prepare(testing.allocator, "SELECT last_status FROM routines WHERE id = 'r1'");
        defer stmt.finalize();
        if (try stmt.step()) {
            const status = stmt.columnText(0);
            if (std.mem.eql(u8, status, "success") or std.mem.eql(u8, status, "failed")) found = true;
        }
        if (found) break;
    }
    try testing.expect(found);
}
```

- [ ] **Step 2: Run the test, verify it FAILS (or passes after sqlite API fix)**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: FAIL — `SqliteBackend.init(io, path)` (used above) is the project's open pattern. If the API differs, adjust to match. SQLite is per-process; the test and sub-process each open the same file. Concurrent writes are protected by SQLite's WAL mode (verify in `SqliteBackend.init`; if not WAL, add `PRAGMA journal_mode=WAL`).

- [ ] **Step 3: Run the test, verify it PASSES**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS within ~6s (scheduler polls every 5s, sub-process exits in <100ms in skip-LLM mode).

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/routines/scheduler_test.zig
git commit -m "test(routines): scheduler spawns sub-process and fires overdue routine"
```

---

### Task 3.4: Replace `recomputeAllNextRunAt` placeholder with the real implementation

**Files:**
- Modify: `src/ai_workflow/tui/routines/model.zig`

- [ ] **Step 1: Read the current placeholder**

The placeholder in `model.zig` (added in Chunk 1) is:

```zig
pub fn recomputeAllNextRunAt(allocator: std.mem.Allocator, db: *SqliteBackend, compute_fn: *const fn (schedule: []const u8, now_unix_nanos: i128) anyerror![]const u8, now_unix_nanos: i128) !void {
    _ = allocator; _ = db; _ = compute_fn; _ = now_unix_nanos;
    return;
}
```

- [ ] **Step 2: Replace the body with a thin wrapper that calls `Scheduler.recomputeDueNextRunAt`**

```zig
const Scheduler = @import("Scheduler.zig");

/// Iterate over all enabled routines, recompute `next_run_at` via
/// `cron.nextFireTime`, and UPDATE the row. The `compute_fn` and
/// `now_unix_nanos` parameters are accepted for backwards
/// compatibility (Chunk 1 placeholder signature) but ignored — the
/// implementation uses the wall clock from `Scheduler.recomputeDueNextRunAt`
/// and the standard `cron.nextFireTime`.
pub fn recomputeAllNextRunAt(
    allocator: std.mem.Allocator,
    db: *SqliteBackend,
    compute_fn: *const fn (schedule: []const u8, now_unix_nanos: i128) anyerror![]const u8,
    now_unix_nanos: i128,
) !void {
    _ = compute_fn;
    _ = now_unix_nanos;
    const di = nalarcore.getSingleton() catch return;
    try Scheduler.recomputeDueNextRunAt(allocator, db, di.io);
}
```

Add the import at the top of `model.zig` (the `nalarcore` import should already be there from Chunk 1; verify):
```zig
const nalarcore = @import("nalarcore");
```

- [ ] **Step 3: Run all tests, verify nothing broke**

Run: `timeout 120 zig build test 2>&1 | tail -n 30`
Expected: PASS. Chunk 1's `model_test.zig` tests still pass (they don't call `recomputeAllNextRunAt`). The `scheduler_test.zig` tests still pass (they call `Scheduler.recomputeDueNextRunAt` directly).

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/routines/model.zig
git commit -m "feat(routines): recomputeAllNextRunAt delegates to Scheduler"
```

---

## Chunk 2 & 3 done — checkpoint

- ✅ `fire.zig` per-fire pipeline: claim, 🔁 message, LLM emit, mark success/fail
- ✅ `bin/nalar-routine-fire.zig` sub-process entry point
- ✅ `fire_test.zig`: user-message, atomic claim, skip-LLM success path
- ✅ `build.zig`: `install:routine-fire` produces `zig-out/bin/nalar-routine-fire`
- ✅ `Scheduler.zig`: polling loop with stuck-row reset + due-row recompute + fire-and-forget spawn
- ✅ `startup.zig`: scheduler spawned on a background thread after migrations
- ✅ `scheduler_test.zig`: end-to-end test — overdue routine fires within 6s via real sub-process
- ✅ `recomputeAllNextRunAt` placeholder replaced with real implementation

Next: **Chunk 4 — Backend HTTP** (`routines_run.zig` handler, `tasks_list.zig` response shape, `workspace_item_tasks_create.zig` body, `workspace_item_tasks_update.zig` body, `llm_history.zig` Task struct changes). See `docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md`. Chunks 5-7 (frontend) follow in `docs/superpowers/plans/2026-06-13-add-task-routines-chunks-5-7.md`.
