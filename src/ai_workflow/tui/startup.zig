//! Process-startup wiring for the TUI module.
//!
//! Runs after the singleton is initialized and migrations have applied
//! (and before the HTTP server binds) to spin up background workers
//! that should live for the lifetime of the process.
//!
//! Today this is just the routine scheduler — `Scheduler.start(...)`
//! blocks forever, polling for due routines every 5s and spawning
//! `nalar-routine-fire --id <id>` sub-processes. Future background
//! workers (rate-limiters, janitors, etc.) belong here too.
//!
//! The worker runs on a dedicated OS thread (matching the
//! `Cronjob.zig:42` / `bash.zig:340` pattern) so the HTTP server's
//! Io runtime on the main thread is never blocked. The thread is
//! detached — the scheduler runs until the process exits.

const std = @import("std");
const nalarcore = @import("nalarcore");
const Scheduler = @import("routines/Scheduler.zig");

/// Spawn the routine scheduler on a fresh OS thread. Returns an error
/// only if the thread itself fails to start; the scheduler's own
/// failures are logged inside the thread (it has no way to propagate
/// errors back to the caller and never returns).
pub fn start(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    io: std.Io,
) !void {
    const thread = try std.Thread.spawn(.{}, schedulerThreadMain, .{ allocator, db, io });
    thread.detach();
}

/// Body of the scheduler thread. The thread cannot propagate errors
/// back to `start`, so it logs and continues (the inner loop in
/// `Scheduler.start` already logs per-tick failures; this catches
/// startup-phase errors from `resetStuckRunning` / `recomputeDueNextRunAt`).
fn schedulerThreadMain(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    io: std.Io,
) void {
    Scheduler.start(allocator, db, io) catch |err| {
        std.log.err("scheduler thread crashed: {s}", .{@errorName(err)});
    };
}
