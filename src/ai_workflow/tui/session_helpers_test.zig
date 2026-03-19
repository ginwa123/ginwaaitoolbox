const std = @import("std");
const session_helpers = @import("session_helpers.zig");
const TUIHistory = @import("models.zig").TUIHistory;
const tree1_mod = @import("nalarcore");
const SqliteBackend = tree1_mod.sqlite.SqliteBackend;
const MigrationManager = tree1_mod.migrations.MigrationManager;
const Migration001CreateLLMHistory = tree1_mod.migrations.Migration001CreateLLMHistory;
const Migration002AddRoleToLLMHistory = tree1_mod.migrations.Migration002AddRoleToLLMHistory;
const Migration003AddReasoningContent = tree1_mod.migrations.Migration003AddReasoningContent;
const Migration004AddSessionDir = tree1_mod.migrations.Migration004AddSessionDir;
const Migration005AddIsFeedToLLM = tree1_mod.migrations.Migration005AddIsFeedToLLM;
const Migration006AddAgent = tree1_mod.migrations.Migration006AddAgent;
const Migration007AddSessionTracking = tree1_mod.migrations.Migration007AddSessionTracking;
const Migration011AddTemperatureAndThinking = tree1_mod.migrations.Migration011AddTemperatureAndThinking;
const Migration012AddParentTracking = tree1_mod.migrations.Migration012AddParentTracking;
const Migration015AddSessionAgents = tree1_mod.migrations.Migration015AddSessionAgents;
const Migration016AddInputOutputColumns = tree1_mod.migrations.Migration016AddInputOutputColumns;

fn setupTestDb(allocator: std.mem.Allocator, mgr: *MigrationManager) !void {
    _ = allocator;
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
        .version = 4,
        .name = "add_session_dir",
        .up = Migration004AddSessionDir.up,
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
    try mgr.registerMigration(.{
        .version = 12,
        .name = "add_parent_tracking",
        .up = Migration012AddParentTracking.up,
    });
    try mgr.registerMigration(.{
        .version = 15,
        .name = "add_session_agents",
        .up = Migration015AddSessionAgents.up,
    });
    try mgr.registerMigration(.{
        .version = 16,
        .name = "add_input_output_columns",
        .up = Migration016AddInputOutputColumns.up,
    });
    try mgr.runMigrations();
}

// ============================================================================
// GetMessages Tests
// ============================================================================

