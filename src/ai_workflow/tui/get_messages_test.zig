const std = @import("std");
const get_messages = @import("get_messages.zig");
const TUIHistory = @import("models.zig").TUIHistory;
const tree1_mod = @import("nalarcore");
const SqliteBackend = tree1_mod.sqlite.SqliteBackend;
const MigrationManager = tree1_mod.migrations.MigrationManager;
const Migration001CreateLLMHistory = tree1_mod.migrations.Migration001CreateLLMHistory;
const Migration002AddRoleToLLMHistory = tree1_mod.migrations.Migration002AddRoleToLLMHistory;
const Migration003AddReasoningContent = tree1_mod.migrations.Migration003AddReasoningContent;
const Migration005AddIsFeedToLLM = tree1_mod.migrations.Migration005AddIsFeedToLLM;
const Migration006AddAgent = tree1_mod.migrations.Migration006AddAgent;
const Migration007AddSessionTracking = tree1_mod.migrations.Migration007AddSessionTracking;
const Migration011AddTemperatureAndThinking = tree1_mod.migrations.Migration011AddTemperatureAndThinking;

test "get_messages returns empty array when no messages exist" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 2,
        .name = "add_role_to_llm_history",
        .up = Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 3,
        .name = "add_reasoning_content",
        .up = Migration003AddReasoningContent.up,
    });
    try mgr.registerMigration(.{
        .version = 5,
        .name = "add_is_feed_to_llm",
        .up = Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = 6,
        .name = "add_agent",
        .up = Migration006AddAgent.up,
    });
    try mgr.registerMigration(.{
        .version = 7,
        .name = "add_session_tracking",
        .up = Migration007AddSessionTracking.up,
    });
    try mgr.registerMigration(.{
        .version = 11,
        .name = "add_temperature_and_thinking",
        .up = Migration011AddTemperatureAndThinking.up,
    });
    try mgr.runMigrations();

    const result = try get_messages.run(allocator, &db, "test-session-123");
    defer {
        for (result) |*msg| {
            msg.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "get_messages returns messages for a session" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 2,
        .name = "add_role_to_llm_history",
        .up = Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 3,
        .name = "add_reasoning_content",
        .up = Migration003AddReasoningContent.up,
    });
    try mgr.registerMigration(.{
        .version = 5,
        .name = "add_is_feed_to_llm",
        .up = Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = 6,
        .name = "add_agent",
        .up = Migration006AddAgent.up,
    });
    try mgr.registerMigration(.{
        .version = 7,
        .name = "add_session_tracking",
        .up = Migration007AddSessionTracking.up,
    });
    try mgr.registerMigration(.{
        .version = 11,
        .name = "add_temperature_and_thinking",
        .up = Migration011AddTemperatureAndThinking.up,
    });
    try mgr.runMigrations();

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, agent, session_name, loop_index) VALUES 
        \\('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Hello', 'stop', 'assistant', 'GeneralAgent', 'Test Session', 0),
        \\('id2', 'test-session', 'gpt-4', '2024-01-01 11:00:00', 'World', 'stop', 'user', 'ExecutingAgent', 'Test Session', 1)
    , &[_][]const u8{});

    const result = try get_messages.run(allocator, &db, "test-session");
    defer {
        for (result) |*msg| {
            msg.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("id1", result[0].id);
    try std.testing.expectEqualStrings("id2", result[1].id);
}

test "get_messages filters out messages with is_feed_to_llm = 0" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 2,
        .name = "add_role_to_llm_history",
        .up = Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 3,
        .name = "add_reasoning_content",
        .up = Migration003AddReasoningContent.up,
    });
    try mgr.registerMigration(.{
        .version = 5,
        .name = "add_is_feed_to_llm",
        .up = Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = 6,
        .name = "add_agent",
        .up = Migration006AddAgent.up,
    });
    try mgr.registerMigration(.{
        .version = 7,
        .name = "add_session_tracking",
        .up = Migration007AddSessionTracking.up,
    });
    try mgr.registerMigration(.{
        .version = 11,
        .name = "add_temperature_and_thinking",
        .up = Migration011AddTemperatureAndThinking.up,
    });
    try mgr.runMigrations();

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, is_feed_to_llm) VALUES 
        \\('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Feed me', 'stop', 'assistant', 1),
        \\('id2', 'test-session', 'gpt-4', '2024-01-01 11:00:00', 'Do not feed', 'stop', 'assistant', 0),
        \\('id3', 'test-session', 'gpt-4', '2024-01-01 12:00:00', 'Feed me too', 'stop', 'user', 1)
    , &[_][]const u8{});

    const result = try get_messages.run(allocator, &db, "test-session");
    defer {
        for (result) |*msg| {
            msg.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("id1", result[0].id);
    try std.testing.expectEqualStrings("id3", result[1].id);
}

test "get_messages respects ORDER BY created_at ASC" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 2,
        .name = "add_role_to_llm_history",
        .up = Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 3,
        .name = "add_reasoning_content",
        .up = Migration003AddReasoningContent.up,
    });
    try mgr.registerMigration(.{
        .version = 5,
        .name = "add_is_feed_to_llm",
        .up = Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = 6,
        .name = "add_agent",
        .up = Migration006AddAgent.up,
    });
    try mgr.registerMigration(.{
        .version = 7,
        .name = "add_session_tracking",
        .up = Migration007AddSessionTracking.up,
    });
    try mgr.registerMigration(.{
        .version = 11,
        .name = "add_temperature_and_thinking",
        .up = Migration011AddTemperatureAndThinking.up,
    });
    try mgr.runMigrations();

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role) VALUES 
        \\('id1', 'test-session', 'gpt-4', '2024-01-01 15:00:00', 'Third', 'stop', 'assistant'),
        \\('id2', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'First', 'stop', 'user'),
        \\('id3', 'test-session', 'gpt-4', '2024-01-01 12:00:00', 'Second', 'stop', 'assistant')
    , &[_][]const u8{});

    const result = try get_messages.run(allocator, &db, "test-session");
    defer {
        for (result) |*msg| {
            msg.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("id2", result[0].id);
    try std.testing.expectEqualStrings("id3", result[1].id);
    try std.testing.expectEqualStrings("id1", result[2].id);
}

test "get_messages handles NULL role with default 'assistant'" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 2,
        .name = "add_role_to_llm_history",
        .up = Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 3,
        .name = "add_reasoning_content",
        .up = Migration003AddReasoningContent.up,
    });
    try mgr.registerMigration(.{
        .version = 5,
        .name = "add_is_feed_to_llm",
        .up = Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = 6,
        .name = "add_agent",
        .up = Migration006AddAgent.up,
    });
    try mgr.registerMigration(.{
        .version = 7,
        .name = "add_session_tracking",
        .up = Migration007AddSessionTracking.up,
    });
    try mgr.registerMigration(.{
        .version = 11,
        .name = "add_temperature_and_thinking",
        .up = Migration011AddTemperatureAndThinking.up,
    });
    try mgr.runMigrations();

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason) VALUES ('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Hello', 'stop')",
        &[_][]const u8{}
    );

    const result = try get_messages.run(allocator, &db, "test-session");
    defer {
        for (result) |*msg| {
            msg.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("assistant", result[0].role);
}

test "get_messages handles reasoning_content correctly" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 2,
        .name = "add_role_to_llm_history",
        .up = Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 3,
        .name = "add_reasoning_content",
        .up = Migration003AddReasoningContent.up,
    });
    try mgr.registerMigration(.{
        .version = 5,
        .name = "add_is_feed_to_llm",
        .up = Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = 6,
        .name = "add_agent",
        .up = Migration006AddAgent.up,
    });
    try mgr.registerMigration(.{
        .version = 7,
        .name = "add_session_tracking",
        .up = Migration007AddSessionTracking.up,
    });
    try mgr.registerMigration(.{
        .version = 11,
        .name = "add_temperature_and_thinking",
        .up = Migration011AddTemperatureAndThinking.up,
    });
    try mgr.runMigrations();

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, reasoning_content) VALUES 
        \\('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'With reasoning', 'stop', 'assistant', 'Step 1: Think'),
        \\('id2', 'test-session', 'gpt-4', '2024-01-01 11:00:00', 'Without reasoning', 'stop', 'assistant', NULL)
    , &[_][]const u8{});

    const result = try get_messages.run(allocator, &db, "test-session");
    defer {
        for (result) |*msg| {
            msg.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expect(result[0].reasoning_content != null);
    try std.testing.expectEqualStrings("Step 1: Think", result[0].reasoning_content.?);
    try std.testing.expect(result[1].reasoning_content == null);
}

test "get_messages handles agent and session tracking fields" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 2,
        .name = "add_role_to_llm_history",
        .up = Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 3,
        .name = "add_reasoning_content",
        .up = Migration003AddReasoningContent.up,
    });
    try mgr.registerMigration(.{
        .version = 5,
        .name = "add_is_feed_to_llm",
        .up = Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = 6,
        .name = "add_agent",
        .up = Migration006AddAgent.up,
    });
    try mgr.registerMigration(.{
        .version = 7,
        .name = "add_session_tracking",
        .up = Migration007AddSessionTracking.up,
    });
    try mgr.registerMigration(.{
        .version = 11,
        .name = "add_temperature_and_thinking",
        .up = Migration011AddTemperatureAndThinking.up,
    });
    try mgr.runMigrations();

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, agent, session_name, loop_index) VALUES ('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Response', 'stop', 'assistant', 'PlanningAgent', 'Plan A', 5)",
        &[_][]const u8{}
    );

    const result = try get_messages.run(allocator, &db, "test-session");
    defer {
        for (result) |*msg| {
            msg.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("PlanningAgent", result[0].agent);
    try std.testing.expectEqualStrings("Plan A", result[0].session_name);
    try std.testing.expectEqual(@as(u32, 5), result[0].loop_index);
}

test "get_messages returns empty array for non-existent session" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = 1,
        .name = "create_llm_history",
        .up = Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 2,
        .name = "add_role_to_llm_history",
        .up = Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = 3,
        .name = "add_reasoning_content",
        .up = Migration003AddReasoningContent.up,
    });
    try mgr.registerMigration(.{
        .version = 5,
        .name = "add_is_feed_to_llm",
        .up = Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = 6,
        .name = "add_agent",
        .up = Migration006AddAgent.up,
    });
    try mgr.registerMigration(.{
        .version = 7,
        .name = "add_session_tracking",
        .up = Migration007AddSessionTracking.up,
    });
    try mgr.registerMigration(.{
        .version = 11,
        .name = "add_temperature_and_thinking",
        .up = Migration011AddTemperatureAndThinking.up,
    });
    try mgr.runMigrations();

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role) VALUES ('id1', 'other-session', 'gpt-4', '2024-01-01 10:00:00', 'Hello', 'stop', 'assistant')",
        &[_][]const u8{}
    );

    const result = try get_messages.run(allocator, &db, "non-existent-session");
    defer {
        for (result) |*msg| {
            msg.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 0), result.len);
}
