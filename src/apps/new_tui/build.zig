const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the zigzag dependency (defined in build.zig.zon)
    const zigzag_dep = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("new_tui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "nalar-new-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "new_tui", .module = mod },
                .{ .name = "zigzag", .module = zigzag_dep.module("zigzag") },
            },
        }),
    });

    exe.linkSystemLibrary("sqlite3");
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");
    exe.linkLibC();
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run module tests");
    test_step.dependOn(&run_mod_tests.step);

    // Add executable tests
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    exe_tests.linkLibC();
    exe_tests.linkLibC();
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_exe_step = b.step("test:exe", "Run executable tests");
    test_exe_step.dependOn(&run_exe_tests.step);
}