test "get_messages returns empty array when no messages exist" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    const result = try session_helpers.GetMessages(allocator, &db, "test-session-123");
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
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, agent, session_name, loop_index) VALUES 
        \\('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Hello', 'stop', 'assistant', 'GeneralAgent', 'Test Session', 0),
        \\('id2', 'test-session', 'gpt-4', '2024-01-01 11:00:00', 'World', 'stop', 'user', 'Agent', 'Test Session', 1)
    , &[_][]const u8{});

    const result = try session_helpers.GetMessages(allocator, &db, "test-session");
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
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, is_feed_to_llm) VALUES 
        \\('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Feed me', 'stop', 'assistant', 1),
        \\('id2', 'test-session', 'gpt-4', '2024-01-01 11:00:00', 'Do not feed', 'stop', 'assistant', 0),
        \\('id3', 'test-session', 'gpt-4', '2024-01-01 12:00:00', 'Feed me too', 'stop', 'user', 1)
    , &[_][]const u8{});

    const result = try session_helpers.GetMessages(allocator, &db, "test-session");
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
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role) VALUES 
        \\('id1', 'test-session', 'gpt-4', '2024-01-01 15:00:00', 'Third', 'stop', 'assistant'),
        \\('id2', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'First', 'stop', 'user'),
        \\('id3', 'test-session', 'gpt-4', '2024-01-01 12:00:00', 'Second', 'stop', 'assistant')
    , &[_][]const u8{});

    const result = try session_helpers.GetMessages(allocator, &db, "test-session");
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
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason) VALUES ('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Hello', 'stop')",
        &[_][]const u8{}
    );

    const result = try session_helpers.GetMessages(allocator, &db, "test-session");
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
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, reasoning_content) VALUES 
        \\('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'With reasoning', 'stop', 'assistant', 'Step 1: Think'),
        \\('id2', 'test-session', 'gpt-4', '2024-01-01 11:00:00', 'Without reasoning', 'stop', 'assistant', NULL)
    , &[_][]const u8{});

    const result = try session_helpers.GetMessages(allocator, &db, "test-session");
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
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, agent, session_name, loop_index) VALUES ('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Response', 'stop', 'assistant', 'Agent', 'Plan A', 5)",
        &[_][]const u8{}
    );

    const result = try session_helpers.GetMessages(allocator, &db, "test-session");
    defer {
        for (result) |*msg| {
            msg.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("Agent", result[0].agent);
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
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role) VALUES ('id1', 'other-session', 'gpt-4', '2024-01-01 10:00:00', 'Hello', 'stop', 'assistant')",
        &[_][]const u8{}
    );

    const result = try session_helpers.GetMessages(allocator, &db, "non-existent-session");
    defer {
        for (result) |*msg| {
            msg.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "get_messages returns parent_session_id for each message" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, parent_session_id) VALUES 
        \\('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'First', 'stop', 'assistant', 'root-session'),
        \\('id2', 'test-session', 'gpt-4', '2024-01-01 11:00:00', 'Second', 'stop', 'user', NULL)
    , &[_][]const u8{});

    const result = try session_helpers.GetMessages(allocator, &db, "test-session");
    defer {
        for (result) |*msg| {
            msg.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expect(result[0].parent_session_id != null);
    try std.testing.expectEqualStrings("root-session", result[0].parent_session_id.?);
    try std.testing.expect(result[1].parent_session_id == null);
}

// ============================================================================
// GetMessageLatest Tests
// ============================================================================

test "get_message_latest returns null when no messages exist" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    const result = try session_helpers.GetMessageLatest(allocator, &db, "test-session-123");
    defer if (result) |msg| {
        var m = msg;
        m.deinit(allocator);
    };

    try std.testing.expect(result == null);
}

test "get_message_latest returns single message when only one exists" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, agent, session_name, loop_index, tool_name) VALUES ('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Hello', 'stop', 'assistant', 'Agent', 'Test Session', 0, 'bash')",
        &[_][]const u8{}
    );

    const result = try session_helpers.GetMessageLatest(allocator, &db, "test-session");
    defer if (result) |msg| {
        var m = msg;
        m.deinit(allocator);
    };

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("id1", result.?.id);
    try std.testing.expectEqualStrings("Hello", result.?.response_content);
    try std.testing.expectEqualStrings("bash", result.?.tool_name);
}

test "get_message_latest returns most recent message when multiple exist" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role) VALUES 
        \\('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'First', 'stop', 'assistant'),
        \\('id2', 'test-session', 'gpt-4', '2024-01-01 11:00:00', 'Second', 'stop', 'user'),
        \\('id3', 'test-session', 'gpt-4', '2024-01-01 12:00:00', 'Third', 'stop', 'assistant')
    , &[_][]const u8{});

    const result = try session_helpers.GetMessageLatest(allocator, &db, "test-session");
    defer if (result) |msg| {
        var m = msg;
        m.deinit(allocator);
    };

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("id3", result.?.id);
    try std.testing.expectEqualStrings("Third", result.?.response_content);
}

test "get_message_latest filters out is_feed_to_llm = 0" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, is_feed_to_llm) VALUES 
        \\('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Should be skipped', 'stop', 'assistant', 0),
        \\('id2', 'test-session', 'gpt-4', '2024-01-01 11:00:00', 'Should be returned', 'stop', 'assistant', 1)
    , &[_][]const u8{});

    const result = try session_helpers.GetMessageLatest(allocator, &db, "test-session");
    defer if (result) |msg| {
        var m = msg;
        m.deinit(allocator);
    };

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("id2", result.?.id);
    try std.testing.expectEqualStrings("Should be returned", result.?.response_content);
}

test "get_message_latest returns null for non-existent session" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role) VALUES ('id1', 'other-session', 'gpt-4', '2024-01-01 10:00:00', 'Hello', 'stop', 'assistant')",
        &[_][]const u8{}
    );

    const result = try session_helpers.GetMessageLatest(allocator, &db, "non-existent-session");
    defer if (result) |msg| {
        var m = msg;
        m.deinit(allocator);
    };

    try std.testing.expect(result == null);
}

