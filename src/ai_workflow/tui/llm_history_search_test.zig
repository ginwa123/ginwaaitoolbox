//! Behavioural regression checks for the server-side search filter on
//! `listWorkspaceItemTasksWithCursor` (kanban task search feature).
//!
//! Why this file exists
//! ────────────────────
//! The kanban task search feature (plan:
//! docs/superpowers/plans/2026-07-30-kanban-task-search.md) extends
//! `listWorkspaceItemTasksWithCursor` with an optional `q: ?[]const u8`
//! parameter that filters by case-insensitive substring match against
//! `name`, `description`, and `tags`. The filter runs at the SQL level
//! via `WHERE … LIKE ? ESCAPE '\'` with `%`/`_`/`\` in user input
//! escaped to literal semantics.
//!
//! Without behavioural tests, a regression (e.g. a future refactor that
//! removes the `ESCAPE` clause or stops escaping user `%`) would let a
//! user typing `%` match every row — silently defeating the filter.
//! These tests catch that class of bug by actually running SQL queries
//! against an in-memory database and asserting on the returned rows.
//!
//! Why a behavioural DB test (not static-source grep)?
//! ────────────────────────────────────────────────────
//! The project's `static-contract-test-when-to-prefer-behavioural`
//! rule says: when feasible, prefer behavioural tests. Search is a
//! runtime concern — SQL correctness can only be verified by running
//! the query and checking the result. A grep test on `ESCAPE '\'` would
//! pass for an implementation that escapes the wrong character or
//! forgets to bind `?` three times.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;
const TaskSortField = llm_history.TaskSortField;
const TaskSortDirection = llm_history.TaskSortDirection;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory SQLite DB with the minimum schema needed for
/// `listWorkspaceItemTasksWithCursor` to run. The function LEFT JOINs
/// `routines` and `sessions` onto `workspace_item_tasks`; we need to
/// create all three (SQLite rejects JOINs onto missing tables).
fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    description TEXT,
        \\    created_at TEXT,
        \\    updated_at TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    is_pinned INTEGER DEFAULT 0,
        \\    pinned_position INTEGER DEFAULT 0,
        \\    kanban_column_id TEXT,
        \\    kanban_position INTEGER DEFAULT 0,
        \\    last_human_touched_at INTEGER,
        \\    tags TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE routines (
        \\    task_id TEXT PRIMARY KEY,
        \\    schedule TEXT,
        \\    initial_prompt TEXT,
        \\    enabled INTEGER,
        \\    last_run_at TEXT,
        \\    next_run_at TEXT,
        \\    last_status TEXT,
        \\    last_error TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    is_auto_retry_until_stop TEXT DEFAULT '0',
        \\    last_finish_reason TEXT,
        \\    updated_at TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn insertTask(
    ctx: *TestCtx,
    alloc: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    description: []const u8,
    tags: []const u8,
) !void {
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO workspace_items (id, workspace_id, item_type) " ++
            "VALUES ('wi_1', 'ws_1', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, description, updated_at, task_type, tags)
        \\VALUES (?, ?, 'wi_1', ?, datetime('now'), 'standard', ?)
    , &.{ id, name, description, tags });
}

/// Free a returned tasks slice — mirrors the production deinit pattern
/// (each row's heap-allocated fields + the slice itself).
fn freeTasks(alloc: std.mem.Allocator, tasks: []llm_history.WorkspaceItemTaskInfo) void {
    for (tasks) |*t| t.deinit(alloc);
    alloc.free(tasks);
}

// ─── Contract 1: q matches against name ───────────────────────────────────

test "listWorkspaceItemTasksWithCursor matches q against name (case-insensitive substring)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "fix login bug", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "logout cleanup", "", "[]");
    try insertTask(&ctx, alloc, "task_3", "design page", "", "[]");

    const result = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 100, null, .updated_at, .desc, "login",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 1), result.tasks.len);
    try testing.expectEqualStrings("task_1", result.tasks[0].id);
    try testing.expect(!result.has_more);
}

// ─── Contract 2: q matches against description ────────────────────────────

test "listWorkspaceItemTasksWithCursor matches q against description" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "feature one", "contains login flow", "[]");
    try insertTask(&ctx, alloc, "task_2", "feature two", "totally unrelated", "[]");
    try insertTask(&ctx, alloc, "task_3", "feature three", "another login ref", "[]");

    const result = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 100, null, .updated_at, .desc, "login",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 2), result.tasks.len);
    try testing.expectEqualStrings("task_3", result.tasks[0].id);
    try testing.expectEqualStrings("task_1", result.tasks[1].id);
}

// ─── Contract 3: q matches against tags (JSON-encode substring) ─────────

test "listWorkspaceItemTasksWithCursor matches q against tags JSON text" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "feature one", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "feature two", "", "[\"login\",\"urgent\"]");
    try insertTask(&ctx, alloc, "task_3", "feature three", "", "[\"design\",\"frontend\"]");

    const result = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 100, null, .updated_at, .desc, "login",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 1), result.tasks.len);
    try testing.expectEqualStrings("task_2", result.tasks[0].id);
}

// ─── Contract 4: q is case-insensitive across all 3 fields ──────────────

