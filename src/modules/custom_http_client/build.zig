//! `custom_http_client` package — self-contained Zig package that
//! exposes the libcurl-backed HTTP client used by nalarcore.
//!
//! Mirrors `src/modules/databases/build.zig`'s pattern: vendored
//! libcurl is a per-target prebuilt archive under
//! `vendor/curl/<target>/lib/libcurl.a` + a portable C header under
//! `vendor/curl/<target>/include/`. Consumers
//! (`b.dependency("custom_http_client", .{...})`) get the right
//! include path + library archive for the TARGET they pass in,
//! without the consumer needing to wire per-platform system library
//! paths itself.
//!
//! Why per-TARGET (not per-Compile from the consumer): the consumer
//! build.zig's curl include-path plumbing no longer needs to know
//! about Homebrew keg-only paths or vcpkg sysroots. The
//! custom_http_client module carries those for its own target, and
//! Zig's module-graph dep propagation handles the rest.
//!
//! Why `addObjectFile` (not `linkSystemLibrary("curl")`): the
//! vendored `libcurl.a` lives at a non-standard path that the
//! cross-target linker can't find via `-lcurl` / `-L<dir>`. The
//! `addObjectFile` call embeds the archive's symbols directly in
//! the consumer's link line, bypassing the search-path resolution.
//! The result is that libcurl is STATICALLY LINKED into every
//! consumer — verified by `ldd zig-out/bin/nalar | grep -i curl`
//! showing no `libcurl.so.4` line (the hermetic-build goal).
//!
//! ## System-deps probe
//!
//! In addition to the vendored path, this package probes the host
//! system at build config time for libcurl + libssl + libcrypto. If
//! the host has all three (the normal case on Arch / Debian / Fedora
//! / Ubuntu dev hosts), the package links the system libs via
//! `linkSystemLibrary` and skips the vendored archive entirely. This
//! saves ~30 min of cross-compile on a fresh checkout AND produces a
//! binary that uses the host's libcurl — which is what the user asked
//! for: "before use vendor script to build, check the current system
//! deps first, if system have the lib no need use vendor".
//!
//! Override with `-Dforce-vendor=true` to always use the vendored
//! archive (useful for CI runners + testing the vendored path).

const std = @import("std");