test "get_message_latest handles tool_name from database" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, tool_name) VALUES ('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Tool result', 'tool', 'tool', 'read_file')",
        &[_][]const u8{}
    );

    const result = try session_helpers.GetMessageLatest(allocator, &db, "test-session");
    defer if (result) |msg| {
        var m = msg;
        m.deinit(allocator);
    };

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("read_file", result.?.tool_name);
}

test "get_message_latest handles parent_session_id from database" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, parent_session_id) VALUES ('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'From parent', 'stop', 'assistant', 'parent-session-123')",
        &[_][]const u8{}
    );

    const result = try session_helpers.GetMessageLatest(allocator, &db, "test-session");
    defer if (result) |msg| {
        var m = msg;
        m.deinit(allocator);
    };

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.parent_session_id != null);
    try std.testing.expectEqualStrings("parent-session-123", result.?.parent_session_id.?);
}

test "get_message_latest returns null parent_session_id when not set" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role) VALUES ('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'No parent', 'stop', 'assistant')",
        &[_][]const u8{}
    );

    const result = try session_helpers.GetMessageLatest(allocator, &db, "test-session");
    defer if (result) |msg| {
        var m = msg;
        m.deinit(allocator);
    };

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.parent_session_id == null);
}

// ============================================================================
// GetSessionsByDir Tests
// ============================================================================

test "get_session_by_dir returns empty array when no sessions exist" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    const result = try session_helpers.GetSessionsByDir(allocator, &db, "/test/dir");
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

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, session_dir, created_at) VALUES 
        \\('id1', 'session1', 'gpt4', '/test/dir', '2024-01-01 10:00:00'),
        \\('id2', 'session2', 'gpt4', '/test/dir', '2024-01-01 11:00:00'),
        \\('id3', 'session3', 'gpt4', '/other/dir', '2024-01-01 12:00:00'),
        \\('id4', 'session4', 'gpt4', '/test/dir', '2024-01-01 13:00:00'),
        \\('id5', 'session5', 'gpt4', '/another/dir', '2024-01-01 14:00:00')
    , &[_][]const u8{});

    const result = try session_helpers.GetSessionsByDir(allocator, &db, "/test/dir");
    defer {
        for (result) |*session| {
            session.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);

    for (result) |*session| {
        try std.testing.expectEqualStrings("/test/dir", session.session_dir);
    }
}

test "get_session_by_dir respects ORDER BY created_at DESC" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, session_dir, created_at) VALUES 
        \\('id1', 'session1', 'gpt4', '/test/dir', '2024-01-01 10:00:00'),
        \\('id2', 'session2', 'gpt4', '/test/dir', '2024-01-01 15:00:00'),
        \\('id3', 'session3', 'gpt4', '/test/dir', '2024-01-01 12:00:00')
    , &[_][]const u8{});

    const result = try session_helpers.GetSessionsByDir(allocator, &db, "/test/dir");
    defer {
        for (result) |*session| {
            session.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);

    try std.testing.expectEqualStrings("session2", result[0].session_id);
    try std.testing.expectEqualStrings("session3", result[1].session_id);
    try std.testing.expectEqualStrings("session1", result[2].session_id);
}

test "get_session_by_dir respects LIMIT 10" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

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
            &[_][]const u8{ id, session_id, "gpt4", "/test/dir", timestamp }
        );
    }

    const result = try session_helpers.GetSessionsByDir(allocator, &db, "/test/dir");
    defer {
        for (result) |*session| {
            session.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 10), result.len);
}

test "get_session_by_dir handles multiple entries per session_id" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, session_dir, created_at) VALUES 
        \\('id1', 'session1', 'gpt4', '/test/dir', '2024-01-01 10:00:00'),
        \\('id2', 'session1', 'gpt4', '/test/dir', '2024-01-01 11:00:00'),
        \\('id3', 'session1', 'gpt4', '/test/dir', '2024-01-01 12:00:00'),
        \\('id4', 'session2', 'gpt4', '/test/dir', '2024-01-01 13:00:00')
    , &[_][]const u8{});

    const result = try session_helpers.GetSessionsByDir(allocator, &db, "/test/dir");
    defer {
        for (result) |*session| {
            session.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);

    try std.testing.expectEqualStrings("/test/dir", result[0].session_dir);
    try std.testing.expectEqualStrings("/test/dir", result[1].session_dir);
}

