const std = @import("std");
const sqlite = @import("nalarcore").sqlite;
const background_process = @import("background_process.zig");

test "background_process module exists" {
    _ = background_process.ProcessInfo;
    _ = background_process.save;
    _ = background_process.getBySession;
    _ = background_process.updateStatus;
    _ = background_process.delete;
    _ = background_process.getRunning;
    _ = background_process.isProcessRunning;
    _ = background_process.killProcess;
    _ = background_process.killAllForSession;
    _ = background_process.pollAndUpdateStatus;
}

test "ProcessInfo struct has correct fields" {
    const info = background_process.ProcessInfo{
        .session_id = "test-session",
        .pid = 12345,
        .command = "test command",
        .log_path = "/tmp/test.log",
        .started_at = 1234567890,
        .status = "running",
    };
    
    try std.testing.expectEqualStrings("test-session", info.session_id);
    try std.testing.expectEqual(@as(u32, 12345), info.pid);
    try std.testing.expectEqualStrings("test command", info.command);
    try std.testing.expectEqualStrings("/tmp/test.log", info.log_path);
    try std.testing.expectEqual(@as(i64, 1234567890), info.started_at);
    try std.testing.expectEqualStrings("running", info.status);
}

test "ProcessInfo with different statuses" {
    const running = background_process.ProcessInfo{
        .session_id = "s1",
        .pid = 1,
        .command = "cmd1",
        .log_path = "log1",
        .started_at = 100,
        .status = "running",
    };
    
    const completed = background_process.ProcessInfo{
        .session_id = "s2",
        .pid = 2,
        .command = "cmd2",
        .log_path = "log2",
        .started_at = 200,
        .status = "completed",
    };
    
    const killed = background_process.ProcessInfo{
        .session_id = "s3",
        .pid = 3,
        .command = "cmd3",
        .log_path = "log3",
        .started_at = 300,
        .status = "killed",
    };
    
    try std.testing.expectEqualStrings("running", running.status);
    try std.testing.expectEqualStrings("completed", completed.status);
    try std.testing.expectEqualStrings("killed", killed.status);
}

test "background_process save and getBySession" {
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

    // Save a background process
    const session_id = "test-session-1";
    const pid: u32 = 12345;
    const command = "sleep 60";
    const log_path = "/tmp/test.log";
    const started_at: i64 = 1234567890;
    
    try background_process.save(&db, allocator, session_id, pid, command, log_path, started_at);
    
    // Get the process back
    const processes = try background_process.getBySession(&db, allocator, session_id);
    defer {
        for (processes) |p| {
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        allocator.free(processes);
    }
    
    try std.testing.expectEqual(@as(usize, 1), processes.len);
    try std.testing.expectEqual(@as(u32, 12345), processes[0].pid);
    try std.testing.expectEqualStrings("sleep 60", processes[0].command);
    try std.testing.expectEqualStrings("/tmp/test.log", processes[0].log_path);
    try std.testing.expectEqualStrings("running", processes[0].status);
}

test "background_process getBySession returns empty for unknown session" {
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

    // Get processes for non-existent session
    const processes = try background_process.getBySession(&db, allocator, "non-existent-session");
    defer {
        for (processes) |p| {
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        allocator.free(processes);
    }
    
    try std.testing.expectEqual(@as(usize, 0), processes.len);
}

test "background_process updateStatus" {
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

    // Save a process
    try background_process.save(&db, allocator, "session-1", 100, "cmd", "/tmp/log", 1000);
    
    // Update status to completed
    try background_process.updateStatus(&db, allocator, "session-1", 100, "completed");
    
    // Verify status changed
    const processes = try background_process.getBySession(&db, allocator, "session-1");
    defer {
        for (processes) |p| {
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        allocator.free(processes);
    }
    
    try std.testing.expectEqualStrings("completed", processes[0].status);
}

test "background_process delete" {
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

    // Save a process
    try background_process.save(&db, allocator, "session-1", 200, "cmd", "/tmp/log", 2000);
    
    // Delete it
    try background_process.delete(&db, allocator, "session-1", 200);
    
    // Verify it's gone
    const processes = try background_process.getBySession(&db, allocator, "session-1");
    defer {
        for (processes) |p| {
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        allocator.free(processes);
    }
    
    try std.testing.expectEqual(@as(usize, 0), processes.len);
}

test "background_process getRunning" {
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

    // Add running processes
    try background_process.save(&db, allocator, "s1", 1, "cmd1", "/tmp/log1", 1000);
    try background_process.save(&db, allocator, "s2", 2, "cmd2", "/tmp/log2", 2000);
    
    // Add completed process
    try background_process.save(&db, allocator, "s3", 3, "cmd3", "/tmp/log3", 3000);
    try background_process.updateStatus(&db, allocator, "s3", 3, "completed");
    
    // Get running processes
    const running = try background_process.getRunning(&db, allocator);
    defer {
        for (running) |p| {
            allocator.free(p.session_id);
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        allocator.free(running);
    }
    
    try std.testing.expectEqual(@as(usize, 2), running.len);
}

test "isProcessRunning with invalid PID" {
    // Use a PID that definitely doesn't exist (0 or negative)
    const result = background_process.isProcessRunning(0);
    try std.testing.expectEqual(false, result);
}

test "killProcess with invalid PID" {
    // Try to kill a PID that doesn't exist - should return false
    const result = background_process.killProcess(0);
    try std.testing.expectEqual(false, result);
}
