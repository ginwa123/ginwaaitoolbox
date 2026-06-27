# SQLite Indexes for Performance Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 9 SQL indexes to the existing schema in a single new migration (`Migration041AddPerformanceIndexes`) to eliminate full-table scans and post-filter sorts on 7 hot read paths (session list, chat history "last message" lookups, worker stream, queue messages, workspace tree). Plus a regression test that asserts every index exists and that the query planner uses them.

**Architecture:** Pure schema change. No application code changes — all hot query SQL is already correct, it just lacks supporting indexes. The migration uses `CREATE INDEX IF NOT EXISTS` (matches every other migration in `migration.zig`), then runs `ANALYZE` so the query planner has fresh statistics for the new indexes. DESC ordering is used in compound indexes so `ORDER BY ... DESC` queries get a forward index scan with no sort step.

**Tech Stack:** Zig 0.15.2, SQLite (system library, `sqlite3` 3.53+ — DESC indexes supported since 3.3.0).

---

## File Structure

```
src/ai_workflow/tui/
├── migration.zig                 (modify) — add Migration041, register in allMigrations
└── migration_performance_indexes_test.zig   (create) — regression test for the 9 new indexes
```

That's it. Two files. No app code touched.

---

## Indexes to Add

| # | Index name | Table | Columns | Query path that uses it |
|---|---|---|---|---|
| 1 | `idx_llm_history_session_created` | `llm_history` | `(session_id, created_at DESC)` | `llm_history.zig:382` and `:1270` — `WHERE session_id = ? ORDER BY created_at DESC LIMIT 1` (last-message lookups, hot path on every chat load) |
| 2 | `idx_sessions_cwd_created` | `sessions` | `(cwd, created_at DESC)` | `llm_history.zig:1234` — `WHERE s.cwd = ? ... ORDER BY s.created_at DESC LIMIT 1` (latest session in a directory) |
| 3 | `idx_sessions_updated_at` | `sessions` | `(updated_at DESC)` | `llm_history.zig:2354` — `ORDER BY s.updated_at DESC` (full session list endpoint) |
| 4 | `idx_session_queue_messages_session_created` | `session_queue_messages` | `(session_id, created_at ASC)` | `llm_history.zig:1642` and `queue_messages_get.zig:36` — `WHERE session_id = ? ORDER BY created_at ASC` (queue drain) |
| 5 | `idx_worker_last_activity` | `worker` | `(last_activity DESC)` | `llm_history.zig:1321` and `worker_list.zig:29` — `ORDER BY last_activity DESC` (worker stream SSE) |
| 6 | `idx_workspace_items_workspace_created` | `workspace_items` | `(workspace_id, created_at DESC)` | `llm_history.zig:2131` — `WHERE workspace_id = ? ORDER BY created_at DESC` |
| 7 | `idx_workspace_items_created_at` | `workspace_items` | `(created_at DESC)` | `llm_history.zig:2164` and `workspaces_list.zig:91` — `ORDER BY created_at DESC` (cross-workspace list) |
| 8 | `idx_workspace_item_tasks_item_created` | `workspace_item_tasks` | `(workspace_item_id, created_at DESC)` | `llm_history.zig:2322` and `workspaces_list.zig:137` — `WHERE workspace_item_id IN (...) ORDER BY created_at DESC` |
| 9 | `idx_workspaces_created_at` | `workspaces` | `(created_at DESC)` | `workspaces_list.zig:47` — `ORDER BY created_at DESC` (workspace sidebar) |

**Indexes NOT added (and why):**
- `idx_sessions_cwd` alone (without `created_at`) — superseded by compound `#2`. The compound serves both pure `WHERE cwd = ?` and `WHERE cwd = ? ORDER BY created_at DESC` from one index.
- Index on `llm_history` for the `getSessionList` `GROUP BY h.session_id ORDER BY MAX(h.created_at) DESC` query (line 101) — the user explicitly chose indexes-only (no denormalized `session_summary` table). This query still does a full scan. Documented as known limitation; revisit in a future plan if chat list perf becomes a complaint.
- Index on `id NOT LIKE '%subagent%'` filter — leading wildcard `LIKE` cannot use a B-tree index in SQLite. No fix possible without schema change.
- `idx_worker_session` (existing) — kept; the new `idx_worker_last_activity` is additive.

