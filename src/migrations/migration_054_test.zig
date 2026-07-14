//! Static regression checks for Migration 054
//! (make `session_queue_messages.message` nullable).
//!
//! Why this file exists
//! ────────────────────
//! Migration 054 drops the NOT NULL constraint on `session_queue_messages.message`
//! so that image-only queued messages can be inserted without hitting
//! `NOT NULL constraint failed: session_queue_messages.message` at the
//! SqliteBackend.bind layer (which binds empty `[]const u8` as SQL NULL).
//! The migration recreates the table to drop NOT NULL portably across all
//! SQLite versions / platforms.
//!
//! The migration must:
//!   1. Drop the NOT NULL on `message` (inserting empty message no longer errors)
//!   2. Preserve all existing rows (id, session_id, message, image_url)
//!   3. Recreate `idx_session_queue_messages_session` (re-added after the table swap)
//!   4. Handle both schemas: with `image_url` (post-Migration037) and without
//!
//! Plan: docs/superpowers/plans/2026-07-01-session-queue-message-nullable.md
//!   (Migration 054 design)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration018CreateSessionQueueMessages = @import("migration.zig").Migration018CreateSessionQueueMessages;
const Migration037AddImageUrlToSessionQueueMessages = @import("migration.zig").Migration037AddImageUrlToSessionQueueMessages;
const Migration054MakeSessionQueueMessageNullable = @import("migration.zig").Migration054MakeSessionQueueMessageNullable;

/// Test fixture for the migration_054 test suite. Hoisted to a top-level named
/// struct (NOT inline anonymous) because Zig 0.16 treats two anonymous
/// `struct { db, threaded }` types as distinct types even with identical
/// fields — see project memory `zig-anonymous-struct-type-identity.md`.
const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with the Migration 018 baseline — i.e. the exact
/// schema that exists in production BEFORE Migration 037 (no image_url) and
/// BEFORE Migration 054 (message NOT NULL). This is the "bug exists" baseline.
fn setupDbWithoutImageUrl() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration018CreateSessionQueueMessages.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Set up an in-memory DB with the Migration 037 schema — i.e. the same as
/// `setupDbWithoutImageUrl` PLUS the `image_url` column. This mirrors the
/// production state for any DB that ran up to Migration 053.
fn setupDbWithImageUrl() !TestCtx {
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl();
    errdefer ctx.threaded.deinit();
    errdefer ctx.db.deinit();
    try Migration037AddImageUrlToSessionQueueMessages.up(&ctx.db, alloc);
    return ctx;
}

test "migration 054: bug exists before migration (insert empty message fails)" {
    // RED-GREEN half: this test demonstrates the original bug. With the
    // original Migration018 schema, inserting a row whose `message` is bound
    // as NULL (the SqliteBackend convention for empty `[]const u8`) hits the
    // NOT NULL constraint. After Migration054, the same insert succeeds.
    //
    // Note: we use `?` placeholders + `&.{ ... }` so the SqliteBackend bind
    // layer (src/modules/databases/sqlite/Sqlite.zig:73-74) sees the empty
    // `""` as `[]const u8` of length 0 and binds it as SQL NULL. A literal
    // `''` in the SQL is treated as the empty string, not NULL, and would
    // NOT trip the NOT NULL constraint.
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Inserting with empty bound `message` — exactly the image-only queued
    // message shape that triggered the production bug. The NOT NULL on
    // `message` should fire because the empty slice binds as NULL.
    const rc = ctx.db.exec(alloc,
        "INSERT INTO session_queue_messages (id, session_id, message) " ++
        "VALUES (?, ?, ?)",
        &.{ "msg-bug", "sess-bug", "" },
    );
    try testing.expectError(error.ExecuteFailed, rc);
}

