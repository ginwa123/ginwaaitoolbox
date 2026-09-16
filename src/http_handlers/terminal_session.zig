//! In-memory PTY session registry for the right-sidebar terminal.
//!
//! Transport is plain REST + poll (no WebSocket, no kabelweb changes):
//!
//!   POST   /api/terminal/sessions            {cwd, shell?, cols?, rows?}
//!   POST   /api/terminal/sessions/:id/input  {data}
//!   GET    /api/terminal/sessions/:id/output?cursor=N
//!   POST   /api/terminal/sessions/:id/resize {cols, rows}
//!   DELETE /api/terminal/sessions/:id
//!
//! Each session owns a real PTY (libc `forkpty`: `pty.h` on Linux,
//! `util.h` on macOS) running the user's shell with the requested cwd.
//! Output accumulates in a capped per-session buffer (256 KiB, oldest
//! dropped first); readers poll with an absolute byte cursor, so a
//! re-mounted frontend resumes without loss or replay.
//!
//! Platform scope: Linux + macOS only. Every other OS gets
//! `error.UnsupportedPlatform` (mapped to 501 by the endpoint files).
//! All libc symbols are declared as `extern "c"` (no `@cImport`, so no
//! header-parse risk on any target) and every reference lives behind a
//! comptime OS gate, so Windows cross-compiles cleanly.
//!
//! SECURITY: the server binds 127.0.0.1 (see main.zig) — localhost is
//! the auth boundary, same as the agent shell tools. `cwd` must be an
//! absolute path to an existing directory; `shell`, when given, must
//! be absolute. No DB, no migration: a server restart drops sessions.

const std = @import("std");
const builtin = @import("builtin");

/// True on the platforms that can host a PTY session.
pub const is_pty_os: bool = switch (builtin.os.tag) {
    .linux, .macos => true,
    else => false,
};

pub const max_sessions: usize = 32;
pub const buffer_cap: usize = 256 * 1024;
pub const default_cols: u16 = 80;
pub const default_rows: u16 = 24;
pub const min_dim: u16 = 2;
pub const max_dim: u16 = 1000;

pub const SessionError = error{
    UnsupportedPlatform,
    InvalidCwd,
    CwdNotDir,
    InvalidShell,
    InvalidSize,
    TooManySessions,
    SessionNotFound,
    SessionExited,
    SpawnFailed,
    WriteFailed,
    ResizeFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------
// libc surface (extern "c" — no headers needed, no @cImport)
// ---------------------------------------------------------------------

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

const PollFd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};

const POLLIN: c_short = 1;
const POLLOUT: c_short = 4;
const WNOHANG: c_int = 1;
const SIGKILL: c_int = 9;

// TIOCSWINSZ: Linux 0x5414, macOS 0x80087467 (_IOW('t', 103, winsize)).
const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
    .macos => 0x80087467,
    else => 0x5414,
};

extern "c" fn forkpty(amaster: *c_int, name: ?[*:0]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, arg: *Winsize) c_int;
extern "c" fn poll(fds: [*]PollFd, nfds: c_uint, timeout: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]?[*:0]const u8) c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;

const Timespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};

// ---------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------

pub const Session = struct {
    id: []u8,
    master_fd: c_int,
    child_pid: c_int,
    cols: u16,
    rows: u16,
    /// Ring-ish output log: `buf` holds the newest bytes, `base` is the
    /// absolute cursor of `buf[0]`, `total` the absolute cursor of the
    /// end. Bytes in [0, base) were dropped by the cap.
    buf: std.ArrayList(u8),
    base: u64,
    total: u64,
    exited: bool,
    exit_code: ?i32,
    mutex: std.atomic.Mutex,
    /// Monotonic last-use stamp (LRU eviction). Touched on every
    /// read/write/resize/create while holding `mutex`.
    last_used: u64,

    /// Raw PTY master fd (for the WS pump's poll loop). Valid until
    /// `destroySession`.
    pub fn masterFd(s: *Session) c_int {
        return s.master_fd;
    }

    /// Current absolute output cursor (for WS attach positioning).
    pub fn totalCursor(s: *Session) u64 {
        mutexLock(&s.mutex);
        defer s.mutex.unlock();
        return s.total;
    }
};

