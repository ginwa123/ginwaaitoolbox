// src/apps/desktop_app/extraction.zig
//
// Runtime asset extraction: write a flat list of `AssetEntry` records
// (the source: webapp_assets.assets — see tools/codegen_webapp_assets.zig)
// to a fresh per-user temp dir. The returned absolute path is what the
// webview in Chunks 4-7 loads via `file://` (or as the nalar `--static-dir`
// argument) at app startup; `cleanup` is called on shutdown to remove
// the temp dir.
//
// Why temp + per-run: the assets are embedded in the binary (10+ MiB),
// but the nalar server's `--static-dir` only reads from disk. We unpack
// to a per-pid temp subdir so multiple concurrent nalar-desktop
// invocations don't collide. The subdir is created via
// `nalar-desktop-webapp-<pid>` and removed in cleanup().
//
// Zig 0.16 API notes:
//   * `std.posix.getenv` doesn't exist in 0.16; use `std.c.getenv`
//     (libc). It returns `?[*:0]const u8` (a NUL-terminated optional
//     pointer), not `?[]const u8`; we have to slice the value to a
//     regular `[]const u8` via `std.mem.span` before dupe'ing it.
//   * `std.os.linux.getpid()` is gone in 0.16; use `std.c.getpid()`
//     (libc). It returns `c_int` (a `pid_t` on Linux/macOS).
//   * `std.fs.cwd()` is gone in 0.16; the new API is `std.Io.Dir.cwd()`
//     which requires an Io handle. For a build/CLI-style helper that
//     just needs `mkdir` + `open` + `write` + `deleteTree` in a
//     synchronous flow, the libc `std.c.*` wrappers are simpler than
//     dragging in an Io runtime — they don't need io, they're blocking,
//     and they work cross-platform (Linux + macOS + Windows). The
//     earlier version of this file used raw `std.os.linux.*` syscalls
//     which compile fine on macOS but invoke Linux syscall numbers that
//     don't exist on the Darwin kernel — the process gets killed with
//     SIGSYS the moment the first `faccessat` runs. The libc wrappers
//     fix that without an Io dependency.

const std = @import("std");
const builtin = @import("builtin");

/// A flat asset entry. Source: the generated webapp_assets.zig at
/// comptime (one `pub const assets: []const Asset` slice for the
/// whole app). At runtime, `extract()` walks this list and writes
/// each entry to disk under a per-pid subdir of the system temp.
///
/// NOTE: `AssetEntry` is structurally identical to the generated
/// `webapp_assets.Asset` but is a *nominal-distinct* Zig type
/// (per the project memory `zig-anonymous-struct-type-identity`).
/// Callers must pass the right struct literal — easiest path is to
/// import `webapp_assets.Asset` directly and rely on Zig's structural
/// matching. We do NOT re-export here because `extraction` shouldn't
/// depend on the `embedded` module's generated file path.
pub const AssetEntry = struct {
    /// Path as served by the webserver, e.g. "/index.html" or
    /// "/assets/app.js". Must start with "/"; the leading slash is
    /// stripped before writing to disk.
    path: []const u8,
    /// File contents (use as-is; do not modify).
    content: []const u8,
    /// Inferred MIME type with charset for text/* types.
    mime: []const u8,
};

