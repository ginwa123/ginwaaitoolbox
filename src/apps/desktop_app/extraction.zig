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
//     synchronous flow, raw `std.os.linux.*` syscalls are simpler —
//     they don't need an Io runtime and they're blocking, which is
//     what we want here. This matches the patterns already used in
//     subprocess.zig / path_resolve.zig / subprocess_test.zig.

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
fn makePathAbsolute(path: []const u8) !void {
    if (path.len == 0 or (path.len == 1 and path[0] == '.')) return;

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = copyToNull(&path_buf, path);

    // If the path already exists, we're done.
    const acc_rc = std.os.linux.faccessat(std.os.linux.AT.FDCWD, path_z, 0, 0);
    if (acc_rc == 0) return;

    // Recurse on the parent first.
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len < path.len) try makePathAbsolute(parent);
    }

    // Now mkdir this path. EEXIST is fine (a concurrent creator).
    // The Zig 0.16 `std.os.linux.mkdir` returns `usize`; on failure
    // the value is `-errno` (cast to usize via two's-complement
    // bitcast). We negate back to `isize` and compare against the
    // EEXIST errno number (17) via @intFromEnum.
    const rc = std.os.linux.mkdir(path_z, 0o755);
    if (rc != 0) {
        const rc_signed: isize = @bitCast(rc);
        const errno: usize = @intCast(-rc_signed);
        if (errno == @intFromEnum(std.os.linux.E.EXIST)) return;
        return error.MkdirFailed;
    }
}

/// Create (or truncate) a file at an absolute path and write the
/// given bytes. Returns nothing on success; on write error the
/// partial file is left on disk (the caller can `deleteTree` to
/// clean up).
fn writeFileAbsolute(path: []const u8, content: []const u8) !void {
    // O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    const flags: std.os.linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = copyToNull(&path_buf, path);

    const fd_rc = std.os.linux.open(path_z, flags, 0o644);
    if (fd_rc > std.math.maxInt(i32)) return error.OpenOutFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);

    var written: usize = 0;
    while (written < content.len) {
        const n_rc = std.os.linux.write(fd, content[written..].ptr, content.len - written);
        if (n_rc > std.math.maxInt(usize)) return error.WriteFailed;
        const n: usize = @intCast(n_rc);
        if (n == 0) return error.WriteFailed;
        written += n;
    }
}

/// `rm -rf` via `getdents64` + `unlinkat`. Best-effort: errors are
/// logged but not propagated.
fn deleteTreeBestEffort(path: []const u8) void {
    deleteTreeRecursive(path) catch |err| {
        std.log.warn("Failed to clean up temp dir {s}: {s}", .{ path, @errorName(err) });
    };
}

fn deleteTreeRecursive(path: []const u8) !void {
    // Open the directory (O_DIRECTORY | O_RDONLY | O_CLOEXEC).
    var dir_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const dir_path_z = copyToNull(&dir_path_buf, path);
    const dir_fd_rc = std.os.linux.open(
        dir_path_z,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true },
        0,
    );
    if (dir_fd_rc > std.math.maxInt(i32)) return error.OpenDirFailed;
    const dir_fd: i32 = @intCast(dir_fd_rc);
    defer _ = std.os.linux.close(dir_fd);

    // Iterate the entries and recursively delete children. We need
    // a stable scratch buffer to hold the child path "<path>/<name>".
    var child_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;

    var buf: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const n_rc = std.os.linux.getdents64(dir_fd, &buf, buf.len);
        if (n_rc > std.math.maxInt(usize)) return error.GetDentsFailed;
        const n: usize = @intCast(n_rc);
        if (n == 0) break;

        var pos: usize = 0;
        while (pos < n) {
            const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&buf[pos]);
            const name_ptr: [*]const u8 = &entry.name;
            const reclen_usize: usize = @as(usize, @intCast(entry.reclen));
            const name_offset: usize = @offsetOf(std.os.linux.dirent64, "name");
            const name_max_len: usize = reclen_usize - name_offset;
            const name = std.mem.sliceTo(name_ptr[0..name_max_len], 0);

            // Skip "." and "..".
            if (name.len > 0 and !(name.len == 1 and name[0] == '.') and
                !(name.len == 2 and name[0] == '.' and name[1] == '.'))
            {
                // Build "<path>/<name>" into a stack buffer.
                if (path.len + 1 + name.len >= child_path_buf.len) return error.NameTooLong;
                @memcpy(child_path_buf[0..path.len], path);
                child_path_buf[path.len] = '/';
                @memcpy(child_path_buf[path.len + 1 ..][0..name.len], name);
                const child_path = child_path_buf[0 .. path.len + 1 + name.len];

                if (entry.type == std.os.linux.DT.DIR) {
                    // Recurse, then rmdir.
                    try deleteTreeRecursive(child_path);
                    var child_z: [std.fs.max_path_bytes:0]u8 = undefined;
                    const child_z_ptr = copyToNull(&child_z, child_path);
                    _ = std.os.linux.unlinkat(dir_fd, child_z_ptr, std.os.linux.AT.REMOVEDIR);
                } else {
                    // unlinkat relative to the parent dir.
                    var child_z: [std.fs.max_path_bytes:0]u8 = undefined;
                    const child_z_ptr = copyToNull(&child_z, name);
                    _ = std.os.linux.unlinkat(dir_fd, child_z_ptr, 0);
                }
            }

            pos += entry.reclen;
        }
    }

    // Finally rmdir the now-empty directory itself.
    const rm_rc = std.os.linux.unlinkat(std.os.linux.AT.FDCWD, dir_path_z, std.os.linux.AT.REMOVEDIR);
    _ = rm_rc; // best-effort
}
