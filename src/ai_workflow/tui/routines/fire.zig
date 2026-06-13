//! `fire.zig` — the per-fire work for a routine (Task 2.1 of the
//! Add Task Routines plan).
//!
//! `fireRoutine(allocator, db, io, task_id)` is called by the
//! `nalar-routine-fire` sub-process (Task 2.2) for every fire. It:
//!
//!   1. Loads the routine by `task_id` and validates it's enabled.
//!   2. Atomically claims the row (`claimForRun`) so a second
//!      concurrent fire is rejected.
//!   3. Pushes a user-style 🔁 message into the session (so the
//!      chat view shows the routine firing and the LLM sees the
//!      full conversation history).
//!   4. Emits an `ai_workflow.RunParamsNew` event on the event bus
//!      — the same path `session_create.zig:184` uses. The
//!      `CallbackAiWorkerFlow` subscription in `main.zig:306` picks
//!      it up on a worker thread.
//!   5. On success: `markSuccess` with a recomputed `next_run_at`.
//!      On error: `markFailed` with the error message + a recomputed
//!      `next_run_at`.
//!
//! Test-only path: when `ROUTINE_FIRE_TEST_SKIP_LLM=1` is set in the
//! environment, the function short-circuits after the message insert
//! and returns `FireError.FakeLLMSuccess`. This lets unit tests
//! exercise the user-message + state-mutation paths without the
//! `nalar` singleton being initialized.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunks-2-3.md
//! Design: docs/plans/2026-06-13-add-task-routines-design.md (§4)

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const model = @import("model.zig");
const cron = @import("cron.zig");

/// Errors returned by `fireRoutine`. These are all SENTINELS — the
/// fire pipeline does NOT propagate underlying errors (e.g.
/// `error.RoutineNotFound`) to the caller. The sub-process
/// (`bin/nalar-routine-fire.zig`) maps them to exit codes; HTTP
/// handlers map them to status codes.
pub const FireError = error{
    /// The task has no `routines` row (it is a standard task).
    NotARoutine,
    /// The routine exists but `enabled = false`.
    Disabled,
    /// A previous fire is still in flight (`last_status = 'running'`).
    AlreadyRunning,
    /// Test-only sentinel. The function short-circuited to avoid
    /// invoking the LLM worker pipeline (env var
    /// `ROUTINE_FIRE_TEST_SKIP_LLM=1` is set). Never returned in
    /// production.
    FakeLLMSuccess,
};

/// Run the per-fire work for the routine owned by `task_id`. On
/// success returns `void` (the row is marked success and
/// `next_run_at` is advanced); on a controlled failure returns one
/// of the `FireError` variants. Uncontrolled errors (allocation
/// failure, DB error) propagate as-is from the helpers and are
/// NOT in the `FireError` set — the sub-process will log and exit
/// non-zero.
///
/// `environment` is the process environment map, used to read the
/// `ROUTINE_FIRE_TEST_SKIP_LLM` env var (test-only). In the test
/// path the caller passes `null`; in production the sub-process
/// passes its inherited env (a `*const std.process.Environ.Map`).
///
/// The function does NOT call `runAgenticMultiStepnew` directly; it
/// emits an `ai_workflow.RunParamsNew` event on the event bus. This
/// is the same pattern as `session_create.zig:184`.
///
/// The return type is `anyerror!void` rather than a narrow error
/// set: `saveMessage`, `db.exec`, and the various helpers each
/// contribute their own variants (e.g. `error.WriteFailed` from
/// `std.Io.Writer`), and propagating them as part of a narrow set
/// would expose internal implementation details. The sub-process
/// maps any error to a non-zero exit code; HTTP handlers (Chunk 4)
/// map the `FireError` variants to specific status codes and treat
/// any other error as 500.
pub fn fireRoutine(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
    task_id: []const u8,
) anyerror!void {
    // 1) Load the routine row. The task_id → routine mapping is
    // 1:1 (UNIQUE on `routines.task_id`); a missing row means this
    // task was created as a standard task, not a routine.
    const routine = model.loadRoutineByTaskId(allocator, db, task_id) catch |err| switch (err) {
        error.RoutineNotFound => return FireError.NotARoutine,
        else => return err,
    };
    defer routine.deinit(allocator);

    if (!routine.enabled) return FireError.Disabled;

    // 2) Atomic claim. `claimForRun` is a single UPDATE…RETURNING;
    // a second concurrent fire on the same row sees zero rows in
    // the result set and `claimForRun` returns false.
    if (!try model.claimForRun(allocator, db, routine.id)) return FireError.AlreadyRunning;

    // 3) Push a user-style 🔁 message into the session BEFORE the
    // LLM emit. The worker (CallbackAiWorkerFlow) will see this
    // message in the conversation history when it builds the next
    // agent prompt.
    const now = std.Io.Timestamp.now(io, .real);
    const now_unix_nanos: i128 = @intCast(now.nanoseconds);
    const message_content = try buildFireMessageContent(allocator, routine, now_unix_nanos);
    defer allocator.free(message_content);

    // Resolve the model name from the singleton's LLM config. In
    // the test path the singleton is NOT initialized — fall back
    // to a sensible default. `saveMessage` will not actually use
    // this string for any behavioral decision (it just stores it
    // in the `model` column), so the default is fine.
    var model_name: []const u8 = "agentic-coding";
    if (nalarcore.getSingleton() catch null) |di| {
        model_name = nalarcore.getLlmConfig(di).model;
    }

    try nalarcore.llm_history.saveMessage(allocator, io, db, .{
        .session_id = task_id,
        .model = model_name,
        .cwd = "",
        .content = message_content,
        .reasoning_content = null,
        .role = "user",
        .finish_reason = "null",
        .tool_calls = null,
        .tool_call_id = null,
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.0,
        .is_thinking = false,
        .is_input = true,
        .is_output = false,
        .parent_id = task_id,
        .parent_session_id = task_id,
    });

    // 4) Test-mode short-circuit. When the env var is set, return
    // BEFORE the LLM emit so the test can assert on the
    // user-message + state-mutation paths without needing the
    // `nalar` singleton initialized. The test still goes through
    // markSuccess (via the FakeLLMSuccess catch in the sub-process)
    // — actually no, the sub-process exits with code 0 on
    // FakeLLMSuccess and does NOT call markSuccess. That's the
    // intended contract: the test asserts on the message-insert
    // path; the state-mutation (markSuccess/markFailed) is
    // verified by the integration test in Task 3.3.
    if (environment) |env| {
        if (env.get("ROUTINE_FIRE_TEST_SKIP_LLM")) |val| {
            if (val.len > 0) return FireError.FakeLLMSuccess;
        }
    }

    // 5) Emit ai_worker_flow. The CallbackAiWorkerFlow subscription
    // (registered in main.zig:306) will pick this up on a worker
    // thread and call `runAgenticMultiStepnew` — the same
    // production path as `session_create.zig:184`. The worker is
    // responsible for streaming the response, writing the
    // assistant message to llm_history, and (eventually) calling
    // markSuccess / markFailed. v1 does NOT roll back the claim if
    // the worker errors; the scheduler's `resetStuckRunning` pass
    // will clean up the row on the next process restart.
    //
    // `getSingleton` can fail with `error.GlobalContextNotInitialized`.
    // In the test path (the FakeLLMSuccess short-circuit) we never
    // reach this line. In production the sub-process is spawned by
    // the scheduler which has the singleton, so this catch is
    // defensive — if it ever fires, we mark the routine as failed
    // rather than leaving the row stuck in 'running'.
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

    event_bus.emit(nalarcore.ai_mod.ai_workflow.RunParamsNew, "ai_worker_flow", .{
        .parent_session_id = heap_sid,
        .session_id = heap_sid,
        .message = heap_msg,
        .cwd = heap_empty,
        .body = heap_empty,
        .allowed_tools = heap_empty,
        .is_sub_agent = false,
        .image_urls = heap_empty,
        .selected_profile_model = heap_empty,
    });

    // 6) Mark success and advance next_run_at. v1: worker errors
    // are not rolled back — the scheduler's stuck-running reset
    // (Task 3.1) handles the case where the worker crashes.
    try markSuccessWithNextRun(allocator, db, routine, io);
}

