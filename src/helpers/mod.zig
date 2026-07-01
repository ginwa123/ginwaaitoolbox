pub const xml = @import("xml.zig");
pub const db_path = @import("db_path.zig");
pub const process = @import("process.zig");
pub const process_status = @import("process_status.zig");
pub const random = @import("random.zig");
pub const dir = @import("dir.zig");
pub const sanitize = @import("sanitize.zig");
pub const image = @import("image.zig");
pub const json_value_to_xml = @import("json_value_to_xml.zig").jsonValueToXml;
pub const xml_escape = @import("xml_escape.zig").xmlEscape;

const std = @import("std");
const builtin = @import("builtin");

// === extern "c" declarations ===
// Zig 0.16's `std.c` exposes some libc functions (fopen, fread, fclose,
// access) on all platforms but NOT others (fseek, ftell, faccessat, stat).
// For the missing ones we declare them here as `extern "c"` so the libc
// symbol resolves at link time. They work on Linux, macOS, and Windows
// (via the UCRT, which is what Zig 0.16 links against by default on
// Windows).

/// `int fseek(FILE *stream, long offset, int whence);` (libc).
extern "c" fn fseek(stream: *std.c.FILE, offset: Clong, whence: c_int) c_int;

/// `long ftell(FILE *stream);` (libc).
extern "c" fn ftell(stream: *std.c.FILE) Clong;

/// `int gettimeofday(struct timeval *tv, struct timezone *tz);` (POSIX).
/// On Windows, the UCRT provides this function too.
extern "c" fn gettimeofday(tv: ?*PosixTimeval, tz: ?*anyopaque) c_int;

/// `struct timeval { time_t tv_sec; suseconds_t tv_usec; }` (POSIX/UCRT).
const PosixTimeval = extern struct {
    sec: Clong,
    usec: Clong,
};

/// `long` (C `long`, usually 64-bit on Linux/macOS 64-bit, 32-bit on
/// Windows 64-bit). Matches libc's `long` and `time_t` sizes on all
/// supported platforms. We avoid `std.c.c_long` because it's not
/// exposed in this Zig 0.16 stdlib version.
const Clong = if (@bitSizeOf(usize) == 64 and builtin.os.tag != .windows) i64 else i32;

/// `void GetSystemTimeAsFileTime(LPFILETIME lpSystemTimeAsFileTime);` (Win32).
extern "kernel32" fn GetSystemTimeAsFileTime(lp_system_time_as_file_time: *std.os.windows.FILETIME) callconv(.winapi) void;

/// Cross-platform current working directory getter (no `io: std.Io` required).
///
/// `std.posix.getcwd` was removed in Zig 0.16 — the stdlib replacement
/// (`std.Io.Dir.cwd().realPath(io, &buf)`) requires an `Io` runtime,
/// which many tool/handler call sites don't have. This wrapper uses
/// `std.c.getcwd` (libc) which works on Linux, macOS, and Windows
/// (via the UCRT) without `Io`.
///
/// Returns a slice into `buf` (the caller owns `buf`). Returns null
/// on failure (e.g. cwd has been deleted, or path is too long for `buf`).
pub fn getcwd(buf: []u8) ?[]u8 {
    const result = std.c.getcwd(buf.ptr, buf.len);
    if (result == null) return null;
    // std.c.getcwd writes a NUL-terminated string. Slice up to (but not
    // including) the NUL. If the buffer is somehow full with no NUL,
    // fall back to the full buffer length.
    const p: [*:0]u8 = @ptrCast(result.?);
    const len = std.mem.indexOfScalar(u8, p[0..buf.len], 0) orelse buf.len;
    return p[0..len];
}

/// Returns true if the file at `path` exists.
///
/// `std.fs.accessAbsolute` was REMOVED in Zig 0.16. The stdlib
/// replacement (`std.Io.Dir.accessAbsolute(io, path, .{})`) requires
/// an `Io` runtime, which many call sites don't have. This wrapper
/// uses libc `access(path, F_OK)` (F_OK = 0) which works on Linux,
/// macOS, and Windows (UCRT) without `Io`.
///
/// Returns false for paths longer than `max_path_bytes` (the libc
/// call would also fail in that case; we short-circuit to keep the
/// stack buffer bounded).
pub fn fileExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    // F_OK == 0 (test for existence) — defined in <unistd.h> on POSIX
    // and via UCRT on Windows. We pass 0 directly because std.c.F_OK
    // is only defined for Linux/emscripten.
    const rc = std.c.access(&buf, 0);
    return rc == 0;
}

