// tools/clean_webapp_cache.zig
//
// Cross-platform "clean" step for the pabrik-desktop fresh-assets build
// path. Deletes the two artifacts that make an embedded-assets build go
// stale:
//
//   1. src/apps/desktop_app/embedded/webapp_assets.zig  (the generated
//      Zig source with every dist/ asset embedded as string literals)
//   2. src/apps/desktop/dist/                           (vite's output)
//
// Why a Zig tool instead of `sh -c 'rm -rf ...'`: the old clean step in
// build.zig spawned `sh -c` unconditionally, which works on Linux/macOS
// and on Windows *only* when Git Bash is on PATH (the CI Windows job
// wraps everything in Git Bash, but a native `zig build pabrik-desktop`
// on a stock Windows box has no `sh`). This tool uses std.fs directly,
// so it runs anywhere Zig runs.
//
// Usage:
//     zig run tools/clean_webapp_cache.zig
// or via the build step wired up in build.zig (`webapp-rebuild` /
// `pabrik-desktop` fresh-assets path).
//
// Exit codes: 0 on success (including "nothing to delete"), non-zero on
// real I/O errors other than FileNotFound (missing paths are fine — that
// just means there was nothing stale to remove).

const std = @import("std");
const builtin = @import("builtin");

/// Paths relative to the project root (the build runner's cwd).
const targets = [_][]const u8{
    "src/apps/desktop_app/embedded/webapp_assets.zig",
    "src/apps/desktop/dist",
};

pub fn main(init: std.process.Init) !void {
    // Zig 0.16: `std.fs.cwd()` was removed; filesystem access goes
    // through `std.Io` (the Io runtime is delivered via process.Init).
    const io = init.io;
    // One-shot CLI: delete two fixed paths, print what happened, exit.
    // (No allocator needed — deleteTree works on caller-provided paths
    // with internal stack buffers.)

    var deleted_any = false;
    for (targets) |rel_path| {
        // deleteTree resolves `sub_path` against the Dir (cwd = project
        // root, since the build runner sets cwd to the build root), so
        // the relative path works as-is — no realpath needed.
        if (deleteTree(rel_path, io)) {
            std.debug.print("clean_webapp_cache: deleted {s}\n", .{rel_path});
            deleted_any = true;
        } else |err| switch (err) {
            // Zig 0.16's Io.Dir.deleteTree error set has no FileNotFound;
            // a missing path surfaces as AccessDenied. Treat it as
            // "nothing stale to remove" (normal on first build).
            error.AccessDenied => {},
            else => return err,
        }
    }

    if (!deleted_any) {
        std.debug.print("clean_webapp_cache: nothing to delete (already clean)\n", .{});
    }
}

/// Delete a file or a directory tree. Returns void on success; the
/// caller treats error.FileNotFound as a no-op.
fn deleteTree(abs_path: []const u8, io: std.Io) !void {
    // std.Io.Dir.cwd().deleteTree handles both files and directories on
    // all platforms (it stats the path first; for a directory it walks +
    // unlinks recursively). On Windows it maps to DeleteFileW /
    // RemoveDirectoryW under the hood — no shell involved.
    try std.Io.Dir.cwd().deleteTree(io, abs_path);
}