var g_mutex: std.atomic.Mutex = .unlocked;
var g_sessions: std.StringHashMap(*Session) = undefined;
var g_inited: bool = false;
var g_id_counter: u64 = 0;
/// Monotonic clock for LRU stamps (order only, no wall time).
var g_seq: u64 = 0;
/// Live session cap (defaults to max_sessions; tests override).
var g_max_sessions: usize = max_sessions;
const g_alloc = std.heap.c_allocator;

/// Spin-lock acquire (std.atomic.Mutex has no blocking lock() in
/// 0.16 — same tryLock + spinLoopHint pattern as shell.zig).
fn mutexLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

fn registry() *std.StringHashMap(*Session) {
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    if (!g_inited) {
        g_sessions = std.StringHashMap(*Session).init(g_alloc);
        g_inited = true;
    }
    return &g_sessions;
}

/// Look a session up by id. The caller must hold no lock; the returned
/// pointer is valid until `destroySession` runs for it.
pub fn getSession(id: []const u8) ?*Session {    const reg = registry();
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    return reg.get(id);
}

pub fn sessionCount() usize {
    const reg = registry();
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    return reg.count();
}

/// Next LRU stamp (g_mutex-guarded; callers hold a session mutex —
/// lock order is always session-then-global, never the reverse).
fn nextSeq() u64 {
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    g_seq += 1;
    return g_seq;
}

fn sessionCap() usize {
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    return g_max_sessions;
}

/// Test-only session-cap override (returns the previous cap — restore
/// with defer). Lets the eviction test run at cap 2 instead of 32.
pub fn setSessionCapForTest(cap: usize) usize {
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    const prev = g_max_sessions;
    g_max_sessions = cap;
    return prev;
}

/// Kill least-recently-used sessions until count < cap. Called on
/// create so the registry never rejects with TooManySessions in
/// practice (abandoned chat sessions age out instead of blocking new
/// ones). Victim choice reads last_used without the session lock — a
/// torn read only mis-picks the victim, never corrupts state.
fn evictToFit() void {
    if (comptime !is_pty_os) return;
    while (true) {
        const reg = registry();
        mutexLock(&g_mutex);
        // Read g_max_sessions directly: sessionCap() would re-lock.
        if (reg.count() < g_max_sessions) {
            g_mutex.unlock();
            return;
        }
        var victim: ?*Session = null;
        var it = reg.valueIterator();
        while (it.next()) |s| {
            if (victim == null or s.*.last_used < victim.?.last_used) victim = s.*;
        }
        g_mutex.unlock();
        const v = victim orelse return;
        // destroySession re-locks internally. SessionNotFound means a
        // concurrent destroy won the race — stop instead of spinning.
        destroySession(v.id) catch return;
    }
}

// ---------------------------------------------------------------------
// Pure validation (unit-tested, no syscalls)
// ---------------------------------------------------------------------

/// Validate create inputs without touching the OS. `cwd` must be a
/// non-empty absolute path; `cols`/`rows` fall back to defaults when
/// null and must land in [min_dim, max_dim] otherwise.
pub fn validateCreate(cwd: []const u8, cols: ?u16, rows: ?u16) SessionError!struct { cols: u16, rows: u16 } {
    if (cwd.len == 0 or !std.fs.path.isAbsolute(cwd)) return error.InvalidCwd;
    const c = cols orelse default_cols;
    const r = rows orelse default_rows;
    if (c < min_dim or c > max_dim or r < min_dim or r > max_dim) return error.InvalidSize;
    return .{ .cols = c, .rows = r };
}

/// Validate a shell override: empty means "default", otherwise it must
/// be absolute (no PATH lookup, no `sh -c` wrapping — the string is
/// exec'd directly).
pub fn validateShell(shell: ?[]const u8) SessionError!void {
    const s = shell orelse return;
    if (s.len == 0) return;
    if (!std.fs.path.isAbsolute(s)) return error.InvalidShell;
}