---

## Chunk 1: The Migration

### Task 1: Write the failing test for the new indexes

**Files:**
- Create: `src/ai_workflow/tui/migration_performance_indexes_test.zig`

- [ ] **Step 1: Create the test file with a stub test that fails**

Create `src/ai_workflow/tui/migration_performance_indexes_test.zig` with this content:

```zig
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

/// Open a fresh in-memory DB, run all migrations, return the backend.
/// `io` is the test's Io — `std.Io.init()` is the pattern used elsewhere
/// in this repo (see `modules/custom_http_server/src/sse_manager_test.zig`)
/// for tests that need a mutex-capable Io without a full Threaded runtime.
fn openMigratedDb(allocator: std.mem.Allocator) !struct { io: std.Io, db: sqlite.SqliteBackend } {
    var io = std.Io.init();
    var db: sqlite.SqliteBackend = undefined;
    try db.init(io, ":memory:");
    errdefer db.deinit();

    var manager = migration.MigrationManager.init(allocator, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .io = io, .db = db };
}

test "all 9 performance indexes exist after running migrations" {
    const allocator = std.testing.allocator;
    var ctx = try openMigratedDb(allocator);
    defer ctx.db.deinit();
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
        try plan_buf.writer(allocator).print("{s}\n", .{row.values[3]});
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
        try plan_buf.writer(allocator).print("{s}\n", .{row.values[3]});
        row.deinit(allocator);
    }
    const plan = plan_buf.items;

    try std.testing.expect(std.mem.indexOf(u8, plan, "idx_llm_history_session_created") != null);
}

test "hot worker-list query uses idx_worker_last_activity" {
    const allocator = std.testing.allocator;
    var ctx = try openMigratedDb(allocator);
    defer ctx.db.deinit();
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
        try plan_buf.writer(allocator).print("{s}\n", .{row.values[3]});
        row.deinit(allocator);
    }
    const plan = plan_buf.items;

    try std.testing.expect(std.mem.indexOf(u8, plan, "idx_worker_last_activity") != null);
}
```

- [ ] **Step 2: Register the new test in test_runner.zig**

Modify `src/ai_workflow/tui/test_runner.zig`. Add one line inside the `test { ... }` block, alphabetically (next to the other `migration`-related imports would be ideal, but there is no existing `migration` import there — just put it next to the other tui tests):

```zig
test {
    _ = @import("handle_tool_test.zig");
    _ = @import("migration_performance_indexes_test.zig");
    _ = @import("parse_diff_view_test.zig");
    _ = @import("save_agent_test.zig");
    _ = @import("save_skill_test.zig");
    _ = @import("http_handlers/nalar_config_put_test.zig");
    // _ = @import("session_helpers_test.zig"); // DISABLED - requires std.Io which needs Init
    // _ = @import("session_table_test.zig"); // DISABLED - requires std.Io which needs Init
    _ = @import("transform_llm_history_to_agent_messages_test.zig");
    // _ = @import("extract_base64_image_urls_test.zig"); // DISABLED - 9 failing tests (investigation shows std.testing.expectEqualStrings has a bug with literal strings)
    // _ = @import("session_db_test.zig"); // DISABLED - pre-existing test errors (see session_db_test.zig for details)
}
```

- [ ] **Step 3: Run the tests and confirm they FAIL**

Run: `zig build test:ai_workflow:tui 2>&1 | tail -n 60`

Expected: the 4 new tests FAIL with messages like "expected to find index `idx_llm_history_session_created` in sqlite_master" / "plan did not reference `idx_sessions_cwd_created`". The exact `expected to find index` text comes from `std.testing.expect(matched)` — Zig's testing framework prints `expected true, found false` and our variable name `matched` makes it scannable.

If the build itself fails, that's a different problem — fix the syntax before proceeding. (Most likely cause: `:memory:` requires the path to be `[:0]const u8`, which the cast in `db.init` already handles — see `sqlite_test.zig` for a working example of the same pattern.)

---

### Task 2: Add Migration041AddPerformanceIndexes

**Files:**
- Modify: `src/ai_workflow/tui/migration.zig` (add the struct + register it in `allMigrations`)

