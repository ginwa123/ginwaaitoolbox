//! Behavioral tests for the `WorkerInfo` join with `sessions.git_worktree_cwd`.
//!
//! Why behavioural (not static)?
//! ─────────────────────────────
//! The `WorkerInfo.git_worktree_cwd` field is populated via a LEFT JOIN
//! between `worker` and `sessions`. A static source-grep test would confirm
//! the SQL string contains `s.git_worktree_cwd` but would not catch
//! the real bugs we cared about during the sprint 2 "git worktree
//! cwd, worker" task:
//!   1. `WorkerInfo.deinit` was leaking `git_worktree_cwd` (the field
//!      was added in a partial refactor but never freed). A
//!      `testing.allocator` run would have caught this immediately.
//!   2. `getActiveWorker`'s SELECT didn't actually return a 5th
//!      column — would silently populate `''`.
//!   3. `getWorkerBySessionId` had the same gap.
//!
//! These tests open a real `:memory:` SQLite DB, create the minimum
//! schema needed by both functions (`worker` + `sessions` with
//! `git_worktree_cwd`), insert a few rows covering the four
//! interesting join cases, and assert the populated
//! `WorkerInfo.git_worktree_cwd` matches expectations.
//!
//! Plan: sprint 2 / "git worktree cwd, worker" task (CHANGELOG-style,
//! not a numbered plan doc).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;

/// Open a fresh in-memory sqlite DB with the minimum schema needed
/// for `getActiveWorker` + `getWorkerBySessionId` (the `worker` +
/// `sessions` tables, the latter with `git_worktree_cwd` from
/// Migration 046).
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

    // Minimal `sessions` schema (matches the columns touched by
    // `getActiveWorker`'s JOIN). `git_worktree_cwd` (Migration 046)
    // is the column we're exercising — it is TEXT, NULLable.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    git_worktree_cwd TEXT,
        \\    selected_profile_model TEXT
        \\)
    , &.{});

    // Worker table — the full canonical schema. We only read from
    // these columns, but the schema matters because the production
    // SQL references `working_directory`, `last_activity`, and
    // `last_activity_description` directly (not via COALESCE on a
    // potentially-NULL field).
    try db.exec(alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    working_directory TEXT,
        \\    last_activity INTEGER DEFAULT (strftime('%s', 'now')),
        \\    last_activity_description TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: getActiveWorker pulls git_worktree_cwd from joined session ─

test "getActiveWorker returns git_worktree_cwd from joined sessions row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert a session that has a bound worktree (Migration 046 semantics).
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name, git_worktree_cwd) VALUES ('s1', 'test', '/home/me/.worktrees/feature-x')",
        &.{});
    // Insert a worker row pointing at that session.
    try ctx.db.exec(alloc,
        "INSERT INTO worker (id, session_id, working_directory, last_activity_description) " ++
        "VALUES ('w1', 's1', '/home/me', 'working on the feature')",
        &.{});

    const workers = try llm_history.getActiveWorker(alloc, &ctx.db);
    defer {
        for (workers) |*w| w.deinit(alloc);
        alloc.free(workers);
    }

    try testing.expectEqual(@as(usize, 1), workers.len);
    try testing.expectEqualStrings("s1", workers[0].session_id);
    try testing.expectEqualStrings("/home/me", workers[0].working_directory);
    try testing.expectEqualStrings("working on the feature", workers[0].last_activity_description);
    try testing.expectEqualStrings("/home/me/.worktrees/feature-x", workers[0].git_worktree_cwd);
}

// ─── Test 2: LEFT JOIN returns empty string when session has no worktree ─

test "getActiveWorker returns empty string when session row has NULL git_worktree_cwd" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Session exists but has no git_worktree_cwd (NULL).
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('s1', 'test')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('w1', 's1')", &.{});

    const workers = try llm_history.getActiveWorker(alloc, &ctx.db);
    defer {
        for (workers) |*w| w.deinit(alloc);
        alloc.free(workers);
    }

    try testing.expectEqual(@as(usize, 1), workers.len);
    // COALESCE(s.git_worktree_cwd, '') maps NULL → empty string so
    // the prompt builder's `if (worker.git_worktree_cwd.len > 0)`
    // guard works as designed (skips the "(git worktree: ...)"
    // suffix when no worktree is bound).
    try testing.expectEqualStrings("", workers[0].git_worktree_cwd);
}

// ─── Test 3: LEFT JOIN preserves orphan workers (no matching session) ───

test "getActiveWorker returns worker with empty git_worktree_cwd when session row missing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Worker exists; no corresponding session row (deleted orphan — should
    // not happen in normal flow, but the LEFT JOIN must not filter it out).
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('w1', 'orphan_sid')", &.{});

    const workers = try llm_history.getActiveWorker(alloc, &ctx.db);
    defer {
        for (workers) |*w| w.deinit(alloc);
        alloc.free(workers);
    }

    try testing.expectEqual(@as(usize, 1), workers.len);
    try testing.expectEqualStrings("orphan_sid", workers[0].session_id);
    try testing.expectEqualStrings("", workers[0].git_worktree_cwd);
}

// ─── Test 4: deinit frees git_worktree_cwd (memory leak regression) ─────

test "WorkerInfo.deinit frees git_worktree_cwd without leaking" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Populated git_worktree_cwd — the case that would leak if deinit forgot
    // the field. The `testing.allocator` will flag any leaked allocation.
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name, git_worktree_cwd) VALUES ('s1', 't', '/some/abs/path')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('w1', 's1')", &.{});

    const workers = try llm_history.getActiveWorker(alloc, &ctx.db);
    defer {
        for (workers) |*w| w.deinit(alloc);
        alloc.free(workers);
    }

    try testing.expectEqual(@as(usize, 1), workers.len);
    try testing.expect(workers[0].git_worktree_cwd.len > 0);
}

// ─── Test 5: getWorkerBySessionId returns git_worktree_cwd ──────────────

test "getWorkerBySessionId returns git_worktree_cwd from joined session" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name, git_worktree_cwd) VALUES ('s1', 't', '/worktree/path')", &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO worker (id, session_id, last_activity_description) VALUES ('w1', 's1', 'hello')", &.{});

    const opt = try llm_history.getWorkerBySessionId(alloc, &ctx.db, "s1");
    var worker = (opt orelse return error.ExpectedWorker);
    defer worker.deinit(alloc);

    try testing.expectEqualStrings("s1", worker.session_id);
    try testing.expectEqualStrings("hello", worker.last_activity_description);
    try testing.expectEqualStrings("/worktree/path", worker.git_worktree_cwd);
}

// ─── Test 6: getWorkerBySessionId returns null when worker row absent ───

test "getWorkerBySessionId returns null when no worker row matches" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const opt = try llm_history.getWorkerBySessionId(alloc, &ctx.db, "no_such_sid");
    try testing.expect(opt == null);
}

// ─── Test 7: getWorkerBySessionId returns empty for orphan worker ────────

test "getWorkerBySessionId returns worker with empty git_worktree_cwd for orphan row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Worker exists, session row missing.
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('w1', 'orphan')", &.{});

    const opt = try llm_history.getWorkerBySessionId(alloc, &ctx.db, "orphan");
    var worker = (opt orelse return error.ExpectedWorker);
    defer worker.deinit(alloc);

    try testing.expectEqualStrings("orphan", worker.session_id);
    try testing.expectEqualStrings("", worker.git_worktree_cwd);
}
