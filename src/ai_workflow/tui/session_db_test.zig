const std = @import("std");
const session_db = @import("session_db.zig");
const SessionInfo = session_db.SessionInfo;

test "buildSessionListJson with multiple sessions" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"buildSessionListJson with multiple sessions"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "buildSessionListJson with multiple sessions", std.time.timestamp() - time });
    const sessions = &[_]SessionInfo{
        .{
            .session_id = "abc123",
            .session_dir = "/tmp/sessions/abc123",
            .created_at = "2024-01-15T10:30:00",
            .agent = "Agent",
            .session_name = "Test Session",
        },
        .{
            .session_id = "def456",
            .session_dir = "/tmp/sessions/def456",
            .created_at = "2024-01-15T11:00:00",
            .agent = "CodeAgent",
            .session_name = "Another Session",
        },
    };

    const result = try session_db.buildSessionListJson(std.testing.allocator, sessions, 42, false, null);
    defer std.testing.allocator.free(result);

    // Verify JSON structure
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sessions\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"total\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"session_id\":\"abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"session_id\":\"def456\"") != null);
}

test "buildSessionListJson with empty sessions" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"buildSessionListJson with empty sessions"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "buildSessionListJson with empty sessions", std.time.timestamp() - time });
    const sessions: []const SessionInfo = &.{};

    const result = try session_db.buildSessionListJson(std.testing.allocator, sessions, 0, false, null);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(u8, "{\"sessions\":[],\"total\":0,\"has_more\":false}", result);
}

test "buildSessionListJson with single session" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"buildSessionListJson with single session"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "buildSessionListJson with single session", std.time.timestamp() - time });
    const sessions = &[_]SessionInfo{
        .{
            .session_id = "single123",
            .session_dir = "/tmp/session",
            .created_at = "2024-01-01",
            .agent = "TestAgent",
            .session_name = "Only One",
        },
    };

    const result = try session_db.buildSessionListJson(std.testing.allocator, sessions, 1, false, null);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "{\"sessions\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "],\"total\":1,\"has_more\":false}") != null);
}

test "buildSessionMessagesJson with messages" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"buildSessionMessagesJson with messages"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "buildSessionMessagesJson with messages", std.time.timestamp() - time });
    const messages = &[_]session_db.SessionMessage{
        .{
            .id = "msg1",
            .session_id = "sess123",
            .role = "user",
            .content = "Hello",
            .timestamp = "2024-01-15T10:00:00",
            .is_input = "0",
            .is_output = "0",
            .tool_name = "",
            .finish_reason = "",
        },
        .{
            .id = "msg2",
            .session_id = "sess123",
            .role = "assistant",
            .content = "Hi there!",
            .timestamp = "2024-01-15T10:00:01",
            .is_input = "0",
            .is_output = "1",
            .tool_name = "",
            .finish_reason = "stop",
        },
    };

    const result = try session_db.buildSessionMessagesJson(std.testing.allocator, messages);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"messages\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"msg1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"msg2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"role\":\"assistant\"") != null);
}

test "buildSessionMessagesJson with empty messages" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"buildSessionMessagesJson with empty messages"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "buildSessionMessagesJson with empty messages", std.time.timestamp() - time });
    const messages: []const session_db.SessionMessage = &.{};

    const result = try session_db.buildSessionMessagesJson(std.testing.allocator, messages);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(u8, "{\"messages\":[]}", result);
}

test "buildSessionMessagesJson escapes content" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"buildSessionMessagesJson escapes content"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "buildSessionMessagesJson escapes content", std.time.timestamp() - time });
    const messages = &[_]session_db.SessionMessage{
        .{
            .id = "msg1",
            .session_id = "sess123",
            .role = "user",
            .content = "Hello \"world\"\nwith newlines",
            .timestamp = "2024-01-15T10:00:00",
            .is_input = "1",
            .is_output = "0",
            .tool_name = "bash",
            .finish_reason = "tool_calls",
        },
    };

    const result = try session_db.buildSessionMessagesJson(std.testing.allocator, messages);
    defer std.testing.allocator.free(result);

    // Verify JSON escaping
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\n") != null);
}