test "migration 054: empty message insert succeeds after migration" {
    // GREEN half: after applying the migration, the same INSERT that errored
    // above must succeed. The row must be readable and message is "" (or NULL,
    // which row.read returns as "").
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    // Sanity: `message` no longer has NOT NULL.
    var q = try ctx.db.query(alloc,
        "SELECT \"notnull\" FROM pragma_table_info('session_queue_messages') " ++
        "WHERE name = 'message'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);

    // The insert that triggered the bug must now succeed.
    try ctx.db.exec(alloc,
        "INSERT INTO session_queue_messages (id, session_id, message) " ++
        "VALUES ('msg-fix', 'sess-fix', '')",
        &[_][]const u8{},
    );

    // Row is present and read back as "" (empty `[]const u8` binds as NULL,
    // but row read returns NULL as "").
    var q2 = try ctx.db.query(alloc,
        "SELECT message FROM session_queue_messages WHERE id = 'msg-fix'",
        &[_][]const u8{},
    );
    defer q2.deinit();
    const row2 = (try q2.next()) orelse return error.NotFound;
    defer row2.deinit(alloc);
    try testing.expectEqualStrings("", row2.values[0]);
}

test "migration 054: existing rows survive the migration (no image_url)" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert a row before the migration.
    try ctx.db.exec(alloc,
        "INSERT INTO session_queue_messages (id, session_id, message) " ++
        "VALUES ('msg-pre', 'sess-pre', 'hello world')",
        &[_][]const u8{},
    );

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    // The row must survive — id, session_id, message all preserved.
    var q = try ctx.db.query(alloc,
        "SELECT id, session_id, message FROM session_queue_messages " ++
        "WHERE id = 'msg-pre'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("msg-pre", row.values[0]);
    try testing.expectEqualStrings("sess-pre", row.values[1]);
    try testing.expectEqualStrings("hello world", row.values[2]);
}

test "migration 054: existing rows survive the migration (with image_url)" {
    // Production-style DB: Migration018 + Migration037 applied (so image_url
    // exists), but NOT yet Migration054. The migration must preserve the
    // image_url column AND its data.
    const alloc = testing.allocator;
    var ctx = try setupDbWithImageUrl();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO session_queue_messages (id, session_id, message, image_url) " ++
        "VALUES ('msg-img', 'sess-img', 'with image', 'data:image/png;base64,xxx')",
        &[_][]const u8{},
    );

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT id, session_id, message, image_url FROM session_queue_messages " ++
        "WHERE id = 'msg-img'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("msg-img", row.values[0]);
    try testing.expectEqualStrings("sess-img", row.values[1]);
    try testing.expectEqualStrings("with image", row.values[2]);
    try testing.expectEqualStrings("data:image/png;base64,xxx", row.values[3]);
}

test "migration 054: index idx_session_queue_messages_session is recreated" {
    // The migration drops and recreates the table — the index from Migration018
    // must be restored, otherwise the GET /api/queue_messages/:session_id
    // endpoint becomes slow + the FK lookup in workflow.zig regresses.
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: index exists after Migration018. We have to properly deinit
    // the row from `try q.next()` or we leak — see project memory
    // `zig-migration-tests-three-pitfalls.md`.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='index' " ++
            "AND name = 'idx_session_queue_messages_session'",
            &[_][]const u8{},
        );
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(alloc);
            try testing.expectEqualStrings("idx_session_queue_messages_session", row.values[0]);
        } else {
            try testing.expect(false); // index should exist after Migration018
        }
    }

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    // After the migration, the index is back.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' " ++
        "AND name = 'idx_session_queue_messages_session'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_session_queue_messages_session", row.values[0]);
}

test "migration 054: table has the expected columns in the expected order" {
    // The recreated table must have exactly: id, session_id, message, image_url,
    // created_at (in that order). ORDER BY cid confirms column ordering.
    const alloc = testing.allocator;
    var ctx = try setupDbWithImageUrl();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    const expected: [5][]const u8 = .{
        "id", "session_id", "message", "image_url", "created_at",
    };
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('session_queue_messages') ORDER BY cid",
        &[_][]const u8{},
    );
    defer q.deinit();
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}
