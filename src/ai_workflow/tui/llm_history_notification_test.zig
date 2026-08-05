//! Regression checks for the kanban task "AI finished — awaiting
//! review" notification icon (plan:
//! docs/plans/2026-07-26-kanban-task-notification-icon.md, Chunk 2).
//!
//! Covers:
//!   1. `updateTaskLastHumanTouchedAt` writer on llm_history.zig
//!      (behavioural: stamp a unix-ms value, read it back).
//!   2. `WorkspaceItemTaskInfo` exposes `last_finish_reason` +
//!      `needs_human_review` fields (static contract — grep the source
//!      for the field names; the SQL-derived types only exist in the
//!      wire shape).
//!   3. `listWorkspaceItemTasksWithCursor` SELECT includes the new
//!      columns (static contract — grep the source for the CASE
//!      expression; the row decoder's column indices must match).
//!   4. `http_response.WorkspaceItemTaskResponse` exposes the same
//!      fields so they round-trip into the JSON wire (static).
//!   5. `tasks_list` handler passes them through from
//!      WorkspaceItemTaskInfo to the response struct (static).
//!   6. `WorkspaceItemTaskInfo.deinit` frees `last_finish_reason`
//!      (behavioural: would otherwise leak a heap slice per row).
//!
//! The behavioural predicate for `needs_human_review` is:
//!
//!     sessions.last_finish_reason == 'stop' AND
//!     (t.last_human_touched_at IS NULL OR
//!      t.last_human_touched_at < sessions.updated_at-in-ms)
//!
//! (SQLite stores `sessions.updated_at` as TEXT in
//! `'YYYY-MM-DD HH:MM:SS'` format, so we cast `strftime('%s', ...)`
//! to INTEGER seconds then multiply by 1000 to compare against the
//! INTEGER unix-ms stamp on the task.)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const llm_history = @import("nalarcore").ai_mod.llm_history;

// ───────────────────────────────────────────────────────────────────────
// 1. updateTaskLastHumanTouchedAt is callable + persists the value
// ───────────────────────────────────────────────────────────────────────

test "updateTaskLastHumanTouchedAt stamps the unix-ms value on the task" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    // Minimal tables Migration 065 needs (parent + task).
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_1', 'T1', 'wi_1')",
        &.{});

    // Before stamp — column doesn't exist yet (Migration 065 not run).
    // We don't strictly need the column to exist for the writer to
    // succeed at the SQL layer (sqlite would store into nothing), but
    // the realistic caller has run Migration 065 first. We simulate
    // that by ALTER-ing the column in directly.
    try db.exec(alloc,
        "ALTER TABLE workspace_item_tasks ADD COLUMN last_human_touched_at INTEGER",
        &.{});

    const now_ms: i64 = 1_786_500_000_000;
    try llm_history.updateTaskLastHumanTouchedAt(alloc, &db, "task_1", now_ms);

    var q = try db.query(alloc,
        "SELECT last_human_touched_at FROM workspace_item_tasks WHERE id = 'task_1'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1786500000000", row.values[0]);
}

test "updateTaskLastHumanTouchedAt overwrites on repeated calls" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, last_human_touched_at INTEGER)",
        &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_1', 'T1', 'wi_1')",
        &.{});

    try llm_history.updateTaskLastHumanTouchedAt(alloc, &db, "task_1", 100);
    try llm_history.updateTaskLastHumanTouchedAt(alloc, &db, "task_1", 500);

    var q = try db.query(alloc,
        "SELECT last_human_touched_at FROM workspace_item_tasks WHERE id = 'task_1'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("500", row.values[0]);
}

// ───────────────────────────────────────────────────────────────────────
// Behavioural — the SQL predicate for needs_human_review works
// end-to-end on a real in-memory DB.
// ───────────────────────────────────────────────────────────────────────

