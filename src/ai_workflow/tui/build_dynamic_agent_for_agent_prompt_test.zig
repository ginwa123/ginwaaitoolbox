const std = @import("std");
const testing = std.testing;
const build_dynamic_agent_content = @import("build_dynamic_agent_for_agent_prompt.zig");
const SqliteBackend = @import("../../modules/databases/sqlite/sqlite.zig").SqliteBackend;
const MigrationManager = @import("../../modules/databases/sqlite/migrations.zig").MigrationManager;
const Migration001CreateLLMHistory = @import("../../modules/databases/sqlite/migrations.zig").Migration001CreateLLMHistory;
const Migration015AddSessionAgents = @import("../../modules/databases/sqlite/migrations.zig").Migration015AddSessionAgents;

test "build_dynamic_agent_content - empty session_id returns empty string" {
    const allocator = testing.allocator;
    const result = try build_dynamic_agent_content.run(allocator, undefined, "");
    defer allocator.free(result);
    
    try testing.expectEqualStrings("", result);
}

test "build_dynamic_agent_content - no agents returns empty string" {
    const allocator = testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{ .version = 1, .name = "create_llm_history", .up = Migration001CreateLLMHistory.up });
    try mgr.registerMigration(.{ .version = 15, .name = "add_session_agents", .up = Migration015AddSessionAgents.up });
    try mgr.runMigrations();

    const result = try build_dynamic_agent_content.run(allocator, &db, "test-session");
    defer allocator.free(result);

    try testing.expectEqualStrings("", result);
}

test "build_dynamic_agent_content - single agent returns formatted content" {
    const allocator = testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{ .version = 1, .name = "create_llm_history", .up = Migration001CreateLLMHistory.up });
    try mgr.registerMigration(.{ .version = 15, .name = "add_session_agents", .up = Migration015AddSessionAgents.up });
    try mgr.runMigrations();

    // Insert an agent
    try db.exec(allocator, "INSERT INTO session_agents (session_id, agent_name) VALUES (?, ?)", &.{ "test-session", "specialized-coder" });

    const result = try build_dynamic_agent_content.run(allocator, &db, "test-session");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Loaded Dynamic Agents") != null);
    try testing.expect(std.mem.indexOf(u8, result, "- specialized-coder") != null);
}

test "build_dynamic_agent_content - multiple agents returns all formatted" {
    const allocator = testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{ .version = 1, .name = "create_llm_history", .up = Migration001CreateLLMHistory.up });
    try mgr.registerMigration(.{ .version = 15, .name = "add_session_agents", .up = Migration015AddSessionAgents.up });
    try mgr.runMigrations();

    // Insert multiple agents
    try db.exec(allocator, "INSERT INTO session_agents (session_id, agent_name) VALUES (?, ?)", &.{ "test-session", "specialized-coder" });
    try db.exec(allocator, "INSERT INTO session_agents (session_id, agent_name) VALUES (?, ?)", &.{ "test-session", "code-reviewer" });
    try db.exec(allocator, "INSERT INTO session_agents (session_id, agent_name) VALUES (?, ?)", &.{ "test-session", "my-custom-agent" });

    const result = try build_dynamic_agent_content.run(allocator, &db, "test-session");
    defer allocator.free(result);

    // Verify header is present
    try testing.expect(std.mem.startsWith(u8, result, "\n\n## Loaded Dynamic Agents\n\n"));

    // Verify all agents are present
    try testing.expect(std.mem.indexOf(u8, result, "- specialized-coder") != null);
    try testing.expect(std.mem.indexOf(u8, result, "- code-reviewer") != null);
    try testing.expect(std.mem.indexOf(u8, result, "- my-custom-agent") != null);
}

test "build_dynamic_agent_content - different session returns only that session's agents" {
    const allocator = testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{ .version = 1, .name = "create_llm_history", .up = Migration001CreateLLMHistory.up });
    try mgr.registerMigration(.{ .version = 15, .name = "add_session_agents", .up = Migration015AddSessionAgents.up });
    try mgr.runMigrations();

    // Insert agents for different sessions
    try db.exec(allocator, "INSERT INTO session_agents (session_id, agent_name) VALUES (?, ?)", &.{ "session-1", "agent-a" });
    try db.exec(allocator, "INSERT INTO session_agents (session_id, agent_name) VALUES (?, ?)", &.{ "session-2", "agent-b" });

    // Query session-1 only
    const result = try build_dynamic_agent_content.run(allocator, &db, "session-1");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "agent-a") != null);
    try testing.expect(std.mem.indexOf(u8, result, "agent-b") == null);
}
