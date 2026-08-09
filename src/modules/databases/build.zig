//! `databases` package — self-contained Zig package that exposes the
//! sqlite3 + libpq bindings used by nalarcore.
//!
//! Consumers (`b.dependency("databases", .{...})`) get the right sqlite3
//! + openssl + libpq link line + include paths based on the TARGET they
//! pass in. This means a Linux native build, a Linux → Windows cross-
//! compile, and a macOS native build each pick up the correct deps
//! automatically — without the consumer needing to wire per-platform
//! system libraries themselves.
//!
//! Why per-TARGET (not per-Compile from the consumer): the consumer
//! build.zig's `linkPlatformDeps` no longer needs to know about
//! sqlite3 / openssl / libpq. The databases module carries those deps
//! for its own target, and Zig's module-graph dep propagation handles
//! the rest.

const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Path to the vendored sqlite3 amalgamation, relative to this
    // package's build.zig. Default assumes the package lives at
    // `<project>/src/modules/databases/` and the vendor dir is at
    // `<project>/vendor/sqlite3/`. Override with `-Dvendor-dir=...`
    // if you move either side.
    //
    // `b.path()` resolves relative to the package's build.zig
    // directory, so `../../../vendor/sqlite3` walks up 3 levels
    // (src → modules → databases's parent's parent's parent) to reach
    // the project root. An absolute path or a different relative
    // layout works too — pass it via `-Dvendor-dir=...`.
    const vendor_dir = b.option(
        []const u8,
        "vendor-dir",
        "Path to vendor/sqlite3/ (relative to this package, default '../../../vendor/sqlite3')",
    ) orelse "../../../vendor/sqlite3";

    const mod = b.addModule("databases", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Universal: libc is required by every sqlite3 binding + cimport.
    mod.linkSystemLibrary("c", .{});
    mod.link_libc = true;

    // sqlite3 header path — needed by `@cImport(@cInclude("sqlite3.h"))`
    // inside src/modules/databases/src/sqlite/Sqlite.zig. The header is
    // portable C, so the same path works for every host (Zig's cimport
    // uses the HOST C compiler, not the cross-target compiler).
    mod.addIncludePath(b.path(vendor_dir));

    // Compile the vendored sqlite3 amalgamation into every consumer.
    // The amalgamation (`vendor/sqlite3/sqlite3.c`, ~9 MB) ships in the
    // repo and is hermetic — same content on Linux, macOS, Windows.
    // Compile flags mirror the existing project convention:
    //   - SQLITE_THREADSAFE=0       — single-threaded app, no mutexes
    //   - SQLITE_OMIT_LOAD_EXTENSION — don't expose the loadable-ext API
    //   - SQLITE_ENABLE_FTS5         — required for the project's FTS5
    //                                  indexes (save_memory, search_history,
    //                                  llm_history)
    //
    // Why compile per-consumer (not a shared prebuilt archive): the
    // amalgamation compile happens once per target — Zig's build graph
    // caches the resulting object file. Cross-target consumers compile
    // their own copy (Linux → Windows gets the Windows-flavoured object),
    // which is what we want. A prebuilt .a archive would save ~30 s on
    // the first build but breaks cross-compile to hosts that don't have
    // the matching .a shipped.
    const sqlite_c = b.path(b.fmt("{s}/sqlite3.c", .{vendor_dir}));
    const sqlite_flags = &[_][]const u8{
        "-DSQLITE_THREADSAFE=0",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_ENABLE_FTS5",
    };
    switch (target.result.os.tag) {
        .linux => {
            mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });

            // OpenSSL + libpq — needed by the main app's libpq / openssl
            // use (NOT by sqlite itself). Linux links them from the system;
            // macOS/Windows don't currently need these (libpq is wired via
            // a shim on Windows; openssl is bundled via the curl client).
            mod.linkSystemLibrary("ssl", .{});
            mod.linkSystemLibrary("crypto", .{});
            mod.linkSystemLibrary("pq", .{});
            mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
            // Debian/Ubuntu layout: libpq-fe.h lives in
            // /usr/include/postgresql (Arch has it directly in
            // /usr/include). Adding both is harmless.
            mod.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
        },
        .macos => {
            mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
        },
        .windows => {
            mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
            // bcrypt.dll is needed by src/modules/custom_http_server/src/security.zig
            // (BCryptGenRandom — Zig's std.c.getrandom is `void` on Windows).
            mod.linkSystemLibrary("bcrypt", .{});
        },
        else => {
            // Cross-compile to non-Linux/macOS/Windows targets (FreeBSD,
            // Android, WASI). Same amalgamation path as the named targets;
            // bcrypt / openssl / pq aren't applicable here.
            mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
        },
    }

    // === Tests for the package itself ===
    // `b.addTest({ .root_module = mod })` walks every `_test.zig`
    // reachable from src/root.zig via the `test { _ = @import(...) }`
    // block. The mod already carries link_libc + sqlite3 amalgamation,
    // so test executables inherit those deps automatically.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run databases package tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(b.getInstallStep());
}