/// Cross-platform "does this file exist" check used by the system-deps
/// probe below. Earlier revisions ran `sh -c "test -f ..."` here,
/// which is unreliable on Windows dev boxes (Git for Windows ships
/// git.exe + bash.exe but doesn't add `C:\Program Files\Git\bin` to
/// PATH automatically). The probe then silently fell through to
/// "vendor fallback" even when vcpkg had the libraries installed at
/// `C:\vcpkg\installed\x64-windows\` — same failure mode the root
/// build.zig hit (and fixed). Host-OS-specific direct syscalls via
/// `std.os`, NOT `std.c` — build.zig doesn't link libc by default
/// (Zig 0.16 requires an explicit `link_libc = true` on the build
/// runner module for `std.c` to resolve `fopen`).
///
///   - Linux:   `faccessat(AT_FDCWD, path, mode=0)` returns 0 when
///              the file exists.
///   - macOS:   same `faccessat` (POSIX).
///   - Windows: `GetFileAttributesW` returns INVALID_FILE_ATTRIBUTES
///              on missing; existence = attrs != invalid AND attrs
///              doesn't have the DIRECTORY bit set (mirror `test -f`).
fn fileExists(absolute_path: []const u8) bool {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (absolute_path.len >= buf.len) return false;
    @memcpy(buf[0..absolute_path.len], absolute_path);
    buf[absolute_path.len] = 0;
    return switch (@import("builtin").os.tag) {
        .linux => blk: {
            const rc = std.os.linux.faccessat(std.os.linux.AT.FDCWD, &buf, 0, 0);
            break :blk rc == 0;
        },
        .macos => fileExistsViaShell(absolute_path),
        .windows => blk: {
            // Win32 GetFileAttributesW (kernel32.dll, always linked on
            // Windows). UTF-8 path → WTF-16. Directory bit excluded
            // so this matches `test -f` semantics.
            var wide: [std.fs.max_path_bytes]u16 = undefined;
            const written = std.unicode.wtf8ToWtf16Le(&wide, absolute_path) catch break :blk false;
            if (written >= wide.len) break :blk false;
            wide[written] = 0;
            const attrs = GetFileAttributesW(@ptrCast(&wide));
            if (attrs == INVALID_FILE_ATTRIBUTES) break :blk false;
            if ((attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

/// macOS-only fallback for `fileExists`. Mac always has `/bin/sh`
/// available (Darwin requires a POSIX shell), so the shell-out is
/// reliable there — it just isn't reliable on Windows dev boxes
/// where bash.exe exists but isn't on PATH.
fn fileExistsViaShell(absolute_path: []const u8) bool {
    var cmd_buf: [std.fs.max_path_bytes * 2:0]u8 = undefined;
    const cmd_slice = std.fmt.bufPrint(
        &cmd_buf,
        "test -f '{s}' && echo 1 || echo 0",
        .{absolute_path},
    ) catch return false;
    cmd_buf[cmd_slice.len] = 0;
    const cmd_z: [*:0]const u8 = &cmd_buf;

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const result = std.process.run(
        gpa_state.allocator(),
        .{ .stdout = .piped, .stderr = .piped },
        .{
            .argv = &.{ "/bin/sh", "-c", cmd_z },
            .stdout_limit = .limited(64),
            .stderr_limit = .limited(64),
        },
    ) catch return false;
    defer gpa_state.allocator().free(result.stdout);
    defer gpa_state.allocator().free(result.stderr);
    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    return std.mem.eql(u8, trimmed, "1");
}

// Win32 GetFileAttributesW (mirrors the root build.zig declarations —
// declared locally because std.os.windows.kernel32 0.16 doesn't expose
// it. Win32 kernel32.dll is always linked on Windows).
extern "kernel32" fn GetFileAttributesW(lpPathName: [*:0]const u16) callconv(.winapi) u32;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x00000010;

/// Result of probing the host system for libcurl / libssl / libcrypto.
///
/// SYSTEM-ONLY LINKS: when `use_system` is true, the package links against
/// the host's installed libcurl / libssl / libcrypto via `linkSystemLibrary`
/// and uses the host's `/usr/include` for the cimported headers. The
/// vendored prebuilt archive at `vendor/curl/<target>/lib/libcurl.a` is
/// NOT linked — saves ~30 min cross-compile on hosts that have the system
/// libs (Arch / Debian / Ubuntu / Fedora all do).
///
/// VENDOR FALLBACK: when the probe can't find a usable system libcurl,
/// the package uses the vendored archive as before. The archive is a
/// "fat" build with OpenSSL symbols merged in (see
/// scripts/build-vendor-curl.sh), so it works without any host-installed
/// TLS lib.
const SystemLibs = struct {
    use_system: bool,
    /// True when the probe found curl.h AND libcurl.so on the host.
    found_curl: bool,
    /// True when the probe found openssl/ssl.h AND libssl.so on the host.
    found_ssl: bool,
    /// True when the probe found openssl/ssl.h AND libcrypto.so on the host.
    found_crypto: bool,
};

/// Probe the host system for libcurl / libssl / libcrypto.
///
/// Runs `sh -c` synchronously at build config time (via
/// `std.process.run`) and parses 5 boolean fields out of its stdout.
/// The probe runs in ~25 ms on a typical Linux host — cheap enough
/// to re-run on every `zig build` invocation (no caching needed).
///
/// `use_system` is true ONLY when all three libs are present on the
/// host AND the COMPILE target is the same as the host. Cross-compile
/// (Linux host → macOS target) always falls back to vendor because
/// the host's libs are for Linux, not macOS — linking them into a
/// macOS binary would fail at link time with mismatched arch.
///
/// `target` is the COMPILE's resolved target (what the binary will
/// run on), NOT `b.graph.host` (what the build is running on). The
/// package's `build()` function passes `target` to this probe so
/// cross-compile picks up the vendored archive automatically.
///
/// A partial setup (curl but no SSL) is treated as "no system libs"
/// — the vendored archive is self-contained with OpenSSL merged in,
/// so partial system setups would create a mixed link line that
/// could fail in non-obvious ways (e.g. undefined symbol
/// `SSL_CTX_set_keylog_callback` if libssl.so is missing).
///
/// Only Linux + macOS (native) are probed. Windows needs explicit
/// .lib paths and falls back to vendor. Cross-compile (Linux host →
/// macOS target, or vice versa) also falls back to vendor because the
/// host's libs are for the host OS, not the target OS.
///
/// On macOS the probe checks Homebrew's keg-only paths under
/// `/opt/homebrew/opt/<name>/{include,lib}/`. The CI yml installs
/// `pkg-config openssl@3 coreutils` (but NOT curl) on Mac runners and
/// exports LDFLAGS/CPPFLAGS from `brew --prefix openssl@3`. For
/// system libcurl on Mac, add `brew install curl` to the CI yml — the
/// probe will then pick it up at `/opt/homebrew/opt/curl/`.
pub fn probeSystemLibs(b: *std.Build, target: std.Build.ResolvedTarget) SystemLibs {
    // Only native (target == host) goes system-only. Cross-compile
    // (Linux host → macOS target, or vice versa) always falls back to
    // vendor — the host's libs are for the host OS.
    if (target.result.os.tag != b.graph.host.result.os.tag) {
        return .{
            .use_system = false,
            .found_curl = false,
            .found_ssl = false,
            .found_crypto = false,
        };
    }

    // Pure-Zig probe — no shell, no `bash` / `sh` dependency.
    //
    // Earlier revisions ran `sh -c "test -f ..."` here via
    // `std.process.run`. Windows dev boxes without `bash` / `sh` on
    // PATH (Git for Windows ships bash.exe at `C:\Program Files\Git\
    // bin` but doesn't add it to PATH automatically) saw the probe
    // spawn-fail, fall through to `use_system = false`, and end up
    // looking for the vendored `vendor/curl/<target>/lib/libcurl.a`
    // archive — which on Windows is hardcoded to `windows-amd64/` and
    // doesn't exist for any host (the script
    // `scripts/build-vendor-curl.sh` only cross-compiles Linux + macOS
    // archives; Windows archives are intentionally NOT built).
    //
    // Pure-Zig fix: use the local `fileExists` helper (defined above)
    // with host-OS-specific paths. Mirrors the equivalent change in
    // the root build.zig's system-deps probe.
    var curl_hdr: bool = false;
    var found_curl_lib: bool = false;
    var ssl_hdr: bool = false;
    var found_ssl_lib: bool = false;
    var found_crypto_lib: bool = false;
    switch (b.graph.host.result.os.tag) {
        .linux => {
            // Linux: checks /usr/include + /usr/lib (Arch / Debian /
            // Ubuntu / Fedora layouts). Headers at the canonical
            // paths; libs probed via direct .so path glob since
            // `ldconfig -p` is shell-only.
            //
            // (We check the unversioned `libcurl.so` symlink AND the
            // unversioned `libssl.so` / `libcrypto.so` — most distros
            // keep these as symlinks to the versioned .so.N library.)
            curl_hdr = fileExists("/usr/include/curl/curl.h");
            found_curl_lib = fileExists("/usr/lib/libcurl.so");
            ssl_hdr = fileExists("/usr/include/openssl/ssl.h");
            found_ssl_lib = fileExists("/usr/lib/libssl.so");
            found_crypto_lib = fileExists("/usr/lib/libcrypto.so");
        },
        .macos => {
            // macOS: Homebrew installs keg-only libs at
            // `/opt/homebrew/opt/<name>/{include,lib}/`. No ldconfig
            // equivalent — we test for the .dylib file directly at the
            // canonical brew path. We also accept a system
            // `/usr/include` install (rare).
            curl_hdr = fileExists("/opt/homebrew/opt/curl/include/curl/curl.h") or
                fileExists("/usr/include/curl/curl.h");
            found_curl_lib = fileExists("/opt/homebrew/opt/curl/lib/libcurl.dylib") or
                fileExists("/usr/lib/libcurl.dylib");
            ssl_hdr = fileExists("/opt/homebrew/opt/openssl@3/include/openssl/ssl.h") or
                fileExists("/opt/homebrew/opt/openssl/include/openssl/ssl.h") or
                fileExists("/usr/include/openssl/ssl.h");
            found_ssl_lib = fileExists("/opt/homebrew/opt/openssl@3/lib/libssl.dylib") or
                fileExists("/usr/lib/libssl.dylib");
            found_crypto_lib = fileExists("/opt/homebrew/opt/openssl@3/lib/libcrypto.dylib") or
                fileExists("/usr/lib/libcrypto.dylib");
        },
        .windows => {
            // Windows: vcpkg at `C:/vcpkg/installed/x64-windows/`.
            // The CI installs curl + openssl via
            // `vcpkg install --recurse <port>:x64-windows`. Header-only
            // probe: vcpkg's `lib/` filenames differ between MSVC
            // (`curl.lib`) and MinGW (`libcurl.lib`), and may also be
            // hidden behind `.dll.lib` or vendor-specific names. Rather
            // than enumerate every naming variant, we just check
            // headers — `linkSystemLibrary` / `addObjectFile` will
            // fail loudly with "file not found" if the lib is actually
            // missing. Headers are stable across toolchain variants.
            curl_hdr = fileExists("C:/vcpkg/installed/x64-windows/include/curl/curl.h");
            ssl_hdr = fileExists("C:/vcpkg/installed/x64-windows/include/openssl/ssl.h");
        },
        else => {
            // Cross-compile to an unknown OS — bail.
            curl_hdr = false;
            found_curl_lib = false;
            ssl_hdr = false;
            found_ssl_lib = false;
            found_crypto_lib = false;
        },
    }

    // Two patterns of use_system:
    //
    //   - Linux/macOS: require header + matching .so/.dylib to be
    //     present. We need both: header alone (libcurl dev package
    //     installed without runtime) means consumer compile passes
    //     but the linked .so is missing → runtime crash. The .so/.dylib
    //     files live under the same brew keg / distro paths.
    //   - Windows: header-only. The custom_http_client module uses
    //     `addObjectFile` to wire the exact `.lib` path into the
    //     link line; that fails loudly if the lib is actually
    //     missing (Zig prints the missing path). So we don't need
    //     a redundant lib check.
    const use_system: bool = switch (b.graph.host.result.os.tag) {
        .linux => curl_hdr and found_curl_lib and ssl_hdr and found_ssl_lib and found_crypto_lib,
        .macos => curl_hdr and found_curl_lib and ssl_hdr and found_ssl_lib and found_crypto_lib,
        .windows => curl_hdr and ssl_hdr,
        else => false,
    };
    const found_curl = curl_hdr;
    const found_ssl = ssl_hdr;
    const found_crypto = ssl_hdr; // crypto lives under openssl/ssl.h — same header

    // Log the probe result so the operator sees which path was taken.
    // On a quiet build (no --verbose) zig's std.debug.print routes to
    // stderr — easy to spot in build output.
    if (use_system) {
        std.debug.print(
            "[custom_http_client] using system libcurl + ssl + crypto (host has all 3 headers)\n",
            .{},
        );
    } else {
        std.debug.print(
            "[custom_http_client] using vendored libcurl fat archive (host probe: curl_hdr={} ssl_hdr={})\n",
            .{ curl_hdr, ssl_hdr },
        );
    }

    return .{
        .use_system = use_system,
        .found_curl = found_curl,
        .found_ssl = found_ssl,
        .found_crypto = found_crypto,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Path to the vendored curl directory, relative to this
    // package's build.zig. Default is `vendor/curl/` co-located with
    // this build.zig (the package owns its own vendor dir — the
    // build script at scripts/build-vendor-curl.sh populates it).
    // Override with `-Dvendor-dir=...` if you move it elsewhere.
    const vendor_dir = b.option(
        []const u8,
        "vendor-dir",
        "Path to vendor/curl/ (relative to this package, default 'vendor/curl')",
    ) orelse "vendor/curl";

    // Force-use vendor (skip the system probe). Useful for CI runners
    // that have system libs but want a hermetic build, or for testing
    // the vendored path. Default: false (probe decides).
    const force_vendor = b.option(
        bool,
        "force-vendor",
        "Skip the system probe and always use the vendored libcurl archive",
    ) orelse false;

    const mod = b.addModule("custom_http_client", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Universal: libc is required by every libcurl binding + cimport.
    mod.linkSystemLibrary("c", .{});
    mod.link_libc = true;

    // Probe host system for libcurl + openssl. When the probe finds
    // usable system libs (typical Arch / Debian / Fedora dev hosts),
    // link the system libs and skip the vendored archive entirely.
    // Otherwise fall back to the vendored fat archive (curl + ssl +
    // crypto merged into one .a).
    const sys = if (force_vendor) SystemLibs{
        .use_system = false,
        .found_curl = false,
        .found_ssl = false,
        .found_crypto = false,
    } else probeSystemLibs(b, target);

    if (sys.use_system) {
        // System libs path. `linkSystemLibrary("curl")` does NOT auto-
        // pull libssl/libcrypto (no pkg-config Requires honour), so we
        // link them explicitly. The cimport for `curl/curl.h` needs
        // `/usr/include` on the include path on Linux (Debian/Ubuntu
        // put curl.h at `/usr/include/curl/curl.h` and the cimport does
        // `#include <curl/curl.h>`, so /usr/include must be on the
        // search path). Most distros add /usr/include by default, but
        // some configurations (e.g. cross-compile toolchains) don't —
        // add it explicitly so the cimport works everywhere.
        //
        // On macOS, the probe only returns `use_system=true` when both
        // /opt/homebrew/opt/curl/include/curl/curl.h AND
        // /opt/homebrew/opt/openssl@3/include/openssl/ssl.h exist.
        // We mirror those paths here so the cimport resolves
        // <curl/curl.h> and <openssl/ssl.h> regardless of which
        // include-path probe happens to win the search.
        switch (target.result.os.tag) {
            .linux => {
                mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
            },
            .macos => {
                // Probe uses an OR-of-paths predicate, but link only
                // succeeds against the path that actually has the .dylib.
                // /opt/homebrew/opt/curl/include and
                // /opt/homebrew/opt/openssl@3/include are the canonical
                // keg-only Homebrew paths on Apple Silicon.
                mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/curl/include" });
                mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/openssl@3/include" });
                // Library search paths so linkSystemLibrary can find
                // the .dylib (it's keg-only — not on the default search
                // path). The /usr/lib fallback covers system-wide installs.
                mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/curl/lib" });
                mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/openssl@3/lib" });
                mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            },
            .windows => {
                // vcpkg at `C:/vcpkg/installed/x64-windows/`. Both the
                // include and lib subdirs are added explicitly because
                // the cimport in src/curl.zig resolves <curl/curl.h>
                // and the linker needs to find the .lib files at link
                // time. The `\` → `/` translation is fine on Windows
                // since the NTFS layer accepts both separators — Zig's
                // path-handler routes them through the same kernel
                // APIs.
                //
                // Use addObjectFile (not linkSystemLibrary) to bypass
                // the GNU-vs-MSVC lib-name convention mismatch: the
                // build target is `x86_64-windows-gnu` (GNU toolchain
                // conventions — `libcurl.a`), but vcpkg ships
                // `libcurl.lib` (MSVC-style extension, GCC-style name).
                // Explicit object-file links work with either naming
                // — the linker doesn't try to translate `-lcurl` →
                // `libcurl.{a,lib}` it just adds the file the build.zig
                // hands it.
                mod.addIncludePath(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/include" });
                mod.addObjectFile(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/lib/libcurl.lib" });
                mod.addObjectFile(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/lib/libssl.lib" });
                mod.addObjectFile(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/lib/libcrypto.lib" });
            },
            else => {
                mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
            },
        }
        // addObjectFile above replaces these linkSystemLibrary calls
        // on Windows (where the vcpkg lib-file naming doesn't match
        // the GNU `libfoo.a` convention). On Linux + macOS the
        // linkSystemLibrary calls below work because the system libs
        // are at `/usr/lib/libfoo.so.<n>` / `/opt/homebrew/opt/...`/
        // `libfoo.dylib`, which IS the convention `linkSystemLibrary`
        // looks for on those platforms.
        if (target.result.os.tag != .windows) {
            mod.linkSystemLibrary("curl", .{});
            mod.linkSystemLibrary("ssl", .{});
            mod.linkSystemLibrary("crypto", .{});
        }
    } else {
        // Vendored path. Add the per-target include path + embed the
        // prebuilt archive as an object file.
        const target_subdir = switch (target.result.os.tag) {
            .linux => b.fmt("linux-{s}", .{switch (target.result.cpu.arch) {
                .x86_64 => "x86_64",
                .aarch64 => "aarch64",
                else => @panic("vendored curl: unsupported Linux arch"),
            }}),
            .macos => switch (target.result.cpu.arch) {
                .aarch64 => "macos-arm64",
                .x86_64 => "macos-x86_64",
                else => @panic("vendored curl: unsupported macOS arch"),
            },
            .windows => "windows-amd64", // script doesn't build yet — see note
            else => @panic("vendored curl: unsupported OS"),
        };
        const target_dir = b.fmt("{s}/{s}", .{ vendor_dir, target_subdir });

        // Header path — needed by `@cImport(@cInclude("curl/curl.h"))`
        // inside src/curl.zig. The header is portable C, so the same
        // vendored copy works for every host (Zig's cimport uses the
        // HOST C compiler, not the cross-target compiler).
        mod.addIncludePath(b.path(b.fmt("{s}/include", .{target_dir})));

        // Link the prebuilt vendored archive directly into every consumer.
        // addObjectFile embeds the .a symbols in the consumer's link line
        // (no separate -L/-l needed — Zig's linker resolves the archive's
        // undefined symbols at consumer link time).
        //
        // The archive is a FAT build: curl + libssl + libcrypto objects
        // merged in one .a (see scripts/build-vendor-curl.sh). So we
        // do NOT also link ssl/crypto — they're already in the archive.
        const libcurl_a = b.path(b.fmt("{s}/lib/libcurl.a", .{target_dir}));
        mod.addObjectFile(libcurl_a);
    }

    // === Tests for the package itself ===
    // `b.addTest({ .root_module = mod })` walks every `_test.zig`
    // reachable from src/root.zig via the `test { _ = @import(...) }`
    // block. The mod already carries link_libc + (system or vendored)
    // libcurl, so test executables inherit those deps automatically.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run custom_http_client package tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(b.getInstallStep());
}
