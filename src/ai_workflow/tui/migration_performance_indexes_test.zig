const std = @import("std");
const sqlite = @import("../../modules/databases/sqlite/Sqlite.zig");
const migration = @import("migration.zig");

const ExpectedIndex = struct {
    name: []const u8,
    table_name: []const u8,
    sql_contains: []const u8, // substring expected in the CREATE INDEX sql text
};

const expected_indexes = [_]ExpectedIndex{
    .{ .name = "idx_llm_history_session_created", .table_name = "llm_history", .sql_contains = "llm_history(session_id,created_at DESC)" },
    .{ .name = "idx_sessions_cwd_created", .table_name = "sessions", .sql_contains = "sessions(cwd,created_at DESC)" },
    .{ .name = "idx_sessions_updated_at", .table_name = "sessions", .sql_contains = "sessions(updated_at DESC)" },
    .{ .name = "idx_session_queue_messages_session_created", .table_name = "session_queue_messages", .sql_contains = "session_queue_messages(session_id,created_at ASC)" },
    .{ .name = "idx_worker_last_activity", .table_name = "worker", .sql_contains = "worker(last_activity DESC)" },
    .{ .name = "idx_workspace_items_workspace_created", .table_name = "workspace_items", .sql_contains = "workspace_items(workspace_id,created_at DESC)" },
    .{ .name = "idx_workspace_items_created_at", .table_name = "workspace_items", .sql_contains = "workspace_items(created_at DESC)" },
    .{ .name = "idx_workspace_item_tasks_item_created", .table_name = "workspace_item_tasks", .sql_contains = "workspace_item_tasks(workspace_item_id,created_at DESC)" },
    .{ .name = "idx_workspaces_created_at", .table_name = "workspaces", .sql_contains = "workspaces(created_at DESC)" },
};

/// Open a fresh in-memory DB, run all migrations, return the backend + the
/// Threaded Io it was opened with. The caller MUST keep the Threaded alive
/// for at least as long as the db — the SqliteBackend stores a copy of the
/// Io (which contains a vtable pointer into the Threaded allocation).
const TestCtx = struct {
    threaded: std.Io.Threaded,
    db: sqlite.SqliteBackend,
};

fn openMigratedDb(allocator: std.mem.Allocator) !TestCtx {
    var threaded = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();

    var db: sqlite.SqliteBackend = undefined;
    try db.init(threaded.io(), ":memory:");
    errdefer db.deinit();

    var manager = migration.MigrationManager.init(allocator, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .threaded = threaded, .db = db };
}

test "all 9 performance indexes exist after running migrations" {
    const allocator = std.testing.allocator;
    var ctx = try openMigratedDb(allocator);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    // Query sqlite_master for every index in the schema.
    var rows = try db.query(allocator,
        \\SELECT name, tbl_name, sql FROM sqlite_master
        \\WHERE type = 'index' AND name NOT LIKE 'sqlite_%'
        \\ORDER BY name
    , &.{});
    defer rows.deinit();

    // Collect into a list of {name, tbl_name, sql} for easy assertion.
    const FoundIndex = struct {
        name: []const u8,
        tbl_name: []const u8,
        sql: []const u8,
    };
    var found = std.ArrayList(FoundIndex).empty;
    defer {
        for (found.items) |f| allocator.free(f.sql);
        found.deinit(allocator);
    }

    while (try rows.next()) |row| {
        try found.append(allocator, .{
            .name = row.values[0],
            .tbl_name = row.values[1],
            .sql = try allocator.dupe(u8, row.values[2]),
        });
        row.deinit(allocator);
    }

    // Assert every expected index is present and on the right table.
    for (expected_indexes) |exp| {
        var matched = false;
        for (found.items) |f| {
            if (std.mem.eql(u8, f.name, exp.name)) {
                try std.testing.expect(std.mem.eql(u8, f.tbl_name, exp.table_name));
                try std.testing.expect(std.mem.indexOf(u8, f.sql, exp.sql_contains) != null);
                matched = true;
                break;
            }
        }
        try std.testing.expect(matched); // fail with a clear missing-index message
    }
}

