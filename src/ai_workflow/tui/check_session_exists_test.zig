const std = @import("std");
const tree1_mod = @import("nalarcore");
const check_session_exists = tree1_mod.tui_check_session_exists;
const SqliteBackend = tree1_mod.sqlite.SqliteBackend;
const MigrationManager = tree1_mod.migrations.MigrationManager;

test "check_session_exists returns false for non-existent session" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Run migration to create llm_history table
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = tree1_mod.migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.runMigrations();

    // Check non-existent session
    const exists = check_session_exists.check_session_exists(allocator, &db, "non_existent_session");
    try std.testing.expectEqual(false, exists);
}

test "check_session_exists returns true for existing session" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Run migration to create llm_history table
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = tree1_mod.migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.runMigrations();

    // Insert a message with session_id (id, session_id, model are required NOT NULL fields)
    try db.exec(allocator, 
        \\INSERT INTO llm_history (id, session_id, model, response_content) VALUES (?, ?, ?, ?)
    , &.{"msg-1", "test_session_123", "gpt-4", "Hello"});

    // Check existing session
    const exists = check_session_exists.check_session_exists(allocator, &db, "test_session_123");
    try std.testing.expectEqual(true, exists);
}

test "check_session_exists returns false after deleting all messages for session" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Run migration to create llm_history table
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = tree1_mod.migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.runMigrations();

    // Insert and then delete
    try db.exec(allocator, 
        \\INSERT INTO llm_history (id, session_id, model, response_content) VALUES (?, ?, ?, ?)
    , &.{"msg-1", "session_to_delete", "gpt-4", "Hello"});
    
    // Delete all messages for the session
    try db.exec(allocator, "DELETE FROM llm_history WHERE session_id = ?", &.{"session_to_delete"});

    // Check non-existent (deleted) session
    const exists = check_session_exists.check_session_exists(allocator, &db, "session_to_delete");
    try std.testing.expectEqual(false, exists);
}

test "check_session_exists handles multiple sessions correctly" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Run migration to create llm_history table
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = tree1_mod.migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.runMigrations();

    // Create multiple sessions
    try db.exec(allocator, 
        \\INSERT INTO llm_history (id, session_id, model, response_content) VALUES (?, ?, ?, ?)
    , &.{"msg-A1", "session_A", "gpt-4", "Hello A"});
    try db.exec(allocator, 
        \\INSERT INTO llm_history (id, session_id, model, response_content) VALUES (?, ?, ?, ?)
    , &.{"msg-B1", "session_B", "gpt-4", "Hello B"});
    try db.exec(allocator, 
        \\INSERT INTO llm_history (id, session_id, model, response_content) VALUES (?, ?, ?, ?)
    , &.{"msg-C1", "session_C", "gpt-4", "Hello C"});

    // All existing
    try std.testing.expectEqual(true, check_session_exists.check_session_exists(allocator, &db, "session_A"));
    try std.testing.expectEqual(true, check_session_exists.check_session_exists(allocator, &db, "session_B"));
    try std.testing.expectEqual(true, check_session_exists.check_session_exists(allocator, &db, "session_C"));

    // Non-existent
    try std.testing.expectEqual(false, check_session_exists.check_session_exists(allocator, &db, "session_D"));
}

test "check_session_exists handles empty session_id" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Run migration to create llm_history table
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = tree1_mod.migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.runMigrations();

    // Empty string should not exist (no session has empty session_id)
    const exists = check_session_exists.check_session_exists(allocator, &db, "");
    try std.testing.expectEqual(false, exists);
}

test "check_session_exists is case-sensitive" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Run migration to create llm_history table
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = tree1_mod.migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.runMigrations();

    // Create session with specific case
    try db.exec(allocator, 
        \\INSERT INTO llm_history (id, session_id, model, response_content) VALUES (?, ?, ?, ?)
    , &.{"msg-1", "MySession", "gpt-4", "Hello"});

    // Exact match exists
    try std.testing.expectEqual(true, check_session_exists.check_session_exists(allocator, &db, "MySession"));

    // Different case does not exist
    try std.testing.expectEqual(false, check_session_exists.check_session_exists(allocator, &db, "mysession"));
    try std.testing.expectEqual(false, check_session_exists.check_session_exists(allocator, &db, "MYSESSION"));
}

test "check_session_exists counts multiple messages in same session" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Run migration to create llm_history table
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = tree1_mod.migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.runMigrations();

    // Create session with multiple messages
    try db.exec(allocator, 
        \\INSERT INTO llm_history (id, session_id, model, response_content) VALUES (?, ?, ?, ?)
    , &.{"msg-1", "multi_msg_session", "gpt-4", "Hello 1"});
    try db.exec(allocator, 
        \\INSERT INTO llm_history (id, session_id, model, response_content) VALUES (?, ?, ?, ?)
    , &.{"msg-2", "multi_msg_session", "gpt-4", "Hello 2"});
    try db.exec(allocator, 
        \\INSERT INTO llm_history (id, session_id, model, response_content) VALUES (?, ?, ?, ?)
    , &.{"msg-3", "multi_msg_session", "gpt-4", "Hello 3"});

    // Session still exists even with multiple messages
    try std.testing.expectEqual(true, check_session_exists.check_session_exists(allocator, &db, "multi_msg_session"));
}
