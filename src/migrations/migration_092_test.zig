//! Migration 092 — `workspace_item_tasks.is_have_image` +
//! `is_have_video` flags + backfill from the TEXT columns.

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const Migration092AddTaskMediaFlags = @import("migration.zig").Migration092AddTaskMediaFlags;

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

    // Pre-Migration-092 shape: TEXT columns exist (069/090), flags don't.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    image_urls TEXT NOT NULL DEFAULT '',
        \\    video_urls TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration092 adds is_have_image/is_have_video columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'is_have_image'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    try Migration092AddTaskMediaFlags.up(&ctx.db, alloc);

    for ([_][]const u8{ "is_have_image", "is_have_video" }) |col| {
        var q = try ctx.db.query(alloc,
            \\SELECT type, "notnull" FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = ?
        , &.{col});
        defer q.deinit();
        const row = (try q.next()) orelse return error.ColumnMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("INTEGER", row.values[0]);
        try testing.expectEqualStrings("1", row.values[1]);
    }
}

test "Migration092 backfills flags from existing TEXT columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, image_urls, video_urls) VALUES ('t_img', 'n', 'w', 'data:image/png;base64,AAA', '')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, image_urls, video_urls) VALUES ('t_none', 'n', 'w', '', '')",
        &.{});

    try Migration092AddTaskMediaFlags.up(&ctx.db, alloc);

    {
        var q = try ctx.db.query(alloc,
            "SELECT is_have_image, is_have_video FROM workspace_item_tasks WHERE id = 't_img'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
        try testing.expectEqualStrings("0", row.values[1]);
    }
    {
        var q = try ctx.db.query(alloc,
            "SELECT is_have_image, is_have_video FROM workspace_item_tasks WHERE id = 't_none'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("0", row.values[0]);
        try testing.expectEqualStrings("0", row.values[1]);
    }

    // Idempotent: second run keeps the same values.
    try Migration092AddTaskMediaFlags.up(&ctx.db, alloc);
    var q = try ctx.db.query(alloc,
        "SELECT is_have_image FROM workspace_item_tasks WHERE id = 't_img'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}