test "hot session query uses idx_sessions_cwd_created compound index" {
    const allocator = std.testing.allocator;
    var ctx = try openMigratedDb(allocator);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    // Seed 200 rows spread across 4 cwds. SQLite's planner cost model only
    // picks an index over a full scan when there are enough rows to make the
    // index walk cheaper; ~200 rows is well past that threshold.
    {
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            const cwd_idx = i % 4;
            const id_buf = try std.fmt.allocPrint(allocator, "s{d}", .{i});
            defer allocator.free(id_buf);
            const cwd_buf = try std.fmt.allocPrint(allocator, "/tmp/dir{d}", .{cwd_idx});
            defer allocator.free(cwd_buf);
            try db.exec(allocator,
                "INSERT INTO sessions (id, name, status, cwd) VALUES (?, 'n', 'active', ?)",
                &.{ id_buf, cwd_buf });
        }
    }

    // EXPLAIN QUERY PLAN for the hot "latest session in this cwd" query.
    const sql =
        \\EXPLAIN QUERY PLAN
        \\SELECT s.id, s.name, s.status, s.cwd, s.created_at, s.updated_at
        \\FROM sessions s
        \\WHERE s.cwd = '/tmp/dir0'
        \\ORDER BY s.created_at DESC LIMIT 1
    ;
    var rows = try db.query(allocator, sql, &.{});
    defer rows.deinit();

    var plan_buf = std.ArrayList(u8).empty;
    defer plan_buf.deinit(allocator);
    while (try rows.next()) |row| {
        try plan_buf.appendSlice(allocator, row.values[3]);
        try plan_buf.append(allocator, '\n');
        row.deinit(allocator);
    }
    const plan = plan_buf.items;

    // The plan should reference our new index. If it does a SCAN of the sessions
    // table, the migration is missing or ANALYZE was skipped.
    try std.testing.expect(std.mem.indexOf(u8, plan, "idx_sessions_cwd_created") != null);
}

test "hot last-message query uses idx_llm_history_session_created" {
    const allocator = std.testing.allocator;
    var ctx = try openMigratedDb(allocator);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    // Seed 200 messages spread across 4 sessions so the planner picks the
    // compound index over a scan+sort.
    {
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            const session_idx = i % 4;
            const id_buf = try std.fmt.allocPrint(allocator, "m{d}", .{i});
            defer allocator.free(id_buf);
            const session_buf = try std.fmt.allocPrint(allocator, "sess{d}", .{session_idx});
            defer allocator.free(session_buf);
            const ts_buf = try std.fmt.allocPrint(allocator, "2026-01-01 10:{:02}:{:02}", .{ i / 60, i % 60 });
            defer allocator.free(ts_buf);
            try db.exec(allocator,
                "INSERT INTO llm_history (id, session_id, model, response_content, created_at) VALUES (?, ?, 'gpt-4', 'x', ?)",
                &.{ id_buf, session_buf, ts_buf });
        }
    }

    const sql =
        \\EXPLAIN QUERY PLAN
        \\SELECT finish_reason FROM llm_history
        \\WHERE session_id = 'sess0'
        \\ORDER BY created_at DESC LIMIT 1
    ;
    var rows = try db.query(allocator, sql, &.{});
    defer rows.deinit();

    var plan_buf = std.ArrayList(u8).empty;
    defer plan_buf.deinit(allocator);
    while (try rows.next()) |row| {
        try plan_buf.appendSlice(allocator, row.values[3]);
        try plan_buf.append(allocator, '\n');
        row.deinit(allocator);
    }
    const plan = plan_buf.items;

    try std.testing.expect(std.mem.indexOf(u8, plan, "idx_llm_history_session_created") != null);
}

test "hot worker-list query uses idx_worker_last_activity" {
    const allocator = std.testing.allocator;
    var ctx = try openMigratedDb(allocator);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    // Seed 200 worker rows so the planner picks the index over a full scan+sort.
    {
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            const id_buf = try std.fmt.allocPrint(allocator, "w{d}", .{i});
            defer allocator.free(id_buf);
            const sess_buf = try std.fmt.allocPrint(allocator, "sess{d}", .{i});
            defer allocator.free(sess_buf);
            // Spread last_activity widely so the sort cost is non-trivial.
            const activity_buf = try std.fmt.allocPrint(allocator, "{}", .{i * 7});
            defer allocator.free(activity_buf);
            try db.exec(allocator,
                "INSERT INTO worker (id, session_id, last_activity) VALUES (?, ?, ?)",
                &.{ id_buf, sess_buf, activity_buf });
        }
    }

    const sql =
        \\EXPLAIN QUERY PLAN
        \\SELECT id, session_id, last_activity FROM worker
        \\ORDER BY last_activity DESC
    ;
    var rows = try db.query(allocator, sql, &.{});
    defer rows.deinit();

    var plan_buf = std.ArrayList(u8).empty;
    defer plan_buf.deinit(allocator);
    while (try rows.next()) |row| {
        try plan_buf.appendSlice(allocator, row.values[3]);
        try plan_buf.append(allocator, '\n');
        row.deinit(allocator);
    }
    const plan = plan_buf.items;

    try std.testing.expect(std.mem.indexOf(u8, plan, "idx_worker_last_activity") != null);
}
