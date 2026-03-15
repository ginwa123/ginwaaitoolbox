const std = @import("std");

pub const BackgroundProcess = struct {
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
    started_at: i64,
    status: []const u8,
};

const sqlite = @import("sqlite.zig");

pub const SqliteBackend = sqlite.SqliteBackend;

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
pub fn getBySession(db: *SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8) ![]BackgroundProcess {
    var rows = try db.query(allocator, "SELECT pid, command, log_path, started_at, status FROM session_background_process WHERE session_id = ?", &.{session_id});
    defer rows.deinit();
    
    var processes = std.ArrayList(BackgroundProcess).init(allocator);
    errdefer {
        for (processes.items) |p| {
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        processes.deinit();
    }
    
    while (try rows.next()) |row| {
        const pid_str = row.values[0];
        const command = row.values[1];
        const log_path = row.values[2];
        const started_at_str = row.values[3];
        const status = row.values[4];
        
        const pid = try std.fmt.parseInt(u32, pid_str, 10);
        const started_at = try std.fmt.parseInt(i64, started_at_str, 10);
        
        try processes.append(.{
            .session_id = session_id,
            .pid = pid,
            .command = try allocator.dupe(u8, command),
            .log_path = try allocator.dupe(u8, log_path),
            .started_at = started_at,
            .status = try allocator.dupe(u8, status),
        });
    }
    
    return processes.toOwnedSlice();
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
pub fn getRunning(db: *SqliteBackend, allocator: std.mem.Allocator) ![]BackgroundProcess {
    var rows = try db.query(allocator, "SELECT session_id, pid, command, log_path, started_at, status FROM session_background_process WHERE status = 'running'", &[_][]const u8{});
    defer rows.deinit();
    
    var processes = std.ArrayList(BackgroundProcess).init(allocator);
    errdefer {
        for (processes.items) |p| {
            allocator.free(p.session_id);
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        processes.deinit();
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
        
        try processes.append(.{
            .session_id = try allocator.dupe(u8, session_id),
            .pid = pid,
            .command = try allocator.dupe(u8, command),
            .log_path = try allocator.dupe(u8, log_path),
            .started_at = started_at,
            .status = try allocator.dupe(u8, status),
        });
    }
    
    return processes.toOwnedSlice();
}

/// Check if a process with the given PID is still running
/// Returns true if process exists, false otherwise
pub fn isProcessRunning(pid: u32) bool {
    // kill(pid, 0) checks if process exists without sending a signal
    // Returns 0 if process exists, -1 if it doesn't (errno ESRCH)
    const result = std.os.kill(@intCast(pid), 0);
    return result == 0;
}

/// Kill a background process by PID
/// Returns true if killed successfully, false if process doesn't exist or error
pub fn killProcess(pid: u32) bool {
    // First try SIGTERM (15)
    const term_result = std.os.kill(@intCast(pid), std.posix.SIGTERM);
    if (term_result == 0) {
        return true;
    }
    // If SIGTERM fails (process doesn't exist), try SIGKILL
    const kill_result = std.os.kill(@intCast(pid), std.posix.SIGKILL);
    return kill_result == 0;
}
