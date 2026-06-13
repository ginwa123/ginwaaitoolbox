//! `fire.zig` — the per-fire work for a routine (Task 2.1 of the
//! Add Task Routines plan, refactored per PR #8 review).
//!
//! `fireRoutine(allocator, db, di, io, task_id)` is called by the
//! scheduler (Task 3.1's `Scheduler.fireDueRoutines`) for every fire.
//! It:
//!
//!   1. Loads the routine by `task_id` and validates it's enabled.
//!   2. Atomically claims the row (`claimForRun`) so a second
//!      concurrent fire is rejected.
//!   3. Submits the LLM work to `di.group_emit_session_create.concurrent`
//!      (mirrors `http_handlers/session_create.zig:161`). The callback
//!      emits an `ai_workflow.RunParamsNew` event on the event bus —
//!      the `CallbackAiWorkerFlow` subscription in `main.zig` picks it
//!      up on a worker thread. The routine's `initial_prompt` is the
//!      `queue_message` of the session create.
//!   4. On success: `markSuccess` with a recomputed `next_run_at`.
//!      The LLM result is NOT observed here — it's fire-and-forget.
//!      If the LLM fails, it shows up as a chat-view error (the same
//!      path as a normal user session).
//!
//! No new binary, no separate OS thread — all work happens on the
//! main process's Io runtime via the existing
//! `group_emit_session_create` group. The "fake-LLM" test short-circuit
//! and the 🔁 user-style message insert are gone (the routine's
//! `initial_prompt` is the natural user-style message; the
//! `session_create` event will accumulate user/assistant pairs over
//! time).
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunks-2-3.md
//! Design: docs/plans/2026-06-13-add-task-routines-design.md (§4)

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_mod.ai_workflow;

const model = @import("model.zig");
const cron = @import("cron.zig");

/// Errors returned by `fireRoutine`. These are all SENTINELS — the
/// fire pipeline does NOT propagate underlying errors (e.g.
/// `error.RoutineNotFound`) to the caller. The scheduler maps them
/// to "skip this id, try the next one"; HTTP handlers (Chunk 4) map
/// them to status codes.
pub const FireError = error{
    /// The task has no `routines` row (it is a standard task).
    NotARoutine,
    /// The routine exists but `enabled = false`.
    Disabled,
    /// A previous fire is still in flight (`last_status = 'running'`).
    AlreadyRunning,
};

