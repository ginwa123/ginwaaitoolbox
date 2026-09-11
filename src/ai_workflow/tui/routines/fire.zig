//! `fire.zig` — the per-fire work for a workspace routine.
//!
//! Retargeted from per-task routines (Migration 044) to
//! `workspace_routines` (Migration 084). `fireWorkspaceRoutine(
//! allocator, db, di, io, routine_id)` is called by the scheduler's
//! `Scheduler.fireDueRoutines` for every due fire and by the manual
//! `POST .../routines/:routine_id/run` endpoint. It:
//!
//!   1. Loads the routine by workspace-routine `id` and validates
//!      it's enabled.
//!   2. Atomically claims the row (`claimForRun`) so a second
//!      concurrent fire is rejected.
//!   3. Submits the LLM work to `di.group_emit_session_create.concurrent`
//!      (mirrors `http_handlers/session_create.zig:161`). The callback
//!      emits an `ai_workflow.RunParamsNew` event on the event bus —
//!      the `CallbackAiWorkerFlow` subscription in `main.zig` picks it
//!      up on a worker thread. The session id IS the routine id (the
//!      workspace-level analogue of the old `task.id == session.id`
//!      convention), so every fire appends to the same session chat.
//!      The `queue_message` is `formatRoutineMessage(schedule,
//!      instruction, next_run_at)` — the routine's `instruction`
//!      wrapped with scheduling context so the LLM knows this is an
//!      automated fire (not a user-typed message) and when to expect
//!      the next one.
//!   4. On success: `markSuccess` with a recomputed `next_run_at`
//!      (NULL for manual-only routines). The LLM result is NOT
//!      observed here — it's fire-and-forget. If the LLM fails, it
//!      shows up as a chat-view error (the same path as a normal
//!      user session).
//!
//! No new binary, no separate OS thread — all work happens on the
//! main process's Io runtime via the existing
//! `group_emit_session_create` group.
//!
//! Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md (Task 3)
//! Task: task_1789032258828_0.

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_mod.ai_workflow;

const model = @import("model.zig");
const cron = @import("cron.zig");

/// Errors returned by `fireWorkspaceRoutine`. These are all SENTINELS —
/// the fire pipeline does NOT propagate underlying errors (e.g.
/// `error.RoutineNotFound`) to the caller. The scheduler maps them
/// to "skip this id, try the next one"; HTTP handlers map them to
/// status codes.
pub const FireError = error{
    /// No `workspace_routines` row for this id.
    NotARoutine,
    /// The routine exists but `enabled = false`.
    Disabled,
    /// A previous fire is still in flight (`last_status = 'running'`).
    AlreadyRunning,
};

