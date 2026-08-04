//! Behavioural regression checks for Migration 069
//! (`workspace_item_tasks.image_urls`).
//!
//! Why this file exists
//! ────────────────────
//! Migration 069 adds an `image_urls TEXT NOT NULL DEFAULT ''` column
//! to `workspace_item_tasks` so task-attached images can be stored inline
//! as `||`-delimited base64 data URLs. This replaces the broken
//! filesystem-backed attachment endpoints (`POST/GET /api/.../attachments`).
//!
//! The migration must:
//!   1. Add the `image_urls` column with `TEXT NOT NULL DEFAULT ''`.
//!   2. Be idempotent on re-run (re-running must not crash with
//!      "duplicate column name").
//!   3. Leave existing rows at `image_urls = ''` (the canonical "no
//!      images" sentinel — every historical task predates the feature).
//!   4. Be registered in `allMigrations` — defining the struct alone
//!      is a silent-skip bug per project memory
//!      `migration-registration-trap`.
//!
//! Plan: docs/superpowers/plans/2026-08-06-kanban-image-urls-column.md
//! Bug: task_1785795051796 ("kanban task not saving the images or
//! base 64 in kanban description, after create a task or run aent")

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration069AddTaskImageUrls = @import("migration.zig").Migration069AddTaskImageUrls;

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

    // Minimal `workspace_item_tasks` schema matching the pre-Migration-069
    // shape — no `image_urls` column yet (that's exactly what the migration
    // adds). Production walks migrations 001 → 068 first, so `description`
    // (Migration 062) and `tags` (Migration 067) are already there; we
    // include them so the migration's addColumnIfMissing succeeds and the
    // schema mirrors what real production rows look like.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    description TEXT NOT NULL DEFAULT '',
        \\    tags TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration069 adds image_urls column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'image_urls'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'image_urls'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("image_urls", row.values[0]);

    // Type + nullability + default sanity: the column must be
    // TEXT NOT NULL DEFAULT '' (the canonical "no images" sentinel —
    // matches the `description` / `tags` patterns from
    // Migrations 062 / 067).
    var qt = try ctx.db.query(alloc,
        \\SELECT type, "notnull", dflt_value
        \\FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'image_urls'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);
    // "notnull" is 1 when NOT NULL.
    try testing.expectEqualStrings("1", type_row.values[1]);
    // Default value is the SQL `''` literal (the canonical "no
    // images" sentinel). `pragma_table_info` reports it as the
    // SQL literal text (i.e. `''` with the single quotes — see the
    // same pattern in migration_062_test for `description`'s
    // DEFAULT '' column). Accept either the bare empty string or the
    // single-quoted empty-string literal — both represent the same
    // semantic default.
    const dflt = type_row.values[2];
    try testing.expect(dflt.len == 0 or std.mem.eql(u8, dflt, "''"));
}

test "Migration069 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    // Still exactly one image_urls column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'image_urls'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration069 leaves pre-existing rows at image_urls='' (the no-images sentinel)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing row BEFORE applying the migration. Every
    // historical task predates the feature; the migration MUST
    // backfill image_urls = '' for every row (the column has NOT NULL
    // DEFAULT '' and ADD COLUMN applies DEFAULT to existing rows at
    // the storage layer).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
            "VALUES ('task_pre_069', 'Pre-existing task', 'item_1')",
        &.{});

    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT image_urls FROM workspace_item_tasks WHERE id = 'task_pre_069'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration069 round-trips a ||-delimited image_urls string" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    // Insert a task with two data URLs joined by || (the convention
    // `llm_history.image_url` uses). Confirm the raw string round-trips
    // — the column stores bytes verbatim, the join/split is the
    // caller's responsibility.
    const joined = "data:image/png;base64,iVBORw0KGgo||data:image/jpeg;base64,/9j/4AAQ";
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, image_urls) " ++
            "VALUES ('task_imgs', 'Two-image task', 'item_1', ?)",
        &[_][]const u8{joined});

    var q = try ctx.db.query(alloc,
        "SELECT image_urls FROM workspace_item_tasks WHERE id = 'task_imgs'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(joined, row.values[0]);
}

test "Migration069 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined
    // but the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version
    // number so the test stays stable across reordering.
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration069AddTaskImageUrls.version) return;
    }
    return error.Migration069NotRegistered;
}