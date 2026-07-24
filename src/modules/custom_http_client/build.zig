const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Cross-platform libcurl paths (mirrors the `-Dsqlite-prefix` convention
    // used by the parent `build.zig` for libsqlite3). Declared ONCE here so
    // we can pass the resolved strings into `configureLibcurl` — Zig's
    // `b.option()` API rejects double-declaration of the same option name.
    //
    //   - Linux:   `/usr/include` + system libcurl
    //   - macOS:   $(brew --prefix curl)/{include,lib}   (Homebrew keg-only)
    //   - Windows: $(vcpkg root)/installed/x64-windows/{include,lib}
    //
    // The macOS default `/opt/homebrew` is the Apple-Silicon layout; Intel
    // Macs override with `-Dcurl-prefix=/usr/local`.
    const curl_prefix = b.option(
        []const u8,
        "curl-prefix",
        "Homebrew prefix for the libcurl keg (default: /opt/homebrew)",
    ) orelse "/opt/homebrew";
    const curl_vcpkg_root = b.option(
        []const u8,
        "curl-vcpkg-root",
        "vcpkg root for Windows libcurl (default: C:/vcpkg)",
    ) orelse "C:/vcpkg";

    const mod = b.addModule("custom_http_client", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Link libcurl on every platform we support. libcurl's `curl_easy_*` ABI
    // is stable across versions; we only need its header path on Linux.
    mod.linkSystemLibrary("curl", .{});
    mod.link_libc = true;
    configureLibcurl(b, mod, target.result.os.tag, curl_prefix, curl_vcpkg_root);

    // CLI executable (manual smoke test). The tests below also exercise
    // the module directly.
    const exe = b.addExecutable(.{
        .name = "custom_http_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "custom_http_client", .module = mod },
            },
        }),
    });
    exe.root_module.linkSystemLibrary("curl", .{});
    exe.root_module.link_libc = true;
    configureLibcurl(b, exe.root_module, target.result.os.tag, curl_prefix, curl_vcpkg_root);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Test executable — exercises every `*_test.zig` registered via test_runner.zig.
    //
    // The streaming tests need an in-process HTTP server. We import the
    // adjacent `custom_http_server` module (compiled from
    // src/modules/custom_http_server/src/http_server.zig) so the tests
    // can spin up a GinwaServer on an ephemeral port in-process,
    // eliminating the httpbin.org network dependency. The import is
    // attached to the test module only — production builds of
    // custom_http_client don't pull in the server.
    const server_mod = b.createModule(.{
        .root_source_file = b.path("../custom_http_server/src/http_server.zig"),
        .target = target,
    });
    server_mod.linkSystemLibrary("c", .{});
    mod.addImport("custom_http_server", server_mod);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.root_module.linkSystemLibrary("curl", .{});
    mod_tests.root_module.link_libc = true;
    configureLibcurl(b, mod_tests.root_module, target.result.os.tag, curl_prefix, curl_vcpkg_root);
    if (target.result.os.tag == .linux) {
        server_mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    }

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.root_module.linkSystemLibrary("curl", .{});
    exe_tests.root_module.link_libc = true;
    configureLibcurl(b, exe_tests.root_module, target.result.os.tag, curl_prefix, curl_vcpkg_root);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // NOTE: `-Dintegration=true` and `-Dstress=true` flags are documented
    // in the plan; the actual opt-in wiring lives in `test_runner.zig` via
    // generated module files we plan to add in Chunk 3 when needed. For
    // Chunk 1 we keep the test suite deterministic (no live network).
}

/// Wire the platform-specific include + library paths for libcurl. Extracted
/// as a helper so the same logic applies to the library module, the CLI exe,
/// and both test executables (4 link points per build invocation).
///
/// Mirrors the `-Dsqlite-prefix` pattern in the parent `build.zig`
/// (lines 430-450) — see that file for the full rationale on brew keg-only
/// paths and vcpkg sysroot layouts.
///
/// Options are resolved in `build()` ONCE (Zig's `b.option()` rejects
/// double-declaration) and passed in as plain `[]const u8` slices.
fn configureLibcurl(
    b: *std.Build,
    module: *std.Build.Module,
    os_tag: std.Target.Os.Tag,
    curl_prefix: []const u8,
    curl_vcpkg_root: []const u8,
) void {
    switch (os_tag) {
        .linux => {
            module.addIncludePath(.{ .cwd_relative = "/usr/include" });
        },
        .macos => {
            // Homebrew's curl is keg-only. Apple-Silicon default prefix is
            // `/opt/homebrew`; Intel macs override with `-Dcurl-prefix=/usr/local`.
            module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/opt/curl/include", .{curl_prefix}) });
            module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/opt/curl/lib", .{curl_prefix}) });
        },
        .windows => {
            // vcpkg layout: <root>/installed/<triplet>/{include,lib}.
            // Default triplet is x64-windows; ARM64 would be arm64-windows.
            module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/installed/x64-windows/include", .{curl_vcpkg_root}) });
            module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/installed/x64-windows/lib", .{curl_vcpkg_root}) });
        },
        else => {
            // Other targets (WASI, freestanding, etc.) — not supported.
            // linkSystemLibrary("curl") will fail at link time with a clear error.
        },
    }
}