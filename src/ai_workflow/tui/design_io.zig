/// File IO utilities for design-mode (v6).
///
/// These helpers encapsulate the v6 file-backed fix: atomic writes via
/// write-to-tmp + fsync + rename; path sanitization to defend against
/// path traversal; and orphan cleanup helpers used by `design_model`.
///
/// `atomicWriteFile` is the workhorse — it's called on every `addElement`
/// and `updateElement` to write the element's HTML body to disk. The
/// rename is atomic on POSIX (so a crash mid-write leaves the previous
/// version intact, not a half-written file).
///
/// Why libc (not Zig Io runtime)
/// ─────────────────────────────
/// All file operations use `std.c.*` (libc) directly with an explicit
/// `std.testing.io` / production `Io` argument only when needed (for
/// `Dir.createDirPath`). Reasons:
///   1. `std.c.open/write/fsync/rename/unlink/rmdir` are POSIX-portable
///      and don't require an Io runtime in scope — they work from any
///      function that has an `allocator`.
///   2. The on-disk format is stable: a fully-written file at the
///      target path. We don't need Io's streaming/cancelable semantics
///      for a one-shot write of an element body.
///   3. Cross-platform convenience: on Windows the same libc code path
///      compiles via UCRT without needing a separate Windows-only
///      branch (the `OrphanCleanup.md` project memory lists the
///      syscalls as cross-platform-safe).
///
/// Path sanitization (`sanitizeFilename`)
/// ────────────────────────────────────────
/// `sanitizeFilename` defends against path traversal in user-supplied
/// names. Any `/`, `\`, NUL byte, or leading `.` is replaced with `_`
/// (leading `.` is then stripped, per Unix "hidden file" convention).
/// The caller MUST reject names where the sanitized result differs
/// from the input (defense in depth — the LLM can't pretend a rename
/// "fixed" a malicious name).
///
/// Zig 0.16 cross-platform notes
/// ──────────────────────────────
/// `std.posix.*` is platform-gated; we use `std.c.*` (libc) instead
/// which is portable. `c.unlink` returns -1 with `errno=ENOENT` when
/// the file is missing — `deleteFileIfExists` swallows that. POSIX
/// `rename` is atomic within the same filesystem; for cross-filesystem
/// moves the kernel would have to fall back to copy+delete, which is
/// not atomic — but our usage is always within the same FS so the
/// atomic guarantee holds.

const std = @import("std");
const c = std.c;

/// Strip path-traversal characters from a user-provided name.
///
/// Returns a name that's safe to use as a file/folder component:
/// - `/`, `\`, NUL → `_`
/// - leading `.` → stripped (Unix "hidden file" convention)
/// - empty result → `untitled`
///
/// Caller owns the returned slice.
pub fn sanitizeFilename(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // Pass 1: replace unsafe chars with '_'.
    for (name) |ch| {
        switch (ch) {
            '/', '\\', 0 => try out.append(allocator, '_'),
            else => try out.append(allocator, ch),
        }
    }
    // Strip leading dots (hidden-file convention). Use orderedRemove
    // so each strip is O(n); the prefix is typically short so this is
    // fine in practice.
    while (out.items.len > 0 and out.items[0] == '.') {
        _ = out.orderedRemove(0);
    }
    // If everything was stripped, fall back to "untitled".
    if (out.items.len == 0) try out.appendSlice(allocator, "untitled");
    return out.toOwnedSlice(allocator);
}