- [ ] **Step 1: Add the migration struct just before `MigrationManager`**

Open `src/ai_workflow/tui/migration.zig` and locate the end of `Migration040AddSelectedProfileModelToSessions` (around line 626). Add this new struct AFTER it (and before the `MigrationManager` struct on line 628):

```zig
pub const Migration041AddPerformanceIndexes = struct {
    pub const version: u32 = 41;
    pub const name = "add_performance_indexes";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Hot read paths in llm_history.zig + http_handlers/queue_messages_get.zig +
        // http_handlers/worker_list.zig + http_handlers/workspaces_list.zig.
        // Compound indexes with explicit DESC match the query's ORDER BY direction
        // so SQLite does a forward index scan with no sort step.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_session_created ON llm_history(session_id, created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_sessions_cwd_created ON sessions(cwd, created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_session_queue_messages_session_created ON session_queue_messages(session_id, created_at ASC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_worker_last_activity ON worker(last_activity DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_items_workspace_created ON workspace_items(workspace_id, created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_items_created_at ON workspace_items(created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_item_tasks_item_created ON workspace_item_tasks(workspace_item_id, created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspaces_created_at ON workspaces(created_at DESC)", &[_][]const u8{});

        // ANALYZE updates sqlite_stat1 so the query planner knows the new indexes
        // exist and how selective they are. Without this, the planner may still pick
        // a full scan on existing databases that pre-date the new indexes.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
```

- [ ] **Step 2: Register the new migration in the `allMigrations` slice**

Find the `allMigrations` slice (starts at line 680 in `migration.zig`) and add a new entry at the end, right after the `Migration040` entry on line 719:

```zig
    .{ .version = Migration040AddSelectedProfileModelToSessions.version, .name = Migration040AddSelectedProfileModelToSessions.name, .up = Migration040AddSelectedProfileModelToSessions.up },
    .{ .version = Migration041AddPerformanceIndexes.version, .name = Migration041AddPerformanceIndexes.name, .up = Migration041AddPerformanceIndexes.up },
};
```

- [ ] **Step 3: Run the tests and confirm they PASS**

Run: `zig build test:ai_workflow:tui 2>&1 | tail -n 60`

Expected: the 4 new tests PASS. The other tests in the runner should be unchanged (no existing tests should regress).

If a test fails with `expected true, found false` on `matched`, the most common cause is whitespace or quote mismatch in the expected SQL substring — re-check the `sql_contains` field against the actual `CREATE INDEX` statement in the migration. The `sql_contains` test asserts the substring appears in `sqlite_master.sql` (the canonical form SQLite stores), so case must match exactly.

If a test fails with `plan did not reference idx_...`:
- Check that the migration actually ran (the `IF NOT EXISTS` makes it idempotent — if a previous run created them with a different name, the test still expects the new name).
- Check that `ANALYZE` ran (without it, the planner may not have statistics to pick the new index).
- Try running `ANALYZE` manually on an existing database to force a re-plan: `sqlite3 ~/.config/nalar/agent.db "ANALYZE"`.

---

## Chunk 2: Final Verification

### Task 3: Build the full app to confirm no regression in any other module

**Files:** N/A (build only)

- [ ] **Step 1: Run the full build**

Run: `zig build 2>&1 | tail -n 30`

Expected: SUCCESS. The migration is in a `pub const` struct, and registering it in `allMigrations` is the only new touchpoint. No other file needs to change.

- [ ] **Step 2: Run the full test suite**

Run: `zig build test 2>&1 | tail -n 40`

