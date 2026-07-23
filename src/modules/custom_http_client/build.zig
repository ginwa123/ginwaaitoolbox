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

    const mod = b.addModule("custom_http_client", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Link libcurl on every platform we support. libcurl's `curl_easy_*` ABI
    // is stable across versions; we only need its header path on Linux.
    // (macOS brew keg-only / Windows vcpkg are documented in NALAR.md as
    // follow-ups — this v1 only verifies the Linux path.)
    mod.linkSystemLibrary("curl", .{});
    mod.link_libc = true;

    // Link against system libcurl headers (libcurl 8.21.0 ships at
    // /usr/include/curl/curl.h on Arch Linux).
    const builtin = @import("builtin");
    if (target.result.os.tag == .linux) {
        mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    } else if (target.result.os.tag == .macos) {
        // Homebrew's curl is keg-only. The parent build is expected to
        // wire the include path via the existing PKG_CONFIG_PATH plumbing.
        mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    }
    _ = builtin;

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
    if (target.result.os.tag == .linux) {
        exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    }
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Test executable — exercises every `*_test.zig` registered via test_runner.zig.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.root_module.linkSystemLibrary("curl", .{});
    mod_tests.root_module.link_libc = true;
    if (target.result.os.tag == .linux) {
        mod_tests.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    }

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.root_module.linkSystemLibrary("curl", .{});
    exe_tests.root_module.link_libc = true;
    if (target.result.os.tag == .linux) {
        exe_tests.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    }
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // NOTE: `-Dintegration=true` and `-Dstress=true` flags are documented
    // in the plan; the actual opt-in wiring lives in `test_runner.zig` via
    // generated module files we plan to add in Chunk 3 when needed. For
    // Chunk 1 we keep the test suite deterministic (no live network).
}
