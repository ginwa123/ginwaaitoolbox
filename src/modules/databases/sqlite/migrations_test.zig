const std = @import("std");
const SqliteBackend = @import("sqlite.zig").SqliteBackend;
const MigrationManager = @import("migrations.zig").MigrationManager;
const Migration001CreateLLMHistory = @import("migrations.zig").Migration001CreateLLMHistory;
const Migration015AddSessionAgents = @import("migrations.zig").Migration015AddSessionAgents;

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

test "migration015 creates session_agents table" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();

    try mgr.registerMigration(.{
        .version = 15,
        .name = "add_session_agents",
        .up = Migration015AddSessionAgents.up,
    });
    try mgr.runMigrations();

    const row = try db.queryRow(allocator, "SELECT name FROM sqlite_master WHERE type = ? AND name = ?", &.{ "table", "session_agents" });
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("session_agents", row.values[0]);
}

test "migration015 version and name" {
    try std.testing.expectEqual(@as(u32, 15), Migration015AddSessionAgents.version);
    try std.testing.expectEqualStrings("add_session_agents", Migration015AddSessionAgents.name);
}

test "migration015 creates session_agents index" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();

    try mgr.registerMigration(.{
        .version = 15,
        .name = "add_session_agents",
        .up = Migration015AddSessionAgents.up,
    });
    try mgr.runMigrations();

    const row = try db.queryRow(allocator, "SELECT name FROM sqlite_master WHERE type = ? AND name = ?", &.{ "index", "idx_session_agents_session" });
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("idx_session_agents_session", row.values[0]);
}

test "migration015 session_agents table can insert and retrieve" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();

    try mgr.registerMigration(.{
        .version = 15,
        .name = "add_session_agents",
        .up = Migration015AddSessionAgents.up,
    });
    try mgr.runMigrations();

    try db.exec(allocator, "INSERT INTO session_agents (session_id, agent_name) VALUES (?, ?)", &.{ "session-123", "Agent" });

    const row = try db.queryRow(allocator, "SELECT session_id, agent_name FROM session_agents WHERE session_id = ?", &.{"session-123"});
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("session-123", row.values[0]);
    try std.testing.expectEqualStrings("Agent", row.values[1]);
}

test "migration015 session_agents enforces primary key constraint" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();

    try mgr.registerMigration(.{
        .version = 15,
        .name = "add_session_agents",
        .up = Migration015AddSessionAgents.up,
    });
    try mgr.runMigrations();

    try db.exec(allocator, "INSERT INTO session_agents (session_id, agent_name) VALUES (?, ?)", &.{ "session-123", "Agent" });

    const result = db.exec(allocator, "INSERT INTO session_agents (session_id, agent_name) VALUES (?, ?)", &.{ "session-123", "AnotherAgent" });
    try std.testing.expectError(error.ExecuteFailed, result);
}

test "migration015 session_agents enforces NOT NULL on agent_name" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();

    try mgr.registerMigration(.{
        .version = 15,
        .name = "add_session_agents",
        .up = Migration015AddSessionAgents.up,
    });
    try mgr.runMigrations();

    const result = db.exec(allocator, "INSERT INTO session_agents (session_id) VALUES (?)", &.{"session-123"});
    try std.testing.expectError(error.ExecuteFailed, result);
}

test "migration015 session_agents can update agent_name" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();

    try mgr.registerMigration(.{
        .version = 15,
        .name = "add_session_agents",
        .up = Migration015AddSessionAgents.up,
    });
    try mgr.runMigrations();

    try db.exec(allocator, "INSERT INTO session_agents (session_id, agent_name) VALUES (?, ?)", &.{ "session-123", "Agent" });
    try db.exec(allocator, "UPDATE session_agents SET agent_name = ? WHERE session_id = ?", &.{ "SpecializedCoder", "session-123" });

    const row = try db.queryRow(allocator, "SELECT agent_name FROM session_agents WHERE session_id = ?", &.{"session-123"});
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("SpecializedCoder", row.values[0]);
}