/// Fire a single workspace routine. Loads the routine, atomically
/// claims the row, then submits the LLM work via
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
/// The return type is `anyerror!void` rather than a narrow
/// `FireError!void` set: the helpers this function calls
/// (`loadWorkspaceRoutineById`, `claimForRun`, `markSuccess`,
/// `cron.nextFireTime`, the `dupe` family) each contribute their own
/// error variants, and propagating them through a narrow set would
/// expose internal implementation details. The three `FireError`
/// variants (NotARoutine, Disabled, AlreadyRunning) are produced
/// only at the controlled boundaries documented in the `FireError`
/// declaration. The scheduler switches on those three explicitly
/// and treats any other error as a generic fire failure (logged,
/// skipped, polling continues).
pub fn fireWorkspaceRoutine(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    di: *nalarcore.ContextIPCTui,
    io: std.Io,
    routine_id: []const u8,
) anyerror!void {
    // 1) Load the routine row. A missing row means the id is not a
    //    workspace routine.
    const routine = model.loadWorkspaceRoutineById(allocator, db, routine_id) catch |err| switch (err) {
        error.RoutineNotFound => return FireError.NotARoutine,
        else => return err,
    };
    defer routine.deinit(allocator);

    if (!routine.enabled) return FireError.Disabled;

    // 2) Atomic claim. `claimForRun` is a single conditional UPDATE;
    //    a second concurrent fire on the same row sees zero affected
    //    rows and `claimForRun` returns false.
    if (!try model.claimForRun(allocator, db, routine.id)) return FireError.AlreadyRunning;

    // 3) Compute the new `next_run_at` ONCE and use it for both the
    //    LLM message and the post-submit markSuccess. Manual-only
    //    routines (empty schedule) keep NULL — there is no next fire.
    var next_sqlite: []const u8 = "";
    var next_sqlite_owned: ?[]u8 = null;
    defer if (next_sqlite_owned) |b| allocator.free(b);
    if (routine.schedule.len > 0) {
        const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
        const next_ns = try cron.nextFireTime(routine.schedule, now_ns);
        next_sqlite_owned = try formatSqliteDatetime(allocator, next_ns);
        next_sqlite = next_sqlite_owned.?;
    }

    // 4) Heap-allocate strings for the concurrent task. The callback
    //    owns these and frees them when done (mirrors
    //    `session_create.zig:141-159`). Use `errdefer` chains so a
    //    mid-allocation failure unwinds cleanly. The `qmsg` is
    //    `formatRoutineMessage(...)` — a structured "automated
    //    workspace-routine fire" header + schedule/next-fire bullets,
    //    then a blank line, then the routine's `instruction` verbatim.
    const sid = try di.allocator.dupe(u8, routine.id);
    errdefer di.allocator.free(sid);
    const schedule_label = if (routine.schedule.len > 0) routine.schedule else "(manual)";
    const qmsg = try formatRoutineMessage(di.allocator, schedule_label, routine.instruction, next_sqlite);
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

    // 5) Submit the LLM work to the Io group. The callback emits the
    //    event; the Io runtime processes the event via
    //    `CallbackAiWorkerFlow` in a worker thread. This call
    //    returns immediately — the actual LLM call happens
    //    asynchronously.
    try di.group_emit_session_create.concurrent(
        io,
        runFire,
        .{ di, sid, qmsg, cwd, bmsg, atools, iurls, spm },
    );

    // 6) Mark success and advance next_run_at. The LLM is
    //    fire-and-forget — we don't wait for it to complete before
    //    marking success. We reuse the `next_sqlite` we computed
    //    above; the defer above will free it once markSuccess
    //    returns.
    try model.markSuccess(allocator, db, routine.id, next_sqlite);
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

/// Format the user-style message that gets sent to the LLM when a
/// routine fires. Wraps the routine's `instruction` with a
/// structured metadata header so the LLM knows this is an automated
/// fire (not a user-typed message) and when to expect the next one.
///
/// The format is:
///
///   This is an automated workspace-routine fire.
///   - Schedule: <schedule>
///   - Next fire: <next_run_at_sqlite>
///
///   <instruction>
///
/// where `<next_run_at_sqlite>` is an SQLite DATETIME literal
/// (`YYYY-MM-DD HH:MM:SS`) — the FUTURE fire time (the time AFTER
/// the current one). Empty for manual-only fires.
///
/// The format is designed to be LLM-friendly:
///   - "automated workspace-routine fire" makes it explicit that this
///     is NOT a user-typed message, so the LLM doesn't expect a
///     conversational back-and-forth — and distinguishes it from the
///     old per-task routine fires.
///   - The metadata header is FIRST and the actual task is LAST, so
///     the LLM reads the context-setting sentence before the task.
///   - A blank line separates the metadata block from the task,
///     giving the LLM a clear instruction boundary.
///   - Bulleted key-value pairs (rather than a prose sentence) let
///     the LLM extract schedule / next-fire without parsing.
///   - No LLM-jargon words ("prompt", "instruction", "execute") that
///     are ambiguous when used inside the prompt itself.
///   - Easy to extend: adding fields like "Last status: success" or
///     "Run #5" slots in as new bullets without breaking parsing.
///
/// Public for unit testing in `fire_test.zig` — the happy-path of
/// `fireWorkspaceRoutine` requires a real `nalarcore.ContextIPCTui`
/// singleton and a live `CallbackAiWorkerFlow` subscription (i.e. a
/// real `nalar` process), so the format is tested in isolation here.
pub fn formatRoutineMessage(
    allocator: std.mem.Allocator,
    schedule: []const u8,
    instruction: []const u8,
    next_run_at_sqlite: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "This is an automated workspace-routine fire.\n" ++
        "- Schedule: {s}\n" ++
        "- Next fire: {s}\n" ++
        "\n" ++
        "{s}", .{ schedule, next_run_at_sqlite, instruction });
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
    return std.fmt.allocPrint(allocator, "{d:04}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        @as(u32, @intCast(day_seconds.getHoursIntoDay())),
        @as(u32, @intCast(day_seconds.getMinutesIntoHour())),
        @as(u32, @intCast(day_seconds.getSecondsIntoMinute())),
    });
}