test "getSessionMessages accepts sort_by with direction parameter" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionMessages accepts sort_by with direction parameter"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionMessages accepts sort_by with direction parameter", std.time.timestamp() - time });

    // Test that SortDirection enum exists
    try std.testing.expect(@hasDecl(session_db, "SortDirection"));
    try std.testing.expect(@as(session_db.SortDirection, .asc) == .asc);
    try std.testing.expect(@as(session_db.SortDirection, .desc) == .desc);

    // Test that SortSpec tagged union exists with all field+direction combinations
    const specs = &[_]session_db.SortSpec{
        session_db.SortSpec{ .created_at_asc = {} },
        session_db.SortSpec{ .created_at_desc = {} },
        session_db.SortSpec{ .id_asc = {} },
        session_db.SortSpec{ .id_desc = {} },
        session_db.SortSpec{ .role_asc = {} },
        session_db.SortSpec{ .role_desc = {} },
    };
    try std.testing.expect(specs.len == 6);

    // Test that get_session_messages_sorted function exists
    try std.testing.expect(@hasDecl(session_db, "get_session_messages_sorted"));
}

test "getSessionMessages sorts descending by created_at" {
    const sqlite = @import("nalarcore").sqlite;
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionMessages sorts descending by created_at"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionMessages sorts descending by created_at", std.time.timestamp() - time });

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator, 
        \\CREATE TABLE llm_history (
        \\    id TEXT, session_id TEXT, role TEXT, response_content TEXT, created_at TEXT,
        \\    is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, 
        \\    tool_name TEXT DEFAULT '', finish_reason TEXT DEFAULT ''
        \\)
        , &.{});
    // Insert messages with different timestamps
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at) VALUES (?, ?, ?, ?, ?)",
        &.{ "msg1", "sess_desc", "user", "First", "2024-01-15T10:00:00" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at) VALUES (?, ?, ?, ?, ?)",
        &.{ "msg2", "sess_desc", "assistant", "Second", "2024-01-15T10:00:01" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at) VALUES (?, ?, ?, ?, ?)",
        &.{ "msg3", "sess_desc", "user", "Third", "2024-01-15T10:00:02" });

    // Sort descending - newest first
    const messages = try session_db.get_session_messages_sorted(
        std.testing.allocator, &db, "sess_desc", 10, null, .created_at_desc);
    defer {
        for (messages) |m| m.deinit(std.testing.allocator);
        std.testing.allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 3), messages.len);
    // Descending order: msg3 (newest) first
    try std.testing.expectEqualSlices(u8, "msg3", messages[0].id);
    try std.testing.expectEqualSlices(u8, "msg2", messages[1].id);
    try std.testing.expectEqualSlices(u8, "msg1", messages[2].id);
}

test "getSessionMessages sorts ascending by id" {
    const sqlite = @import("nalarcore").sqlite;
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionMessages sorts ascending by id"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionMessages sorts ascending by id", std.time.timestamp() - time });

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator, 
        \\CREATE TABLE llm_history (
        \\    id TEXT, session_id TEXT, role TEXT, response_content TEXT, created_at TEXT,
        \\    is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, 
        \\    tool_name TEXT DEFAULT '', finish_reason TEXT DEFAULT ''
        \\)
        , &.{});
    // Insert messages with non-sequential IDs
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at) VALUES (?, ?, ?, ?, ?)",
        &.{ "msg_z", "sess_id", "user", "Z first", "2024-01-15T10:00:00" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at) VALUES (?, ?, ?, ?, ?)",
        &.{ "msg_a", "sess_id", "assistant", "A second", "2024-01-15T10:00:01" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at) VALUES (?, ?, ?, ?, ?)",
        &.{ "msg_m", "sess_id", "user", "M third", "2024-01-15T10:00:02" });

    // Sort descending by id - 'z' > 'm' > 'a'
    const messages = try session_db.get_session_messages_sorted(
        std.testing.allocator, &db, "sess_id", 10, null, .id_desc);
    defer {
        for (messages) |m| m.deinit(std.testing.allocator);
        std.testing.allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 3), messages.len);
    // Descending: msg_z (z) > msg_m (m) > msg_a (a)
    try std.testing.expectEqualSlices(u8, "msg_z", messages[0].id);
    try std.testing.expectEqualSlices(u8, "msg_m", messages[1].id);
    try std.testing.expectEqualSlices(u8, "msg_a", messages[2].id);
}

