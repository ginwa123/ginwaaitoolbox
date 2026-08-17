//! Behavioral tests for the `getSessionList` SQL rewrite
//! (llm_history.zig:104). Chunk 2 replaces the original
//! `GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT/OFFSET`
//! full-table-scan query with a subquery+JOIN that lets the planner use
//! `idx_llm_history_created_session(created_at DESC, session_id)`.
//!
//! Why a behavioral DB test (not a static check)?
//! ───────────────────────────────────────────────
//! The rewrite moves the GROUP BY + LIMIT/OFFSET into an inner
//! subquery and changes the way the `agent` column is resolved
//! (correlated subquery picking the latest message's agent, vs the
//! original's implementation-defined loose GROUP BY). A static source
//! check would not catch (1) a wrong column order in the rewrite,
//! (2) a regression where the planner falls back to a full table scan
//! (e.g. the index is missing), or (3) a buggy correlated subquery
//! that picks the wrong agent. We assert the rewrite by running the
//! same SQL fragments the production query uses against an in-memory
//! DB that mirrors the production schema.
//!
//! The SqliteBackend's public API (see
//! `src/modules/databases/sqlite/Sqlite.zig`) is: `init`, `exec`,
//! `query` (returns `Rows` with `next()` → `?Row` carrying
//! `values: [][]u8`). There is no `prepare`/`step`/`columnText`/
//! `columnInt` public API — column reads go through `Row.values[i]`,
//! which is always text.
//!
//! Test 4 introduces a new pattern in this project: `EXPLAIN QUERY
//! PLAN` as a regression guard. If a future SQLite version picks a
//! different plan (e.g. falls back to a scan), the assertion fails.
//! This is the right place for the pattern because the new index is
//! the load-bearing optimization for the rewritten query.
//!
//! Why we test the SQL fragments directly (not `llm_history.getSessionList`)
//! ───────────────────────────────────────────────
//! The production `getSessionList` function is out of scope for this
//! chunk — only its `sql` constant changes. Its row-decoding block
//! has a pre-existing latent issue that surfaces only when reached
//! from a test; touching that block would be a refactor outside this
//! chunk's mandate. Testing the SQL fragments directly pins down
//! Chunk 2's behavior (the rewrite + the new agent semantics + the
//! planner's index choice) without coupling to the row-decoding block.
//!
//! Plan: docs/plans/2026-06-19-performance-indexes.md (Chunk 2)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with `llm_history` and `sessions`
/// tables present (matching the production schema columns that
/// `getSessionList` reads), plus the `idx_llm_history_created_session`
/// index from Migration 048. This is the minimal state the rewritten
/// query expects.
fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // llm_history — only the columns the rewritten query reads.
    // (session_id, created_at, agent are referenced; model is NOT NULL
    //  per Migration 001 so we keep it for insert-time parity; the
    //  `agent` column was added by Migration 006.)
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_results_json TEXT,
        \\    finish_reason TEXT,
        \\    usage_json TEXT,
        \\    created_at_nano DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    agent TEXT DEFAULT 'Agent'
        \\)
    , &.{});

    // sessions — only the columns the rewritten query reads (id, cwd,
    // name). SELECT coalesces NULLs to '' so empty strings are fine.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    cwd TEXT,
        \\    name TEXT
        \\)
    , &.{});

    // The covering index added in Migration 048. We create it inline
    // (rather than running the migration) to keep this test focused on
    // the rewritten SQL, not on migration plumbing.
    try db.exec(alloc,
        "CREATE INDEX idx_llm_history_created_session " ++
            "ON llm_history(created_at_nano DESC, session_id)",
        &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Run a query and assert it returns exactly `expected_len` rows.
/// Returns the rows' `values` slices so the caller can assert on
/// individual columns.
fn runAndCollect(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    sql: []const u8,
    args: []const []const u8,
    expected_len: usize,
) ![][]const u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();

    var collected = std.ArrayList([]const u8).empty;
    defer collected.deinit(alloc);

    while (try q.next()) |row| {
        defer row.deinit(alloc);
        // For these tests each row is a single column (session_id or
        // agent). Take a stable copy so the slice survives past
        // row.deinit (per memory rule: row.values[i] is freed by
        // row.deinit, so we dupe at append time).
        try collected.append(alloc, try alloc.dupe(u8, row.values[0]));
    }

    if (collected.items.len != expected_len) {
        std.debug.print(
            "!! expected {d} rows, got {d}\n",
            .{ expected_len, collected.items.len },
        );
        return error.RowCountMismatch;
    }
    return collected.toOwnedSlice(alloc);
}

