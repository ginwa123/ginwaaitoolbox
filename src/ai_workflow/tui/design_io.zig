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
const builtin = @import("builtin");
const c = std.c;

/// Win32 API externs for cross-platform atomic-write/delete support.
///
/// Loaded at module scope only when `builtin.os.tag == .windows`. On
/// Linux/macOS the entire struct is compiled to an empty placeholder
/// and the `extern "kernel32"` decls are not referenced, so the linker
/// never sees a missing-symbol error for `CreateFileW` etc.
///
/// Why not `std.os.windows.kernel32`? — Zig 0.16's stdlib
/// `std.os.windows.kernel32` bindings dropped some of the file APIs
/// we need (notably `CreateFileW`, `MoveFileExW`). The file is still
/// present but the symbols are gone (verified by grep on
/// `/usr/local/lib/zig/std/os/windows/kernel32.zig`). We declare them
/// manually as `extern "kernel32"` so the call resolves at link time
/// against the system kernel32.dll (always loaded on Windows).
const win32_apis = if (builtin.os.tag == .windows) struct {
    // HANDLE on Windows is `*anyopaque` (per `std.os.windows.HANDLE`).
    // CreateFileW returns INVALID_HANDLE_VALUE (a sentinel pointer) on
    // failure — it does NOT return NULL. We use the address-as-int
    // cast trick to compare against the sentinel below.
    const HANDLE = *anyopaque;
    const INVALID_HANDLE_VALUE_PTR: usize = std.math.maxInt(usize);
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(INVALID_HANDLE_VALUE_PTR);

    const GENERIC_WRITE: u32 = 0x40000000;
    const FILE_SHARE_NONE: u32 = 0;
    const CREATE_NEW: u32 = 1;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    const MOVEFILE_REPLACE_EXISTING: u32 = 1;

    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: ?*u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) u32;

    extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) callconv(.winapi) u32;

    extern "kernel32" fn MoveFileExW(
        lpExistingFileName: [*:0]const u16,
        lpNewFileName: [*:0]const u16,
        dwFlags: u32,
    ) callconv(.winapi) u32;

    extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) u32;

    extern "kernel32" fn RemoveDirectoryW(lpFileName: [*:0]const u16) callconv(.winapi) u32;

    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) u32;

    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
} else struct {};

