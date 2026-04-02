const std = @import("std");
const root_mod = @import("nalarcore");
const sqlite = root_mod.sqlite;

pub const ProcessInfo = struct {
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
    started_at: i64,
    status: []const u8,
};

const SqliteBackend = sqlite.SqliteBackend;

/// Save a new background process to the database
pub fn save(db: *SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8, pid: u32, command: []const u8, log_path: []const u8, started_at: i64) !void {
    const pid_str = try std.fmt.allocPrint(allocator, "{}", .{pid});
    defer allocator.free(pid_str);

    const started_at_str = try std.fmt.allocPrint(allocator, "{}", .{started_at});
    defer allocator.free(started_at_str);

    try db.exec(allocator,
        \\INSERT OR REPLACE INTO session_background_process (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, ?, ?, ?, 'running')
    , &.{ session_id, pid_str, command, log_path, started_at_str });
}

/// Get all background processes for a session
pub fn getBySession(db: *SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8) ![]ProcessInfo {
    var rows = try db.query(allocator, "SELECT pid, command, log_path, started_at, status FROM session_background_process WHERE session_id = ?", &.{session_id});
    defer rows.deinit();

    var processes = std.ArrayList(ProcessInfo).empty;
    errdefer {
        for (processes.items) |p| {
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        processes.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const pid_str = row.values[0];
        const command = row.values[1];
        const log_path = row.values[2];
        const started_at_str = row.values[3];
        const status = row.values[4];

        const pid = try std.fmt.parseInt(u32, pid_str, 10);
        const started_at = try std.fmt.parseInt(i64, started_at_str, 10);

        try processes.append(allocator, .{
            .session_id = session_id,
            .pid = pid,
            .command = try allocator.dupe(u8, command),
            .log_path = try allocator.dupe(u8, log_path),
            .started_at = started_at,
            .status = try allocator.dupe(u8, status),
        });
    }

    return processes.toOwnedSlice(allocator);
}

/// Update the status of a background process
pub fn updateStatus(db: *SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8, pid: u32, new_status: []const u8) !void {
    const pid_str = try std.fmt.allocPrint(allocator, "{}", .{pid});
    defer allocator.free(pid_str);

    try db.exec(allocator,
        \\UPDATE session_background_process SET status = ? WHERE session_id = ? AND pid = ?
    , &.{ new_status, session_id, pid_str });
}

/// Delete a background process from the database
pub fn delete(db: *SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8, pid: u32) !void {
    const pid_str = try std.fmt.allocPrint(allocator, "{}", .{pid});
    defer allocator.free(pid_str);

    try db.exec(allocator, "DELETE FROM session_background_process WHERE session_id = ? AND pid = ?", &.{ session_id, pid_str });
}

/// Get all running background processes
pub fn getRunning(db: *SqliteBackend, allocator: std.mem.Allocator) ![]ProcessInfo {
    var rows = try db.query(allocator, "SELECT session_id, pid, command, log_path, started_at, status FROM session_background_process WHERE status = 'running'", &[_][]const u8{});
    defer rows.deinit();

    var processes = std.ArrayList(ProcessInfo).empty;
    errdefer {
        for (processes.items) |p| {
            allocator.free(p.session_id);
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        processes.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const session_id = row.values[0];
        const pid_str = row.values[1];
        const command = row.values[2];
        const log_path = row.values[3];
        const started_at_str = row.values[4];
        const status = row.values[5];

        const pid = try std.fmt.parseInt(u32, pid_str, 10);
        const started_at = try std.fmt.parseInt(i64, started_at_str, 10);

        try processes.append(allocator, .{
            .session_id = try allocator.dupe(u8, session_id),
            .pid = pid,
            .command = try allocator.dupe(u8, command),
            .log_path = try allocator.dupe(u8, log_path),
            .started_at = started_at,
            .status = try allocator.dupe(u8, status),
        });
    }

    return processes.toOwnedSlice(allocator);
}

/// Check if a process with the given PID is still running
/// Returns true if process exists, false otherwise
pub fn isProcessRunning(pid: u32) bool {
    // kill(pid, 0) returns error if process doesn't exist
    std.posix.kill(@intCast(pid), 0) catch return false;
    return true;
}

/// Kill a background process by PID
/// Returns true if killed successfully, false if process doesn't exist or error
pub fn killProcess(pid: u32) bool {
    // Try SIGTERM first (15)
    std.posix.kill(@intCast(pid), 15) catch {
        // If SIGTERM fails, try SIGKILL (9)
        std.posix.kill(@intCast(pid), 9) catch return false;
        return true;
    };
    return true;
}

/// Kill all background processes for a session
/// This is called when a session is cancelled
pub fn killAllForSession(db: *SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8) !void {
    const processes = try getBySession(db, allocator, session_id);
    defer {
        for (processes) |p| {
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        allocator.free(processes);
    }

    for (processes) |p| {
        if (killProcess(p.pid)) {
            // Update status to killed
            try updateStatus(db, allocator, session_id, p.pid, "killed");
        }
    }
}

/// Poll all running processes and update their status
/// Returns the number of processes that changed status
pub fn pollAndUpdateStatus(db: *SqliteBackend, allocator: std.mem.Allocator) !u32 {
    var changed: u32 = 0;

    const processes = try getRunning(db, allocator);
    defer {
        for (processes) |p| {
            allocator.free(p.session_id);
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        allocator.free(processes);
    }

    for (processes) |p| {
        const is_running = isProcessRunning(p.pid);

        if (!is_running) {
            // Process has exited - check the log file for exit status or assume completed
            // For now, we'll mark as 'completed' since we can't easily get exit code
            try updateStatus(db, allocator, p.session_id, p.pid, "completed");
            changed += 1;
        }
    }

    return changed;
}

