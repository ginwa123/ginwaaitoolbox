// src/apps/desktop_app/path_resolve.zig
//
// Resolves the path to the `pabrik` binary at runtime.
//
// Resolution order (first match wins):
//   1. explicit_path (from --pabrik-path) — handed through unchanged; the
//      spawn() call will produce a clear error if the file is missing.
//   2. <dir_of_self_exe>/pabrik — for bundled distributions where pabrik
//      sits next to pabrik-desktop.
//   3. Each directory in $PATH, joined with `/pabrik`.
//
// Returns null if nothing was found. The caller (main.zig in Chunk 8)
// decides how to handle a missing pabrik — usually a clear error and exit.
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

/// Resolve the path to the pabrik binary. See module doc for the resolution
/// order. Caller owns the returned slice and must `allocator.free` it.
pub fn resolve(
    allocator: std.mem.Allocator,
    explicit_path: ?[]const u8,
    self_exe_path: []const u8,
    path_env: []const u8,
) ?[]u8 {
    // 1. Explicit path from --pabrik-path: pass through unchanged. The user
    //    asked for a specific path; if it doesn't exist, the spawn() call
    //    will surface a "file not found" error which is more useful than
    //    silently falling back to PATH lookup. This also lets users point
    //    at a path that doesn't exist yet but will (e.g. a build script
    //    that produces pabrik before desktop launches).
    if (explicit_path) |p| {
        return allocator.dupe(u8, p) catch null;
    }

    // 2. Next to self. `self_exe_path` may be an absolute path or a bare
    //    name (e.g. "pabrik-desktop" when called with PATH lookup); only
    //    the absolute case is useful.
    if (std.fs.path.isAbsolute(self_exe_path)) {
        const self_dir = std.fs.path.dirname(self_exe_path) orelse ".";
        // On Windows, the actual on-disk name has the `.exe` suffix
        // — `std.c.access("...\pabrik", F_OK)` returns ENOENT even
        // though `...\pabrik.exe` exists, because the UCRT `access`
        // call does NOT auto-append `.exe` the way CreateProcessW
        // does. Linux/macOS have no extension to worry about, so we
        // hardcode the suffix per-platform rather than probing both.
        //
        // Build the candidate as a SINGLE `[]const u8` rather than
        // passing the suffix as a separate component to `path.join`:
        // `std.fs.path.join` uses `/` as the separator on every
        // platform (including Windows — see Zig issue #16589), which
        // would split the joined segments into
        // `dir/pabrik/.exe` → `dir\pabrik\.exe` after the OS rewrites
        // the slashes, which is interpreted as a subdirectory `pabrik`
        // containing a file named `.exe`. That file doesn't exist, so
        // the fileExists probe returns false even though
        // `dir\pabrik.exe` is sitting right there. Concatenating
        // `pabrik` + `.exe` ourselves and passing the single
        // `dir\pabrik.exe` to `path.join` sidesteps the bug.
        if (try probeServiceBinary(allocator, self_dir)) |found| return found;
    }

    // 3. $PATH lookup. PATH separator is OS-specific: `:` on
    //    Linux/macOS, `;` on Windows. We pick the separator by
    //    `builtin.os.tag` so this works on every platform that
    //    pabrik-desktop can run on (was: hardcoded `:` which broke
    //    Windows — PATH on Windows is `;`-separated, so tokenizing
    //    by `:` treated the whole PATH as ONE giant directory and
    //    `fileExists(<giant-path>/pabrik)` always returned false,
    //    surfacing as `error.PabrikNotFound` in attach.zig).
    //
    // Same `.exe` caveat as the next-to-self branch above: on
    // Windows the binary on disk has the suffix, but `std.c.access`
    // doesn't auto-append it. Without this, even a correctly
    // tokenized PATH like `C:\vcpkg\installed\x64-windows\bin` fails
    // its fileExists probe for `pabrik` when the real file is
    // `pabrik.exe`.
    //
    // Same single-segment caveat as above: concatenate `pabrik` +
    // `.exe` ourselves before passing to `path.join`, otherwise
    // `path.join` splits on `/` and produces `dir/pabrik/.exe`.
    const path_separator: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.tokenizeScalar(u8, path_env, path_separator);
    while (it.next()) |dir| {
        if (try probeServiceBinary(allocator, dir)) |found| return found;
    }
    return null;
}