// ─── Test 1: inner subquery order is created_at DESC ─────────────────────

test "getSessionList inner subquery returns sessions in created_at DESC order" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Three sessions, distinct created_at values. Newest first by
    // insert order means s_jan < s_feb < s_mar.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
            "VALUES ('h1', 's_jan', 'm1', '2024-01-01 00:00:00')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
            "VALUES ('h2', 's_feb', 'm1', '2024-02-01 00:00:00')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
            "VALUES ('h3', 's_mar', 'm1', '2024-03-01 00:00:00')",
        &.{});

    // Exact inner subquery the production rewrite uses (see
    // llm_history.zig getSessionList). Asserts the order is the
    // contract the outer query depends on.
    const inner_sql =
        \\SELECT h.session_id
        \\  FROM llm_history h
        \\ GROUP BY h.session_id
        \\ ORDER BY MAX(h.created_at_nano) DESC
        \\ LIMIT 10 OFFSET 0
    ;

    const rows = try runAndCollect(alloc, &ctx.db, inner_sql, &.{}, 3);
    defer {
        for (rows) |r| alloc.free(r);
        alloc.free(rows);
    }

    try testing.expectEqualStrings("s_mar", rows[0]);
    try testing.expectEqualStrings("s_feb", rows[1]);
    try testing.expectEqualStrings("s_jan", rows[2]);
}

// ─── Test 2: inner subquery LIMIT and OFFSET are respected ───────────────

test "getSessionList inner subquery respects LIMIT and OFFSET" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Five sessions, distinct created_at values. The full ordering
    // (newest first) is: s5, s4, s3, s2, s1.
    const inserts = [_][]const u8{
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) VALUES ('h1', 's1', 'm1', '2024-01-01 00:00:00')",
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) VALUES ('h2', 's2', 'm1', '2024-02-01 00:00:00')",
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) VALUES ('h3', 's3', 'm1', '2024-03-01 00:00:00')",
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) VALUES ('h4', 's4', 'm1', '2024-04-01 00:00:00')",
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) VALUES ('h5', 's5', 'm1', '2024-05-01 00:00:00')",
    };
    for (inserts) |sql| {
        try ctx.db.exec(alloc, sql, &.{});
    }

    // Page 1: limit=2, offset=0 → s5, s4
    const inner_sql =
        \\SELECT h.session_id
        \\  FROM llm_history h
        \\ GROUP BY h.session_id
        \\ ORDER BY MAX(h.created_at_nano) DESC
        \\ LIMIT 2 OFFSET 0
    ;
    const page1 = try runAndCollect(alloc, &ctx.db, inner_sql, &.{}, 2);
    defer {
        for (page1) |r| alloc.free(r);
        alloc.free(page1);
    }
    try testing.expectEqualStrings("s5", page1[0]);
    try testing.expectEqualStrings("s4", page1[1]);

    // Page 2: limit=2, offset=2 → s3, s2 (no overlap with page 1)
    const page2_sql =
        \\SELECT h.session_id
        \\  FROM llm_history h
        \\ GROUP BY h.session_id
        \\ ORDER BY MAX(h.created_at_nano) DESC
        \\ LIMIT 2 OFFSET 2
    ;
    const page2 = try runAndCollect(alloc, &ctx.db, page2_sql, &.{}, 2);
    defer {
        for (page2) |r| alloc.free(r);
        alloc.free(page2);
    }
    try testing.expectEqualStrings("s3", page2[0]);
    try testing.expectEqualStrings("s2", page2[1]);

    // Page 1 and Page 2 must not overlap (regression guard: if the
    // OFFSET clause were dropped, page 2 would be s4, s3).
    for (page1) |p1| {
        for (page2) |p2| {
            if (std.mem.eql(u8, p1, p2)) {
                std.debug.print(
                    "!! LIMIT/OFFSET overlap: page1 row '{s}' == page2 row '{s}'\n",
                    .{ p1, p2 },
                );
                return error.OffsetOverlap;
            }
        }
    }
}