/// Parse an output cursor query value: missing/garbage falls back to 0
/// (full replay from the buffer's oldest retained byte).
pub fn parseCursor(raw: ?[]const u8) u64 {
    const s = raw orelse return 0;
    return std.fmt.parseInt(u64, s, 10) catch 0;
}

// ---------------------------------------------------------------------
// Lifecycle (POSIX only — every reference is comptime-gated)
// ---------------------------------------------------------------------

pub const SessionInfo = struct {
    id: []const u8,
    pid: i32,
};

/// Spawn a shell on a fresh PTY. `shell` null/empty selects
/// `$SHELL`, then `/bin/bash`, then `/bin/sh`.
pub fn createSession(io: std.Io, cwd: []const u8, shell: ?[]const u8, cols: ?u16, rows: ?u16) SessionError!SessionInfo {
    if (comptime !is_pty_os) return error.UnsupportedPlatform;
    return createSessionPosix(io, cwd, shell, cols, rows);
}

fn allocId() SessionError![]u8 {
    mutexLock(&g_mutex);
    g_id_counter += 1;
    const n = g_id_counter;
    g_mutex.unlock();
    // Counter-only: unique within the process lifetime, which is the
    // registry's lifetime (no persistence, no cross-process readers).
    return std.fmt.allocPrint(g_alloc, "term-{x}", .{n}) catch return error.OutOfMemory;
}

fn defaultShell() []const u8 {
    // $SHELL via libc (no allocator, no std.posix.getenv in 0.16).
    if (getenv("SHELL")) |s| {
        const span = std.mem.span(s);
        if (span.len > 0 and std.fs.path.isAbsolute(span)) return span;
    }
    return "/bin/bash";
}

fn createSessionPosix(io: std.Io, cwd: []const u8, shell_opt: ?[]const u8, cols_opt: ?u16, rows_opt: ?u16) SessionError!SessionInfo {
    // Empty cwd (fresh standalone chats have no session cwd yet):
    // fall back to the server process cwd, mirroring the agent shell
    // tools' optional-cwd behavior. Never fail closed here — an empty
    // string from the frontend must still yield a working shell.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const eff_cwd: []const u8 = if (cwd.len == 0) blk: {
        const ptr = getcwd(&cwd_buf, cwd_buf.len) orelse return error.CwdNotDir;
        break :blk std.mem.span(ptr);
    } else cwd;

    const dims = try validateCreate(eff_cwd, cols_opt, rows_opt);
    try validateShell(shell_opt);

    // eff_cwd must exist and be a directory (checked before fork so the
    // child never has to report it).
    {
        var dir = std.Io.Dir.openDirAbsolute(io, eff_cwd, .{}) catch return error.CwdNotDir;
        dir.close(io);
    }

    // LRU eviction keeps creates succeeding at cap (abandoned chat
    // sessions age out instead of 429ing new ones).
    evictToFit();

    const shell_path: []const u8 = blk: {
        const s = shell_opt orelse "";
        if (s.len > 0) break :blk s;
        break :blk defaultShell();
    };

    var win = Winsize{ .ws_row = dims.rows, .ws_col = dims.cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    var master: c_int = -1;
    const pid = forkpty(&master, null, null, &win);
    if (pid < 0) return error.SpawnFailed;

    if (pid == 0) {
        // Child: never return. NUL-terminate via stack copies (no
        // allocator use after fork).
        childMain(eff_cwd, shell_path);
    }

    // Parent.
    errdefer {
        _ = kill(pid, SIGKILL);
        _ = close(master);
    }

    const id = try allocId();
    errdefer g_alloc.free(id);

    const session = g_alloc.create(Session) catch return error.OutOfMemory;
    errdefer g_alloc.destroy(session);
    session.* = .{
        .id = id,
        .master_fd = master,
        .child_pid = pid,
        .cols = dims.cols,
        .rows = dims.rows,
        .buf = .empty,
        .base = 0,
        .total = 0,
        .exited = false,
        .exit_code = null,
        .mutex = .unlocked,
        .last_used = nextSeq(),
    };

    const reg = registry();
    mutexLock(&g_mutex);
    reg.put(id, session) catch {
        g_mutex.unlock();
        return error.OutOfMemory;
    };
    g_mutex.unlock();

    return .{ .id = id, .pid = @intCast(pid) };
}

