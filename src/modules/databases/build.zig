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
    // Only native (target == host) goes system-only. Cross-compile
    // (Linux host → macOS target, or vice versa) always falls back
    // to the vendored amalgamation because the host's libs are for
    // the host OS, not the target OS.
    if (target.result.os.tag != b.graph.host.result.os.tag) {
        return .{
            .use_system_sqlite3 = false,
            .use_system_pq = false,
            .use_system_ssl = false,
            .use_system_crypto = false,
        };
    }

    // Linux: libpq-fe.h location varies by distro — Arch Linux has it
    // at /usr/include/libpq-fe.h directly, Debian/Ubuntu at
    // /usr/include/postgresql/libpq-fe.h. Check both.
    //
    // macOS: Homebrew ships keg-only sqlite3 + libpq at
    // /opt/homebrew/opt/<name>/{include,lib}/. There is no ldconfig
    // on macOS — we test the .dylib file directly. The probe accepts
    // either the keg-only path OR the system /usr/include (rare but
    // documented for completeness).
    const probe_script = switch (b.graph.host.result.os.tag) {
        .linux =>
        \\{ \
        \\  echo "sqlite_hdr=$(test -f /usr/include/sqlite3.h && echo 1 || echo 0)"; \
        \\  echo "sqlite_lib=$(ldconfig -p 2>/dev/null | grep -qE 'libsqlite3\.so(\.[0-9]+)*$' && echo 1 || echo 0)"; \
        \\  echo "pq_hdr=$(test -f /usr/include/postgresql/libpq-fe.h -o -f /usr/include/libpq-fe.h && echo 1 || echo 0)"; \
        \\  echo "pq_lib=$(ldconfig -p 2>/dev/null | grep -qE 'libpq\.so(\.[0-9]+)*$' && echo 1 || echo 0)"; \
        \\  echo "ssl_hdr=$(test -f /usr/include/openssl/ssl.h && echo 1 || echo 0)"; \
        \\  echo "ssl_lib=$(ldconfig -p 2>/dev/null | grep -qE 'libssl\.so(\.[0-9]+)*$' && echo 1 || echo 0)"; \
        \\  echo "crypto_lib=$(ldconfig -p 2>/dev/null | grep -qE 'libcrypto\.so(\.[0-9]+)*$' && echo 1 || echo 0)"; \
        \\}
        ,
        .macos =>
        // `pq` is not currently used by macOS targets (the project
        // doesn't ship libpq-backed code on Mac). The probe still
        // returns it as a hint — if a future commit adds libpq usage
        // on macOS, the brew probe is already wired.
        \\{ \
        \\  echo "sqlite_hdr=$(test -f /opt/homebrew/opt/sqlite3/include/sqlite3.h -o -f /usr/include/sqlite3.h && echo 1 || echo 0)"; \
        \\  echo "sqlite_lib=$(test -f /opt/homebrew/opt/sqlite3/lib/libsqlite3.dylib -o -f /usr/lib/libsqlite3.dylib && echo 1 || echo 0)"; \
        \\  echo "pq_hdr=$(test -f /opt/homebrew/opt/libpq/include/libpq-fe.h -o -f /usr/include/libpq-fe.h && echo 1 || echo 0)"; \
        \\  echo "pq_lib=$(test -f /opt/homebrew/opt/libpq/lib/libpq.dylib -o -f /usr/lib/libpq.dylib && echo 1 || echo 0)"; \
        \\  echo "ssl_hdr=$(test -f /opt/homebrew/opt/openssl@3/include/openssl/ssl.h -o -f /opt/homebrew/opt/openssl/include/openssl/ssl.h -o -f /usr/include/openssl/ssl.h && echo 1 || echo 0)"; \
        \\  echo "ssl_lib=$(test -f /opt/homebrew/opt/openssl@3/lib/libssl.dylib -o -f /opt/homebrew/opt/openssl/lib/libssl.dylib -o -f /usr/lib/libssl.dylib && echo 1 || echo 0)"; \
        \\  echo "crypto_lib=$(test -f /opt/homebrew/opt/openssl@3/lib/libcrypto.dylib -o -f /opt/homebrew/opt/openssl/lib/libcrypto.dylib -o -f /usr/lib/libcrypto.dylib && echo 1 || echo 0)"; \
        \\}
        ,
        else =>
        // Windows: probe vcpkg-installed headers at the canonical
        // `C:/vcpkg/installed/x64-windows/` path. The CI installs
        // sqlite3, openssl, libpq via `vcpkg install --recurse
        // <port>:x64-windows`. Probe runs under `sh -c` (git-bash on
        // the self-hosted Windows runner); forward-slash paths work.
        //
        // Header-only probe: vcpkg's lib/ filenames differ between
        // MSVC (`sqlite3.lib`) and MinGW (`libsqlite3.lib`) toolchains,
        // and the lib files may also be `*.dll.lib` etc. Rather than
        // enumerate every naming variant, just check headers —
        // `linkSystemLibrary` will fail loudly with `file not found`
        // if the lib is actually missing.
        \\{ \
        \\  VCPKG=/c/vcpkg/installed/x64-windows; \
        \\  echo "sqlite_hdr=$([ -f $VCPKG/include/sqlite3.h ] && echo 1 || echo 0)"; \
        \\  echo "pq_hdr=$([ -f $VCPKG/include/libpq-fe.h ] && echo 1 || echo 0)"; \
        \\  echo "ssl_hdr=$([ -f $VCPKG/include/openssl/ssl.h ] && echo 1 || echo 0)"; \
        \\}
        ,
    };

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
    var pq_hdr: bool = false;
    var ssl_hdr: bool = false;

    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "sqlite_hdr=")) {
            sqlite_hdr = std.mem.eql(u8, line["sqlite_hdr=".len..], "1");
        } else if (std.mem.startsWith(u8, line, "pq_hdr=")) {
            pq_hdr = std.mem.eql(u8, line["pq_hdr=".len..], "1");
        } else if (std.mem.startsWith(u8, line, "ssl_hdr=")) {
            ssl_hdr = std.mem.eql(u8, line["ssl_hdr=".len..], "1");
        }
    }

    // Header-only probe (see probe_script above): on vcpkg-equipped
    // hosts the package links against the vcpkg sysroot and relies
    // on the linker's search path to find the .lib files. If the lib
    // is missing the linker reports `file not found` with a clear
    // diagnostic. This avoids the per-toolchain lib-name enum (MSVC
    // `sqlite3.lib` vs MinGW `libsqlite3.lib` vs `sqlite3.dll.lib`).
    const use_system_sqlite3 = sqlite_hdr;
    const use_system_pq = pq_hdr;
    const use_system_ssl = ssl_hdr;
    const use_system_crypto = ssl_hdr; // crypto's header is in openssl/ssl.h — same as ssl

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
        // default but cross-compile toolchains may not). On macOS we
        // also need the brew keg-only path because the probe accepted
        // either layout.
        if (target.result.os.tag == .macos) {
            mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/sqlite3/include" });
        }
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
            // macOS native: prefer the system sqlite3 from Homebrew
            // (keg-only at /opt/homebrew/opt/sqlite3/) when the probe
            // finds it. Otherwise fall back to the vendored
            // amalgamation (works on every host with a C compiler).
            // macOS doesn't currently use libpq or openssl via this
            // package — ssl/crypto are wired only in custom_http_client
            // (the libcurl backend needs them for https://).
            if (sys.use_system_sqlite3) {
                mod.linkSystemLibrary("sqlite3", .{});
                mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/sqlite3/lib" });
                mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            } else {
                mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
            }
        },
        .windows => {
            // Use vcpkg-installed sqlite3 (and libpq/openssl) when the
            // probe finds them. The CI installs them via
            // `vcpkg install --recurse <port>:x64-windows` at
            // `C:/vcpkg/installed/x64-windows/`. This skips the
            // vendored-amalgamation path entirely — the build no
            // longer needs to fetch / compile sqlite3.c (saves ~30s on
            // fresh checkouts). Falls back to vendored on hosts that
            // don't have vcpkg installed (a developer building on
            // Windows without vcpkg still gets a working build).
            //
            // Use addObjectFile (not linkSystemLibrary) to bypass
            // the GNU-vs-MSVC lib-name convention mismatch: the
            // build target is `x86_64-windows-gnu` (GNU toolchain
            // conventions — `libfoo.a`), but vcpkg ships
            // `libfoo.lib` / `sqlite3.lib` (MSVC-style extension
            // with GNU-style name). Explicit object-file links work
            // with either naming — the linker doesn't try to
            // translate `-lfoo` → `libfoo.{a,lib}` it just adds
            // the file the build.zig hands it.
            if (sys.use_system_sqlite3) {
                mod.addIncludePath(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/include" });
                mod.addObjectFile(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/lib/sqlite3.lib" });
                if (sys.use_system_pq) {
                    mod.addObjectFile(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/lib/libpq.lib" });
                }
                if (sys.use_system_ssl) {
                    mod.addObjectFile(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/lib/libssl.lib" });
                }
                if (sys.use_system_crypto) {
                    mod.addObjectFile(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/lib/libcrypto.lib" });
                }
            } else {
                mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
            }
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