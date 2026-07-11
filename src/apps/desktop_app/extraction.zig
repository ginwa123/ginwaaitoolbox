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
//   * `std.os.linux.*` syscall wrappers are Linux-only; on macOS they
//     resolve to the wrong syscall number and crash with SIGSYS (macOS
//     kill signal for sandboxed/invalid syscalls). We use the libc
//     wrappers from `std.c` (`std.c.mkdir`, `std.c.open`, `std.c.write`,
//     `std.c.unlinkat`, `std.c.faccessat`, ...) which work on every
//     POSIX-ish target Zig 0.16 supports. The trade-off is we can't
//     use the `std.os.linux.O` struct literal anymore; we OR the
//     individual flag bits together (see `makeOpenFlags`).
//   * For directory iteration in deleteTree, we use `opendir`/`readdir`
//     from libc instead of `getdents64`. getdents64 is Linux-only;
//     readdir's `dirent` struct is platform-specific (Linux puts the
//     name as a NUL-terminated `[256]u8`; macOS uses a separate
//     `namlen: u16` field with `[1024]u8`) so we extract the name
//     through a comptime branch.

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

    // If the path already exists, we're done. `faccessat(FDCWD, path, F_OK)`
    // returns 0 on success, -1 on error (ENOENT for "missing").
    if (std.c.faccessat(std.c.AT.FDCWD, path_z, std.c.F_OK, 0) == 0) return;

    // Recurse on the parent first.
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len < path.len) try makePathAbsolute(parent);
    }

    // Now mkdir this path. EEXIST is fine (a concurrent creator).
    // `std.c.mkdir` returns 0 on success, -1 on error with errno set;
    // we capture errno via `std.c._errno().*` (POSIX) before any
    // other libc call can clobber it.
    if (std.c.mkdir(path_z, 0o755) != 0) {
        // `std.c._errno().*` is a `c_int`; on Linux the matching
        // constant is also a `c_int`, but on macOS `std.c.E` is a
        // tagged enum (`c.darwin.E`) that won't compare directly.
        // Cast both sides to `c_int` to keep the comparison portable.
        const errno_value: c_int = std.c._errno().*;
        const exist_value: c_int = @intFromEnum(std.c.E.EXIST);
        if (errno_value == exist_value) return;
        return error.MkdirFailed;
    }
}

/// Create (or truncate) a file at an absolute path and write the
/// given bytes. Returns nothing on success; on write error the
/// partial file is left on disk (the caller can `deleteTree` to
/// clean up).
fn writeFileAbsolute(path: []const u8, content: []const u8) !void {
    // O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC. `std.posix.O` is a
    // packed struct on macOS and an integer-backed typedef on Linux,
    // and the `open(2)` libc declaration expects exactly that type as
    // its `oflag` argument. Build via named-field initializer so the
    // bit-layout is correct on both targets (the underlying numeric
    // values differ: O_CREAT=0o100 on Linux, 0x200 on macOS).
    const flags: std.posix.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = copyToNull(&path_buf, path);

    const fd = std.c.open(path_z, flags, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.OpenOutFailed;
    defer _ = std.c.close(fd);

    var written: usize = 0;
    while (written < content.len) {
        const n: isize = std.c.write(fd, content[written..].ptr, content.len - written);
        if (n < 0) return error.WriteFailed;
        const n_usize: usize = @intCast(n);
        if (n_usize == 0) return error.WriteFailed;
        written += n_usize;
    }
}

/// `rm -rf` via `opendir` + `readdir` + `unlinkat`. Best-effort: errors
/// are logged but not propagated.
///
/// `getdents64` is Linux-only; on macOS we use the POSIX
/// `opendir`/`readdir` pair which is available on every Unix Zig
/// supports. The `dirent` struct varies by platform — Linux has
/// `name: [256]u8` NUL-terminated, macOS has `namlen: u16` +
/// `name: [1024]u8`. We pick the name accessor via comptime.
fn deleteTreeBestEffort(path: []const u8) void {
    deleteTreeRecursive(path) catch |err| {
        std.log.warn("Failed to clean up temp dir {s}: {s}", .{ path, @errorName(err) });
    };
}

fn deleteTreeRecursive(path: []const u8) !void {
    var dir_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const dir_path_z = copyToNull(&dir_path_buf, path);
    const dir_ptr = std.c.opendir(dir_path_z) orelse return error.OpenDirFailed;
    defer _ = std.c.closedir(dir_ptr);

    // Iterate the entries and recursively delete children. We need
    // a stable scratch buffer to hold the child path "<path>/<name>".
    var child_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;

    while (std.c.readdir(dir_ptr)) |entry_ptr| {
        const entry = entry_ptr;
        // Extract the entry name. Platform branch: on Linux, the
        // dirent's `name` is NUL-terminated; on macOS the `namlen`
        // field gives the length directly (no terminator guaranteed
        // because the kernel writes exactly `namlen` bytes).
        const name: []const u8 = comptime_block: {
            if (builtin.os.tag == .macos) {
                break :comptime_block entry.name[0..entry.namlen];
            } else {
                // Linux + other POSIX: NUL-terminated `name` field.
                break :comptime_block std.mem.sliceTo(&entry.name, 0);
            }
        };

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

            // File type bit is portable (DT_DIR == 4 on every POSIX we
            // care about). On Linux entry.type is u8 directly; on
            // macOS it's also u8. No struct difference at the field
            // level here — only the `name` length access differs.
            const is_dir = entry.type == std.c.DT.DIR;
            if (is_dir) {
                try deleteTreeRecursive(child_path);
            }

            // Remove the leaf (file or empty dir after recursion).
            var leaf_z: [std.fs.max_path_bytes:0]u8 = undefined;
            const leaf_z_ptr = copyToNull(&leaf_z, name);
            if (is_dir) {
                _ = std.c.unlinkat(std.c.AT.FDCWD, leaf_z_ptr, std.c.AT.REMOVEDIR);
            } else {
                _ = std.c.unlinkat(std.c.AT.FDCWD, leaf_z_ptr, 0);
            }
        }
    }

    // Finally rmdir the now-empty directory itself.
    _ = std.c.unlinkat(std.c.AT.FDCWD, dir_path_z, std.c.AT.REMOVEDIR);
}
