const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Executable
    const exe = b.addExecutable(.{
        .name = "custom_http_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test module - test_runner.zig imports root and all test files
    const test_mod = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_runner.zig"),
            .target = target,
        }),
    });
    const run_test_mod = b.addRunArtifact(test_mod);

    // Exe tests (main.zig tests if any)
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Test step runs both in parallel
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test_mod.step);
    test_step.dependOn(&run_exe_tests.step);
}