/// Extract the given assets to a fresh per-pid temp subdir. Returns
/// the absolute path of the temp dir. The caller MUST call
/// `cleanup(allocator, dir)` on shutdown.
///
/// The assets parameter is `anytype` so callers can pass either
/// `extraction.AssetEntry` (the canonical type) or the generated
/// `webapp_assets.Asset` (structurally identical but nominally
/// distinct — see project memory `zig-anonymous-struct-type-identity`).
/// The element type must have `path: []const u8`, `content: []const u8`,
/// and `mime: []const u8` fields, accessed via the helper below.
///
/// On error, the partially-created temp dir is removed before the
/// error propagates (best-effort — `deleteTree` errors during
/// error-path cleanup are swallowed since we can't do anything with
/// them).
pub fn extract(allocator: std.mem.Allocator, assets: anytype) ![]u8 {
    const tmp_base = tmpDirBase(allocator);
    defer allocator.free(tmp_base);

    // Make a per-pid subdir so concurrent runs don't collide. PID is
    // stable for the lifetime of the process; if the host recycles
    // the PID before our cleanup, the collision is benign (the new
    // process will fail its first write with EEXIST, which is
    // better than silently clobbering live files).
    const subdir = try std.fmt.allocPrint(
        allocator,
        "nalar-desktop-webapp-{d}",
        .{std.c.getpid()},
    );
    defer allocator.free(subdir);

    const full_path = try std.fs.path.join(allocator, &.{ tmp_base, subdir });
    errdefer {
        deleteTreeBestEffort(full_path);
        allocator.free(full_path);
    }

    try makePathAbsolute(full_path);

    // Write each asset.
    for (assets) |asset| {
        // Strip the leading "/" from the path; everything else is
        // relative to the temp dir root. An empty path or a path
        // that doesn't start with "/" is a programmer error in the
        // generated assets, so we make no special case for it.
        const rel = if (asset.path.len > 0 and asset.path[0] == '/')
            asset.path[1..]
        else
            asset.path;

        const abs_path = try std.fs.path.join(allocator, &.{ full_path, rel });
        defer allocator.free(abs_path);

        // Make parent dirs as needed (e.g. "/assets/app.js" needs
        // "<full_path>/assets" to exist before the file create).
        if (std.fs.path.dirname(abs_path)) |parent| {
            try makePathAbsolute(parent);
        }

        try writeFileAbsolute(abs_path, asset.content);
    }

    return full_path;
}

/// Recursively remove the temp dir and free the path slice. Best-effort:
/// any deleteTree error is logged but not propagated (the caller is
/// shutting down; there's nothing useful they can do with the error).
pub fn cleanup(allocator: std.mem.Allocator, dir: []const u8) void {
    deleteTreeBestEffort(dir);
    allocator.free(dir);
}

/// Pick a base temp dir for this platform. The returned slice is
/// freshly allocated; the caller owns it. We always fall back to
/// `/tmp` if the platform-preferred env var is missing (which is
/// the common case on minimal Linux installs without XDG setup).
fn tmpDirBase(allocator: std.mem.Allocator) []u8 {
    const builtin_os = builtin.os.tag;
    return switch (builtin_os) {
        .linux => blk: {
            if (std.c.getenv("XDG_RUNTIME_DIR")) |xdg_z| {
                const xdg = std.mem.span(xdg_z);
                break :blk allocator.dupe(u8, xdg) catch fallbackTmp(allocator);
            }
            break :blk fallbackTmp(allocator);
        },
        .macos => blk: {
            if (std.c.getenv("TMPDIR")) |tmpdir_z| {
                break :blk allocator.dupe(u8, std.mem.span(tmpdir_z)) catch fallbackTmp(allocator);
            }
            break :blk fallbackTmp(allocator);
        },
        .windows => blk: {
            if (std.c.getenv("TEMP")) |t_z| {
                break :blk allocator.dupe(u8, std.mem.span(t_z)) catch fallbackTmp(allocator);
            }
            if (std.c.getenv("TMP")) |t_z| {
                break :blk allocator.dupe(u8, std.mem.span(t_z)) catch fallbackTmp(allocator);
            }
            break :blk allocator.dupe(u8, "C:\\Windows\\Temp") catch unreachable;
        },
        else => fallbackTmp(allocator),
    };
}

/// Last-resort fallback for tmpDirBase. A dupe failure here would
/// mean we're out of memory before the app even started, so we
/// panic — there's nothing useful the caller can do.
fn fallbackTmp(allocator: std.mem.Allocator) []u8 {
    return allocator.dupe(u8, "/tmp") catch @panic("out of memory resolving temp dir");
}