test "get_session_by_dir handles NULL session_dir" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at) VALUES 
        \\('id1', 'session1', 'gpt4', '2024-01-01 10:00:00'),
        \\('id2', 'session2', 'gpt4', '2024-01-01 11:00:00')
    , &[_][]const u8{});

    const result = try session_helpers.GetSessionsByDir(allocator, &db, "/test/dir");
    defer {
        for (result) |*session| {
            session.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// ============================================================================
// GetCurrentAgentBySessionId Tests
// ============================================================================

test "get_current_agent_by_session_id returns defaults when no sessions exist" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    const result = try session_helpers.GetCurrentAgentBySessionId(allocator, &db, "non-existent");
    defer {
        allocator.free(result.agent);
    }

    try std.testing.expectEqualStrings("Agent", result.agent);
    try std.testing.expectEqual(@as(f32, 0.5), result.temperature);
    try std.testing.expect(result.is_thinking == true);
}

test "get_current_agent_by_session_id returns agent state from database" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, agent, temperature, is_thinking) VALUES ('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Hello', 'stop', 'assistant', 'CustomAgent', 0.7, 1)",
        &[_][]const u8{}
    );

    const result = try session_helpers.GetCurrentAgentBySessionId(allocator, &db, "test-session");
    defer {
        allocator.free(result.agent);
    }

    try std.testing.expectEqualStrings("CustomAgent", result.agent);
    try std.testing.expectEqual(@as(f32, 0.7), result.temperature);
    try std.testing.expect(result.is_thinking == true);
}

test "get_current_agent_by_session_id uses most recent entry" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, agent, temperature, is_thinking) VALUES 
        \\('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'First', 'stop', 'assistant', 'OldAgent', 0.3, 0),
        \\('id2', 'test-session', 'gpt-4', '2024-01-01 12:00:00', 'Second', 'stop', 'assistant', 'NewAgent', 0.9, 1)
    , &[_][]const u8{});

    const result = try session_helpers.GetCurrentAgentBySessionId(allocator, &db, "test-session");
    defer {
        allocator.free(result.agent);
    }

    try std.testing.expectEqualStrings("NewAgent", result.agent);
    try std.testing.expectEqual(@as(f32, 0.9), result.temperature);
    try std.testing.expect(result.is_thinking == true);
}

test "get_current_agent_by_session_id handles is_thinking = 0" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role, agent, temperature, is_thinking) VALUES ('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Hello', 'stop', 'assistant', 'Agent', 0.5, 0)",
        &[_][]const u8{}
    );

    const result = try session_helpers.GetCurrentAgentBySessionId(allocator, &db, "test-session");
    defer {
        allocator.free(result.agent);
    }

    try std.testing.expectEqualStrings("Agent", result.agent);
    try std.testing.expectEqual(@as(f32, 0.5), result.temperature);
    try std.testing.expect(result.is_thinking == false);
}

test "get_current_agent_by_session_id defaults NULL values" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try setupTestDb(allocator, &mgr);

    try db.exec(allocator,
        "INSERT INTO llm_history (id, session_id, model, created_at, response_content, finish_reason, role) VALUES ('id1', 'test-session', 'gpt-4', '2024-01-01 10:00:00', 'Hello', 'stop', 'assistant')",
        &[_][]const u8{}
    );

    const result = try session_helpers.GetCurrentAgentBySessionId(allocator, &db, "test-session");
    defer {
        allocator.free(result.agent);
    }

    try std.testing.expectEqualStrings("Agent", result.agent);
    // temperature defaults to 0.2 from COALESCE in SQL
    try std.testing.expectEqual(@as(f32, 0.2), result.temperature);
    // is_thinking defaults to false (0) from database DEFAULT 0
    try std.testing.expect(result.is_thinking == false);
}
