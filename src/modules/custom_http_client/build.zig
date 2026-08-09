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

const std = @import("std");

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

    const mod = b.addModule("custom_http_client", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Universal: libc is required by every libcurl binding + cimport.
    mod.linkSystemLibrary("c", .{});
    mod.link_libc = true;

    // Resolve the per-target subdirectory name. The bootstrap script
    // (scripts/build-vendor-curl.sh — co-located with this build.zig) writes:
    //   vendor/curl/linux-x86_64/{lib,include}/
    //   vendor/curl/macos-arm64/{lib,include}/
    //   vendor/curl/macos-x86_64/{lib,include}/
    //   vendor/curl/windows-amd64/{lib,include}/  ← not built yet
    //
    // The Zig target triple (arch-os-abi) doesn't directly match these
    // directory names (e.g. aarch64-macos-none != macos-arm64), so we
    // map explicitly. Unsupported targets panic at config time with a
    // clear message — better than a cryptic link error later.
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
    // For Linux native builds, this REPLACES the system libcurl.so —
    // the vendored archive is statically linked. For cross-targets
    // (Linux→macOS, Linux→Windows), the target-appropriate archive
    // is used. No more `linkSystemLibrary("curl", ...)` leak.
    const libcurl_a = b.path(b.fmt("{s}/lib/libcurl.a", .{target_dir}));
    mod.addObjectFile(libcurl_a);

    // === Tests for the package itself ===
    // `b.addTest({ .root_module = mod })` walks every `_test.zig`
    // reachable from src/root.zig via the `test { _ = @import(...) }`
    // block. The mod already carries link_libc + vendored libcurl,
    // so test executables inherit those deps automatically.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run custom_http_client package tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(b.getInstallStep());
}