test "listWorkspaceItemTasksWithCursor q is case-insensitive" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "Fix Login", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "feature", "LOGIN FLOW", "[]");
    try insertTask(&ctx, alloc, "task_3", "feature", "", "[\"Login\",\"urgent\"]");

    const upper = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 100, null, .updated_at, .desc, "LOGIN",
    );
    defer freeTasks(alloc, upper.tasks);
    try testing.expectEqual(@as(usize, 3), upper.tasks.len);

    const mixed = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 100, null, .updated_at, .desc, "LoGiN",
    );
    defer freeTasks(alloc, mixed.tasks);
    try testing.expectEqual(@as(usize, 3), mixed.tasks.len);
}

// ─── Contract 5: empty q is equivalent to no filter ──────────────────────

test "listWorkspaceItemTasksWithCursor with empty q returns all tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "beta", "", "[]");
    try insertTask(&ctx, alloc, "task_3", "gamma", "", "[]");

    const result = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 100, null, .updated_at, .desc, "",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 3), result.tasks.len);
}

// ─── Contract 6: null q is equivalent to no filter ───────────────────────

test "listWorkspaceItemTasksWithCursor with null q returns all tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "beta", "", "[]");

    const result = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 100, null, .updated_at, .desc, null,
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 2), result.tasks.len);
}

// ─── Contract 7: user-supplied % is escaped (matches nothing, not all) ──

test "listWorkspaceItemTasksWithCursor escapes % so literal % matches nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "beta", "", "[]");

    const result = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 100, null, .updated_at, .desc, "%",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 0), result.tasks.len);
}

// ─── Contract 8: user-supplied _ is escaped (matches nothing, not all) ───

test "listWorkspaceItemTasksWithCursor escapes _ so literal _ matches nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "beta", "", "[]");

    const result = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 100, null, .updated_at, .desc, "_",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 0), result.tasks.len);
}

// ─── Contract 9: SQL injection attempt is a no-op ───────────────────────

test "listWorkspaceItemTasksWithCursor SQL-injection attempt returns no rows (parameterized)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "beta", "", "[]");

    const result = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 100, null, .updated_at, .desc, "' OR '1'='1",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 0), result.tasks.len);
}

// ─── Contract 10: q + cursor pagination advances through matches only ────

test "listWorkspaceItemTasksWithCursor q + cursor advances through matches only" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_m1", "match one", "", "[]");
    try insertTask(&ctx, alloc, "task_m2", "match two", "", "[]");
    try insertTask(&ctx, alloc, "task_m3", "match three", "", "[]");
    try insertTask(&ctx, alloc, "task_m4", "match four", "", "[]");
    try insertTask(&ctx, alloc, "task_m5", "match five", "", "[]");
    try insertTask(&ctx, alloc, "task_x1", "other one", "", "[]");
    try insertTask(&ctx, alloc, "task_x2", "other two", "", "[]");
    try insertTask(&ctx, alloc, "task_x3", "other three", "", "[]");
    try insertTask(&ctx, alloc, "task_x4", "other four", "", "[]");
    try insertTask(&ctx, alloc, "task_x5", "other five", "", "[]");

    const page1 = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 2, null, .updated_at, .desc, "match",
    );
    defer freeTasks(alloc, page1.tasks);

    try testing.expectEqual(@as(usize, 2), page1.tasks.len);
    try testing.expect(page1.has_more);
    try testing.expectEqualStrings("task_m5", page1.tasks[0].id);
    try testing.expectEqualStrings("task_m4", page1.tasks[1].id);

    // Cursor = "<updated_at>|<id>". production handler encodes this; the
    // DB fn just splits on the pipe. Use the first page's last row's
    // updated_at + id to construct the next cursor.
    const cursor_value = page1.tasks[1].updated_at orelse return error.UpdatedAtMissing;
    var cursor_buf: [256]u8 = undefined;
    const cursor_str = try std.fmt.bufPrint(
        &cursor_buf,
        "{s}|{s}",
        .{ cursor_value, page1.tasks[1].id },
    );
    const page2 = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 2, cursor_str, .updated_at, .desc, "match",
    );
    defer freeTasks(alloc, page2.tasks);

    try testing.expectEqual(@as(usize, 2), page2.tasks.len);
    try testing.expect(page2.has_more);
    try testing.expectEqualStrings("task_m3", page2.tasks[0].id);
    try testing.expectEqualStrings("task_m2", page2.tasks[1].id);

    const cursor_value2 = page2.tasks[1].updated_at orelse return error.UpdatedAtMissing;
    var cursor_buf2: [256]u8 = undefined;
    const cursor_str2 = try std.fmt.bufPrint(
        &cursor_buf2,
        "{s}|{s}",
        .{ cursor_value2, page2.tasks[1].id },
    );
    const page3 = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 2, cursor_str2, .updated_at, .desc, "match",
    );
    defer freeTasks(alloc, page3.tasks);

    try testing.expectEqual(@as(usize, 1), page3.tasks.len);
    try testing.expect(!page3.has_more);
    try testing.expectEqualStrings("task_m1", page3.tasks[0].id);
}

// ─── Contract 11: nonexistent q returns empty + has_more=false ───────────

test "listWorkspaceItemTasksWithCursor with nonexistent q returns empty + has_more=false" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertTask(&ctx, alloc, "task_1", "alpha", "", "[]");
    try insertTask(&ctx, alloc, "task_2", "beta", "", "[]");

    const result = try llm_history.listWorkspaceItemTasksWithCursor(
        alloc, &ctx.db, "wi_1", 100, null, .updated_at, .desc,
        "nonexistent_token_xyz_12345",
    );
    defer freeTasks(alloc, result.tasks);

    try testing.expectEqual(@as(usize, 0), result.tasks.len);
    try testing.expect(!result.has_more);
}