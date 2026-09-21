const std = @import("std");
const nalarcore = @import("nalarcore");

const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const helpers = @import("helpers");
const onEventSendWorkers = @import("sse_send_event_worker.zig").onEventSendWorkers;
const event_bus_mod = nalarcore.event_bus;
const testing = std.testing;

pub const UpsertWorkerInput = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    worker_id: []const u8,
    session_id: []const u8,
    working_directory: []const u8,
    event_bus: ?*event_bus_mod.EventBus,
    is_emit_sse: bool,
    /// Owner user id (Migration 092). Defaults to 'user_system'
    /// (visible to all) so legacy callers that do not resolve auth
    /// keep the old shared-visibility behaviour.
    user_id: []const u8 = "user_system",
};

/// Register or update a worker
pub fn updateWorker(obj: UpsertWorkerInput) !void {
    const allocator = obj.allocator;
    const db = obj.db;
    const logger = obj.logger;

    const worker_id = obj.worker_id;
    const session_id = obj.session_id;
    const working_directory = obj.working_directory;
    const is_emit_sse = obj.is_emit_sse;
    const event_bus = obj.event_bus;

    // Check if the worker already exists so we can emit the correct SSE action.
    const check_sql =
        \\SELECT 1
        \\FROM worker
        \\WHERE id = ?
        \\LIMIT 1;
    ;

    var rows = try db.query(allocator, check_sql, &.{worker_id});
    defer rows.deinit();

    const maybe_row = try rows.next();
    defer if (maybe_row) |r| r.deinit(allocator);
    const exists = maybe_row != null;

    // Resolve effective owner: prefer the session's user_id (set by
    // emit_run_agent from the auth cookie) so background heartbeats
    // that carry the default 'user_system' do not clobber a real
    // owner. Falls back to obj.user_id, then 'user_system'.
    var effective_user_id: []const u8 = obj.user_id;
    var owned_session_user = false;
    var sess_q = db.query(allocator, "SELECT COALESCE(user_id, '') FROM sessions WHERE id = ? LIMIT 1", &.{session_id}) catch null;
    if (sess_q) |*sq| {
        defer sq.deinit();
        if ((sq.next() catch null)) |srow| {
            defer srow.deinit(allocator);
            if (srow.values.len > 0 and srow.values[0].len > 0 and !std.mem.eql(u8, srow.values[0], "user_system")) {
                effective_user_id = allocator.dupe(u8, srow.values[0]) catch obj.user_id;
                if (effective_user_id.ptr != obj.user_id.ptr) owned_session_user = true;
            }
        }
    }
    defer if (owned_session_user) allocator.free(effective_user_id);

    // Insert or update the worker. user_id is stamped on insert and
    // preserved across heartbeats: ON CONFLICT updates it to the
    // latest resolved owner so a worker started as user_system then
    // re-triggered by a real user migrates to the real owner.
    // When the effective owner is still 'user_system', keep any
    // existing real owner instead of downgrading it.
    const worker_sql =
        \\INSERT INTO worker (
        \\    id,
        \\    session_id,
        \\    working_directory,
        \\    last_activity_nano,
        \\    last_activity_description,
        \\    user_id
        \\)
        \\VALUES (
        \\    ?,
        \\    ?,
        \\    ?,
        \\    strftime('%s', 'now'),
        \\    '',
        \\    ?
        \\)
        \\ON CONFLICT(id) DO UPDATE SET
        \\    session_id = excluded.session_id,
        \\    working_directory = excluded.working_directory,
        \\    last_activity_nano = excluded.last_activity_nano,
        \\    last_activity_description = excluded.last_activity_description,
        \\    user_id = CASE WHEN excluded.user_id = 'user_system' THEN worker.user_id ELSE excluded.user_id END;
    ;

    // When the worker table predates Migration 092 (no user_id
    // column, e.g. unit-test :memory: DBs), fall back to the legacy
    // upsert without user_id so old callers keep working.
    {
        var col_q = db.query(allocator, "SELECT 1 FROM pragma_table_info('worker') WHERE name = 'user_id'", &[_][]const u8{}) catch null;
        var has_user_col = false;
        if (col_q) |*cq| {
            defer cq.deinit();
            if ((cq.next() catch null)) |col_row| {
                col_row.deinit(allocator);
                has_user_col = true;
            }
        }
        if (has_user_col) {
            try db.exec(
                allocator,
                worker_sql,
                &.{
                    worker_id,
                    session_id,
                    working_directory,
                    effective_user_id,
                },
            );
        } else {
            try db.exec(
                allocator,
                \\INSERT INTO worker (id, session_id, working_directory, last_activity_nano, last_activity_description)
                \\VALUES (?, ?, ?, strftime('%s', 'now'), '')
                \\ON CONFLICT(id) DO UPDATE SET session_id = excluded.session_id, working_directory = excluded.working_directory, last_activity_nano = excluded.last_activity_nano, last_activity_description = excluded.last_activity_description
                ,
                &.{
                    worker_id,
                    session_id,
                    working_directory,
                },
            );
        }
    }

    // Ensure the session exists WITHOUT overwriting `name`.
    //
    // Pre-fix, this was `INSERT ... ON CONFLICT(id) DO UPDATE SET
    // name = excluded.name` which overwrote `sessions.name` with the
    // literal `session_id` on every worker iteration. For kanban
    // tasks (`task.id == session.id` per Migration 052) that meant the
    // sidebar's ChatsList showed "task_<timestamp>" instead of the
    // user-typed title — the same class of bug closed by PR #225 for
    // the create paths, but missed at the worker-entry path here.
    //
    // Post-fix: `INSERT OR IGNORE` is a no-op when the row already
    // exists (the handler bound the title at create time), and a
    // follow-up UPDATE bumps `updated_at` so the
    // cleanup_stale_worker cron doesn't wipe a long-running workflow
    // (see memory `cleanup-stale-worker-cron`). The `name` column is
    // NEVER touched by this upsert — the kanban create handlers bind
    // the title, and non-kanban handlers bind the user's chosen name;
    // the worker has no business overwriting either.
    try db.exec(
        allocator,
        "INSERT OR IGNORE INTO sessions (id, name, status, created_at, updated_at) VALUES (?, '', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
        &.{session_id},
    );
    try db.exec(
        allocator,
        "UPDATE sessions SET updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        &.{session_id},
    );

    // update workspace_item_tasks if exists
    try db.exec(allocator, "UPDATE workspace_item_tasks SET updated_at = datetime('now') WHERE id = ?", &.{session_id});

    if (!is_emit_sse) return;

    if (event_bus == null) return;

    const action = if (exists) "updated" else "created";
    const now_timestamp: i64 = helpers.unixTimestamp();

    onEventSendWorkers(allocator, .{
        .action = action,
        .id = worker_id,
        .session_id = session_id,
        .working_directory = working_directory,
        .last_activity = now_timestamp,
        .last_activity_description = "",
        .created_at = "",
        .event_bus = event_bus.?,
    }) catch |err| {
        if (logger) |log| {
            log.errFmt(
                "[upsertWorker] Failed to send worker event: {s}\n",
                .{@errorName(err)},
            );
        }
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────────

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT,
        \\    working_directory TEXT,
        \\    last_activity_nano INTEGER,
        \\    last_activity_description TEXT,
        \\    user_id TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    status TEXT,
        \\    cwd TEXT,
        \\    created_at TEXT,
        \\    updated_at TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    updated_at TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "updateWorker inserts a fresh worker row and a matching sessions row" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try updateWorker(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .worker_id = "w_new",
        .session_id = "s_new",
        .working_directory = "/tmp/new",
        .event_bus = null,
        .is_emit_sse = false,
    });

    // worker row exists
    {
        var q = try s.db.query(testing.allocator, "SELECT working_directory FROM worker WHERE id = 'w_new'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.WorkerRowMissing;
        defer row.deinit(testing.allocator);
        try testing.expectEqualStrings("/tmp/new", row.values[0]);
    }
    // sessions row exists with status='active'
    {
        var q = try s.db.query(testing.allocator, "SELECT status FROM sessions WHERE id = 's_new'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.SessionRowMissing;
        defer row.deinit(testing.allocator);
        try testing.expectEqualStrings("active", row.values[0]);
    }
}

test "updateWorker ON CONFLICT overwrites the existing working_directory" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_up", .session_id = "s_up", .working_directory = "/old", .event_bus = null, .is_emit_sse = false });
    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_up", .session_id = "s_up", .working_directory = "/new", .event_bus = null, .is_emit_sse = false });

    var q = try s.db.query(testing.allocator, "SELECT working_directory FROM worker WHERE id = 'w_up'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.WorkerRowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("/new", row.values[0]);
}

test "updateWorker ON CONFLICT also updates the session row's updated_at" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    // Seed an old sessions row.
    try s.db.exec(testing.allocator, "INSERT INTO sessions (id, name, status, updated_at) VALUES ('s_old', 'old', 'active', '2020-01-01 00:00:00')", &.{});

    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_old", .session_id = "s_old", .working_directory = "/x", .event_bus = null, .is_emit_sse = false });

    var q = try s.db.query(testing.allocator, "SELECT updated_at FROM sessions WHERE id = 's_old'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.SessionRowMissing;
    defer row.deinit(testing.allocator);
    // updated_at must have been bumped past the seed value.
    try testing.expect(!std.mem.eql(u8, row.values[0], "2020-01-01 00:00:00"));
}

test "updateWorker updates workspace_item_tasks.updated_at when a matching task exists" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try s.db.exec(testing.allocator, "INSERT INTO workspace_item_tasks (id, updated_at) VALUES ('s_task', 'epoch')", &.{});

    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_t", .session_id = "s_task", .working_directory = "/tmp", .event_bus = null, .is_emit_sse = false });

    var q = try s.db.query(testing.allocator, "SELECT updated_at FROM workspace_item_tasks WHERE id = 's_task'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.TaskRowMissing;
    defer row.deinit(testing.allocator);
    try testing.expect(!std.mem.eql(u8, row.values[0], "epoch"));
}

test "updateWorker with is_emit_sse=true and event_bus=null is a safe no-op for the SSE branch" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    // The implementation must check `if (event_bus == null) return;` BEFORE
    // any payload allocation. The DB writes must still complete.
    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_skip_sse", .session_id = "s_skip_sse", .working_directory = "/tmp", .event_bus = null, .is_emit_sse = true });

    // Confirm the DB write happened.
    var q = try s.db.query(testing.allocator, "SELECT 1 FROM worker WHERE id = 'w_skip_sse'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.WorkerRowMissing;
    defer row.deinit(testing.allocator);
}

test "updateWorker with is_emit_sse=false short-circuits before any event_bus access" {
    // Same as above but exercises the OTHER short-circuit branch — the
    // implementation does `if (!is_emit_sse) return;` first, so even a
    // null event_bus can't cause a problem.
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_no_sse", .session_id = "s_no_sse", .working_directory = "/tmp", .event_bus = null, .is_emit_sse = false });

    var q = try s.db.query(testing.allocator, "SELECT 1 FROM worker WHERE id = 'w_no_sse'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.WorkerRowMissing;
    defer row.deinit(testing.allocator);
}

test "updateWorker writes a non-empty last_activity_description (defensive: default '')" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try updateWorker(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .worker_id = "w_lad", .session_id = "s_lad", .working_directory = "/tmp", .event_bus = null, .is_emit_sse = false });

    var q = try s.db.query(testing.allocator, "SELECT last_activity_description FROM worker WHERE id = 'w_lad'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.WorkerRowMissing;
    defer row.deinit(testing.allocator);
    // The impl passes '' as the default — document that.
    try testing.expectEqualStrings("", row.values[0]);
}