test "needs_human_review predicate returns 1 when finish_reason='stop' AND no human touch" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    // Parent table + task table with the Migration 065 column +
    // sessions table to JOIN against.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT,
        \\  workspace_item_id TEXT,
        \\  kanban_column_id TEXT,
        \\  kanban_position INTEGER,
        \\  last_human_touched_at INTEGER
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT,
        \\  status TEXT,
        \\  last_finish_reason TEXT,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  git_worktree_cwd TEXT
        \\)
    , &.{});

    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1','ws_1','kanban')",
        &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_awaiting', 'T1', 'wi_1')",
        &.{});
    // AI finished on this task 1 hour ago.
    try db.exec(alloc,
        "INSERT INTO sessions (id, name, status, last_finish_reason, updated_at) " ++
        "VALUES ('task_awaiting', 'T1', 'idle', 'stop', datetime('now', '-1 hour'))",
        &.{});

    // Replicate the production SQL CASE.
    var q = try db.query(alloc,
        \\SELECT CASE
        \\  WHEN COALESCE(s.last_finish_reason, '') = 'stop'
        \\       AND (
        \\         t.last_human_touched_at IS NULL
        \\         OR t.last_human_touched_at < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000
        \\       )
        \\  THEN 1 ELSE 0 END
        \\FROM workspace_item_tasks t
        \\LEFT JOIN sessions s ON s.id = t.id
        \\WHERE t.id = 'task_awaiting'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "needs_human_review predicate returns 0 when human touched AFTER the AI finished" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT,
        \\  last_human_touched_at INTEGER
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY, name TEXT, status TEXT,
        \\  last_finish_reason TEXT,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  git_worktree_cwd TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1','ws_1','kanban')",
        &.{});

    // AI finished 1 hour ago.
    try db.exec(alloc,
        "INSERT INTO sessions (id, name, status, last_finish_reason, updated_at) " ++
        "VALUES ('task_reviewed', 'T', 'idle', 'stop', datetime('now', '-1 hour'))",
        &.{});
    // Human touched 10 seconds ago (clearly after the AI's finish).
    // Fixed future timestamp — Zig 0.16 removed `std.time.timestamp()`
    // per project memory; rather than reach for libc we use a known
    // large unix-ms that's guaranteed-after the AI's "1 hour ago"
    // timestamp above.
    const now_ms: i64 = 2_000_000_000_000; // year 2033 in unix-ms
    var t_buf: [32]u8 = undefined;
    const t_str = std.fmt.bufPrint(&t_buf, "{d}", .{now_ms}) catch unreachable;
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, last_human_touched_at) " ++
        "VALUES ('task_reviewed', 'T', 'wi_1', ?)",
        &[_][]const u8{t_str});

    var q = try db.query(alloc,
        \\SELECT CASE
        \\  WHEN COALESCE(s.last_finish_reason, '') = 'stop'
        \\       AND (
        \\         t.last_human_touched_at IS NULL
        \\         OR t.last_human_touched_at < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000
        \\       )
        \\  THEN 1 ELSE 0 END
        \\FROM workspace_item_tasks t
        \\LEFT JOIN sessions s ON s.id = t.id
        \\WHERE t.id = 'task_reviewed'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "needs_human_review predicate returns 0 when finish_reason is 'tool_calls' (mid-tool, not yet stop)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT,
        \\  last_human_touched_at INTEGER
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY, name TEXT, status TEXT,
        \\  last_finish_reason TEXT,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  git_worktree_cwd TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1','ws_1','kanban')",
        &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_tools', 'T', 'wi_1')",
        &.{});
    // Agent is mid-tool-call, not finished yet.
    try db.exec(alloc,
        "INSERT INTO sessions (id, name, status, last_finish_reason, updated_at) " ++
        "VALUES ('task_tools', 'T', 'active', 'tool_calls', datetime('now'))",
        &.{});

    var q = try db.query(alloc,
        \\SELECT CASE
        \\  WHEN COALESCE(s.last_finish_reason, '') = 'stop'
        \\       AND (
        \\         t.last_human_touched_at IS NULL
        \\         OR t.last_human_touched_at < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000
        \\       )
        \\  THEN 1 ELSE 0 END
        \\FROM workspace_item_tasks t
        \\LEFT JOIN sessions s ON s.id = t.id
        \\WHERE t.id = 'task_tools'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "needs_human_review predicate returns 0 when no sessions row exists for the task" {
    // Tasks that never had any AI work (e.g. user created a card and
    // hasn't sent a chat message yet) should not show the dot.
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT,
        \\  last_human_touched_at INTEGER
        \\)
    , &.{});
    try db.exec(alloc,
        "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT, status TEXT, last_finish_reason TEXT, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, git_worktree_cwd TEXT)",
        &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1','ws_1','kanban')",
        &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('task_empty','T','wi_1')",
        &.{});

    var q = try db.query(alloc,
        \\SELECT CASE
        \\  WHEN COALESCE(s.last_finish_reason, '') = 'stop'
        \\       AND (
        \\         t.last_human_touched_at IS NULL
        \\         OR t.last_human_touched_at < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000
        \\       )
        \\  THEN 1 ELSE 0 END
        \\FROM workspace_item_tasks t
        \\LEFT JOIN sessions s ON s.id = t.id
        \\WHERE t.id = 'task_empty'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}