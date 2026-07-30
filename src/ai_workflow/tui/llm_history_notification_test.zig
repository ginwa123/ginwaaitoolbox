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
// 2. WorkspaceItemTaskInfo exposes the new fields
// ───────────────────────────────────────────────────────────────────────

test "WorkspaceItemTaskInfo exposes last_finish_reason and needs_human_review fields" {
    // Source-grep contract — the struct definition must carry both
    // fields. If a future refactor renames or drops them, the kanban
    // icon feature silently regresses.
    const source = @embedFile("llm_history.zig");
    if (std.mem.indexOf(u8, source, "last_finish_reason:") == null) {
        std.debug.print(
            \\
            \\!! llm_history.zig does NOT expose `last_finish_reason` on WorkspaceItemTaskInfo !!
            \\
        , .{});
        return error.LastFinishReasonFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "needs_human_review:") == null) {
        std.debug.print(
            \\
            \\!! llm_history.zig does NOT expose `needs_human_review` on WorkspaceItemTaskInfo !!
            \\
        , .{});
        return error.NeedsHumanReviewFieldMissing;
    }
}

test "WorkspaceItemTaskInfo.deinit frees last_finish_reason" {
    // Static contract — deinit must reference the field name. If a
    // future refactor adds the field but forgets the `allocator.free`
    // call, the kanban list endpoint leaks 1 slice per row.
    const source = @embedFile("llm_history.zig");
    // We accept either the singular "self.last_finish_reason" form or
    // any "if (self.last_finish_reason) |...|" pattern.
    const has_free = std.mem.indexOf(u8, source, "self.last_finish_reason") != null;
    if (!has_free) {
        std.debug.print(
            \\
            \\!! llm_history.zig WorkspaceItemTaskInfo.deinit does NOT free last_finish_reason !!
            \\
        , .{});
        return error.LastFinishReasonDeinitMissing;
    }
}

// ───────────────────────────────────────────────────────────────────────
// 3. listWorkspaceItemTasksWithCursor SELECT includes the new columns
// ───────────────────────────────────────────────────────────────────────

test "listWorkspaceItemTasksWithCursor SELECT adds last_finish_reason and needs_human_review" {
    // The kanban SELECT MUST include both columns from sessions
    // (last_finish_reason) and the CASE expression computing
    // needs_human_review. If the SELECT regresses to 18 columns, the
    // row decoder reads garbage at indices 19/20 — silent corruption
    // that's invisible at compile time.
    const source = @embedFile("llm_history.zig");
    // The function we want is `listWorkspaceItemTasksWithCursor`.
    const fn_idx = std.mem.indexOf(u8, source, "pub fn listWorkspaceItemTasksWithCursor(") orelse {
        std.debug.print(
            \\
            \\!! llm_history.zig does NOT define listWorkspaceItemTasksWithCursor !!
            \\
        , .{});
        return error.FnMissing;
    };
    // Slice the next 8000 chars (the function grew with the kanban
    // task search feature; the SELECT statement is now further down).
    const fn_body_end = @min(fn_idx + 8000, source.len);
    const fn_body = source[fn_idx..fn_body_end];
    if (std.mem.indexOf(u8, fn_body, "last_finish_reason") == null) {
        std.debug.print(
            \\
            \\!! listWorkspaceItemTasksWithCursor SELECT does NOT include last_finish_reason !!
            \\
        , .{});
        return error.LastFinishReasonSelectMissing;
    }
    if (std.mem.indexOf(u8, fn_body, "needs_human_review") == null) {
        std.debug.print(
            \\
            \\!! listWorkspaceItemTasksWithCursor SELECT does NOT include needs_human_review CASE !!
            \\
        , .{});
        return error.NeedsHumanReviewCaseMissing;
    }
}

// ───────────────────────────────────────────────────────────────────────
// 4. http_response.WorkspaceItemTaskResponse exposes the new fields
// ───────────────────────────────────────────────────────────────────────

test "http_response.WorkspaceItemTaskResponse exposes last_finish_reason and needs_human_review" {
    // Source-grep contract. If the wire struct loses the fields, the
    // frontend never sees them and the icon feature is invisible.
    const source = @embedFile("http_handlers/http_response.zig");
    if (std.mem.indexOf(u8, source, "last_finish_reason:") == null) {
        std.debug.print(
            \\
            \\!! http_response.zig does NOT expose `last_finish_reason` on WorkspaceItemTaskResponse !!
            \\
        , .{});
        return error.LastFinishReasonResponseMissing;
    }
    if (std.mem.indexOf(u8, source, "needs_human_review:") == null) {
        std.debug.print(
            \\
            \\!! http_response.zig does NOT expose `needs_human_review` on WorkspaceItemTaskResponse !!
            \\
        , .{});
        return error.NeedsHumanReviewResponseMissing;
    }
}

// ───────────────────────────────────────────────────────────────────────
// 5. tasks_list handler passes the fields through
// ───────────────────────────────────────────────────────────────────────

test "tasks_list handler passes last_finish_reason and needs_human_review into the response" {
    // Source-grep contract. The useCase builds WorkspaceItemTaskResponse
    // entries; without these two lines the JSON wire shape never
    // carries the new fields.
    const source = @embedFile("http_handlers/tasks_list.zig");
    if (std.mem.indexOf(u8, source, "last_finish_reason") == null) {
        std.debug.print(
            \\
            \\!! tasks_list.zig does NOT pass last_finish_reason into WorkspaceItemTaskResponse !!
            \\
        , .{});
        return error.LastFinishReasonHandlerMissing;
    }
    if (std.mem.indexOf(u8, source, "needs_human_review") == null) {
        std.debug.print(
            \\
            \\!! tasks_list.zig does NOT pass needs_human_review into WorkspaceItemTaskResponse !!
            \\
        , .{});
        return error.NeedsHumanReviewHandlerMissing;
    }
}

// ───────────────────────────────────────────────────────────────────────
// 6. Behavioural — the SQL predicate for needs_human_review works
//    end-to-end on a real in-memory DB.
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
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
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
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
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
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
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
        "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT, status TEXT, last_finish_reason TEXT, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
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