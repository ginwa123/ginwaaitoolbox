const std = @import("std");
const get_session = @import("get_session_by_dir.zig");
const SqliteBackend = @import("../../modules/databases/sqlite/sqlite.zig").SqliteBackend;
const MigrationManager = @import("../../modules/databases/sqlite/migrations.zig").MigrationManager;
const Migration001CreateLLMHistory = @import("../../modules/databases/sqlite/migrations.zig").Migration001CreateLLMHistory;
const Migration004AddSessionDir = @import("../../modules/databases/sqlite/migrations.zig").Migration004AddSessionDir;

test "get_session_by_dir returns empty array when no sessions exist" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup database schema
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 4,
        .name = "add_session_dir",
        .up = Migration004AddSessionDir.up,
    });
    try mgr.runMigrations();

    const result = try get_session.run(allocator, &db, "/test/dir");
    defer {
        for (result) |*session| {
            session.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "get_session_by_dir returns sessions matching directory" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup database schema
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 4,
        .name = "add_session_dir",
        .up = Migration004AddSessionDir.up,
    });
    try mgr.runMigrations();

    // Insert test data - some sessions in /test/dir, some in other directories
    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, session_dir, created_at) VALUES 
        \\('id1', 'session1', 'gpt4', '/test/dir', '2024-01-01 10:00:00'),
        \\('id2', 'session2', 'gpt4', '/test/dir', '2024-01-01 11:00:00'),
        \\('id3', 'session3', 'gpt4', '/other/dir', '2024-01-01 12:00:00'),
        \\('id4', 'session4', 'gpt4', '/test/dir', '2024-01-01 13:00:00'),
        \\('id5', 'session5', 'gpt4', '/another/dir', '2024-01-01 14:00:00')
    , &[_][]const u8{});

    const result = try get_session.run(allocator, &db, "/test/dir");
    defer {
        for (result) |*session| {
            session.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    
    // Verify all results are from the correct directory
    for (result) |*session| {
        try std.testing.expectEqualStrings("/test/dir", session.session_dir);
    }
}

test "get_session_by_dir respects ORDER BY created_at DESC" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup database schema
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 4,
        .name = "add_session_dir",
        .up = Migration004AddSessionDir.up,
    });
    try mgr.runMigrations();

    // Insert test data with different timestamps
    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, session_dir, created_at) VALUES 
        \\('id1', 'session1', 'gpt4', '/test/dir', '2024-01-01 10:00:00'),
        \\('id2', 'session2', 'gpt4', '/test/dir', '2024-01-01 15:00:00'),
        \\('id3', 'session3', 'gpt4', '/test/dir', '2024-01-01 12:00:00')
    , &[_][]const u8{});

    const result = try get_session.run(allocator, &db, "/test/dir");
    defer {
        for (result) |*session| {
            session.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    
    // Verify order: newest first
    try std.testing.expectEqualStrings("session2", result[0].session_id);
    try std.testing.expectEqualStrings("session3", result[1].session_id);
    try std.testing.expectEqualStrings("session1", result[2].session_id);
}

test "get_session_by_dir respects LIMIT 10" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup database schema
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 4,
        .name = "add_session_dir",
        .up = Migration004AddSessionDir.up,
    });
    try mgr.runMigrations();

    // Insert 15 sessions in the same directory
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        const session_id = try std.fmt.allocPrint(allocator, "session{d}", .{i});
        defer allocator.free(session_id);
        const id = try std.fmt.allocPrint(allocator, "id{d}", .{i});
        defer allocator.free(id);
        const timestamp = try std.fmt.allocPrint(allocator, "2024-01-01 {d:02}:00:00", .{i});
        defer allocator.free(timestamp);
        
        try db.exec(allocator, 
            "INSERT INTO llm_history (id, session_id, model, session_dir, created_at) VALUES (?, ?, ?, ?, ?)",
            &[_][]const u8{id, session_id, "gpt4", "/test/dir", timestamp}
        );
    }

    const result = try get_session.run(allocator, &db, "/test/dir");
    defer {
        for (result) |*session| {
            session.deinit(allocator);
        }
        allocator.free(result);
    }

    // Should return exactly 10, not 15
    try std.testing.expectEqual(@as(usize, 10), result.len);
}

test "get_session_by_dir handles multiple entries per session_id" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup database schema
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 4,
        .name = "add_session_dir",
        .up = Migration004AddSessionDir.up,
    });
    try mgr.runMigrations();

    // Insert multiple entries for the same session_id
    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, session_dir, created_at) VALUES 
        \\('id1', 'session1', 'gpt4', '/test/dir', '2024-01-01 10:00:00'),
        \\('id2', 'session1', 'gpt4', '/test/dir', '2024-01-01 11:00:00'),
        \\('id3', 'session1', 'gpt4', '/test/dir', '2024-01-01 12:00:00'),
        \\('id4', 'session2', 'gpt4', '/test/dir', '2024-01-01 13:00:00')
    , &[_][]const u8{});

    const result = try get_session.run(allocator, &db, "/test/dir");
    defer {
        for (result) |*session| {
            session.deinit(allocator);
        }
        allocator.free(result);
    }

    // GROUP BY session_id should return only 2 distinct sessions
    try std.testing.expectEqual(@as(usize, 2), result.len);
    
    // Both sessions should be from the correct directory
    try std.testing.expectEqualStrings("/test/dir", result[0].session_dir);
    try std.testing.expectEqualStrings("/test/dir", result[1].session_dir);
}

test "get_session_by_dir handles NULL session_dir" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup database schema
    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 4,
        .name = "add_session_dir",
        .up = Migration004AddSessionDir.up,
    });
    try mgr.runMigrations();

    // Insert test data with NULL session_dir
    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at) VALUES 
        \\('id1', 'session1', 'gpt4', '2024-01-01 10:00:00'),
        \\('id2', 'session2', 'gpt4', '2024-01-01 11:00:00')
    , &[_][]const u8{});

    const result = try get_session.run(allocator, &db, "/test/dir");
    defer {
        for (result) |*session| {
            session.deinit(allocator);
        }
        allocator.free(result);
    }

    // Should return empty since NULL doesn't match "/test/dir"
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
