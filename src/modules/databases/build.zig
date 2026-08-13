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
//!
//! ## System-deps probe
//!
//! In addition to the vendored sqlite3 amalgamation, this package probes
//! the host system at build config time for sqlite3 + libpq + openssl.
//! If the host has all of them (the normal case on Arch / Debian /
//! Fedora / Ubuntu dev hosts), the package links the system sqlite3 via
//! `linkSystemLibrary("sqlite3")` and skips the 9 MB amalgamation
//! compile entirely. This is what the user asked for: "before use
//! vendor script to build, check the current system deps first, if
//! system have the lib no need use vendor".
//!
//! Override with `-Dforce-vendor=true` to always compile the vendored
//! amalgamation (useful for CI runners + testing the vendored path).

const std = @import("std");
const builtin = @import("builtin");

/// Result of probing the host system for sqlite3 + libpq + openssl.
const SystemLibs = struct {
    /// True when the probe found sqlite3.h AND libsqlite3.so on the host.
    use_system_sqlite3: bool,
    /// True when the probe found libpq-fe.h AND libpq.so on the host.
    use_system_pq: bool,
    /// True when the probe found openssl/ssl.h AND libssl.so on the host.
    use_system_ssl: bool,
    /// True when the probe found openssl/ssl.h AND libcrypto.so on the host.
    use_system_crypto: bool,
};