/// Child side of forkpty: chdir, set TERM, exec the shell. Diverges
/// (noreturn) — on any failure `_exit(127)` so the parent observes a
/// clean child exit instead of a hung PTY.
fn childMain(cwd: []const u8, shell_path: []const u8) noreturn {
    // Stack buffers: paths longer than max_path_bytes fail closed.
    var cwd_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var shell_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (cwd.len > std.fs.max_path_bytes or shell_path.len > std.fs.max_path_bytes) _exit(127);
    @memcpy(cwd_buf[0..cwd.len], cwd);
    cwd_buf[cwd.len] = 0;
    @memcpy(shell_buf[0..shell_path.len], shell_path);
    shell_buf[shell_path.len] = 0;

    if (chdir(cwd_buf[0..cwd.len :0]) != 0) _exit(127);
    _ = setenv("TERM", "xterm-256color", 1);
    var argv = [_:null]?[*:0]const u8{ shell_buf[0..shell_path.len :0], null };
    _ = execvp(shell_buf[0..shell_path.len :0], argv[0..]);
    _exit(127);
}

/// Drain newly arrived output into the session buffer and refresh the
/// exit state. Safe to call on every poll; never blocks (zero-timeout
/// `poll()` gates each `read()`).
pub fn drainSession(s: *Session) void {
    if (comptime !is_pty_os) return;
    mutexLock(&s.mutex);
    s.last_used = nextSeq();
    defer s.mutex.unlock();
    drainLocked(s);
    pollExitLocked(s);
}

fn drainLocked(s: *Session) void {
    var pfds = [_]PollFd{.{ .fd = s.master_fd, .events = POLLIN, .revents = 0 }};
    var chunk: [8192]u8 = undefined;
    while (true) {
        if (poll(&pfds, 1, 0) <= 0) return;
        if (pfds[0].revents & POLLIN == 0) return;
        const n = read(s.master_fd, &chunk, chunk.len);
        if (n <= 0) return; // EAGAIN/EIO/closed slave — exit state comes from waitpid.
        appendLocked(s, chunk[0..@intCast(n)]);
    }
}

fn appendLocked(s: *Session, bytes: []const u8) void {
    s.buf.appendSlice(g_alloc, bytes) catch {
        // OOM mid-stream: drop the incoming chunk rather than killing
        // the session; the cursor still advances so readers stay in
        // sync (they observe a gap, not a stall).
        s.total += bytes.len;
        s.base = s.total;
        s.buf.clearRetainingCapacity();
        return;
    };
    s.total += bytes.len;
    if (s.buf.items.len > buffer_cap) {
        const drop = s.buf.items.len - buffer_cap;
        // Ordered drop of the oldest bytes.
        std.mem.copyForwards(u8, s.buf.items[0..s.buf.items.len - drop], s.buf.items[drop..]);
        s.buf.items.len -= drop;
        s.base += drop;
    }
}

/// Non-blocking child reaping. Sets `exited`/`exit_code` exactly once.
fn pollExitLocked(s: *Session) void {
    if (s.exited) return;
    var status: c_int = 0;
    const rc = waitpid(s.child_pid, &status, WNOHANG);
    if (rc <= 0) return;
    s.exited = true;
    s.exit_code = decodeStatus(status);
}

fn decodeStatus(status: c_int) i32 {
    const u: c_uint = @bitCast(status);
    // WIFEXITED: low 7 bits zero. WEXITSTATUS: bits 8..15.
    if ((u & 0x7f) == 0) return @intCast((u >> 8) & 0xff);
    // Signaled: report as a negative signal number (128+SIGKILL
    // shell convention would collide with real exit codes).
    const sig = u & 0x7f;
    if (sig == 0x7f) return -100; // stopped, not exited — shouldn't happen via WNOHANG reap.
    return -@as(i32, @intCast(sig));
}

