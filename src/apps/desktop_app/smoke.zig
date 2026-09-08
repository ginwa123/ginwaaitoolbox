// src/apps/desktop_app/smoke.zig
//
// Headless 404 guard for `nalar-desktop --smoke-test`.
//
// Why this exists: the Windows CI cell builds with `-Dno-webapp-rebuild`
// (the runner OOMs on the vite build). When `webapp_assets.zig` is absent
// on that runner — it is gitignored and deliberately NOT in the CI cache
// (per-OS cache keys, see the "Cache Zig build artifacts" step) —
// build.zig writes an EMPTY STUB (`assets = &.{}`). The desktop then
// extracts zero files, spawns nalar with an empty `--static-dir`, and
// GET / answers `404 Not Found` (see `writeStaticFileResponse` in
// src/main.zig: the `.not_found` arm). The user sees a 404 page inside
// the desktop window instead of the app.
//
// `verifyWebappDir` checks the exact condition the server checks before
// serving `/`: the extracted dir must contain a non-empty `index.html`
// (mirrors `static_files.resolve` root-index logic — no index.html at
// the root means `.not_found` means a 404 at `/`). `--smoke-test` calls
// it after extraction, so a stub/empty build fails fast with a clear
// error instead of shipping a binary that 404s at runtime.

const std = @import("std");

pub const VerifyError = error{
    /// The extracted dir itself cannot be opened (missing / not a dir).
    WebappDirNotFound,
    /// No `index.html` at the dir root — GET / would 404.
    IndexHtmlMissing,
    /// `index.html` exists but is 0 bytes — GET / would serve an
    /// empty page (and the stub/empty-build class this guards).
    IndexHtmlEmpty,
};

/// Verify that `dir` (an already-extracted webapp dir) would serve `/`
/// with 200 instead of 404. Returns the `index.html` byte size on
/// success so the caller can log it.
///
/// Cross-platform: only `std.Io.Dir` absolute-path APIs (the same ones
/// `src/main.zig`'s static handler uses), no `std.os.linux` syscalls.
pub fn verifyWebappDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
) !u64 {
    var root = std.Io.Dir.openDirAbsolute(io, dir, .{}) catch
        return error.WebappDirNotFound;
    root.close(io);

    const index_path = try std.fs.path.join(allocator, &.{ dir, "index.html" });
    defer allocator.free(index_path);

    const file = std.Io.Dir.openFileAbsolute(io, index_path, .{}) catch
        return error.IndexHtmlMissing;
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size == 0) return error.IndexHtmlEmpty;
    return stat.size;
}