Expected: All previously-passing tests still pass. The 4 new tests pass. (Look for "N/N tests passed" at the end — Zig's test runner prints the totals on the final line.)

- [ ] **Step 3: Smoke-test the new indexes on a real database**

This is a manual verification step that doesn't fit in `zig build` but is important for confidence before merging. The migration is forward-only and the `IF NOT EXISTS` guard makes it safe to re-run.

Run:

```bash
# 1. Back up the real DB (paranoid — the migration is additive, no rows touched)
cp ~/.config/nalar/agent.db ~/.config/nalar/agent.db.bak-$(date +%s)

# 2. Start the app once to trigger migration (or run it for 2 seconds and stop)
zig build run &
APP_PID=$!
sleep 2
kill $APP_PID 2>/dev/null
wait $APP_PID 2>/dev/null

# 3. Verify the new indexes exist
sqlite3 ~/.config/nalar/agent.db <<'SQL'
SELECT name, tbl_name FROM sqlite_master
WHERE type = 'index' AND name LIKE 'idx_%'
  AND name NOT IN (
    'idx_llm_history_session',
    'idx_llm_history_parent_session',
    'idx_session_skills_session',
    'idx_bg_process_session',
    'idx_session_agents_session',
    'idx_session_queue_messages_session',
    'idx_worker_session',
    'idx_sessions_status',
    'idx_sessions_workspace',
    'idx_workspace_items_workspace',
    'idx_workspace_item_tasks_item'
  )
ORDER BY tbl_name, name;
SQL
```

Expected: 9 rows, one for each new index:

```
idx_workspace_items_created_at|workspace_items
idx_workspace_items_workspace_created|workspace_items
idx_workspace_item_tasks_item_created|workspace_item_tasks
idx_workspaces_created_at|workspaces
idx_llm_history_session_created|llm_history
idx_session_queue_messages_session_created|session_queue_messages
idx_sessions_cwd_created|sessions
idx_sessions_updated_at|sessions
idx_worker_last_activity|worker
```

(Exact order varies — SQLite doesn't guarantee a sort order without an `ORDER BY` on `sqlite_master.name` or `tbl_name`, which is why the query has the `ORDER BY`.)

- [ ] **Step 4: Verify query plans use the new indexes (manual)**

Pick a hot query and confirm the planner uses the new index. The most impactful is the chat-list-by-cwd query:

```bash
sqlite3 ~/.config/nalar/agent.db <<'SQL'
EXPLAIN QUERY PLAN
SELECT s.id, s.name, s.status, s.cwd, s.created_at, s.updated_at
FROM sessions s
WHERE s.cwd = '/your/typical/cwd'
ORDER BY s.created_at DESC LIMIT 1;
SQL
```

Expected: the output contains `USING INDEX idx_sessions_cwd_created`. If it shows `SCAN sessions` instead, run `ANALYZE` and try again — the planner needs statistics to pick the index, and on a freshly-migrated DB they're sometimes not yet collected.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/migration.zig src/ai_workflow/tui/migration_performance_indexes_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "perf(sqlite): add 9 indexes for hot read paths in llm_history, sessions, worker, queues, workspaces"
```

---

## Summary

After this plan is executed:

- **9 new indexes** are created by `Migration041AddPerformanceIndexes` on first run; the `IF NOT EXISTS` guard makes the migration idempotent.
- **No application code changes** — every query that benefits already exists in the codebase unchanged.
- **4 new regression tests** assert (a) every index exists in `sqlite_master` with the right columns, and (b) the query planner uses 3 of the most critical new indexes for the most-called endpoints.
- **`ANALYZE` runs as part of the migration** so the planner has statistics for the new indexes on existing databases.
- **Known limitation** (out of scope per user request): the `GROUP BY h.session_id ORDER BY MAX(h.created_at) DESC` in `getSessionList` (`llm_history.zig:101`) still does a full table scan. Indexes can't help a `GROUP BY` aggregation. A denormalized `session_summary` table would fix it — document as a follow-up plan if chat-list perf becomes a complaint.

Expected end-state performance on a database with 10k llm_history rows and 500 sessions:
- `getSessionList` (still full scan, no change): 50-200ms
- `getSessionListWithCursor` filtered by `cwd` + sorted by `created_at`: ~200ms → **<5ms** (40×)
- `getActiveWorker` (full `worker` table sorted): ~5ms → **<1ms** (5×, with index walk instead of sort)
- `loadChatHistory` last-message lookup: ~10ms → **<1ms** (10×, with `(session_id, created_at DESC)` instead of session_id scan + sort)
- `queueMessagesGet`: ~3ms → **<1ms** (3×)
- `workspacesList` page load: ~20ms → **<2ms** (10×)

(Calibration: these are estimates for a database with the row counts above on a developer laptop. Actual gains depend on row count, data distribution, and machine. Run `EXPLAIN QUERY PLAN` on real production data to confirm.)