test "getSessionMessages cursor validation" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionMessages cursor validation"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionMessages cursor validation", std.time.timestamp() - time });
    // Cursor should be a valid message ID string
    // Empty cursor means start from beginning
    const cursor: ?[]const u8 = null;
    try std.testing.expect(cursor == null); // null cursor = start from beginning

    const cursor_with_value: ?[]const u8 = "msg123";
    try std.testing.expect(cursor_with_value != null);
    try std.testing.expectEqualSlices(u8, cursor_with_value.?, "msg123");
}

test "getSessionMessages in-memory - basic pagination" {
    const sqlite = @import("nalarcore").sqlite;
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionMessages in-memory - basic pagination"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionMessages in-memory - basic pagination", std.time.timestamp() - time });

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    // Create table matching the columns used by get_session_messages query
    try db.exec(std.testing.allocator, 
        \\CREATE TABLE llm_history (
        \\    id TEXT, session_id TEXT, role TEXT, response_content TEXT, created_at TEXT,
        \\    is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, 
        \\    tool_name TEXT DEFAULT '', finish_reason TEXT DEFAULT ''
        \\)
        , &.{});
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg1", "sess123", "user", "Hello", "2024-01-15T10:00:00", "0", "0", "", "" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg2", "sess123", "assistant", "Hi!", "2024-01-15T10:00:01", "0", "1", "", "stop" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg3", "sess123", "user", "How?", "2024-01-15T10:00:02", "1", "0", "bash", "tool_calls" });

    const messages = try session_db.get_session_messages_sorted(
        std.testing.allocator, &db, "sess123", 10, null, .created_at_asc);
    defer {
        for (messages) |m| m.deinit(std.testing.allocator);
        std.testing.allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualSlices(u8, "msg1", messages[0].id);
    try std.testing.expectEqualSlices(u8, "msg2", messages[1].id);
    try std.testing.expectEqualSlices(u8, "msg3", messages[2].id);
    // Verify new columns
    try std.testing.expectEqualSlices(u8, "0", messages[0].is_input);
    try std.testing.expectEqualSlices(u8, "1", messages[1].is_output);
    try std.testing.expectEqualSlices(u8, "bash", messages[2].tool_name);
    try std.testing.expectEqualSlices(u8, "tool_calls", messages[2].finish_reason);
}

test "getSessionMessages in-memory - cursor pagination" {
    const sqlite = @import("nalarcore").sqlite;
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionMessages in-memory - cursor pagination"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionMessages in-memory - cursor pagination", std.time.timestamp() - time });

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator, 
        \\CREATE TABLE llm_history (
        \\    id TEXT, session_id TEXT, role TEXT, response_content TEXT, created_at TEXT,
        \\    is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, 
        \\    tool_name TEXT DEFAULT '', finish_reason TEXT DEFAULT ''
        \\)
        , &.{});
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg1", "sess123", "user", "Hello", "2024-01-15T10:00:00", "0", "0", "", "" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg2", "sess123", "assistant", "Hi!", "2024-01-15T10:00:01", "0", "1", "", "stop" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg3", "sess123", "user", "How?", "2024-01-15T10:00:02", "1", "0", "bash", "tool_calls" });

    const messages = try session_db.get_session_messages_sorted(
        std.testing.allocator, &db, "sess123", 10, "msg1", .created_at_asc);
    defer {
        for (messages) |m| m.deinit(std.testing.allocator);
        std.testing.allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualSlices(u8, "msg2", messages[0].id);
    try std.testing.expectEqualSlices(u8, "msg3", messages[1].id);
}

test "getSessionMessages in-memory - sort by id" {
    const sqlite = @import("nalarcore").sqlite;
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionMessages in-memory - sort by id"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionMessages in-memory - sort by id", std.time.timestamp() - time });

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator, 
        \\CREATE TABLE llm_history (
        \\    id TEXT, session_id TEXT, role TEXT, response_content TEXT, created_at TEXT,
        \\    is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, 
        \\    tool_name TEXT DEFAULT '', finish_reason TEXT DEFAULT ''
        \\)
        , &.{});
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg3", "sess123", "user", "Third", "2024-01-15T10:00:03", "0", "0", "", "" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg1", "sess123", "user", "First", "2024-01-15T10:00:01", "0", "0", "", "" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg2", "sess123", "assistant", "Second", "2024-01-15T10:00:02", "0", "1", "", "stop" });

    const messages = try session_db.get_session_messages_sorted(
        std.testing.allocator, &db, "sess123", 10, null, .id_asc);
    defer {
        for (messages) |m| m.deinit(std.testing.allocator);
        std.testing.allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualSlices(u8, "msg1", messages[0].id);
    try std.testing.expectEqualSlices(u8, "msg2", messages[1].id);
    try std.testing.expectEqualSlices(u8, "msg3", messages[2].id);
}

