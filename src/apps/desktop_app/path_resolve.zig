// src/apps/desktop_app/path_resolve.zig
//
// Resolves the path to the `nalar` binary at runtime.
//
// Resolution order (first match wins):
//   1. explicit_path (from --nalar-path) — handed through unchanged; the
//      spawn() call will produce a clear error if the file is missing.
//   2. <dir_of_self_exe>/nalar — for bundled distributions where nalar
//      sits next to nalar-desktop.
//   3. Each directory in $PATH, joined with `/nalar`.
//
// Returns null if nothing was found. The caller (main.zig in Chunk 8)
// decides how to handle a missing nalar — usually a clear error and exit.
//
// Zig 0.16 API notes:
//   * `std.fs.accessAbsolute(path, .{})` is the in-fs helper for "does
//     this path exist?" (we use it for the `fileExists` predicate).
//     In 0.16 it's a free function, not a method on `std.fs.Dir`.
//   * `std.os.linux.readlink` returns `usize`; on Linux, a value larger
//     than a sane path length (> 4096) is an error code (the kernel
//     returns `-errno` cast to `usize`). We treat anything > 4096 as
//     an error and propagate error.ReadLinkFailed. macOS/Windows return
//     `error.UnsupportedPlatform` — Chunk 8 can fall back to "." for
//     those platforms if needed.

const std = @import("std");
const builtin = @import("builtin");

const SelfExeError = error{
    ReadLinkFailed,
    UnsupportedPlatform,
    OutOfMemory,
};

/// Resolve the path to the nalar binary. See module doc for the resolution
/// order. Caller owns the returned slice and must `allocator.free` it.
pub fn resolve(
    allocator: std.mem.Allocator,
    explicit_path: ?[]const u8,
    self_exe_path: []const u8,
    path_env: []const u8,
) ?[]u8 {
    // 1. Explicit path from --nalar-path: pass through unchanged. The user
    //    asked for a specific path; if it doesn't exist, the spawn() call
    //    will surface a "file not found" error which is more useful than
    //    silently falling back to PATH lookup. This also lets users point
    //    at a path that doesn't exist yet but will (e.g. a build script
    //    that produces nalar before desktop launches).
    if (explicit_path) |p| {
        return allocator.dupe(u8, p) catch null;
    }

    // 2. Next to self. `self_exe_path` may be an absolute path or a bare
    //    name (e.g. "nalar-desktop" when called with PATH lookup); only
    //    the absolute case is useful.
    if (std.fs.path.isAbsolute(self_exe_path)) {
        const self_dir = std.fs.path.dirname(self_exe_path) orelse ".";
        const candidate = std.fs.path.join(allocator, &.{ self_dir, "nalar" }) catch return null;
        if (fileExists(candidate)) {
            return candidate; // hand off ownership
        }
        allocator.free(candidate);
    }

    // 3. $PATH lookup. tokenizeScalar on ':' is the Unix convention
    //    (PATH is `:`-separated on Linux/macOS, `;`-separated on Windows —
    //    we only run on Unix for v1 so ':' is correct).
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = std.fs.path.join(allocator, &.{ dir, "nalar" }) catch continue;
        if (fileExists(candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    }
    return null;
}

/// Return the absolute path to the running executable. Linux reads
/// `/proc/self/exe` via `readlink(2)`. macOS/Windows are not implemented
/// in this chunk — Chunk 8's main.zig will fall back to "." on those
/// platforms, which causes `resolve()` to skip step 2 and use $PATH.
pub fn selfExePath(allocator: std.mem.Allocator) SelfExeError![]u8 {
    return switch (builtin.os.tag) {
        .linux => linuxSelfExePath(allocator),
        else => return error.UnsupportedPlatform,
    };
}

fn linuxSelfExePath(allocator: std.mem.Allocator) SelfExeError![]u8 {
    // PATH_MAX is 4096 on Linux; 1024 is enough for almost all real
    // installations. If the path is longer, readlink will return -ENAMETOOLONG
    // and we'll surface that as ReadLinkFailed.
    var buf: [4096]u8 = undefined;
    const rc = std.os.linux.readlink("/proc/self/exe", &buf, buf.len);
    // On Linux, readlink returns the number of bytes written, or
    // (cast to usize) -errno. The kernel caps the return at the buffer
    // size, so a value > 4096 means an error occurred.
    if (rc > buf.len) return error.ReadLinkFailed;
    return allocator.dupe(u8, buf[0..rc]) catch return error.OutOfMemory;
}

fn fileExists(path: []const u8) bool {
    // Zig 0.16 removed `std.fs.accessAbsolute`; the new path is
    // `std.Io.Dir.accessAbsolute(io, path, .{})` which requires an io
    // handle. Since `fileExists` is a small local helper used during a
    // pure-CPU path lookup, we use the underlying libc call instead —
    // it's a single `faccessat(2)` syscall and doesn't need io.
    // (faccessat with AT.FDCWD == check accessibility relative to cwd,
    //  which is exactly what we want for an absolute path.)
    // The libc call wants a null-terminated string, so we copy the path
    // into a stack buffer with a trailing NUL. If the path is too long
    // for the buffer, it can't possibly be a real file on this system.
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    // F_OK (== 0) means "file exists" — we don't care about read/write
    // permissions, just whether the path resolves to anything.
    const rc = std.c.faccessat(std.c.AT.FDCWD, &buf, std.c.F_OK, 0);
    return rc == 0;
}
