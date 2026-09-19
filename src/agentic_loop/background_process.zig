const std = @import("std");
const root_mod = @import("nalarcore");
const sqlite = root_mod.sqlite;
const process_status = root_mod.helpers.process_status;
const testing = std.testing;

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
    // Cross-platform: kill(pid, 0) on POSIX, OpenProcess(QUERY_LIMITED) on
    // Windows. See src/helpers/process_status.zig for the platform switch.
    // `std.posix.kill` is `@compileError`'d on Windows because `std.c.pid_t`
    // is `*anyopaque` there.
    return process_status.isProcessRunning(@intCast(pid));
}

/// Kill a background process by PID
/// Returns true if killed successfully, false if process doesn't exist or error
pub fn killProcess(pid: u32) bool {
    // The previous implementation tried SIGTERM (15) first and fell back to
    // SIGKILL (9). We send SIGKILL directly via the cross-platform helper
    // (TerminateProcess on Windows is the equivalent of "force kill" — no
    // graceful shutdown path). For graceful shutdown on POSIX, the caller
    // can use std.c.kill(pid, SIGTERM) directly.
    return process_status.killProcess(@intCast(pid));
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

// ─── Background completion message helpers (Task 1) ─────────────────────────
//
// Pure helpers (no DB) used by the Task 2 completion queue: read a finished
// background command's log file with a byte cap, then format the queue
// message envelope the agent will see.
//
// Ownership: every function here returns caller-owned slices. Free with
// `allocator.free` (or `TruncatedLog.free`). No arena memory is freed
// inside — per the per-request arena rule, arena-backed inputs are simply
// borrowed, never freed.

/// Byte cap callers use when reading a background command's log file.
pub const completion_log_cap_bytes: usize = 20 * 1024;

/// Result of `readLogTruncated`. `content` is caller-owned (free with
/// `allocator.free`, or call `free`); `total_bytes` is the full on-disk
/// file size; `truncated` is `total_bytes > cap_bytes` (computed from the
/// file size, NOT from the post-NUL-strip length, so stripping NULs never
/// flips the flag).
pub const TruncatedLog = struct {
    content: []u8,
    total_bytes: usize,
    truncated: bool,

    pub fn free(self: TruncatedLog, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

/// Read up to `cap_bytes` bytes (HEAD — the first bytes of the file) from
/// the log at `log_path`, strip NUL bytes so the content can never break
/// SSE JSON framing, and report the full file size for the truncation
/// suffix.
///
/// Missing file returns `error.FileNotFound` (surfaced by `statFile`;
/// the caller maps it to a not-found marker — nothing is printed here).
/// Empty file returns an empty (allocated) `content` with
/// `truncated == false`.
///
/// Implementation note: `Dir.readFileAlloc` with `.limited(n)` FAILS with
/// `error.StreamTooLong` when the file exceeds the limit (it is a safety
/// cap, not a truncation) — so the head window is read explicitly with
/// `openFile` + `readPositionalAll` (the Zig 0.16 positional-read idiom
/// per `main.zig:writeFileRange`), which yields short reads instead of
/// errors. A short read (file shrank between stat and read) just ends
/// the window early; `total_bytes` still reports the stat size.
pub fn readLogTruncated(
    allocator: std.mem.Allocator,
    io: std.Io,
    log_path: []const u8,
    cap_bytes: usize,
) !TruncatedLog {
    const cwd = std.Io.Dir.cwd();

    // Stat first: yields the total size AND surfaces FileNotFound for a
    // missing log in one syscall. Absolute paths work through cwd()
    // (same as Dir.readFileAlloc / writeFile elsewhere in the codebase).
    const stat = try cwd.statFile(io, log_path, .{});
    const total: usize = stat.size;

    if (total == 0) {
        return .{
            .content = try allocator.alloc(u8, 0),
            .total_bytes = 0,
            .truncated = false,
        };
    }

    const truncated = total > cap_bytes;
    const to_read: usize = @min(total, cap_bytes);

    // Absolute log paths (the production `/tmp/bg_*.log` shape) go
    // through openFileAbsolute; relative paths resolve against cwd().
    const file = if (std.fs.path.isAbsolute(log_path))
        try std.Io.Dir.openFileAbsolute(io, log_path, .{})
    else
        try cwd.openFile(io, log_path, .{});
    defer file.close(io);

    const raw = try allocator.alloc(u8, to_read);
    errdefer allocator.free(raw);
    var filled: usize = 0;
    while (filled < raw.len) {
        const n = try file.readPositionalAll(io, raw[filled..], filled);
        if (n == 0) break; // EOF — file shrank between stat and read.
        filled += n;
    }
    const head = raw[0..filled];
    defer allocator.free(raw);

    // Compact out NUL bytes into an exactly-sized owned slice. The raw
    // buffer is freed via defer; `out` is the caller's to free.
    var kept: usize = 0;
    for (head) |b| {
        if (b != 0) kept += 1;
    }
    const out = try allocator.alloc(u8, kept);
    var i: usize = 0;
    for (head) |b| {
        if (b == 0) continue;
        out[i] = b;
        i += 1;
    }

    return .{
        .content = out,
        .total_bytes = total,
        .truncated = truncated,
    };
}

/// Build the queue message payload for a finished background command.
///
/// The payload is JSON (role stays `user` — the frontend renders
/// background_command rows with the shell tool card instead of the
/// user bubble):
/// ```json
/// {"pid":1234,"command":"sleep 10","stdout":"hello\nworld",
///  "truncated":false,"total_bytes":null,"log_path":null}
/// ```
/// When the log was truncated, `truncated` is `true` and the payload
/// also carries `total_bytes` + `log_path` so the agent knows where
/// the full log lives. `command`, log content, and `log_path` go through
/// the control-char sanitizer; Stringify handles the rest.
pub fn buildCompletionMessage(
    allocator: std.mem.Allocator,
    command: []const u8,
    pid: u32,
    log_content_truncated: []const u8,
    was_truncated: bool,
    total_bytes: usize,
    log_path: []const u8,
) ![]u8 {
    const sanitize = @import("helpers").sanitize_control_chars;
    const inner: []const u8 = if (log_content_truncated.len == 0) "(empty output)" else log_content_truncated;

    const clean_command = try sanitize(allocator, command);
    defer allocator.free(clean_command);
    const clean_stdout = try sanitize(allocator, inner);
    defer allocator.free(clean_stdout);

    if (!was_truncated) {
        return std.json.Stringify.valueAlloc(allocator, .{
            .pid = pid,
            .command = clean_command,
            .stdout = clean_stdout,
            .truncated = false,
            .total_bytes = @as(?usize, null),
            .log_path = @as(?[]const u8, null),
        }, .{});
    }

    const clean_log_path = try sanitize(allocator, log_path);
    defer allocator.free(clean_log_path);
    return std.json.Stringify.valueAlloc(allocator, .{
        .pid = pid,
        .command = clean_command,
        .stdout = clean_stdout,
        .truncated = true,
        .total_bytes = total_bytes,
        .log_path = clean_log_path,
    }, .{});
}

test "buildCompletionMessage renders the JSON payload" {
    const msg = try buildCompletionMessage(testing.allocator, "sleep 10", 1234, "hello\nworld", false, 11, "/tmp/x.log");
    defer testing.allocator.free(msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 1234), obj.get("pid").?.integer);
    try testing.expectEqualStrings("sleep 10", obj.get("command").?.string);
    try testing.expectEqualStrings("hello\nworld", obj.get("stdout").?.string);
    try testing.expect(!obj.get("truncated").?.bool);
    try testing.expect(obj.get("total_bytes").? == .null);
    try testing.expect(obj.get("log_path").? == .null);
}

test "buildCompletionMessage maps empty log content to (empty output)" {
    const msg = try buildCompletionMessage(testing.allocator, "true", 42, "", false, 0, "/tmp/x.log");
    defer testing.allocator.free(msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("(empty output)", parsed.value.object.get("stdout").?.string);
}

test "buildCompletionMessage carries truncation fields when truncated" {
    const msg = try buildCompletionMessage(testing.allocator, "make", 7, "partial", true, 99999, "/tmp/full.log");
    defer testing.allocator.free(msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("truncated").?.bool);
    try testing.expectEqual(@as(i64, 99999), obj.get("total_bytes").?.integer);
    try testing.expectEqualStrings("/tmp/full.log", obj.get("log_path").?.string);
}

test "buildCompletionMessage preserves metacharacters verbatim in JSON strings" {
    const msg = try buildCompletionMessage(testing.allocator, "echo <a>&", 9, "it's \"done\"", false, 12, "/tmp/x.log");
    defer testing.allocator.free(msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("echo <a>&", obj.get("command").?.string);
    try testing.expectEqualStrings("it's \"done\"", obj.get("stdout").?.string);
}

test "readLogTruncated returns FileNotFound for a missing file" {
    const result = readLogTruncated(testing.allocator, testing.io, "/tmp/nalar-bg-test-never-exists-12345.log", 100);
    try testing.expectError(error.FileNotFound, result);
}

test "readLogTruncated roundtrips a small file under cap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "small.log", .data = "hello log" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "small.log" });
    defer testing.allocator.free(path);

    const got = try readLogTruncated(testing.allocator, testing.io, path, 100);
    defer got.free(testing.allocator);
    try testing.expectEqualStrings("hello log", got.content);
    try testing.expectEqual(@as(usize, 9), got.total_bytes);
    try testing.expectEqual(false, got.truncated);
}

test "readLogTruncated truncates a large file at cap (head semantics)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // 300 bytes of 'A' with a distinct head marker.
    var payload: [300]u8 = undefined;
    @memset(&payload, 'A');
    @memcpy(payload[0..4], "HEAD");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.log", .data = &payload });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "big.log" });
    defer testing.allocator.free(path);

    const got = try readLogTruncated(testing.allocator, testing.io, path, 100);
    defer got.free(testing.allocator);
    try testing.expectEqual(@as(usize, 100), got.content.len);
    try testing.expectEqual(@as(usize, 300), got.total_bytes);
    try testing.expectEqual(true, got.truncated);
    // Head: the first bytes are kept.
    try testing.expectEqualStrings("HEAD", got.content[0..4]);
}

test "readLogTruncated strips NUL bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "nul.log", .data = "a\x00b\x00c" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "nul.log" });
    defer testing.allocator.free(path);

    const got = try readLogTruncated(testing.allocator, testing.io, path, 100);
    defer got.free(testing.allocator);
    try testing.expectEqualStrings("abc", got.content);
    // Total reflects the on-disk size (5), truncation flag is size-based.
    try testing.expectEqual(@as(usize, 5), got.total_bytes);
    try testing.expectEqual(false, got.truncated);
}

test "readLogTruncated handles an empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty.log", .data = "" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "empty.log" });
    defer testing.allocator.free(path);

    const got = try readLogTruncated(testing.allocator, testing.io, path, 100);
    defer got.free(testing.allocator);
    try testing.expectEqual(@as(usize, 0), got.content.len);
    try testing.expectEqual(@as(usize, 0), got.total_bytes);
    try testing.expectEqual(false, got.truncated);
}