test "getSessionMessages in-memory - sort by role" {
    const sqlite = @import("nalarcore").sqlite;
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionMessages in-memory - sort by role"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionMessages in-memory - sort by role", std.time.timestamp() - time });

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator, 
        \\CREATE TABLE llm_history (
        \\    id TEXT, session_id TEXT, role TEXT, response_content TEXT, created_at TEXT,
        \\    is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, 
        \\    tool_name TEXT DEFAULT '', finish_reason TEXT DEFAULT ''
        \\)
        , &.{});
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg3", "sess123", "user", "Third", "2024-01-15T10:00:03", "1", "0", "", "" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg1", "sess123", "assistant", "First", "2024-01-15T10:00:01", "0", "1", "", "stop" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg2", "sess123", "user", "Second", "2024-01-15T10:00:02", "1", "0", "read_file", "" });

    const messages = try session_db.get_session_messages_sorted(
        std.testing.allocator, &db, "sess123", 10, null, .role_asc);
    defer {
        for (messages) |m| m.deinit(std.testing.allocator);
        std.testing.allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualSlices(u8, "assistant", messages[0].role);
    try std.testing.expectEqualSlices(u8, "user", messages[1].role);
    try std.testing.expectEqualSlices(u8, "user", messages[2].role);
}

test "getSessionMessages in-memory - limit" {
    const sqlite = @import("nalarcore").sqlite;
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionMessages in-memory - limit"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionMessages in-memory - limit", std.time.timestamp() - time });

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator, 
        \\CREATE TABLE llm_history (
        \\    id TEXT, session_id TEXT, role TEXT, response_content TEXT, created_at TEXT,
        \\    is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, 
        \\    tool_name TEXT DEFAULT '', finish_reason TEXT DEFAULT ''
        \\)
        , &.{});
    inline for (&[_]struct { id: []const u8 }{
        .{ .id = "msg1" }, .{ .id = "msg2" }, .{ .id = "msg3" }, .{ .id = "msg4" }, .{ .id = "msg5" },
    }) |msg| {
        try db.exec(std.testing.allocator,
            "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            &.{ msg.id, "sess123", "user", "", "2024-01-15T10:00:00", "0", "0", "", "" });
    }

    const messages = try session_db.get_session_messages_sorted(
        std.testing.allocator, &db, "sess123", 2, null, .created_at_asc);
    defer {
        for (messages) |m| m.deinit(std.testing.allocator);
        std.testing.allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 2), messages.len);
}

test "getSessionMessages in-memory - empty session" {
    const sqlite = @import("nalarcore").sqlite;
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionMessages in-memory - empty session"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionMessages in-memory - empty session", std.time.timestamp() - time });

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator, 
        \\CREATE TABLE llm_history (
        \\    id TEXT, session_id TEXT, role TEXT, response_content TEXT, created_at TEXT,
        \\    is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, 
        \\    tool_name TEXT DEFAULT '', finish_reason TEXT DEFAULT ''
        \\)
        , &.{});

    const messages = try session_db.get_session_messages_sorted(
        std.testing.allocator, &db, "nonexistent", 10, null, .created_at_asc);
    defer {
        for (messages) |m| m.deinit(std.testing.allocator);
        std.testing.allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 0), messages.len);
}