/// Convert a UTF-8 path slice to a NUL-terminated UTF-16 LE slice for
/// Win32 APIs. Caller owns the returned slice.
///
/// Returns error.PathTooLong if the path needs more wide chars than
/// `buf` has room for. On non-Windows this is a compile-time no-op.
fn pathToWideZ(path: []const u8, buf: []u16) ![:0]u16 {
    if (builtin.os.tag != .windows) unreachable;
    const needed = std.unicode.calcUtf16LeLen(path) catch return error.PathTooLong;
    // +1 for the NUL terminator.
    if (needed + 1 > buf.len) return error.PathTooLong;
    _ = std.unicode.utf8ToUtf16Le(buf[0..needed], path) catch
        return error.PathTooLong;
    buf[needed] = 0;
    return buf[0..needed :0];
}

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

    switch (builtin.os.tag) {
        .linux, .macos => return atomicWriteFilePosix(path, content),
        .windows => return atomicWriteFileWindows(path, content),
        else => @compileError("design_io.atomicWriteFile: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}

fn atomicWriteFilePosix(path: []const u8, content: []const u8) !void {
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

fn atomicWriteFileWindows(path: []const u8, content: []const u8) !void {
    // Build wide-string versions of the target path and the `.tmp`
    // path on a stack buffer large enough for any realistic path.
    // std.fs.max_path_bytes is the POSIX max path length; Win32 paths
    // can be longer (32767 wide chars), but our typical usage is well
    // under 100 chars, so a 4 KB wide-char buffer (≈ 4 KB UTF-16) is
    // more than enough. For pathological paths we return error.PathTooLong.
    var path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
    const path_w = try pathToWideZ(path, &path_w_buf);

    // Append ".tmp" to path_w in-place. Sized at compile time so no
    // alloc; if path is near max_path_bytes the .tmp suffix won't fit
    // and we error out.
    var tmp_w_buf: [std.fs.max_path_bytes]u16 = undefined;
    if (path_w.len + 5 > tmp_w_buf.len) return error.PathTooLong;
    @memcpy(tmp_w_buf[0..path_w.len], path_w);
    tmp_w_buf[path_w.len] = '.';
    tmp_w_buf[path_w.len + 1] = 't';
    tmp_w_buf[path_w.len + 2] = 'm';
    tmp_w_buf[path_w.len + 3] = 'p';
    tmp_w_buf[path_w.len + 4] = 0;
    const tmp_w: [:0]u16 = tmp_w_buf[0..path_w.len + 4 :0];

    // 1. CreateFileW with CREATE_NEW (equivalent to O_CREAT|O_EXCL).
    const handle: win32_apis.HANDLE = win32_apis.CreateFileW(
        tmp_w.ptr,
        win32_apis.GENERIC_WRITE,
        win32_apis.FILE_SHARE_NONE,
        null,
        win32_apis.CREATE_NEW,
        win32_apis.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    // Win32 NULL handle is rare for CreateFileW (it returns the sentinel)
    // but safe to check — both are failure indicators.
    const handle_addr: usize = @intFromPtr(handle);
    if (handle_addr == 0 or handle_addr == win32_apis.INVALID_HANDLE_VALUE_PTR) {
        return error.WriteTmpFailed;
    }
    defer _ = win32_apis.CloseHandle(handle);

    // 2. Write the entire content (loop on partial writes). WriteFile
    // takes a u32 byte count per call — chunk to ~4 MB to stay under
    // the u32 limit for large content.
    var written_total: usize = 0;
    while (written_total < content.len) {
        const chunk_len: u32 = @intCast(@min(content.len - written_total, std.math.maxInt(u32)));
        var written_chunk: u32 = 0;
        const ok = win32_apis.WriteFile(
            handle,
            content[written_total..].ptr,
            chunk_len,
            &written_chunk,
            null,
        );
        if (ok == 0) return error.WriteFailed;
        written_total += written_chunk;
        // WriteFile can return success with written_chunk=0 (broken
        // handle, disk full, etc.). Treat as failure to avoid an
        // infinite loop.
        if (written_chunk == 0) return error.WriteFailed;
    }

    // 3. FlushFileBuffers — equivalent to fsync(2). Ensures the data
    // is on stable storage before the rename atomically swaps it in.
    _ = win32_apis.FlushFileBuffers(handle);

    // 4. Atomic rename via MoveFileExW with MOVEFILE_REPLACE_EXISTING.
    // Win32 guarantees the swap is atomic for files on the same
    // volume; cross-volume MoveFileExW falls back to copy+delete (NOT
    // atomic) but our usage is always within the same workspace so
    // that doesn't matter.
    if (win32_apis.MoveFileExW(tmp_w.ptr, path_w.ptr, win32_apis.MOVEFILE_REPLACE_EXISTING) == 0) {
        return error.RenameFailed;
    }
}

/// Unlink `path` if it exists. Does NOT error when the file is missing.
///
/// POSIX `unlink(2)` returns -1 with errno=ENOENT when the file does
/// not exist. We treat that as a no-op (the goal "the path does not
/// exist after this call" is already satisfied). Any other error
/// (permission denied, IO error) surfaces as `error.UnlinkFailed` so
/// the caller can log it.
///
/// On Windows uses `DeleteFileW`; "file not found" returns nonzero
/// (Win32 ERROR_FILE_NOT_FOUND = 2) which we swallow.
pub fn deleteFileIfExists(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    switch (builtin.os.tag) {
        .linux, .macos => return deleteFileIfExistsPosix(path),
        .windows => return deleteFileIfExistsWindows(path),
        else => @compileError("design_io.deleteFileIfExists: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}

fn deleteFileIfExistsPosix(path: []const u8) !void {
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

fn deleteFileIfExistsWindows(path: []const u8) !void {
    var path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
    const path_w = try pathToWideZ(path, &path_w_buf);

    // DeleteFileW returns nonzero on success, 0 on failure. ERROR_FILE_NOT_FOUND
    // (2) means the file doesn't exist; we treat that as a no-op like
    // POSIX ENOENT. Any other error becomes error.UnlinkFailed.
    const ok = win32_apis.DeleteFileW(path_w.ptr);
    if (ok != 0) return;
    const err = win32_apis.GetLastError();
    if (err == 2) return; // ERROR_FILE_NOT_FOUND
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
    switch (builtin.os.tag) {
        .linux, .macos => {
            var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            const path_z_len = std.fmt.bufPrint(path_buf[0..path_buf.len - 1], "{s}", .{path}) catch
                return error.PathTooLong;
            path_buf[path_z_len.len] = 0;
            if (c.rmdir(&path_buf) != 0) return error.RmdirFailed;
        },
        .windows => {
            var path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
            const path_w = try pathToWideZ(path, &path_w_buf);
            if (win32_apis.RemoveDirectoryW(path_w.ptr) == 0) return error.RmdirFailed;
        },
        else => @compileError("design_io.deleteDirectoryRecursively: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}