/// Fire a single routine. Loads the routine, atomically claims the
/// row, then submits the LLM work via
/// `di.group_emit_session_create.concurrent(io, runFire, .{...})` —
/// the same pattern as `http_handlers/session_create.zig:161`. The
/// callback emits `ai_workflow.RunParamsNew` to the event bus;
/// `CallbackAiWorkerFlow` picks it up on the Io runtime and runs the
/// LLM in a worker thread.
///
/// The function returns as soon as the event is submitted (the
/// `group_emit_session_create.concurrent` call is non-blocking). The
/// routine row is marked `success` and `next_run_at` is advanced
/// immediately — the LLM is fire-and-forget. A failed LLM call will
/// surface as a chat-view error (the same path as a normal user
/// session), not as a routine status change.
///
/// `di` must be the initialized `nalarcore.ContextIPCTui` singleton
/// (the scheduler already has it from the start() call chain). The
/// sub-allocated strings (`sid`/`qmsg`/...) are owned by the
/// `runFire` callback and freed when it returns.
///
/// The return type is `FireError!void` (narrower than the previous
/// `anyerror!void`): the only error paths that reach the caller are
/// the three controlled `FireError` variants. Underlying errors
/// (allocation failure, DB error) propagate as-is from the helpers
/// and are NOT in the `FireError` set — the scheduler logs and
/// continues with the next routine.
pub fn fireRoutine(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    di: *nalarcore.ContextIPCTui,
    io: std.Io,
    task_id: []const u8,
) FireError!void {
    // 1) Load the routine row. The task_id → routine mapping is
    //    1:1 (UNIQUE on `routines.task_id`); a missing row means this
    //    task was created as a standard task, not a routine.
    const routine = model.loadRoutineByTaskId(allocator, db, task_id) catch |err| switch (err) {
        error.RoutineNotFound => return FireError.NotARoutine,
        else => return err,
    };
    defer routine.deinit(allocator);

    if (!routine.enabled) return FireError.Disabled;

    // 2) Atomic claim. `claimForRun` is a single UPDATE…RETURNING;
    //    a second concurrent fire on the same row sees zero rows in
    //    the result set and `claimForRun` returns false.
    if (!try model.claimForRun(allocator, db, routine.id)) return FireError.AlreadyRunning;

    // 3) Heap-allocate strings for the concurrent task. The callback
    //    owns these and frees them when done (mirrors
    //    `session_create.zig:141-159`). Use `errdefer` chains so a
    //    mid-allocation failure unwinds cleanly.
    const sid = try di.allocator.dupe(u8, task_id);
    errdefer di.allocator.free(sid);
    const qmsg = try di.allocator.dupe(u8, routine.initial_prompt);
    errdefer di.allocator.free(qmsg);
    const cwd = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(cwd);
    const bmsg = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(bmsg);
    const atools = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(atools);
    const iurls = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(iurls);
    const spm = try di.allocator.dupe(u8, "");
    errdefer di.allocator.free(spm);

    // 4) Submit the LLM work to the Io group. The callback emits the
    //    event; the Io runtime processes the event via
    //    `CallbackAiWorkerFlow` in a worker thread. This call
    //    returns immediately — the actual LLM call happens
    //    asynchronously.
    try di.group_emit_session_create.concurrent(
        io,
        runFire,
        .{ di, sid, qmsg, cwd, bmsg, atools, iurls, spm },
    );

    // 5) Mark success and advance next_run_at. The LLM is
    //    fire-and-forget — we don't wait for it to complete before
    //    marking success.
    try markSuccessWithNextRun(allocator, db, routine, io);
}

/// Callback for `group_emit_session_create.concurrent`. Emits the LLM
/// event to the event bus. The Io runtime processes the event in a
/// worker thread; this callback returns immediately. Frees the
/// heap-allocated string args on the way out.
fn runFire(
    di: *nalarcore.ContextIPCTui,
    sid: []u8,
    qmsg: []u8,
    cwd: []u8,
    bmsg: []u8,
    atools: []u8,
    iurls: []u8,
    spm: []u8,
) void {
    defer di.allocator.free(sid);
    defer di.allocator.free(qmsg);
    defer di.allocator.free(cwd);
    defer di.allocator.free(bmsg);
    defer di.allocator.free(atools);
    defer di.allocator.free(iurls);
    defer di.allocator.free(spm);

    di.event_bus.emit(ai_workflow.RunParamsNew, "ai_worker_flow", .{
        .parent_session_id = sid,
        .session_id = sid,
        .message = qmsg,
        .cwd = cwd,
        .body = bmsg,
        .allowed_tools = atools,
        .is_sub_agent = false,
        .image_urls = iurls,
        .selected_profile_model = spm,
    });
}

// ─── Helpers ──────────────────────────────────────────────────────────────

/// Compute the next `next_run_at` from the routine's cron
/// expression and persist the success state. Used for the
/// happy-path emit-success path.
fn markSuccessWithNextRun(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    routine: model.Routine,
    io: std.Io,
) !void {
    const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const next_ns = try cron.nextFireTime(routine.schedule, now_ns);
    const next_sqlite = try formatSqliteDatetime(allocator, next_ns);
    defer allocator.free(next_sqlite);
    try model.markSuccess(allocator, db, routine.id, next_sqlite);
}

/// Convert unix nanos (i128) to a SQLite DATETIME literal
/// `YYYY-MM-DD HH:MM:SS`. Public so `Scheduler.zig` can reuse the
/// helper (the scheduler recomputes `next_run_at` for every enabled
/// routine at startup, and lists due routines every tick — both
/// paths need this formatter). Uses the same `std.time.epoch` helpers
/// as `cron.zig`.
pub fn formatSqliteDatetime(allocator: std.mem.Allocator, unix_nanos: i128) ![]u8 {
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