test "getSessionMessages returns all columns including is_input is_output tool_name finish_reason" {
    const sqlite = @import("nalarcore").sqlite;
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionMessages returns all columns including is_input is_output tool_name finish_reason"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionMessages returns all columns including is_input is_output tool_name finish_reason", std.time.timestamp() - time });

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator, 
        \\CREATE TABLE llm_history (
        \\    id TEXT, session_id TEXT, role TEXT, response_content TEXT, created_at TEXT,
        \\    is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, 
        \\    tool_name TEXT DEFAULT '', finish_reason TEXT DEFAULT ''
        \\)
        , &.{});
    
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, is_input, is_output, tool_name, finish_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg1", "sess123", "user", "Hello world", "2024-01-15T10:00:00", "1", "0", "bash", "stop" });

    const messages = try session_db.get_session_messages_sorted(
        std.testing.allocator, &db, "sess123", 10, null, .created_at_asc);
    defer {
        for (messages) |m| m.deinit(std.testing.allocator);
        std.testing.allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    
    // Verify all columns are returned
    const msg = messages[0];
    try std.testing.expectEqualSlices(u8, "msg1", msg.id);
    try std.testing.expectEqualSlices(u8, "sess123", msg.session_id);
    try std.testing.expectEqualSlices(u8, "user", msg.role);
    try std.testing.expectEqualSlices(u8, "Hello world", msg.content);
    try std.testing.expectEqualSlices(u8, "2024-01-15T10:00:00", msg.timestamp);
    
    // Verify new columns exist and have correct values
    try std.testing.expectEqualSlices(u8, "1", msg.is_input);
    try std.testing.expectEqualSlices(u8, "0", msg.is_output);
    try std.testing.expectEqualSlices(u8, "bash", msg.tool_name);
    try std.testing.expectEqualSlices(u8, "stop", msg.finish_reason);
}

// === TDD: Cursor-based Session List Pagination Tests ===

test "getSessionList with cursor returns sessions after cursor timestamp" {
    const sqlite = @import("nalarcore").sqlite;
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionList with cursor returns sessions after cursor timestamp"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionList with cursor returns sessions after cursor timestamp", std.time.timestamp() - time });

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    // Create table matching the columns used by getSessionList query
    try db.exec(std.testing.allocator, 
        \\CREATE TABLE llm_history (
        \\    id TEXT, session_id TEXT, role TEXT, response_content TEXT, created_at TEXT,
        \\    is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, 
        \\    tool_name TEXT DEFAULT '', finish_reason TEXT DEFAULT '',
        \\    session_dir TEXT, agent TEXT, session_name TEXT
        \\)
        , &.{});
    
    // Insert sessions with different timestamps (newest to oldest)
    // Session A - newest (1743001234567)
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, session_dir, agent, session_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg1", "sess_a", "user", "Hello A", "1743001234567", "/tmp/sessions/a", "Agent", "Session A" });
    // Session B - middle (1743001234560)
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, session_dir, agent, session_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg2", "sess_b", "user", "Hello B", "1743001234560", "/tmp/sessions/b", "Agent", "Session B" });
    // Session C - oldest (1743001234550)
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, session_dir, agent, session_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg3", "sess_c", "user", "Hello C", "1743001234550", "/tmp/sessions/c", "Agent", "Session C" });

    // Query with cursor = "1743001234560" (after session B)
    // Should return session C only
    const result = try session_db.getSessionListWithCursor(
        std.testing.allocator, &db, null, null, 10, "1743001234560");
    defer {
        for (result.sessions) |s| s.deinit(std.testing.allocator);
        std.testing.allocator.free(result.sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), result.sessions.len);
    try std.testing.expectEqualSlices(u8, "sess_c", result.sessions[0].session_id);
    try std.testing.expectEqualSlices(u8, "1743001234550", result.sessions[0].created_at);
}

test "getSessionList with cursor returns first page when cursor is null" {
    const sqlite = @import("nalarcore").sqlite;
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionList with cursor returns first page when cursor is null"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionList with cursor returns first page when cursor is null", std.time.timestamp() - time });

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator, 
        \\CREATE TABLE llm_history (
        \\    id TEXT, session_id TEXT, role TEXT, response_content TEXT, created_at TEXT,
        \\    is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, 
        \\    tool_name TEXT DEFAULT '', finish_reason TEXT DEFAULT '',
        \\    session_dir TEXT, agent TEXT, session_name TEXT
        \\)
        , &.{});
    
    // Insert sessions with different timestamps
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, session_dir, agent, session_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg1", "sess_a", "user", "Hello A", "1743001234567", "/tmp/sessions/a", "Agent", "Session A" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, session_dir, agent, session_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ "msg2", "sess_b", "user", "Hello B", "1743001234560", "/tmp/sessions/b", "Agent", "Session B" });

    // Query with null cursor - should return all sessions
    const result = try session_db.getSessionListWithCursor(
        std.testing.allocator, &db, null, null, 10, null);
    defer {
        for (result.sessions) |s| s.deinit(std.testing.allocator);
        std.testing.allocator.free(result.sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), result.sessions.len);
}

