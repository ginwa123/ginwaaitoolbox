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
    test_mod.root_module.linkSystemLibrary("c", .{});
    const run_test_mod = b.addRunArtifact(test_mod);

    // Test step runs test module
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test_mod.step);
}