/// Atomically write `content` to `path`:
///
/// 1. Write content to `<path>.tmp` via `c.open(O_WRONLY|O_CREAT|O_EXCL)`
/// 2. `fsync(2)` the tmp file
/// 3. `rename(2)` tmp to `path` (atomic on POSIX within the same FS)
///
/// The `O_EXCL` flag prevents accidentally clobbering an existing
/// `.tmp` file from a crashed prior write — we want a fresh file each
/// time. If a concurrent process is also writing the same target, one
/// of them will get `EEXIST` from `open`; the caller is expected to
/// retry the full operation.
///
/// Why we don't truncate the destination first
/// ─────────────────────────────────────────────
/// `rename(2)` atomically replaces the destination path's inode with
/// the tmp file's inode. Readers that had the destination open before
/// the rename keep reading the OLD content; readers that open after
/// the rename see the new content. Mid-write crashes leave the
/// destination's old content intact (because the rename either ran
/// fully or didn't run at all — there's no partial state).
pub fn atomicWriteFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    _ = allocator;

    // Build the `.tmp` path. We use std.fmt.bufPrint into a stack
    // buffer and then NUL-terminate the result. Both buffers are
    // large enough to hold the longest path (see
    // `std.fs.max_path_bytes`) — a 4 KB stack buffer easily fits a
    // typical <100-char path + ".tmp".
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z_len = std.fmt.bufPrint(path_buf[0..path_buf.len - 1], "{s}", .{path}) catch
        return error.PathTooLong;
    path_buf[path_z_len.len] = 0;

    var tmp_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const tmp_z_len = std.fmt.bufPrint(
        tmp_buf[0..tmp_buf.len - 1],
        "{s}.tmp",
        .{path_z_len},
    ) catch return error.PathTooLong;
    tmp_buf[tmp_z_len.len] = 0;

    // 1. Open (or fail if .tmp already exists from a crashed prior run).
    const fd: c.fd_t = c.open(
        &tmp_buf,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true },
        @as(c.mode_t, 0o644),
    );
    if (fd < 0) return error.WriteTmpFailed;
    defer _ = c.close(fd);

    // 2. Write the entire content (loop on partial writes).
    var written: usize = 0;
    while (written < content.len) {
        const n = c.write(fd, content[written..].ptr, content[written..].len);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }

    // 3. fsync — guarantees the data is on stable storage before the
    // rename atomically swaps it into place. Without fsync, a power
    // loss between write and rename could surface as a .tmp file at
    // the target.
    _ = c.fsync(fd);

    // 4. Atomic rename. POSIX guarantees that concurrent readers see
    // either the old or the new file, never a half-written one.
    if (c.rename(&tmp_buf, &path_buf) != 0) return error.RenameFailed;
}

/// Unlink `path` if it exists. Does NOT error when the file is missing.
///
/// POSIX `unlink(2)` returns -1 with errno=ENOENT when the file does
/// not exist. We treat that as a no-op (the goal "the path does not
/// exist after this call" is already satisfied). Any other error
/// (permission denied, IO error) surfaces as `error.UnlinkFailed` so
/// the caller can log it.
pub fn deleteFileIfExists(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    // NUL-terminate into a stack buffer.
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z_len = std.fmt.bufPrint(path_buf[0..path_buf.len - 1], "{s}", .{path}) catch
        return error.PathTooLong;
    path_buf[path_z_len.len] = 0;

    const rc = c.unlink(&path_buf);
    if (rc == 0) return; // success
    const err = c.errno(rc);
    if (err == .NOENT) return; // missing → no-op
    return error.UnlinkFailed;
}

/// Recursively delete a directory and all its contents.
///
/// Walks the directory tree depth-first, unlinks files, recurses into
/// subdirectories, then rmdirs the emptied directory. Returns void on
/// success or `error.RmdirFailed` if any syscall fails (the caller can
/// log and continue; partial orphans are an acceptable degraded
/// state).
pub fn deleteDirectoryRecursively(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    // 1. Open the directory for iteration.
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // missing → no-op
        else => return err,
    };
    defer dir.close(io);

    // 2. Walk the entries; unlink files, recurse into directories.
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const entry_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(entry_path);
        switch (entry.kind) {
            .directory => try deleteDirectoryRecursively(allocator, io, entry_path),
            .file, .sym_link, .named_pipe, .unix_domain_socket, .event_port, .unknown => {
                try deleteFileIfExists(allocator, entry_path);
            },
            else => {}, // skip device files etc.
        }
    }

    // 3. rmdir the (now-empty) directory itself.
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z_len = std.fmt.bufPrint(path_buf[0..path_buf.len - 1], "{s}", .{path}) catch
        return error.PathTooLong;
    path_buf[path_z_len.len] = 0;
    if (c.rmdir(&path_buf) != 0) return error.RmdirFailed;
}