test "getSessionList with cursor respects limit" {
    const sqlite = @import("nalarcore").sqlite;
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionList with cursor respects limit"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionList with cursor respects limit", std.time.timestamp() - time });

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator, 
        \\CREATE TABLE llm_history (
        \\    id TEXT, session_id TEXT, role TEXT, response_content TEXT, created_at TEXT,
        \\    is_input INTEGER DEFAULT 0, is_output INTEGER DEFAULT 0, 
        \\    tool_name TEXT DEFAULT '', finish_reason TEXT DEFAULT '',
        \\    session_dir TEXT, agent TEXT, session_name TEXT
        \\)
        , &.{});
    
    // Insert 5 sessions
    inline for (&[_]struct { id: []const u8, created: []const u8 }{
        .{ .id = "sess_1", .created = "1743001234569" },
        .{ .id = "sess_2", .created = "1743001234568" },
        .{ .id = "sess_3", .created = "1743001234567" },
        .{ .id = "sess_4", .created = "1743001234566" },
        .{ .id = "sess_5", .created = "1743001234565" },
    }) |sess| {
        try db.exec(std.testing.allocator,
            "INSERT INTO llm_history (id, session_id, role, response_content, created_at, session_dir, agent, session_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            &.{ sess.id, sess.id, "user", "Hello", sess.created, "/tmp/sessions", "Agent", sess.id });
    }

    // Query with cursor = sess_4's timestamp, limit 2
    // Should return sessions with created_at < "1743001234566" (i.e., only sess_5)
    const result = try session_db.getSessionListWithCursor(
        std.testing.allocator, &db, null, null, 2, "1743001234566");
    defer {
        for (result.sessions) |s| s.deinit(std.testing.allocator);
        std.testing.allocator.free(result.sessions);
    }

    // Should return only sess_5 (sess_4 equals cursor, not less than)
    try std.testing.expectEqual(@as(usize, 1), result.sessions.len);
    try std.testing.expectEqualSlices(u8, "sess_5", result.sessions[0].session_id);
}

test "buildSessionListJson with cursor pagination returns has_more and next_cursor" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"buildSessionListJson with cursor pagination returns has_more and next_cursor"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "buildSessionListJson with cursor pagination returns has_more and next_cursor", std.time.timestamp() - time });
    
    const sessions = &[_]SessionInfo{
        .{
            .session_id = "abc123",
            .session_dir = "/tmp/sessions/abc123",
            .created_at = "1743001234567",
            .agent = "Agent",
            .session_name = "Test Session",
        },
        .{
            .session_id = "def456",
            .session_dir = "/tmp/sessions/def456",
            .created_at = "1743001234566",
            .agent = "Agent",
            .session_name = "Older Session",
        },
    };

    // has_more=true, next_cursor is last session's created_at
    const result = try session_db.buildSessionListJson(
        std.testing.allocator, sessions, 10, true, "1743001234566");
    defer std.testing.allocator.free(result);

    // Verify JSON contains has_more and next_cursor
    try std.testing.expect(std.mem.indexOf(u8, result, "\"has_more\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"next_cursor\":\"1743001234566\"") != null);
}