/// Write input bytes to the PTY master (terminal input = keystrokes).
pub fn writeInput(s: *Session, data: []const u8) SessionError!usize {
    if (comptime !is_pty_os) return error.UnsupportedPlatform;
    mutexLock(&s.mutex);
    s.last_used = nextSeq();
    defer s.mutex.unlock();
    drainLocked(s);
    pollExitLocked(s);
    if (s.exited) return error.SessionExited;
    var off: usize = 0;
    var pfds = [_]PollFd{.{ .fd = s.master_fd, .events = POLLOUT, .revents = 0 }};
    while (off < data.len) {
        if (poll(&pfds, 1, 1000) <= 0) return error.WriteFailed;
        if (pfds[0].revents & POLLOUT == 0) return error.WriteFailed;
        const n = write(s.master_fd, data[off..].ptr, data.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
    return off;
}

pub const OutputSlice = struct {
    data: []const u8,
    cursor: u64,
    exited: bool,
    exit_code: ?i32,
};

/// Read output since `cursor` (absolute). `data` borrows the session
/// buffer — the caller must copy it before the next registry call.
/// Call `drainSession` first (or use `readOutput`, which does).
pub fn sliceOutput(s: *Session, cursor: u64) OutputSlice {
    mutexLock(&s.mutex);
    s.last_used = nextSeq();
    defer s.mutex.unlock();
    const start = @max(cursor, s.base);
    if (start >= s.total) {
        return .{ .data = &.{}, .cursor = s.total, .exited = s.exited, .exit_code = s.exit_code };
    }
    const off = start - s.base;
    return .{
        .data = s.buf.items[off..],
        .cursor = s.total,
        .exited = s.exited,
        .exit_code = s.exit_code,
    };
}

/// Drain + slice in one call (the poll endpoint's primitive).
pub fn readOutput(s: *Session, cursor: u64) OutputSlice {
    if (comptime !is_pty_os) {
        return .{ .data = &.{}, .cursor = cursor, .exited = true, .exit_code = null };
    }
    mutexLock(&s.mutex);
    s.last_used = nextSeq();
    defer s.mutex.unlock();
    drainLocked(s);
    pollExitLocked(s);
    const start = @max(cursor, s.base);
    if (start >= s.total) {
        return .{ .data = &.{}, .cursor = s.total, .exited = s.exited, .exit_code = s.exit_code };
    }
    const off = start - s.base;
    return .{
        .data = s.buf.items[off..],
        .cursor = s.total,
        .exited = s.exited,
        .exit_code = s.exit_code,
    };
}

/// Send SIGWINCH-sized window to the child (TIOCSWINSZ + SIGWINCH is
/// delivered by the kernel on resize).
pub fn resizeSession(s: *Session, cols: u16, rows: u16) SessionError!void {
    if (comptime !is_pty_os) return error.UnsupportedPlatform;
    if (cols < min_dim or cols > max_dim or rows < min_dim or rows > max_dim) return error.InvalidSize;
    mutexLock(&s.mutex);
    s.last_used = nextSeq();
    defer s.mutex.unlock();
    if (s.exited) return error.SessionExited;
    var win = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    if (ioctl(s.master_fd, TIOCSWINSZ, &win) != 0) return error.ResizeFailed;
    s.cols = cols;
    s.rows = rows;
}

/// Kill the child (if running), close the master, drop the session.
pub fn destroySession(id: []const u8) SessionError!void {
    if (comptime !is_pty_os) return error.UnsupportedPlatform;
    const reg = registry();
    mutexLock(&g_mutex);
    const entry = reg.fetchRemove(id) orelse {
        g_mutex.unlock();
        return error.SessionNotFound;
    };
    g_mutex.unlock();
    const s = entry.value;

    mutexLock(&s.mutex);
    s.last_used = nextSeq();
    const already_exited = s.exited;
    s.mutex.unlock();
    if (!already_exited) _ = kill(s.child_pid, SIGKILL);

    // Bounded reap so the child never stays a zombie (50 x 10ms).
    var i: usize = 0;
    var status: c_int = 0;
    while (i < 50) : (i += 1) {
        if (waitpid(s.child_pid, &status, WNOHANG) != 0) break;
        sleepMillis(10);
    }

    _ = close(s.master_fd);
    s.buf.deinit(g_alloc);
    g_alloc.free(s.id);
    g_alloc.destroy(s);
}

fn sleepMillis(ms: u64) void {
    const ts = Timespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = nanosleep(&ts, null);
}

// ---------------------------------------------------------------------
// Inline tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "validateCreate accepts absolute cwd with defaults" {
    const dims = try validateCreate("/tmp", null, null);
    try testing.expectEqual(default_cols, dims.cols);
    try testing.expectEqual(default_rows, dims.rows);
}

test "validateCreate rejects relative/empty cwd and bad sizes" {
    try testing.expectError(error.InvalidCwd, validateCreate("", null, null));
    try testing.expectError(error.InvalidCwd, validateCreate("relative/path", null, null));
    try testing.expectError(error.InvalidSize, validateCreate("/tmp", 1, 24));
    try testing.expectError(error.InvalidSize, validateCreate("/tmp", 80, 1001));
    const dims = try validateCreate("/tmp", 100, 40);
    try testing.expectEqual(@as(u16, 100), dims.cols);
    try testing.expectEqual(@as(u16, 40), dims.rows);
}

test "validateShell rejects relative shells, accepts absolute/empty" {
    try validateShell(null);
    try validateShell("");
    try validateShell("/bin/bash");
    try testing.expectError(error.InvalidShell, validateShell("bash"));
}

test "parseCursor defaults to 0 on missing/garbage" {
    try testing.expectEqual(@as(u64, 0), parseCursor(null));
    try testing.expectEqual(@as(u64, 0), parseCursor(""));
    try testing.expectEqual(@as(u64, 0), parseCursor("nope"));
    try testing.expectEqual(@as(u64, 42), parseCursor("42"));
}

test "decodeStatus maps normal exits and signals" {
    // exit(3): status word 0x0300.
    try testing.expectEqual(@as(i32, 3), decodeStatus(0x0300));
    try testing.expectEqual(@as(i32, 0), decodeStatus(0));
    // Killed by SIGKILL (9): 0x0009 -> -9.
    try testing.expectEqual(@as(i32, -9), decodeStatus(0x0009));
}

test "empty cwd falls back to the server cwd (posix only)" {
    if (comptime !is_pty_os) return error.SkipZigTest;

    const info = try createSession(testing.io, "", "/bin/sh", 80, 24);
    defer destroySession(info.id) catch {};
    const s = getSession(info.id) orelse return error.SessionNotFound;
    _ = s;
}

test "create evicts the LRU session at cap (posix only)" {
    if (comptime !is_pty_os) return error.SkipZigTest;
    const prev_cap = setSessionCapForTest(2);
    defer _ = setSessionCapForTest(prev_cap);

    const a = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24);
    const a_id = try testing.allocator.dupe(u8, a.id);
    defer testing.allocator.free(a_id);
    const b = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24);

    // Touch b so a is unambiguously least-recently-used.
    const sb = getSession(b.id) orelse return error.SessionNotFound;
    _ = readOutput(sb, 0);

    const c = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24);
    defer destroySession(c.id) catch {};

    try testing.expect(getSession(a_id) == null);
    try testing.expect(getSession(b.id) != null);
    try testing.expect(getSession(c.id) != null);
    try testing.expectEqual(@as(usize, 2), sessionCount());

    destroySession(b.id) catch {};
}

test "spawned shell echoes input (posix only)" {
    if (comptime !is_pty_os) return error.SkipZigTest;

    const cwd = "/tmp";
    const info = try createSession(testing.io, cwd, "/bin/sh", 80, 24);
    defer destroySession(info.id) catch {};

    const s = getSession(info.id) orelse return error.SessionNotFound;
    // Give the shell a moment to start, then send a marker.
    sleepMillis(500);
    _ = try writeInput(s, "echo MARKER-7f3a9c\n");

    // Poll for the marker (shell echo + command output).
    var found = false;
    var cursor: u64 = 0;
    var ticks: usize = 0;
    while (ticks < 100) : (ticks += 1) {
        const out = readOutput(s, cursor);
        cursor = out.cursor;
        if (std.mem.indexOf(u8, out.data, "MARKER-7f3a9c") != null) {
            found = true;
            break;
        }
        if (out.exited) break;
        sleepMillis(100);
    }
    try testing.expect(found);
}
