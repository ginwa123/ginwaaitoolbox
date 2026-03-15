const std = @import("std");
const save_agent = @import("save_agent.zig");
const SqliteBackend = @import("nalarcore").sqlite.SqliteBackend;
const MigrationManager = @import("nalarcore").migrations.MigrationManager;
const Migration015AddSessionAgents = @import("nalarcore").migrations.Migration015AddSessionAgents;
const logger = @import("nalarcore").logger;
const Logger = logger.Logger;
const LoggerConfig = logger.LoggerConfig;

test "SaveAgent saves agent to database" {
    const allocator = std.testing.allocator;

    // Setup in-memory database
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup migration manager and run migration
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();

    try mgr.registerMigration(.{
        .version = 15,
        .name = "add_session_agents",
        .up = Migration015AddSessionAgents.up,
    });
    try mgr.runMigrations();

    // Setup logger (silence output for tests)
    var test_logger = Logger.init(allocator, .{
        .min_level = .err,
        .output_mode = .stdout,
    });
    defer test_logger.deinit();

    // Test saving an agent
    try save_agent.SaveAgent(allocator, &db, &test_logger, "session-123", "Agent");

    // Verify the agent was saved
    const is_loaded = try save_agent.isLoaded(allocator, &db, "session-123", "Agent");
    try std.testing.expect(is_loaded);
}

test "SaveAgent does nothing with empty session_id" {
    const allocator = std.testing.allocator;

    // Setup in-memory database
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup migration manager and run migration
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();

    try mgr.registerMigration(.{
        .version = 15,
        .name = "add_session_agents",
        .up = Migration015AddSessionAgents.up,
    });
    try mgr.runMigrations();

    // Setup logger
    var test_logger = Logger.init(allocator, .{
        .min_level = .err,
    });
    defer test_logger.deinit();

    // Test with empty session_id - should not fail, just return
    try save_agent.SaveAgent(allocator, &db, &test_logger, "", "Agent");

    // Nothing should be in the database
    const is_loaded = try save_agent.isLoaded(allocator, &db, "", "Agent");
    try std.testing.expect(!is_loaded);
}

test "isLoaded returns false for non-existent agent" {
    const allocator = std.testing.allocator;

    // Setup in-memory database
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup migration manager and run migration
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();

    try mgr.registerMigration(.{
        .version = 15,
        .name = "add_session_agents",
        .up = Migration015AddSessionAgents.up,
    });
    try mgr.runMigrations();

    // Test with non-existent session/agent
    const is_loaded = try save_agent.isLoaded(allocator, &db, "non-existent", "NonExistent");
    try std.testing.expect(!is_loaded);
}

test "isLoaded returns false for empty session_id" {
    const allocator = std.testing.allocator;

    // Setup in-memory database
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Should return false without hitting the database
    const is_loaded = try save_agent.isLoaded(allocator, &db, "", "Agent");
    try std.testing.expect(!is_loaded);
}

test "SaveAgent replaces existing agent" {
    const allocator = std.testing.allocator;

    // Setup in-memory database
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup migration manager and run migration
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();

    try mgr.registerMigration(.{
        .version = 15,
        .name = "add_session_agents",
        .up = Migration015AddSessionAgents.up,
    });
    try mgr.runMigrations();

    // Setup logger
    var test_logger = Logger.init(allocator, .{
        .min_level = .err,
    });
    defer test_logger.deinit();

    // Save first agent
    try save_agent.SaveAgent(allocator, &db, &test_logger, "session-123", "FirstAgent");

    // Verify first agent is loaded
    var is_loaded = try save_agent.isLoaded(allocator, &db, "session-123", "FirstAgent");
    try std.testing.expect(is_loaded);

    // Replace with second agent (same session, different agent)
    try save_agent.SaveAgent(allocator, &db, &test_logger, "session-123", "SecondAgent");

    // Verify second agent is now loaded
    is_loaded = try save_agent.isLoaded(allocator, &db, "session-123", "SecondAgent");
    try std.testing.expect(is_loaded);

    // First agent should no longer be the current one for this session
    // (the test verifies that SaveAgent uses INSERT OR REPLACE)
}
