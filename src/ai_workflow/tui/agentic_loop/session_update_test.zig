//! Behavioural tests for the `ensureSessionExists` helper that
//! `session_update.zig` calls before any UPDATE. Drives the helper
//! against an in-memory SQLite DB that mirrors the production
//! `sessions` schema (canonical post-Migration-063 shape so
//! `is_auto_retry_until_stop` + `last_finish_reason` columns exist).
//!
//! Why this file exists
//! ─────────────────────
//! Bug "session not found when change profile" (plan
//! 2026-08-06-set-active-profile-default): PUT /api/session/:id
//! 404'd when the user tried to pick a profile on a brand-new chat,
//! because the session_id is in the URL but the row hasn't been
//! INSERTed yet (no message queued). The fix is to call
//! `ensureSessionExists` before any UPDATE so the helper auto-creates
//! the row with sensible defaults. We test the helper directly
//! (the HTTP handler calls `nalarcore.getSingleton()` which is
//! global state and out of scope for a unit test).
//!
//! Test pattern: mirrors `migration_063_runtime_test.zig` — in-memory
//! DB, the production helper function, read back via SELECT.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Canonical post-Migration-063 schema (matches
    // migration_063_runtime_test.zig).
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    selected_profile_model TEXT,
        \\    git_worktree_cwd TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Read a single TEXT column from `sessions` by id. Returns null when
/// the row is missing. Used to assert the post-fix state.
fn readColumn(
    ctx: *TestCtx,
    allocator: std.mem.Allocator,
    column: []const u8,
    row_id: []const u8,
) !?[]u8 {
    const sql = try std.fmt.allocPrint(allocator, "SELECT {s} FROM sessions WHERE id = ?", .{column});
    defer allocator.free(sql);
    var q = try ctx.db.query(allocator, sql, &.{row_id});
    defer q.deinit();
    const row_opt = try q.next();
    if (row_opt) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

test "ensureSessionExists: returns false when row already exists" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Pre-create a session row.
    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s_existing", "Existing", "0");
        session.deinit(alloc);
    }

    const created = try llm_history.ensureSessionExists(alloc, &ctx.db, "s_existing");
    try testing.expectEqual(false, created);

    // Name was NOT overwritten by the default.
    const name = (try readColumn(&ctx, alloc, "name", "s_existing")) orelse
        return error.NoRow;
    defer alloc.free(name);
    try testing.expectEqualStrings("Existing", name);
}

test "ensureSessionExists: creates a row when missing, returns true" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: no row exists yet.
    const before = (try readColumn(&ctx, alloc, "name", "s_brand_new")) orelse
        @as(?[]u8, null);
    if (before) |b| {
        defer alloc.free(b);
        return error.ExpectedNoRow;
    }

    const created = try llm_history.ensureSessionExists(alloc, &ctx.db, "s_brand_new");
    try testing.expectEqual(true, created);

    // Row is now present with the default name.
    const name = (try readColumn(&ctx, alloc, "name", "s_brand_new")) orelse
        return error.NoRow;
    defer alloc.free(name);
    try testing.expectEqualStrings("New Session", name);

    // is_auto_retry_until_stop defaults to '0' (matches
    // create_session's coercion).
    const flag = (try readColumn(&ctx, alloc, "is_auto_retry_until_stop", "s_brand_new")) orelse
        return error.NoRow;
    defer alloc.free(flag);
    try testing.expectEqualStrings("0", flag);
}

test "ensureSessionExists: idempoent — calling twice on a missing row creates exactly once" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    _ = try llm_history.ensureSessionExists(alloc, &ctx.db, "s_idemp");
    const second = try llm_history.ensureSessionExists(alloc, &ctx.db, "s_idemp");
    try testing.expectEqual(false, second);

    // There is exactly one row.
    var q = try ctx.db.query(alloc, "SELECT id FROM sessions WHERE id = ?", &.{"s_idemp"});
    defer q.deinit();
    var row_count: usize = 0;
    while (try q.next()) |row| {
        row.deinit(alloc);
        row_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), row_count);
}

test "ensureSessionExists + updateSessionSelectedProfileModel: preserves the profile when session is created on the fly" {
    // This is the exact bug: PUT /api/session/:id 404'd when the
    // user picked a profile on a brand-new chat. With
    // ensureSessionExists called before the UPDATE, the helper
    // auto-creates the row, then updateSessionSelectedProfileModel
    // writes the profile. The next read sees the profile — the
    // user's choice is preserved for the first real LLM call.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Brand-new session that doesn't exist yet.
    _ = try llm_history.ensureSessionExists(alloc, &ctx.db, "s_fresh");
    try llm_history.updateSessionSelectedProfileModel(alloc, &ctx.db, "s_fresh", "900ribu");

    const profile = (try readColumn(&ctx, alloc, "selected_profile_model", "s_fresh")) orelse
        return error.NoRow;
    defer alloc.free(profile);
    try testing.expectEqualStrings("900ribu", profile);
}