/// Reads the entire file at `path` into a heap-allocated buffer.
/// Returns the contents (caller must `free`); returns error if the
/// file does not exist or cannot be read.
///
/// `std.fs.cwd().openFile` + `readToEndAlloc` was REMOVED in Zig 0.16
/// (the `std.fs.cwd()` shortcut is gone; the replacement requires
/// `io: std.Io`). This wrapper uses libc `fopen`/`fseek`/`ftell`/
/// `fread`/`fclose` (with `fseek`/`ftell` declared manually since
/// they're not in `std.c` in 0.16) which work on Linux, macOS, and
/// Windows (via the UCRT) without `Io`.
///
/// Why a custom helper rather than passing `io: std.Io` through every
/// caller: the existing lsp_*/Cronjob/etc. callers all take only
/// `allocator` (no `io`); adding `io` is invasive (touches every
/// tool's signature and the agent dispatch path). The libc approach
/// is contained to this one helper.
pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Path must be NUL-terminated for libc fopen. Use a stack buffer
    // (max_path_bytes) to avoid an extra allocation just for the NUL.
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const f = std.c.fopen(&path_buf, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);

    // SEEK_END and SEEK_SET are defined as 2 and 0 respectively on both
    // POSIX and Windows (UCRT). We pass the literal values to avoid
    // pulling in the platform-specific std.c.SEEK_* enum.
    if (fseek(f, 0, 2) != 0) return error.ReadFailed; // SEEK_END = 2
    const size_signed = ftell(f);
    if (size_signed < 0) return error.ReadFailed;
    if (fseek(f, 0, 0) != 0) return error.ReadFailed; // SEEK_SET = 0

    const size: usize = @intCast(size_signed);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    if (size > 0) {
        const n = std.c.fread(buf.ptr, 1, size, f);
        if (n != size) return error.ReadFailed;
    }
    return buf;
}

/// Returns the current Unix timestamp in seconds (i64).
///
/// `std.time.timestamp` was REMOVED in Zig 0.16. The stdlib replacement
/// requires `io: std.Io` (`std.Io.Clock.now(.real, io).toSeconds()`),
/// which many call sites don't have.
///
/// Platform implementation:
/// - **POSIX (Linux/macOS):** libc `gettimeofday` (declared as
///   `extern "c"` since it's not in `std.c` in 0.16). Works on
///   Windows too via UCRT but we use the Win32 path on Windows for
///   better precision.
/// - **Windows:** Win32 `GetSystemTimeAsFileTime` returns a `FILETIME`
///   (100-ns ticks since 1601-01-01). We convert to Unix epoch
///   (1970-01-01) by subtracting the offset and dividing.
pub fn unixTimestamp() i64 {
    return switch (builtin.os.tag) {
        .linux, .macos => unixTimestampPosix(),
        .windows => unixTimestampWindows(),
        else => @compileError("helpers.unixTimestamp: unsupported platform " ++ @tagName(builtin.os.tag)),
    };
}

fn unixTimestampPosix() i64 {
    var tv: PosixTimeval = undefined;
    const rc = gettimeofday(&tv, null);
    _ = rc; // 0 on success, -1 with errno on failure (we ignore — best effort)
    return @intCast(tv.sec);
}

fn unixTimestampWindows() i64 {
    var ft: std.os.windows.FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    // Combine low + high 32 bits into u64 (little-endian on Windows).
    const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
    // 100-ns ticks → seconds: divide by 10_000_000.
    // Then subtract the 1601→1970 offset (11_644_473_600 seconds).
    const seconds_since_1601: u64 = ticks / 10_000_000;
    const unix_offset: u64 = 11_644_473_600;
    if (seconds_since_1601 < unix_offset) return 0;
    return @intCast(seconds_since_1601 - unix_offset);
}

// === Tests ===

test "getcwd: returns non-empty slice on a real system" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = getcwd(&buf) orelse return; // not an error if no cwd
    try std.testing.expect(cwd.len > 0);
}

test "fileExists: /tmp exists" {
    try std.testing.expect(fileExists("/tmp"));
}

test "fileExists: non-existent path returns false" {
    try std.testing.expect(!fileExists("/this/path/does/not/exist/anywhere"));
}

test "readFile: /etc/hostname (linux) or /etc/passwd (fallback)" {
    const allocator = std.testing.allocator;
    // Try /etc/hostname first, then /etc/hosts as fallback
    const content = readFile(allocator, "/etc/hostname") catch
        readFile(allocator, "/etc/hosts") catch return; // skip if neither exists
    defer allocator.free(content);
    try std.testing.expect(content.len > 0);
}

test "unixTimestamp: returns positive value within sane range" {
    const ts = unixTimestamp();
    // 2020-01-01 ≈ 1_577_836_800. Current time should be well above.
    try std.testing.expect(ts > 1_577_836_800);
    // Sanity upper bound: 2100-01-01 ≈ 4_102_444_800.
    try std.testing.expect(ts < 4_102_444_800);
}