// ─── Helpers ──────────────────────────────────────────────────────────────

/// Build the user-visible message body for a fire:
///
/// ```
/// 🔁 Routine fire — <routine.schedule> — <YYYY-MM-DD HH:MM:SS>
///
/// <routine.initial_prompt>
/// ```
///
/// The schedule is shown (not the task name) because the task
/// name lives in the session header and would be redundant. Caller
/// owns the returned slice.
fn buildFireMessageContent(allocator: std.mem.Allocator, routine: model.Routine, now_unix_nanos: i128) ![]u8 {
    const stamp = try formatSqliteDatetime(allocator, now_unix_nanos);
    defer allocator.free(stamp);
    return std.fmt.allocPrint(allocator,
        "🔁 Routine fire — {s} — {s}\n\n{s}",
        .{ routine.schedule, stamp, routine.initial_prompt });
}

/// Convert unix nanos (i128) to a SQLite DATETIME literal
/// `YYYY-MM-DD HH:MM:SS`. Uses the same `std.time.epoch` helpers
/// as `cron.zig`. The epoch.zig API only goes one direction
/// (EpochSeconds → broken-down), so this is a small duplication
/// rather than a refactor of `cron.zig`'s `BrokenDownTime`.
fn formatSqliteDatetime(allocator: std.mem.Allocator, unix_nanos: i128) ![]u8 {
    const secs: i64 = @intCast(@divTrunc(unix_nanos, std.time.ns_per_s));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(allocator,
        "{d:04}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            @as(u32, @intCast(day_seconds.getHoursIntoDay())),
            @as(u32, @intCast(day_seconds.getMinutesIntoHour())),
            @as(u32, @intCast(day_seconds.getSecondsIntoMinute())),
        });
}

/// Compute the next `next_run_at` from the routine's cron
/// expression and persist the success state. Used for the
/// happy-path emit-success path.
fn markSuccessWithNextRun(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    routine: model.Routine,
    io: std.Io,
) !void {
    const next_ns = try computeNextRun(allocator, routine, io);
    defer allocator.free(next_ns);
    try model.markSuccess(allocator, db, routine.id, next_ns);
}

/// Compute the next `next_run_at` from the routine's cron
/// expression and persist the failure state. Used when the
/// fire pipeline itself errors (not the worker — v1 doesn't
/// roll back worker errors).
fn markFailedWithNextRun(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    routine: model.Routine,
    io: std.Io,
    err_msg: []const u8,
) !void {
    const next_ns = try computeNextRun(allocator, routine, io);
    defer allocator.free(next_ns);
    try model.markFailed(allocator, db, routine.id, err_msg, next_ns);
}

/// Compute the next `next_run_at` SQLite datetime literal from the
/// routine's cron expression. The cron field is `routine.schedule`
/// (a 5-field expression); `now` is the wall clock at the time of
/// the fire. Caller owns the returned slice.
fn computeNextRun(allocator: std.mem.Allocator, routine: model.Routine, io: std.Io) ![]u8 {
    const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const next_ns = try cron.nextFireTime(routine.schedule, now_ns);
    return formatSqliteDatetime(allocator, next_ns);
}