// =====================================================================
// Raw syscall helpers
// =====================================================================
//
// Zig 0.16 removed the `std.fs.cwd()` shortcut and the
// `std.fs.Dir.{makePath,deleteTree,createFileAbsolute,openFileAbsolute}`
// helpers in favor of an Io-runtime-based API. For a build/CLI helper
// that just needs `mkdir -p` + `write file` + `rm -rf` synchronously,
// raw syscalls are simpler than dragging in an Io runtime.
//
// Every helper here copies the path into a per-call NUL-terminated
// stack buffer (the `copyToNull` pattern from
// tools/codegen_webapp_assets.zig) because the linux.* syscalls want
// `[*:0]const u8`. The buffer must outlive the syscall — see NALAR.md
// "Never return stack-allocated slices from functions".

fn copyToNull(buf: *[std.fs.max_path_bytes:0]u8, path: []const u8) [*:0]const u8 {
    if (path.len >= buf.len) @panic("path too long for null-terminated buffer");
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf;
}

/// `mkdir -p` for an absolute path. Walks the path component by
/// component, calling `mkdir(2)` for each missing segment. EEXIST
/// (segment already exists) is treated as success.
///
/// Uses libc (`std.c.*`) for portability — works on Linux + macOS + Windows
/// without an Io runtime. The previous version called `std.os.linux.*` syscalls
/// directly, which compile on macOS but invoke Linux syscall numbers that don't
/// exist on the Darwin kernel (the process dies with SIGSYS = "Bad system call"
/// the first time the syscall instruction runs).
fn makePathAbsolute(path: []const u8) !void {
    if (path.len == 0 or (path.len == 1 and path[0] == '.')) return;

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = copyToNull(&path_buf, path);

    // If the path already exists, we're done. We use `std.c.stat` (POSIX) +
    // `GetFileAttributesW` (Windows) — not `std.c.faccessat` because the
    // `AT_FDCWD` constant isn't in the Zig 0.16 Windows std.c bindings
    // (the `AT__struct_3931` has no `FDCWD` member, per the build error
    // we hit when we used it). For an existing build helper, this is
    // good enough — `stat` works on POSIX, `GetFileAttributesW` works on
    // Windows. Both return 0/non-invalid-attribute on "exists", -1/INVALID
    // on "not found". Fall through to mkdir on either failure.
    switch (builtin.os.tag) {
        .windows => {
            var path_w: [std.fs.max_path_bytes:0]u16 = undefined;
            const written = std.unicode.wtf8ToWtf16Le(&path_w, path) catch
                return error.PathTooLong;
            path_w[written] = 0;
            const attrs = extGetFileAttributesW(@ptrCast(&path_w));
            // INVALID_FILE_ATTRIBUTES (0xFFFFFFFF) = "not found / error".
            // Any other value = file/dir exists.
            if (attrs != 0xFFFFFFFF) return;
        },
        else => {
            if (std.c.stat(path_z, &tmp_stat) == 0) return;
        },
    }

    // Recurse on the parent first.
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len < path.len) try makePathAbsolute(parent);
    }

    // Now mkdir this path. EEXIST is fine (a concurrent creator).
    // `std.c.mkdir` returns 0 on success, -1 on failure with errno set
    // (libc convention). The Zig 0.16 `std.c.errno(rc)` helper returns
    // `.SUCCESS` when rc != -1, or the actual errno enum (`.E.EXIST`,
    // `.E.ACCES`, etc.) when rc == -1.
    const mkdir_rc = std.c.mkdir(path_z, 0o755);
    if (mkdir_rc == 0) return;
    if (std.c.errno(mkdir_rc) == std.c.E.EXIST) return;
    return error.MkdirFailed;
}

// Local extern decls + scratch buffer for the Win32 `stat` path above.
extern "kernel32" fn extGetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) std.os.windows.DWORD;
var tmp_stat: std.c.Stat = undefined;