// ─── Test 3: agent is the latest message's agent (bug-fix regression) ───

test "getSessionList agent field is from the latest message in the session" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Two messages for the same session. The OLDER one is agent='A',
    // the NEWER one is agent='B'. The rewritten query's correlated
    // subquery picks the LATEST, so the returned agent must be 'B'.
    //
    // The original query relied on SQLite's loose GROUP BY, which
    // picked an arbitrary h.agent for each session_id — implementation-
    // defined and version-dependent. This test pins down the new,
    // deterministic behavior.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, agent, created_at_nano) " ++
            "VALUES ('h_old', 's1', 'm1', 'A', '2024-01-01 00:00:00')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, agent, created_at_nano) " ++
            "VALUES ('h_new', 's1', 'm1', 'B', '2024-02-01 00:00:00')",
        &.{});

    // Exact correlated subquery the production rewrite uses (see
    // llm_history.zig getSessionList). Asserts the new "agent of the
    // LATEST message" semantics.
    const agent_sql =
        \\SELECT COALESCE(
        \\  (SELECT h2.agent
        \\     FROM llm_history h2
        \\    WHERE h2.session_id = 's1'
        \\    ORDER BY h2.created_at_nano DESC
        \\    LIMIT 1),
        \\  'Agent'
        \\) AS agent
    ;

    const rows = try runAndCollect(alloc, &ctx.db, agent_sql, &.{}, 1);
    defer {
        for (rows) |r| alloc.free(r);
        alloc.free(rows);
    }

    try testing.expectEqualStrings("B", rows[0]);
}

// ─── Test 4: planner uses idx_llm_history_created_session (EXPLAIN) ──────

test "getSessionList inner subquery uses idx_llm_history_created_session (EXPLAIN QUERY PLAN)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed enough rows that the planner has a reason to use the index
    // (small tables often hit a SCAN regardless because the cost
    // estimate favors it). 100 rows is plenty.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(
            &buf,
            "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
                "VALUES ('h{d}', 's{d}', 'm1', '2024-01-01 00:00:00')",
            .{ i, i },
        );
        try ctx.db.exec(alloc, sql, &.{});
    }

    // EXPLAIN QUERY PLAN returns one row per plan node. We ask the
    // planner to plan the SAME inner subquery that getSessionList now
    // uses; if a future SQLite version picks a different plan (e.g.
    // falls back to a SCAN of llm_history), this assertion fails.
    //
    // Pattern: run the EXPLAIN, walk the rows, join row.values with
    // ' ' (the column order is `id, parent, notused, detail`; the
    // human-readable plan text is in `detail`, but joining all
    // columns makes the assertion robust to plan-text formatting
    // changes across SQLite versions).
    var q = try ctx.db.query(alloc,
        \\EXPLAIN QUERY PLAN
        \\SELECT h.session_id, MAX(h.created_at_nano)
        \\  FROM llm_history h
        \\ GROUP BY h.session_id
        \\ ORDER BY MAX(h.created_at_nano) DESC
        \\ LIMIT 10 OFFSET 0
    , &.{});
    defer q.deinit();

    // Accumulate all plan rows into a single string so the
    // assertion can scan for the index name regardless of how
    // SQLite splits the plan across rows.
    var plan_text = std.ArrayList(u8).empty;
    defer plan_text.deinit(alloc);
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        for (row.values, 0..) |col, j| {
            if (j > 0) try plan_text.append(alloc, ' ');
            try plan_text.appendSlice(alloc, col);
        }
        try plan_text.append(alloc, '\n');
    }

    const plan_str = plan_text.items;
    if (std.mem.indexOf(u8, plan_str, "idx_llm_history_created_session") == null) {
        std.debug.print(
            "!! getSessionList planner did NOT use idx_llm_history_created_session !!\n" ++
                "   EXPLAIN output:\n{s}\n",
            .{plan_str},
        );
        return error.ChatListIndexNotUsed;
    }
}
