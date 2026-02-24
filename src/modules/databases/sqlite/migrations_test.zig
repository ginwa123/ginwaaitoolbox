const std = @import("std");
const SqliteBackend = @import("sqlite.zig").SqliteBackend;
const MigrationManager = @import("migrations.zig").MigrationManager;
const Migration001CreateLLMHistory = @import("migrations.zig").Migration001CreateLLMHistory;

test "migration manager init" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
}

test "migration run creates table" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();

    try mgr.registerMigration(.{
        .version = 1,
        .name = "test_migration",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.runMigrations();

    const row = try db.queryRow(allocator, "SELECT name FROM sqlite_master WHERE type = ? AND name = ?", &.{ "table", "llm_history" });
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("llm_history", row.values[0]);
}

test "migration creates index" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();

    try mgr.registerMigration(.{
        .version = 1,
        .name = "test_migration",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.runMigrations();

    const row = try db.queryRow(allocator, "SELECT name FROM sqlite_master WHERE type = ? AND name = ?", &.{ "index", "idx_llm_history_session" });
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("idx_llm_history_session", row.values[0]);
}

test "migration001 version and name" {
    try std.testing.expectEqual(@as(u32, 1), Migration001CreateLLMHistory.version);
    try std.testing.expectEqualStrings("create_llm_history", Migration001CreateLLMHistory.name);
}
