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
/// Only Linux is probed. macOS Homebrew libcurl is keg-only
/// (`/opt/homebrew/opt/curl/` — not on the default link path), and
/// Windows needs explicit .lib paths; both fall back to vendor.
pub fn probeSystemLibs(b: *std.Build, target: std.Build.ResolvedTarget) SystemLibs {
    // Only Linux native (target == host == linux) goes system-only.
    // Anything else falls back to the vendored path.
    if (target.result.os.tag != .linux or b.graph.host.result.os.tag != .linux) {
        return .{
            .use_system = false,
            .found_curl = false,
            .found_ssl = false,
            .found_crypto = false,
        };
    }

    // Probe via a single shell command. Each line of output is
    // `<key>=<0|1>` — the parser below reads 5 keys.
    //
    // The probe uses `command -v` (POSIX) for the .so detection on
    // the off chance `ldconfig` is missing (Android, some containers),
    // and falls back to `command -v` which is always on POSIX paths.
    // The `grep -E "libcurl\.so(\.[0-9]+)*$"` matches libcurl.so
    // (unversioned) AND libcurl.so.4 (versioned) — both are valid
    // linker names.
    const probe_script =
        \\{ \
        \\  echo "curl_hdr=$(test -f /usr/include/curl/curl.h && echo 1 || echo 0)"; \
        \\  echo "curl_lib=$(ldconfig -p 2>/dev/null | grep -qE 'libcurl\.so(\.[0-9]+)*$' && echo 1 || echo 0)"; \
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
            .use_system = false,
            .found_curl = false,
            .found_ssl = false,
            .found_crypto = false,
        };
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    var curl_hdr: bool = false;
    var curl_lib: bool = false;
    var ssl_hdr: bool = false;
    var ssl_lib: bool = false;
    var crypto_lib: bool = false;

    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "curl_hdr=")) {
            curl_hdr = std.mem.eql(u8, line["curl_hdr=".len..], "1");
        } else if (std.mem.startsWith(u8, line, "curl_lib=")) {
            curl_lib = std.mem.eql(u8, line["curl_lib=".len..], "1");
        } else if (std.mem.startsWith(u8, line, "ssl_hdr=")) {
            ssl_hdr = std.mem.eql(u8, line["ssl_hdr=".len..], "1");
        } else if (std.mem.startsWith(u8, line, "ssl_lib=")) {
            ssl_lib = std.mem.eql(u8, line["ssl_lib=".len..], "1");
        } else if (std.mem.startsWith(u8, line, "crypto_lib=")) {
            crypto_lib = std.mem.eql(u8, line["crypto_lib=".len..], "1");
        }
    }

    const found_curl = curl_hdr and curl_lib;
    const found_ssl = ssl_hdr and ssl_lib;
    const found_crypto = ssl_hdr and crypto_lib; // ssl_hdr shared — crypto's header is also in openssl/ssl.h
    const use_system = found_curl and found_ssl and found_crypto;

    // Log the probe result so the operator sees which path was taken.
    // On a quiet build (no --verbose) zig's std.debug.print routes to
    // stderr — easy to spot in build output.
    if (use_system) {
        std.debug.print(
            "[custom_http_client] using system libcurl + ssl + crypto (host has all 3 libs + headers)\n",
            .{},
        );
    } else {
        std.debug.print(
            "[custom_http_client] using vendored libcurl fat archive (host probe: curl_hdr={} curl_lib={} ssl_hdr={} ssl_lib={} crypto_lib={})\n",
            .{ curl_hdr, curl_lib, ssl_hdr, ssl_lib, crypto_lib },
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
        // `/usr/include` on the include path (Debian/Ubuntu put curl.h
        // at `/usr/include/curl/curl.h` and the cimport does
        // `#include <curl/curl.h>`, so /usr/include must be on the
        // search path). Most distros add /usr/include by default, but
        // some configurations (e.g. cross-compile toolchains) don't —
        // add it explicitly so the cimport works everywhere.
        mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
        mod.linkSystemLibrary("curl", .{});
        mod.linkSystemLibrary("ssl", .{});
        mod.linkSystemLibrary("crypto", .{});
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