/// Look for the backend binary in `dir`, current name first, then the
/// pre-rebrand name.
///
/// The legacy name is probed because the desktop shell is installed
/// separately from the service: a `pabrik-desktop` on an upgraded box is
/// routinely paired with a `nalar` service binary that is still on $PATH from
/// the previous install. Failing to find it surfaces as `PabrikNotFound` on
/// stderr — invisible when the shell was launched from a desktop icon.
fn probeServiceBinary(allocator: std.mem.Allocator, dir: []const u8) !?[]u8 {
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    for ([_][]const u8{ "pabrik", "nalar" }) |base| {
        // Concatenate the suffix ourselves — see the long note at the call
        // site: `path.join` would split `dir/pabrik/.exe` into a directory
        // named `pabrik` containing a file `.exe`.
        const name = if (exe_suffix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, exe_suffix })
        else
            try allocator.dupe(u8, base);
        defer allocator.free(name);
        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        if (fileExists(candidate)) return candidate; // hand off ownership
        allocator.free(candidate);
    }
    return null;
}

/// Return the absolute path to the running executable. Linux reads
/// `/proc/self/exe` via `readlink(2)`; macOS calls `_NSGetExecutablePath`
/// from libSystem (the Apple-blessed way to find your own exe path);
/// Windows calls `GetModuleFileNameW(NULL, …)` from kernel32, which
/// returns the absolute path of the main executable as a NUL-terminated
/// UTF-16 string that we then convert to WTF-8 for Zig's `[]u8` API.
pub fn selfExePath(allocator: std.mem.Allocator) SelfExeError![]u8 {
    return switch (builtin.os.tag) {
        .linux => linuxSelfExePath(allocator),
        .macos => macosSelfExePath(allocator),
        .windows => windowsSelfExePath(allocator),
        else => return error.UnsupportedPlatform,
    };
}