/// Probe the host system for sqlite3 + libpq + openssl.
///
/// Runs `sh -c` synchronously at build config time (via
/// `std.process.run`) and parses 6 boolean fields out of its stdout.
/// The probe runs in ~25 ms on a typical Linux host — cheap enough
/// to re-run on every `zig build` invocation (no caching needed).
///
/// Only Linux is probed. macOS Homebrew sqlite3 is keg-only; Windows
/// needs explicit .lib paths; both fall back to vendor. Cross-compile
/// (Linux host → Windows target) also falls back to vendor because
/// the probe checks the HOST's system libs, not the TARGET's.
///
/// `target` is the COMPILE's resolved target. Cross-compile always
/// returns "no system libs" because the host's libs are for the host
/// OS, not the target OS.
pub fn probeSystemLibs(b: *std.Build, target: std.Build.ResolvedTarget) SystemLibs {
    // Only Linux native (target == host == linux) goes system-only.
    // Anything else falls back to the vendored amalgamation.
    if (target.result.os.tag != .linux or b.graph.host.result.os.tag != .linux) {
        return .{
            .use_system_sqlite3 = false,
            .use_system_pq = false,
            .use_system_ssl = false,
            .use_system_crypto = false,
        };
    }

    // libpq-fe.h location varies by distro: Arch Linux has it at
    // /usr/include/libpq-fe.h directly, Debian/Ubuntu at
    // /usr/include/postgresql/libpq-fe.h. Check both.
    const probe_script =
        \\{ \
        \\  echo "sqlite_hdr=$(test -f /usr/include/sqlite3.h && echo 1 || echo 0)"; \
        \\  echo "sqlite_lib=$(ldconfig -p 2>/dev/null | grep -qE 'libsqlite3\.so(\.[0-9]+)*$' && echo 1 || echo 0)"; \
        \\  echo "pq_hdr=$(test -f /usr/include/postgresql/libpq-fe.h -o -f /usr/include/libpq-fe.h && echo 1 || echo 0)"; \
        \\  echo "pq_lib=$(ldconfig -p 2>/dev/null | grep -qE 'libpq\.so(\.[0-9]+)*$' && echo 1 || echo 0)"; \
        \\  echo "ssl_hdr=$(test -f /usr/include/openssl/ssl.h && echo 1 || echo 0)"; \
        \\  echo "ssl_lib=$(ldconfig -p 2>/dev/null | grep -qE 'libssl\.so(\.[0-9]+)*$' && echo 1 || echo 0)"; \
        \\  echo "crypto_lib=$(ldconfig -p 2>/dev/null | grep -qE 'libcrypto\.so(\.[0-9]+)*$' && echo 1 || echo 0)"; \
        \\}
    ;

    const result = std.process.run(
        b.allocator,
        b.graph.io,
        .{
            .argv = &.{ "sh", "-c", probe_script },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        },
    ) catch {
        // Probe failed — fall back to vendor.
        return .{
            .use_system_sqlite3 = false,
            .use_system_pq = false,
            .use_system_ssl = false,
            .use_system_crypto = false,
        };
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    var sqlite_hdr: bool = false;
    var sqlite_lib: bool = false;
    var pq_hdr: bool = false;
    var pq_lib: bool = false;
    var ssl_hdr: bool = false;
    var ssl_lib: bool = false;
    var crypto_lib: bool = false;

    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "sqlite_hdr=")) {
            sqlite_hdr = std.mem.eql(u8, line["sqlite_hdr=".len..], "1");
        } else if (std.mem.startsWith(u8, line, "sqlite_lib=")) {
            sqlite_lib = std.mem.eql(u8, line["sqlite_lib=".len..], "1");
        } else if (std.mem.startsWith(u8, line, "pq_hdr=")) {
            pq_hdr = std.mem.eql(u8, line["pq_hdr=".len..], "1");
        } else if (std.mem.startsWith(u8, line, "pq_lib=")) {
            pq_lib = std.mem.eql(u8, line["pq_lib=".len..], "1");
        } else if (std.mem.startsWith(u8, line, "ssl_hdr=")) {
            ssl_hdr = std.mem.eql(u8, line["ssl_hdr=".len..], "1");
        } else if (std.mem.startsWith(u8, line, "ssl_lib=")) {
            ssl_lib = std.mem.eql(u8, line["ssl_lib=".len..], "1");
        } else if (std.mem.startsWith(u8, line, "crypto_lib=")) {
            crypto_lib = std.mem.eql(u8, line["crypto_lib=".len..], "1");
        }
    }

    const use_system_sqlite3 = sqlite_hdr and sqlite_lib;
    const use_system_pq = pq_hdr and pq_lib;
    const use_system_ssl = ssl_hdr and ssl_lib;
    const use_system_crypto = ssl_hdr and crypto_lib;

    std.debug.print(
        "[databases] probe: sqlite3={} libpq={} ssl={} crypto={}\n",
        .{ use_system_sqlite3, use_system_pq, use_system_ssl, use_system_crypto },
    );

    return .{
        .use_system_sqlite3 = use_system_sqlite3,
        .use_system_pq = use_system_pq,
        .use_system_ssl = use_system_ssl,
        .use_system_crypto = use_system_crypto,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Path to the vendored sqlite3 amalgamation, relative to this
    // package's build.zig. Default is `vendor/sqlite3/` co-located with
    // this build.zig (the package owns its own vendor dir — the fetch
    // script at scripts/fetch-vendor-sqlite3.sh populates it).
    // Override with `-Dvendor-dir=...` if you move it elsewhere.
    const vendor_dir = b.option(
        []const u8,
        "vendor-dir",
        "Path to vendor/sqlite3/ (relative to this package, default 'vendor/sqlite3')",
    ) orelse "vendor/sqlite3";

    // Force-use vendor (skip the system probe). Default: false
    // (probe decides).
    const force_vendor = b.option(
        bool,
        "force-vendor",
        "Skip the system probe and always compile the vendored sqlite3 amalgamation",
    ) orelse false;

    const mod = b.addModule("databases", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Universal: libc is required by every sqlite3 binding + cimport.
    mod.linkSystemLibrary("c", .{});
    mod.link_libc = true;

    // Probe host system for sqlite3 + libpq + openssl. When the probe
    // finds usable system libs (typical Arch / Debian / Fedora dev
    // hosts), link them and skip the vendored amalgamation entirely.
    // Otherwise fall back to the vendored amalgamation (works on every
    // host with a C compiler).
    const sys = if (force_vendor) SystemLibs{
        .use_system_sqlite3 = false,
        .use_system_pq = false,
        .use_system_ssl = false,
        .use_system_crypto = false,
    } else probeSystemLibs(b, target);

    // sqlite3 header path — needed by `@cImport(@cInclude("sqlite3.h"))`
    // inside src/sqlite/Sqlite.zig. On system path: /usr/include is
    // already on the cimport search path so no addIncludePath needed.
    // On vendor path: the amalgamation co-locates sqlite3.h with the
    // .c file in vendor/sqlite3/, so we add that include path.
    if (!sys.use_system_sqlite3) {
        mod.addIncludePath(b.path(vendor_dir));
    } else {
        // Explicit /usr/include for cimport (most distros have it by
        // default but cross-compile toolchains may not).
        mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    }

    // Compile flags mirror the existing project convention:
    //   - SQLITE_THREADSAFE=1       — multi-threaded app, mutexes OK
    //   - SQLITE_OMIT_LOAD_EXTENSION — don't expose the loadable-ext API
    //   - SQLITE_ENABLE_FTS5         — required for the project's FTS5
    //                                  indexes (save_memory, search_history,
    //                                  llm_history)
    const sqlite_c = b.path(b.fmt("{s}/sqlite3.c", .{vendor_dir}));
    const sqlite_flags = &[_][]const u8{
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_ENABLE_FTS5",
    };
    switch (target.result.os.tag) {
        .linux => {
            if (sys.use_system_sqlite3) {
                // System sqlite3 — link the shared lib. Don't compile
                // the amalgamation (saves ~3 min on first build +
                // ~10 MB of build artifacts).
                mod.linkSystemLibrary("sqlite3", .{});
            } else {
                // Vendored amalgamation. Compile the .c into every
                // consumer (Zig caches the resulting object file).
                mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
            }
            // libpq — link from system when probe finds it, otherwise
            // try system headers anyway (link will fail with a clear
            // error if libpq isn't installed; that's the correct
            // outcome).
            if (sys.use_system_pq) {
                mod.linkSystemLibrary("pq", .{});
                // Add both /usr/include and /usr/include/postgresql
                // because Debian/Ubuntu put libpq-fe.h in
                // /usr/include/postgresql while Arch has it directly
                // in /usr/include. Harmless if the other is missing.
                mod.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
            }
            // OpenSSL — only link when system probe finds them. The
            // vendored amalgamation is independent of ssl/crypto
            // (it doesn't pull in TLS), so even if the probe fails for
            // ssl/crypto, the amalgamation still compiles. But we
            // still try to link ssl/crypto when available because the
            // main app's libpq / openssl use depends on them.
            if (sys.use_system_ssl) mod.linkSystemLibrary("ssl", .{});
            if (sys.use_system_crypto) mod.linkSystemLibrary("crypto", .{});
        },
        .macos => {
            // macOS: always use vendored amalgamation (no Homebrew
            // path handling in the probe yet). macOS doesn't currently
            // use libpq or openssl — those are wired in the linux
            // branch only.
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
    // block. The mod already carries link_libc + (system or vendored)
    // sqlite3 amalgamation, so test executables inherit those deps
    // automatically.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run databases package tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(b.getInstallStep());
}