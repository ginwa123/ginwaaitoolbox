const std = @import("std");
const session_helpers = @import("session_helpers.zig");
const TUIHistory = @import("models.zig").TUIHistory;
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;

test "get_message_latest returns all new columns correctly" {
    std.log.info("get_message_latest returns all new columns correctly", .{});
    defer std.log.info("get_message_latest returns all new columns correctly", .{});
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();

    // Use in-memory database for testing
    try db.init(":memory:");

    // Create table with all columns including new ones
    try db.exec(std.testing.allocator,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_results_json TEXT,
        \\    finish_reason TEXT,
        \\    usage_json TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    role TEXT DEFAULT 'assistant',
        \\    reasoning_content TEXT,
        \\    session_dir TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1,
        \\    agent TEXT DEFAULT 'Agent',
        \\    session_name TEXT,
        \\    loop_index INTEGER DEFAULT 0,
        \\    temperature REAL DEFAULT 0.2,
        \\    is_thinking INTEGER DEFAULT 0,
        \\    parent_session_id TEXT,
        \\    prompt_tokens INTEGER DEFAULT 0,
        \\    completion_tokens INTEGER DEFAULT 0,
        \\    total_tokens INTEGER DEFAULT 0,
        \\    is_input INTEGER DEFAULT 0,
        \\    is_output INTEGER DEFAULT 0,
        \\    tool_name TEXT
        \\)
    , &[_][]const u8{});

    // Insert test record with specific values for new columns
    try db.exec(std.testing.allocator,
        \\INSERT INTO llm_history
        \\    (id, session_id, model, response_content, finish_reason, role,
        \\     tool_calls_json, reasoning_content, agent, session_name, loop_index,
        \\     temperature, is_thinking, parent_session_id, prompt_tokens,
        \\     completion_tokens, total_tokens, is_input, is_output, tool_name, is_feed_to_llm)
        \\VALUES
        \\    ('test-123', 'session-abc', 'gpt-4', 'Hello world', 'stop', 'assistant',
        \\     '{"tools":[]}', 'thinking content', 'Agent', 'Test Session', 5,
        \\     0.7, 1, 'parent-session', 100, 50, 150, 1, 1, 'bash_tool', 1)
    , &[_][]const u8{});

    // Call the function under test
    const result = try session_helpers.get_message_latest(std.testing.allocator, &db, "session-abc");
    try std.testing.expect(result != null);

    var msg = result.?;
    defer msg.deinit(std.testing.allocator);

    // Verify new columns
    try std.testing.expectEqual(@as(f32, 0.7), msg.temperature);
    try std.testing.expect(msg.is_thinking == true);
    try std.testing.expectEqual(@as(u32, 100), msg.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 50), msg.completion_tokens);
    try std.testing.expectEqual(@as(u32, 150), msg.total_tokens);
    try std.testing.expect(msg.is_input == true);
    try std.testing.expect(msg.is_output == true);
    try std.testing.expectEqualStrings("bash_tool", msg.tool_name);
}

test "get_message_latest returns defaults for NULL columns" {
    std.log.info("get_message_latest returns defaults for NULL columns", .{});
    defer std.log.info("get_message_latest returns defaults for NULL columns", .{});
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();

    try db.init(":memory:");

    // Create table with all columns
    try db.exec(std.testing.allocator,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_results_json TEXT,
        \\    finish_reason TEXT,
        \\    usage_json TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    role TEXT DEFAULT 'assistant',
        \\    reasoning_content TEXT,
        \\    session_dir TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1,
        \\    agent TEXT DEFAULT 'Agent',
        \\    session_name TEXT,
        \\    loop_index INTEGER DEFAULT 0,
        \\    temperature REAL DEFAULT 0.2,
        \\    is_thinking INTEGER DEFAULT 0,
        \\    parent_session_id TEXT,
        \\    prompt_tokens INTEGER DEFAULT 0,
        \\    completion_tokens INTEGER DEFAULT 0,
        \\    total_tokens INTEGER DEFAULT 0,
        \\    is_input INTEGER DEFAULT 0,
        \\    is_output INTEGER DEFAULT 0,
        \\    tool_name TEXT
        \\)
    , &[_][]const u8{});

    // Insert record with NULL values for new columns
    try db.exec(std.testing.allocator,
        \\INSERT INTO llm_history
        \\    (id, session_id, model, response_content, finish_reason, is_feed_to_llm)
        \\VALUES
        \\    ('test-null', 'session-null', 'gpt-3.5', 'Response', 'stop', 1)
    , &[_][]const u8{});

    const result = try session_helpers.get_message_latest(std.testing.allocator, &db, "session-null");
    try std.testing.expect(result != null);

    var msg = result.?;
    defer msg.deinit(std.testing.allocator);

    // Verify defaults are used for NULL columns
    try std.testing.expectEqual(@as(f32, 0.2), msg.temperature);
    try std.testing.expect(msg.is_thinking == false);
    try std.testing.expectEqual(@as(u32, 0), msg.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 0), msg.completion_tokens);
    try std.testing.expectEqual(@as(u32, 0), msg.total_tokens);
    try std.testing.expect(msg.is_input == false);
    try std.testing.expect(msg.is_output == false);
    try std.testing.expectEqualStrings("", msg.tool_name);
}