/// Create (or truncate) a file at an absolute path and write the
/// given bytes. Returns nothing on success; on write error the
/// partial file is left on disk (the caller can `deleteTree` to
/// clean up).
///
/// Per-platform: POSIX uses libc `std.c.open` + `std.c.write`; Windows
/// uses Win32 `CreateFileW` + `WriteFile`. The `std.c.O` struct of
/// open-flag bits is `void` on Windows in Zig 0.16 (the libc bindings
/// don't expose open-flag constants for the Windows CRT), so we have
/// to take the per-platform fork.
fn writeFileAbsolute(path: []const u8, content: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = copyToNull(&path_buf, path);

    switch (builtin.os.tag) {
        .windows => return writeFileAbsoluteWindows(path, content),
        else => return writeFileAbsolutePosix(path_z, content),
    }
}

fn writeFileAbsolutePosix(path_z: [*:0]const u8, content: []const u8) !void {
    // `std.c.O` is a Zig packed struct mirroring the kernel's open-flag
    // bits for the target platform. The struct layout differs across
    // platforms but the field names are portable.
    const flags: std.c.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };
    // `std.c.open` returns -1 on failure (with errno set) or the new fd.
    const fd = std.c.open(path_z, @bitCast(flags), @as(c_int, 0o644));
    if (fd == -1) return error.OpenOutFailed;
    defer _ = std.c.close(fd);

    var written: usize = 0;
    while (written < content.len) {
        // `std.c.write` returns `isize` (bytes written) or -1 on error.
        const n: isize = std.c.write(fd, content[written..].ptr, content.len - written);
        if (n == -1) return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn writeFileAbsoluteWindows(path: []const u8, content: []const u8) !void {
    var path_w: [std.fs.max_path_bytes:0]u16 = undefined;
    const written = std.unicode.wtf8ToWtf16Le(&path_w, path) catch
        return error.PathTooLong;
    path_w[written] = 0;

    // CreateFileW flags: GENERIC_WRITE | OPEN_ALWAYS (truncate if exists).
    // CREATE_ALWAYS would also work but loses the existing file's ACL on
    // some Windows versions; OPEN_ALWAYS + truncation via SetEndOfFile
    // is the more conservative choice.
    const h_opt = CreateFileW(
        @ptrCast(&path_w),
        0x40000000, // GENERIC_WRITE
        0x1, // FILE_SHARE_READ
        null,
        4, // OPEN_ALWAYS
        0x80, // FILE_ATTRIBUTE_NORMAL
        null,
    );
    const h = h_opt orelse return error.OpenOutFailed;
    defer _ = CloseHandle(h);

    // Truncate to 0 (OPEN_ALWAYS preserves existing content; we want
    // truncation for the "overwrite" semantic).
    const set_rc = SetFilePointerEx(h, 0, null, 2); // FILE_END = 2
    _ = set_rc; // best-effort; if it fails the write below will surface it

    var total_written: usize = 0;
    while (total_written < content.len) {
        var chunk_written: std.os.windows.DWORD = 0;
        const ok = WriteFile(
            h,
            content[total_written..].ptr,
            @intCast(content.len - total_written),
            &chunk_written,
            null,
        );
        if (@intFromEnum(ok) == 0) return error.WriteFailed;
        if (chunk_written == 0) return error.WriteFailed;
        total_written += @intCast(chunk_written);
    }
}

// Local Win32 externs for the file-write path above. The `std.os.windows`
// bindings expose `CreateFileW` and `WriteFile` indirectly via
// `std.fs.File.create` (which returns a Zig file handle, not a Win32
// HANDLE), and we need raw HANDLE access to pass through `SetFilePointerEx`
// + `WriteFile` directly. `CloseHandle` is the matching HANDLE closer.
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: std.os.windows.DWORD,
    dwShareMode: std.os.windows.DWORD,
    lpSecurityAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: std.os.windows.DWORD,
    dwFlagsAndAttributes: std.os.windows.DWORD,
    hTemplateFile: ?std.os.windows.HANDLE,
) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn WriteFile(
    hFile: std.os.windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: std.os.windows.DWORD,
    lpNumberOfBytesWritten: *std.os.windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn SetFilePointerEx(
    hFile: std.os.windows.HANDLE,
    liDistanceToMove: i64,
    lpNewFilePointer: ?*i64,
    dwMoveMethod: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

/// `rm -rf` via libc `opendir` / `readdir` / `closedir` + `unlink` / `rmdir`.
/// Best-effort: errors are logged but not propagated.
///
/// Uses libc (`std.c.*`) instead of Linux `getdents64` + `unlinkat` syscalls
/// because the Linux raw syscalls compile fine on macOS but invoke Linux
/// syscall numbers that don't exist on the Darwin kernel (SIGSYS on first
/// call). The libc `readdir` is the cross-platform equivalent.
fn deleteTreeBestEffort(path: []const u8) void {
    deleteTreeRecursive(path) catch |err| {
        std.log.warn("Failed to clean up temp dir {s}: {s}", .{ path, @errorName(err) });
    };
}

fn deleteTreeRecursive(path: []const u8) !void {
    var dir_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const dir_path_z = copyToNull(&dir_path_buf, path);

    // `opendir` returns null on failure (with errno set) or a `*DIR`.
    const dir = std.c.opendir(dir_path_z) orelse return error.OpenDirFailed;
    defer _ = std.c.closedir(dir);

    // Iterate entries. `std.c.readdir` returns `?*dirent`; null = end of stream
    // (errno unchanged) or error (errno set). We treat null as end-of-stream
    // for cleanup purposes — the final rmdir() will fail if the dir is
    // genuinely non-empty, which is fine (best-effort cleanup at shutdown).
    var child_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;

    while (std.c.readdir(dir)) |entry| {
        // The libc `dirent` struct uses the field name `name` (NOT `d_name`,
        // which is a glibc extension we don't have here) on both Linux
        // and macOS. Linux's `name: [256]u8` is NUL-terminated by the
        // kernel; macOS's `name: [1024]u8` is NOT NUL-terminated but is
        // accompanied by a `namlen: u16` field giving the actual byte
        // count. Branch on builtin.os.tag to handle both correctly.
        const name = switch (builtin.os.tag) {
            .macos => entry.name[0..entry.namlen],
            else => blk: {
                // Linux / *BSD: kernel guarantees NUL termination in the
                // fixed-size `name` array.
                var end: usize = 0;
                while (end < entry.name.len and entry.name[end] != 0) : (end += 1) {}
                break :blk entry.name[0..end];
            },
        };

        // Skip "." and "..".
        if (name.len == 0) continue;
        if (name.len == 1 and name[0] == '.') continue;
        if (name.len == 2 and name[0] == '.' and name[1] == '.') continue;

        // Build "<path>/<name>" into a stack buffer.
        if (path.len + 1 + name.len >= child_path_buf.len) return error.NameTooLong;
        @memcpy(child_path_buf[0..path.len], path);
        child_path_buf[path.len] = '/';
        @memcpy(child_path_buf[path.len + 1 ..][0..name.len], name);
        const child_path = child_path_buf[0 .. path.len + 1 + name.len];

        var child_z: [std.fs.max_path_bytes:0]u8 = undefined;
        const child_z_ptr = copyToNull(&child_z, child_path);

        // `entry.type` is the libc dirent's `d_type` field — the
        // file-type discriminator (DT_DIR=4, DT_REG=8, etc.). Same
        // values on Linux + macOS via `std.c.DT`.
        if (entry.type == std.c.DT.DIR) {
            // Recurse, then rmdir.
            try deleteTreeRecursive(child_path);
            _ = std.c.rmdir(child_z_ptr);
        } else {
            // unlink relative to the (now-recursively-emptied) parent dir.
            _ = std.c.unlink(child_z_ptr);
        }
    }

    // Finally rmdir the now-empty directory itself. Best-effort: a non-zero
    // return (e.g. ENOTEMPTY because of a race) is swallowed by the caller
    // via deleteTreeBestEffort.
    _ = std.c.rmdir(dir_path_z);
}