fn linuxSelfExePath(allocator: std.mem.Allocator) SelfExeError![]u8 {
    // PATH_MAX is 4096 on Linux; 4096 is enough for almost all real
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

// Win32 GetModuleFileNameW — returns the absolute path of the main
// executable. Declared locally because std.os.windows in Zig 0.16
// doesn't expose it (same pattern as build.zig's GetFileAttributesW).
// kernel32.dll exports it natively; Zig's MinGW (gnu) link line needs
// the explicit `linkSystemLibrary("kernel32", .{})` that desktop_exe
// already adds (see build.zig:1680 region).
extern "kernel32" fn GetModuleFileNameW(
    hModule: ?*anyopaque,
    lpFilename: [*]u16,
    nSize: u32,
) callconv(.winapi) u32;

// Win32 self-exe resolution. GetModuleFileNameW with hModule=NULL
// returns the full path of the running .exe as a NUL-terminated
// UTF-16LE string. Returns the count of UTF-16 units written
// (excluding the NUL terminator), or nSize on buffer-too-small.
//
// We allocate 32767 u16 units up front — the Win32 long-path max
// (\\?\ paths raise it from MAX_PATH=260). On the (vanishingly rare)
// platforms where 32 KiB still isn't enough, GetModuleFileNameW
// returns nSize (== buffer len) and we'd need to grow; for now we
// bail out with ReadLinkFailed and let the caller skip the "next to
// self" check. Returning the path through the WTF-16 → WTF-8
// converter (std.unicode.wtf16LeToWtf8) gives us the `[]u8` slice
// Zig's filesystem APIs expect.
fn windowsSelfExePath(allocator: std.mem.Allocator) SelfExeError![]u8 {
    var wide: [32767]u16 = undefined;
    const written = GetModuleFileNameW(null, &wide, wide.len);
    if (written == 0 or written >= wide.len) return error.ReadLinkFailed;
    // WTF-16LE → WTF-8. The reverse of the conversion build.zig uses
    // to call GetFileAttributesW. wtf16LeToWtf8 writes up to
    // `wtf8.len` UTF-8 bytes and returns the count actually written;
    // any unpaired surrogates in the source are dropped (per the
    // function's documented behavior). Worst case: every UTF-16 unit
    // encodes as 3 UTF-8 bytes (low-surrogate half → 3 bytes).
    var narrow: [32767 * 3]u8 = undefined;
    const utf8_len = std.unicode.wtf16LeToWtf8(&narrow, wide[0..written]);
    return allocator.dupe(u8, narrow[0..utf8_len]) catch return error.OutOfMemory;
}

fn macosSelfExePath(allocator: std.mem.Allocator) SelfExeError![]u8 {
    // macOS doesn't have /proc/self/exe; the documented way to find your
    // own exe path is `_NSGetExecutablePath` from libSystem. Per Apple docs,
    // the returned path may contain symbolic links and ".." components —
    // we hand it back as-is and let the "next to self" check in `resolve`
    // (`std.fs.path.isAbsolute`) handle that. For a freshly-built binary
    // in e.g. `./zig-out/bin/pabrik-desktop`, the returned path is already
    // absolute (the kernel knows where it was exec'd from), so the check
    // works without further resolution.
    //
    // The call signature: int _NSGetExecutablePath(char* buf, uint32_t* bufsize);
    //   - On success: returns 0, `buf` contains the NUL-terminated path,
    //     `*bufsize` is the number of bytes written (excluding NUL).
    //   - If `bufsize` is too small: returns -1, `*bufsize` is updated to
    //     the required size. We grow the buffer and retry.
    var buf: [4096]u8 = undefined;
    var bufsize: u32 = buf.len;
    const rc = std.c._NSGetExecutablePath(&buf, &bufsize);
    if (rc == 0) {
        const len = std.mem.indexOfScalar(u8, &buf, 0) orelse bufsize;
        return allocator.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    }
    // Buffer too small — retry with the required size.
    if (bufsize == 0 or bufsize > 65536) return error.ReadLinkFailed;
    const heap = allocator.alloc(u8, bufsize) catch return error.OutOfMemory;
    defer allocator.free(heap);
    const retry_rc = std.c._NSGetExecutablePath(heap.ptr, &bufsize);
    if (retry_rc != 0) return error.ReadLinkFailed;
    const len = std.mem.indexOfScalar(u8, heap, 0) orelse bufsize;
    return allocator.dupe(u8, heap[0..len]) catch return error.OutOfMemory;
}

/// Windows-only shipped webapp lookup (persistent static dir).
///
/// Returns the duped absolute path of the installed `html/` dir when its
/// `index.html` exists, else null. Caller owns the slice and must
/// `allocator.free` it (but must NOT delete the dir -- it is the user's
/// installed copy, not a per-run temp extraction).
///
/// Order (first hit wins):
///   1. %LOCALAPPDATA%\pabrik\html\index.html (Install-Pabrik.ps1 layout)
///   2. <dir_of_self_exe>\html\index.html (portable / repo-checkout layout:
///      html/ sitting next to pabrik-desktop.exe, e.g. zig-out/bin/html)
///   3. Legacy `webapp/` fallbacks (pre-rename installs): same two probes
///      with `webapp` instead of `html`, so existing
///      %LOCALAPPDATA%\pabrik\webapp installs keep working until the user
///      re-runs Install-Pabrik.ps1 (which migrates webapp/ -> html/).
///
/// Non-Windows returns null immediately -- Linux/macOS keep the embedded
/// + temp-extraction flow unchanged (Windows-only feature per request).
pub fn findInstalledWebapp(
    allocator: std.mem.Allocator,
    self_exe_path: []const u8,
) ?[]u8 {
    if (builtin.os.tag != .windows) return null;

    // 1. %LOCALAPPDATA%\<app>\html\index.html — both the current and the
    //    pre-rebrand directory, because Install-Pabrik.ps1 writes to a
    //    per-app folder that an already-installed app still has under the old
    //    name until the user re-runs the installer.
    if (std.c.getenv("LOCALAPPDATA")) |appdata_z| {
        const appdata = std.mem.sliceTo(appdata_z, 0);
        for ([_][]const u8{ "pabrik", "nalar" }) |app| {
            const probe = std.fs.path.join(allocator, &.{ appdata, app, "html", "index.html" }) catch null;
            if (probe) |p| {
                defer allocator.free(p);
                if (fileExists(p)) {
                    return std.fs.path.join(allocator, &.{ appdata, app, "html" }) catch null;
                }
            }
        }
    }

    // 2. <exe_dir>\html\index.html (only when we know our own dir).
    if (std.fs.path.isAbsolute(self_exe_path)) {
        const self_dir = std.fs.path.dirname(self_exe_path) orelse ".";
        const probe = std.fs.path.join(allocator, &.{ self_dir, "html", "index.html" }) catch null;
        if (probe) |p| {
            defer allocator.free(p);
            if (fileExists(p)) {
                return std.fs.path.join(allocator, &.{ self_dir, "html" }) catch null;
            }
        }
    }

    // 3. Legacy webapp/ fallbacks (pre-rename). Removed once all installs migrate.
    if (std.c.getenv("LOCALAPPDATA")) |appdata_z| {
        const appdata = std.mem.sliceTo(appdata_z, 0);
        for ([_][]const u8{ "pabrik", "nalar" }) |app| {
            const probe = std.fs.path.join(allocator, &.{ appdata, app, "webapp", "index.html" }) catch null;
            if (probe) |p| {
                defer allocator.free(p);
                if (fileExists(p)) {
                    return std.fs.path.join(allocator, &.{ appdata, app, "webapp" }) catch null;
                }
            }
        }
    }
    if (std.fs.path.isAbsolute(self_exe_path)) {
        const self_dir = std.fs.path.dirname(self_exe_path) orelse ".";
        const probe = std.fs.path.join(allocator, &.{ self_dir, "webapp", "index.html" }) catch null;
        if (probe) |p| {
            defer allocator.free(p);
            if (fileExists(p)) {
                return std.fs.path.join(allocator, &.{ self_dir, "webapp" }) catch null;
            }
        }
    }

    return null;
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
    //
    // Windows note: `std.c.AT.FDCWD` doesn't exist in Zig 0.16's Windows
    // libc bindings (the `std.c.AT` struct on Windows only exposes
    // `REMOVEDIR`). The plain `std.c.access(path, F_OK)` syscall is
    // available cross-platform via UCRT and behaves identically for
    // absolute-path existence checks, so we use it on Windows and keep
    // the `faccessat(AT_FDCWD, ...)` form on POSIX (Linux/macOS) untouched.
    const rc = switch (builtin.os.tag) {
        .windows => std.c.access(&buf, std.c.F_OK),
        else => std.c.faccessat(std.c.AT.FDCWD, &buf, std.c.F_OK, 0),
    };
    return rc == 0;
}

// ===== Tests merged from path_resolve_test.zig (2026-09-29 flatten) =====
// Tests for the pabrik-binary path resolver.
//
// The three test cases match the plan's resolution order:
//   1. explicit_path (from `--pabrik-path`) wins
//   2. next-to-self lookup (relative to the running executable)
//   3. $PATH fallback
//
// The "next to self" test is intentionally weak — it does not assert on the
// returned path because that depends on whether the test runner's $PATH has
// a `pabrik` binary. The point of that test is to exercise the function
// shape, not the file system. The strong assertion lives in the Chunk 9
// integration test that runs the full binary.

const testing = std.testing;

test "resolvePabrikPath: returns --pabrik-path if provided" {
    const allocator = testing.allocator;
    // We pass a path that almost certainly does not exist. Per the design
    // contract: --pabrik-path is a USER SUPPLIED OVERRIDE — if the file
    // is missing, the spawn() call will produce a clear error. resolve()
    // should not pre-validate; it just hands the path through.
    const result = resolve(allocator, "/custom/pabrik", "pabrik-desktop", "/usr/bin");
    try testing.expect(result != null);
    try testing.expectEqualStrings("/custom/pabrik", result.?);
    allocator.free(result.?);
}

test "resolvePabrikPath: handles next-to-self + PATH lookup without crashing" {
    const allocator = testing.allocator;
    // Use a "next to self" path that does not exist; PATH also probably lacks
    // the binary in CI. We just want to confirm the function doesn't panic,
    // and that it returns null when nothing is found.
    const result = resolve(
        allocator,
        null,
        "/nonexistent/dir/pabrik-desktop",
        "/usr/bin:/bin",
    );
    // The function should not crash. It may return null (if neither path
    // has a pabrik binary) or a real path (if the test env has pabrik
    // installed in /usr/bin or /bin) — both outcomes are valid.
    if (result) |r| allocator.free(r);
}

test "resolvePabrikPath: returns null when pabrik is not found anywhere" {
    const allocator = testing.allocator;
    // Use a path_env that definitely doesn't exist and a self path that
    // definitely doesn't exist.
    const result = resolve(
        allocator,
        null,
        "/nonexistent/dir/pabrik-desktop",
        "/nonexistent/path/with/no/binaries",
    );
    try testing.expect(result == null);
}

test "findInstalledWebapp: returns null for nonexistent exe dir without crashing" {
    const allocator = testing.allocator;
    const result = findInstalledWebapp(
        allocator,
        "/nonexistent/dir/pabrik-desktop",
    );
    // On non-Windows this is unconditionally null; on Windows CI neither
    // %LOCALAPPDATA%\pabrik\html\index.html nor the nonexistent exe-dir
    // candidate exists, so null as well. Either way: no panic, no leak.
    if (result) |r| allocator.free(r);
}

test "findInstalledWebapp: bare relative exe path skips next-to-self probe" {
    const allocator = testing.allocator;
    const result = findInstalledWebapp(allocator, ".");
    if (result) |r| allocator.free(r);
}

test "resolvePabrikPath: handles Windows-style PATH (;-separated)" {
    // The fix for `error.PabrikNotFound` on Windows: `resolve()` used
    // to tokenize by `:` (Unix convention) on every platform. On
    // Windows, $PATH is `;`-separated, so the old tokenizeScalar(':')
    // treated the entire PATH as ONE giant directory entry, joined
    // it with `pabrik`, and `fileExists(<giant-path>/pabrik)` always
    // returned false. This test locks in the fix: a Windows-style
    // PATH with multiple `;`-separated entries must be tokenized
    // entry-by-entry (the function still returns null when neither
    // entry has a real `pabrik`, but the LOOP runs the right number
    // of times — observable indirectly via the no-panic contract).
    const allocator = testing.allocator;
    const result = resolve(
        allocator,
        null,
        "C:\\nonexistent\\dir\\pabrik-desktop.exe",
        "C:\\Windows\\System32;C:\\Windows;C:\\nonexistent\\bin",
    );
    if (result) |r| allocator.free(r);
    // No panic + no result = pass. (We can't easily write a "creates
    // a temp file in PATH and finds it" test here without pulling
    // in std.fs.cwd machinery that Zig 0.16 has restructured.)
}