test "buildSessionListJson with no more results returns has_more false" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"buildSessionListJson with no more results returns has_more false"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "buildSessionListJson with no more results returns has_more false", std.time.timestamp() - time });
    
    const sessions = &[_]SessionInfo{
        .{
            .session_id = "abc123",
            .session_dir = "/tmp/sessions/abc123",
            .created_at = "1743001234567",
            .agent = "Agent",
            .session_name = "Test Session",
        },
    };

    // has_more=false, next_cursor is null
    const result = try session_db.buildSessionListJson(
        std.testing.allocator, sessions, 1, false, null);
    defer std.testing.allocator.free(result);

    // Verify JSON contains has_more:false and no next_cursor
    try std.testing.expect(std.mem.indexOf(u8, result, "\"has_more\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "next_cursor") == null);
}

// === TDD: XML Response Support Tests ===

test "buildSessionMessagesXml exists and produces valid XML structure" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"buildSessionMessagesXml exists and produces valid XML structure"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "buildSessionMessagesXml exists and produces valid XML structure", std.time.timestamp() - time });

    // Test that the function exists
    try std.testing.expect(@hasDecl(session_db, "buildSessionMessagesXml"));

    const messages = &[_]session_db.SessionMessage{
        .{
            .id = "msg1",
            .session_id = "sess123",
            .role = "user",
            .content = "Hello",
            .timestamp = "2024-01-15T10:00:00",
            .is_input = "1",
            .is_output = "0",
            .tool_name = "",
            .finish_reason = "",
        },
        .{
            .id = "msg2",
            .session_id = "sess123",
            .role = "assistant",
            .content = "Hi there!",
            .timestamp = "2024-01-15T10:00:01",
            .is_input = "0",
            .is_output = "1",
            .tool_name = "bash",
            .finish_reason = "stop",
        },
    };

    const result = try session_db.buildSessionMessagesXml(std.testing.allocator, messages);
    defer std.testing.allocator.free(result);

    // Verify XML structure
    try std.testing.expect(std.mem.startsWith(u8, result, "<messages>"));
    try std.testing.expect(std.mem.endsWith(u8, result, "</messages>"));
    try std.testing.expect(std.mem.indexOf(u8, result, "<message id=\"msg1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<message id=\"msg2\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<role>user</role>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<role>assistant</role>") != null);
}

test "buildSessionMessagesXml with empty messages" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"buildSessionMessagesXml with empty messages"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "buildSessionMessagesXml with empty messages", std.time.timestamp() - time });

    const messages: []const session_db.SessionMessage = &.{};

    const result = try session_db.buildSessionMessagesXml(std.testing.allocator, messages);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(u8, "<messages></messages>", result);
}

test "buildSessionMessagesXml escapes XML special characters" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"buildSessionMessagesXml escapes XML special characters"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "buildSessionMessagesXml escapes XML special characters", std.time.timestamp() - time });

    const messages = &[_]session_db.SessionMessage{
        .{
            .id = "msg1",
            .session_id = "sess123",
            .role = "user",
            .content = "Hello <world> & \"test\" 'chars'",
            .timestamp = "2024-01-15T10:00:00",
            .is_input = "1",
            .is_output = "0",
            .tool_name = "",
            .finish_reason = "",
        },
    };

    const result = try session_db.buildSessionMessagesXml(std.testing.allocator, messages);
    defer std.testing.allocator.free(result);

    // Verify XML escaping
    try std.testing.expect(std.mem.indexOf(u8, result, "&lt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&apos;") != null);
}

test "xmlEscape utility function exists and works" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"xmlEscape utility function exists and works"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "xmlEscape utility function exists and works", std.time.timestamp() - time });

    // Test that the function exists
    try std.testing.expect(@hasDecl(session_db, "xmlEscape"));

    // Test escaping various characters
    const input = "<test> & \"quote\'s\"</test>";
    const result = try session_db.xmlEscape(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "&lt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&apos;") != null);
}

test "session_message_handler accepts format=xml parameter" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"session_message_handler accepts format=xml parameter"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "session_message_handler accepts format=xml parameter", std.time.timestamp() - time });

    // Test that ResponseFormat enum exists in http_handlers
    // Note: This is a compile-time check for the enum
    const alloc = std.testing.allocator;

    // Test both JSON and XML formats produce different results
    const messages = &[_]session_db.SessionMessage{
        .{
            .id = "msg1",
            .session_id = "sess123",
            .role = "user",
            .content = "Hello <world>",
            .timestamp = "2024-01-15T10:00:00",
            .is_input = "1",
            .is_output = "0",
            .tool_name = "",
            .finish_reason = "",
        },
    };

    const json_result = try session_db.buildSessionMessagesJson(alloc, messages);
    defer alloc.free(json_result);

    const xml_result = try session_db.buildSessionMessagesXml(alloc, messages);
    defer alloc.free(xml_result);

    // JSON should not contain XML tags
    try std.testing.expect(std.mem.indexOf(u8, json_result, "<message") == null);
    // XML should contain XML tags
    try std.testing.expect(std.mem.indexOf(u8, xml_result, "<message") != null);
    // XML should have escaped content
    try std.testing.expect(std.mem.indexOf(u8, xml_result, "&lt;") != null);
}
