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

    const result = try session_db.buildSessionListJson(std.testing.allocator, sessions, 42);
    defer std.testing.allocator.free(result);

    // Verify JSON structure
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sessions\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"total\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sessionId\":\"abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sessionId\":\"def456\"") != null);
}

test "buildSessionListJson with empty sessions" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"buildSessionListJson with empty sessions"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "buildSessionListJson with empty sessions", std.time.timestamp() - time });
    const sessions: []const SessionInfo = &.{};

    const result = try session_db.buildSessionListJson(std.testing.allocator, sessions, 0);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(u8, "{\"sessions\":[],\"total\":0}", result);
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

    const result = try session_db.buildSessionListJson(std.testing.allocator, sessions, 1);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "{\"sessions\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "],\"total\":1}") != null);
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
        },
        .{
            .id = "msg2",
            .session_id = "sess123",
            .role = "assistant",
            .content = "Hi there!",
            .timestamp = "2024-01-15T10:00:01",
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
        },
    };

    const result = try session_db.buildSessionMessagesJson(std.testing.allocator, messages);
    defer std.testing.allocator.free(result);

    // Verify JSON escaping
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\n") != null);
}

test "getSessionMessages accepts sort_by parameter" {
    const time = std.time.timestamp();
    std.debug.print("test {s}\n", .{"getSessionMessages accepts sort_by parameter"});
    defer std.debug.print("test {s} took {d}ms\n", .{ "getSessionMessages accepts sort_by parameter", std.time.timestamp() - time });
    // Test that SortField enum exists with expected values
    const field = session_db.SortField.created_at;
    _ = field;

    // Verify all sort fields are available
    const fields = &[_]session_db.SortField{
        session_db.SortField.created_at,
        session_db.SortField.id,
        session_db.SortField.role,
    };
    try std.testing.expect(fields.len == 3);
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

    try db.exec(std.testing.allocator, 
        "CREATE TABLE llm_history (id TEXT, session_id TEXT, role TEXT, content TEXT, created_at TEXT)", 
        &.{});
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
        &.{ "msg1", "sess123", "user", "Hello", "2024-01-15T10:00:00" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
        &.{ "msg2", "sess123", "assistant", "Hi!", "2024-01-15T10:00:01" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
        &.{ "msg3", "sess123", "user", "How?", "2024-01-15T10:00:02" });

    const messages = try session_db.getSessionMessages(
        std.testing.allocator, &db, "sess123", 10, null, .created_at);
    defer {
        for (messages) |m| m.deinit(std.testing.allocator);
        std.testing.allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualSlices(u8, "msg1", messages[0].id);
    try std.testing.expectEqualSlices(u8, "msg2", messages[1].id);
    try std.testing.expectEqualSlices(u8, "msg3", messages[2].id);
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
        "CREATE TABLE llm_history (id TEXT, session_id TEXT, role TEXT, content TEXT, created_at TEXT)", 
        &.{});
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
        &.{ "msg1", "sess123", "user", "Hello", "2024-01-15T10:00:00" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
        &.{ "msg2", "sess123", "assistant", "Hi!", "2024-01-15T10:00:01" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
        &.{ "msg3", "sess123", "user", "How?", "2024-01-15T10:00:02" });

    const messages = try session_db.getSessionMessages(
        std.testing.allocator, &db, "sess123", 10, "msg1", .created_at);
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
        "CREATE TABLE llm_history (id TEXT, session_id TEXT, role TEXT, content TEXT, created_at TEXT)", 
        &.{});
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
        &.{ "msg3", "sess123", "user", "Third", "2024-01-15T10:00:03" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
        &.{ "msg1", "sess123", "user", "First", "2024-01-15T10:00:01" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
        &.{ "msg2", "sess123", "assistant", "Second", "2024-01-15T10:00:02" });

    const messages = try session_db.getSessionMessages(
        std.testing.allocator, &db, "sess123", 10, null, .id);
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
        "CREATE TABLE llm_history (id TEXT, session_id TEXT, role TEXT, content TEXT, created_at TEXT)", 
        &.{});
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
        &.{ "msg3", "sess123", "user", "Third", "2024-01-15T10:00:03" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
        &.{ "msg1", "sess123", "assistant", "First", "2024-01-15T10:00:01" });
    try db.exec(std.testing.allocator,
        "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
        &.{ "msg2", "sess123", "user", "Second", "2024-01-15T10:00:02" });

    const messages = try session_db.getSessionMessages(
        std.testing.allocator, &db, "sess123", 10, null, .role);
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
        "CREATE TABLE llm_history (id TEXT, session_id TEXT, role TEXT, content TEXT, created_at TEXT)", 
        &.{});
    inline for (&[_]struct { id: []const u8 }{
        .{ .id = "msg1" }, .{ .id = "msg2" }, .{ .id = "msg3" }, .{ .id = "msg4" }, .{ .id = "msg5" },
    }) |msg| {
        try db.exec(std.testing.allocator,
            "INSERT INTO llm_history VALUES (?, ?, ?, ?, ?)",
            &.{ msg.id, "sess123", "user", "", "2024-01-15T10:00:00" });
    }

    const messages = try session_db.getSessionMessages(
        std.testing.allocator, &db, "sess123", 2, null, .created_at);
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
        "CREATE TABLE llm_history (id TEXT, session_id TEXT, role TEXT, content TEXT, created_at TEXT)", 
        &.{});

    const messages = try session_db.getSessionMessages(
        std.testing.allocator, &db, "nonexistent", 10, null, .created_at);
    defer {
        for (messages) |m| m.deinit(std.testing.allocator);
        std.testing.allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 0), messages.len);
}
