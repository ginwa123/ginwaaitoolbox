//! Process-startup wiring for the TUI module.
//!
//! Runs after the singleton is initialized and migrations have applied
//! (and before the HTTP server binds) to spin up background workers
//! that should live for the lifetime of the process.
//!
//! Today this is just the routine scheduler — `Scheduler.start(...)`
//! blocks forever, polling for due routines every 5s and firing them
//! via the same `group_emit_session_create` group the session-create
//! HTTP handler uses (per the PR #8 review comment: "no thread, use
//! async I/O"). Future background workers (rate-limiters, janitors,
//! etc.) belong here too.
//!
//! The scheduler runs on the main process's Io runtime (NOT a
//! separate OS thread) — see the user-facing review comment that
//! called this out. Submitting to
//! `di.group_emit_session_create.concurrent` is the project's
//! async-I/O pattern; the same pattern that
//! `session_create.zig:161` uses for per-session LLM work.
//!
//! The call site in `main.zig` must run AFTER `setSingleton(ctxParent)`
//! (so `di` is available) and after the event bus has been
//! initialized (so the scheduler's fire path can emit
//! `ai_workflow.RunParamsNew` events).

const std = @import("std");
const nalarcore = @import("nalarcore");
const Scheduler = @import("../routines/Scheduler.zig");

/// Submit the routine scheduler as a concurrent task on the Io
/// runtime. The task runs forever; on the same Io group as
/// session-create tasks. No thread is spawned.
pub fn start(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    di: *nalarcore.ContextIPCTui,
    io: std.Io,
) !void {
    try di.group_emit_session_create.concurrent(
        io,
        struct {
            fn run(
                alloc: std.mem.Allocator,
                database: *nalarcore.sqlite.SqliteBackend,
                di_inner: *nalarcore.ContextIPCTui,
                io_inner: std.Io,
            ) void {
                Scheduler.start(alloc, database, di_inner, io_inner) catch |err| {
                    std.log.err("scheduler crashed: {s}", .{@errorName(err)});
                };
            }
        }.run,
        .{ allocator, db, di, io },
    );
}
