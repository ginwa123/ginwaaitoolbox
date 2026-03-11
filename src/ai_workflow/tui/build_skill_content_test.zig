const std = @import("std");
const testing = std.testing;
const build_skill_content = @import("build_skill_content.zig");
const SqliteBackend = @import("../../modules/databases/sqlite/sqlite.zig").SqliteBackend;
const MigrationManager = @import("../../modules/databases/sqlite/migrations.zig").MigrationManager;
const Migration001CreateLLMHistory = @import("../../modules/databases/sqlite/migrations.zig").Migration001CreateLLMHistory;
const Migration008AddSessionSkills = @import("../../modules/databases/sqlite/migrations.zig").Migration008AddSessionSkills;

test "build_skill_content - empty session_id returns empty string" {
    const allocator = testing.allocator;
    const result = try build_skill_content.run(allocator, undefined, "");
    defer allocator.free(result);
    
    try testing.expectEqualStrings("", result);
}

test "build_skill_content - no skills returns empty string" {
    const allocator = testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{ .version = 1, .name = "create_llm_history", .up = Migration001CreateLLMHistory.up });
    try mgr.registerMigration(.{ .version = 8, .name = "add_session_skills", .up = Migration008AddSessionSkills.up });
    try mgr.runMigrations();

    const result = try build_skill_content.run(allocator, &db, "test-session");
    defer allocator.free(result);

    try testing.expectEqualStrings("", result);
}

test "build_skill_content - single skill returns formatted content" {
    const allocator = testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{ .version = 1, .name = "create_llm_history", .up = Migration001CreateLLMHistory.up });
    try mgr.registerMigration(.{ .version = 8, .name = "add_session_skills", .up = Migration008AddSessionSkills.up });
    try mgr.runMigrations();

    // Insert a skill
    try db.exec(allocator, "INSERT INTO session_skills (session_id, skill_name, content) VALUES (?, ?, ?)", &.{ "test-session", "brainstorming", "This is the brainstorming skill content." });

    const result = try build_skill_content.run(allocator, &db, "test-session");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Loaded Skills") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### brainstorming") != null);
    try testing.expect(std.mem.indexOf(u8, result, "This is the brainstorming skill content.") != null);
}

test "build_skill_content - multiple skills returns all formatted" {
    const allocator = testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{ .version = 1, .name = "create_llm_history", .up = Migration001CreateLLMHistory.up });
    try mgr.registerMigration(.{ .version = 8, .name = "add_session_skills", .up = Migration008AddSessionSkills.up });
    try mgr.runMigrations();

    // Insert multiple skills
    try db.exec(allocator, "INSERT INTO session_skills (session_id, skill_name, content) VALUES (?, ?, ?)", &.{ "test-session", "brainstorming", "Brainstorming content here." });
    try db.exec(allocator, "INSERT INTO session_skills (session_id, skill_name, content) VALUES (?, ?, ?)", &.{ "test-session", "zig-expert", "Zig expert content here." });
    try db.exec(allocator, "INSERT INTO session_skills (session_id, skill_name, content) VALUES (?, ?, ?)", &.{ "test-session", "test-skill", "Test skill content here." });

    const result = try build_skill_content.run(allocator, &db, "test-session");
    defer allocator.free(result);

    // Verify header is present
    try testing.expect(std.mem.startsWith(u8, result, "\n\n## Loaded Skills\n\n"));

    // Verify all skills are present
    try testing.expect(std.mem.indexOf(u8, result, "### brainstorming") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### zig-expert") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### test-skill") != null);

    // Verify all content is present
    try testing.expect(std.mem.indexOf(u8, result, "Brainstorming content here.") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Zig expert content here.") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Test skill content here.") != null);
}

test "build_skill_content - different session returns only that session's skills" {
    const allocator = testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{ .version = 1, .name = "create_llm_history", .up = Migration001CreateLLMHistory.up });
    try mgr.registerMigration(.{ .version = 8, .name = "add_session_skills", .up = Migration008AddSessionSkills.up });
    try mgr.runMigrations();

    // Insert skills for different sessions
    try db.exec(allocator, "INSERT INTO session_skills (session_id, skill_name, content) VALUES (?, ?, ?)", &.{ "session-1", "skill-a", "Content for session 1" });
    try db.exec(allocator, "INSERT INTO session_skills (session_id, skill_name, content) VALUES (?, ?, ?)", &.{ "session-2", "skill-b", "Content for session 2" });

    // Query session-1 only
    const result = try build_skill_content.run(allocator, &db, "session-1");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "skill-a") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Content for session 1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "skill-b") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Content for session 2") == null);
}
