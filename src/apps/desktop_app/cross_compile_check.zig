// src/apps/desktop_app/cross_compile_check.zig
//
// Cross-target compile check for the desktop app's per-OS branches.
// Compiled (not run) by the `check:desktop-cross` build step, which CI runs
// alongside `zig build test`.
//
// WHY THIS EXISTS
// `extraction.zig` and friends fork on `builtin.os.tag`, and Zig only analyses
// the branch matching the TARGET. So `zig build test:desktop-app` running on
// Linux can never see a type error in the Windows or macOS paths, and CI only
// ever compiles a given OS's branch on that OS's runner (a ~20-minute round
// trip). That hole shipped a real bug: Win32 `BOOL` is a typed enum
// (`os.windows.Bool(c_int)`) in Zig 0.16, so `MoveFileW(...) != 0` in
// extraction.zig's `renameAbsolute` was a Windows-only compile error that
// turned the Windows CI job red. This file makes such an error fail on ANY
// runner, in about a second.
//
// HOW
// Call the module's public API from an `export`ed function — that forces full
// semantic analysis + codegen for the target (a bare `_ = f;` reference would
// not). The build step compiles this file as a plain OBJECT for
// Windows / macOS / Linux: no linking, no SDK, no webview/vcpkg deps.
//
// DELIBERATELY TARGET-CLEAN
// The build step gives this file a per-TARGET `helpers` module (not the
// project-wide one, which is built for the HOST). Mixing a host-target module
// into a foreign-target build makes Zig compile the host's `std.os.<host>`
// against the foreign target and die on the calling convention (observed on
// the Windows runner: `calling convention 'aarch64_aapcs_win' not supported
// by compiler backend 'stage2_llvm'`, blamed on helpers/mod.zig's
// `extern "kernel32" fn Sleep`).
//
// WHEN TO UPDATE
// Add a call here whenever one of these modules gains a public entry point
// that touches OS-specific code — a `builtin.os.tag` fork, a `std.c.*` or
// Win32 extern.

const std = @import("std");
const extraction = @import("extraction.zig");
const subprocess = @import("subprocess.zig");

const assets = [_]extraction.AssetEntry{
    .{ .path = "/index.html", .content = "<html></html>", .mime = "text/html" },
    .{ .path = "/assets/app.js", .content = "console.log(1)", .mime = "application/javascript" },
};

export fn pabrik_desktop_cross_compile_check() callconv(.c) void {
    // Persistent content-addressed dir: `persistentBaseDir` (env + per-OS
    // path joining), the staging/marker publish, `renameAbsolute`'s
    // POSIX-vs-Win32 branches and `pathExistsAbs`'s per-OS existence check.
    const persistent = extraction.ensurePersistent(std.heap.page_allocator, &assets) catch return;
    std.heap.page_allocator.free(persistent);

    const in_base = extraction.ensurePersistentIn(
        std.heap.page_allocator,
        "/tmp/pabrik-xcheck",
        &assets,
    ) catch return;
    std.heap.page_allocator.free(in_base);

    // The legacy per-pid temp-dir path (same write/cleanup helpers).
    const temp = extraction.extract(std.heap.page_allocator, &assets) catch return;
    extraction.cleanup(std.heap.page_allocator, temp);

    // Raw-socket probes: winsock on Windows, libc on POSIX, plus the
    // status/HTML parsing shared by both. Never executed — only analysed.
    if (subprocess.probeHealth(1)) return;
    if (subprocess.probeWebapp(1)) return;
    if (subprocess.waitForHealth(1, 1, 1)) |_| {} else |_| {}
}
