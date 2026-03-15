const std = @import("std");
const sqlite = @import("nalarcore").sqlite;
const build_background_process_content = @import("build_background_process_for_agent_prompt.zig");

test "build_background_process_content module exists" {
    _ = build_background_process_content.BuildBackgroundProcessPrompt;
}

test "BuildBackgroundProcessContent returns empty for empty session_id" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    const result = try build_background_process_content.BuildBackgroundProcessPrompt(allocator, &db, "");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "BuildBackgroundProcessContent returns empty when no processes" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Create the table
    try db.exec(allocator,
        \\CREATE TABLE IF NOT EXISTS session_background_process (
        \\    session_id TEXT NOT NULL,
        \\    pid INTEGER NOT NULL,
        \\    command TEXT NOT NULL,
        \\    log_path TEXT NOT NULL,
        \\    started_at INTEGER NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'running',
        \\    PRIMARY KEY (session_id, pid)
        \\)
    , &.{});

    const result = try build_background_process_content.BuildBackgroundProcessPrompt(allocator, &db, "no-processes-session");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "BuildBackgroundProcessContent returns content for running process" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Create the table and insert a process
    try db.exec(allocator,
        \\CREATE TABLE IF NOT EXISTS session_background_process (
        \\    session_id TEXT NOT NULL,
        \\    pid INTEGER NOT NULL,
        \\    command TEXT NOT NULL,
        \\    log_path TEXT NOT NULL,
        \\    started_at INTEGER NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'running',
        \\    PRIMARY KEY (session_id, pid)
        \\)
    , &.{});

    try db.exec(allocator,
        \\INSERT INTO session_background_process (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, ?, ?, ?, ?)
    , &.{ "test-session", "12345", "sleep 60", "/tmp/sleep.log", "1234567890", "running" });

    const result = try build_background_process_content.BuildBackgroundProcessPrompt(allocator, &db, "test-session");
    defer allocator.free(result);

    // Verify the content contains expected parts
    try std.testing.expect(std.mem.indexOf(u8, result, "Running Background Processes") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "PID: 12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Status: running") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Command: `sleep 60`") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Log: /tmp/sleep.log") != null);
}

test "BuildBackgroundProcessContent returns content for multiple processes" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Create the table and insert multiple processes
    try db.exec(allocator,
        \\CREATE TABLE IF NOT EXISTS session_background_process (
        \\    session_id TEXT NOT NULL,
        \\    pid INTEGER NOT NULL,
        \\    command TEXT NOT NULL,
        \\    log_path TEXT NOT NULL,
        \\    started_at INTEGER NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'running',
        \\    PRIMARY KEY (session_id, pid)
        \\)
    , &.{});

    try db.exec(allocator,
        \\INSERT INTO session_background_process (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, ?, ?, ?, ?)
    , &.{ "multi-session", "100", "process1", "/tmp/p1.log", "1000", "running" });

    try db.exec(allocator,
        \\INSERT INTO session_background_process (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, ?, ?, ?, ?)
    , &.{ "multi-session", "200", "process2", "/tmp/p2.log", "2000", "running" });

    const result = try build_background_process_content.BuildBackgroundProcessPrompt(allocator, &db, "multi-session");
    defer allocator.free(result);

    // Should contain both processes
    try std.testing.expect(std.mem.indexOf(u8, result, "PID: 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "PID: 200") != null);
}

test "BuildBackgroundProcessContent returns content for completed process" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Create the table and insert a completed process
    try db.exec(allocator,
        \\CREATE TABLE IF NOT EXISTS session_background_process (
        \\    session_id TEXT NOT NULL,
        \\    pid INTEGER NOT NULL,
        \\    command TEXT NOT NULL,
        \\    log_path TEXT NOT NULL,
        \\    started_at INTEGER NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'running',
        \\    PRIMARY KEY (session_id, pid)
        \\)
    , &.{});

    try db.exec(allocator,
        \\INSERT INTO session_background_process (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, ?, ?, ?, ?)
    , &.{ "completed-session", "999", "done.sh", "/tmp/done.log", "1234567890", "completed" });

    const result = try build_background_process_content.BuildBackgroundProcessPrompt(allocator, &db, "completed-session");
    defer allocator.free(result);

    // Verify status shows completed
    try std.testing.expect(std.mem.indexOf(u8, result, "Status: completed") != null);
}

test "BuildBackgroundProcessContent only shows processes for specified session" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    // Create the table and insert processes for different sessions
    try db.exec(allocator,
        \\CREATE TABLE IF NOT EXISTS session_background_process (
        \\    session_id TEXT NOT NULL,
        \\    pid INTEGER NOT NULL,
        \\    command TEXT NOT NULL,
        \\    log_path TEXT NOT NULL,
        \\    started_at INTEGER NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'running',
        \\    PRIMARY KEY (session_id, pid)
        \\)
    , &.{});

    // Insert for session A
    try db.exec(allocator,
        \\INSERT INTO session_background_process (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, ?, ?, ?, ?)
    , &.{ "session-a", "1", "cmd-a", "/tmp/a.log", "1000", "running" });

    // Insert for session B
    try db.exec(allocator,
        \\INSERT INTO session_background_process (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, ?, ?, ?, ?)
    , &.{ "session-b", "2", "cmd-b", "/tmp/b.log", "2000", "running" });

    // Get for session A only
    const result = try build_background_process_content.BuildBackgroundProcessPrompt(allocator, &db, "session-a");
    defer allocator.free(result);

    // Should contain session A process
    try std.testing.expect(std.mem.indexOf(u8, result, "cmd-a") != null);
    // Should NOT contain session B process
    try std.testing.expect(std.mem.indexOf(u8, result, "cmd-b") == null);
}
