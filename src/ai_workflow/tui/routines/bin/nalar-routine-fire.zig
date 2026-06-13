//! `nalar-routine-fire` — sub-process entry point that runs the
//! per-fire work for a single routine.
//!
//! Invoked by the routine scheduler (Task 3.1's `Scheduler.zig`)
//! once per fire via `std.process.spawn`, fire-and-forget:
//!
//!     nalar-routine-fire --id <routine_task_id> [--db <path>]
//!
//! The `--id` value is the `workspace_item_tasks.id` of the parent
//! task (NOT the `routines.id` — the fire pipeline looks the
//! routine up by `task_id`). The `--db` path is optional and
//! defaults to `$HOME/.config/nalar/agent.db` (resolved via
//! `helpers.db_path.getDbPath`, the same helper `main.zig` uses).
//!
//! Exit codes:
//!   0 — fire completed (the message was inserted, the LLM emit was
//!       either dispatched or short-circuited via the test-only
//!       `ROUTINE_FIRE_TEST_SKIP_LLM` env var).
//!   1 — arg parse error, DB open error, or the fire pipeline
//!       returned a `FireError` other than `FakeLLMSuccess`
//!       (e.g. `NotARoutine`, `Disabled`, `AlreadyRunning`).
//!
//! The sub-process is intentionally tiny: parse args, open DB,
//! call `fire.fireRoutine`, exit. The actual per-fire work lives
//! in `nalarcore.ai_mod.routines.fire` and is shared with the HTTP
//! handler (Chunk 4) so the two paths can't drift.
//!
//! Build target: Task 2.4 adds the `install:routine-fire` step in
//! `build.zig` (parallel to `install:linux`); this file's only
//! `build.zig` requirement is that the new step passes the same
//! `nalarcore` module import the other executables use.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunks-2-3.md (Task 2.2)
//! Design: docs/plans/2026-06-13-add-task-routines-design.md (§4.2)

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const fire = nalarcore.ai_mod.routines.fire;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const environment = init.environ_map;

    // ── 1. Parse args ─────────────────────────────────────────────────
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

    // ── 2. Resolve DB path ────────────────────────────────────────────
    // Override → use as-is. Otherwise → helpers.db_path.getDbPath reads
    // $HOME, creates ~/.config/nalar/, and returns a null-terminated
    // path. The helper returns a heap-allocated `[:0]const u8` we own.
    const db_path: [:0]const u8 = if (db_path_override) |p|
        try allocator.dupeZ(u8, p)
    else
        try nalarcore.helpers.db_path.getDbPath(allocator, io, environment);
    defer allocator.free(db_path);

    // ── 3. Open DB and run the fire pipeline ──────────────────────────
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, db_path);

    // `fire.fireRoutine` returns `anyerror!void`. The `FireError`
    // variants are mapped to a non-zero exit code (the sub-process
    // is a control surface, not an interactive one — the scheduler
    // only inspects the exit code). The test-only `FakeLLMSuccess`
    // sentinel is treated as a normal successful completion (exit
    // 0) because the production work it short-circuits is itself
    // just "insert message + emit event", both of which the test
    // path has already done.
    fire.fireRoutine(allocator, &db, io, environment, routine_id) catch |err| {
        if (err == fire.FireError.FakeLLMSuccess) {
            std.process.exit(0);
        }
        std.log.err("fireRoutine failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(0);
}