test "get_messages returns multiple records with new columns" {
    std.log.info("get_messages returns multiple records with new columns", .{});
    defer std.log.info("get_messages returns multiple records with new columns", .{});
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();

    try db.init(":memory:");

    // Create table
    try db.exec(std.testing.allocator,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_results_json TEXT,
        \\    finish_reason TEXT,
        \\    usage_json TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    role TEXT DEFAULT 'assistant',
        \\    reasoning_content TEXT,
        \\    session_dir TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1,
        \\    agent TEXT DEFAULT 'Agent',
        \\    session_name TEXT,
        \\    loop_index INTEGER DEFAULT 0,
        \\    temperature REAL DEFAULT 0.2,
        \\    is_thinking INTEGER DEFAULT 0,
        \\    parent_session_id TEXT,
        \\    prompt_tokens INTEGER DEFAULT 0,
        \\    completion_tokens INTEGER DEFAULT 0,
        \\    total_tokens INTEGER DEFAULT 0,
        \\    is_input INTEGER DEFAULT 0,
        \\    is_output INTEGER DEFAULT 0,
        \\    tool_name TEXT
        \\)
    , &[_][]const u8{});

    // Insert two records with different token values
    try db.exec(std.testing.allocator,
        \\INSERT INTO llm_history
        \\    (id, session_id, model, response_content, finish_reason, created_at, is_feed_to_llm,
        \\     prompt_tokens, completion_tokens, total_tokens, tool_name)
        \\VALUES
        \\    ('msg-1', 'multi-session', 'gpt-4', 'First', 'stop', '2024-01-01 10:00:00', 1, 100, 50, 150, 'bash'),
        \\    ('msg-2', 'multi-session', 'gpt-4', 'Second', 'stop', '2024-01-01 10:01:00', 1, 200, 100, 300, 'read_file')
    , &[_][]const u8{});

    const results = try session_helpers.get_messages(std.testing.allocator, &db, "multi-session");
    defer {
        for (results) |*msg| msg.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 2), results.len);

    // Verify first message
    try std.testing.expectEqualStrings("msg-1", results[0].id);
    try std.testing.expectEqual(@as(u32, 100), results[0].prompt_tokens);
    try std.testing.expectEqual(@as(u32, 50), results[0].completion_tokens);
    try std.testing.expectEqual(@as(u32, 150), results[0].total_tokens);
    try std.testing.expectEqualStrings("bash", results[0].tool_name);

    // Verify second message
    try std.testing.expectEqualStrings("msg-2", results[1].id);
    try std.testing.expectEqual(@as(u32, 200), results[1].prompt_tokens);
    try std.testing.expectEqual(@as(u32, 100), results[1].completion_tokens);
    try std.testing.expectEqual(@as(u32, 300), results[1].total_tokens);
    try std.testing.expectEqualStrings("read_file", results[1].tool_name);
}

test "get_message_latest returns null for non-existent session" {
    std.log.info("get_message_latest returns null for non-existent session", .{});
    defer std.log.info("get_message_latest returns null for non-existent session", .{});
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();

    try db.init(":memory:");

    try db.exec(std.testing.allocator,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_results_json TEXT,
        \\    finish_reason TEXT,
        \\    usage_json TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    role TEXT DEFAULT 'assistant',
        \\    reasoning_content TEXT,
        \\    session_dir TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1,
        \\    agent TEXT DEFAULT 'Agent',
        \\    session_name TEXT,
        \\    loop_index INTEGER DEFAULT 0,
        \\    temperature REAL DEFAULT 0.2,
        \\    is_thinking INTEGER DEFAULT 0,
        \\    parent_session_id TEXT,
        \\    prompt_tokens INTEGER DEFAULT 0,
        \\    completion_tokens INTEGER DEFAULT 0,
        \\    total_tokens INTEGER DEFAULT 0,
        \\    is_input INTEGER DEFAULT 0,
        \\    is_output INTEGER DEFAULT 0,
        \\    tool_name TEXT
        \\)
    , &[_][]const u8{});

    const result = try session_helpers.get_message_latest(std.testing.allocator, &db, "non-existent-session");
    try std.testing.expect(result == null);
}
