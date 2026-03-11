const std = @import("std");

// Helper function to create platform-specific executables
fn createPlatformExe(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nalarcore", .module = mod }},
        }),
    });
    exe.linkSystemLibrary("sqlite3");
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");
    exe.linkLibC();
    return exe;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const http_dep = b.dependency("http", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("nalarcore", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.addImport("nalarcore", mod);
    mod.addImport("httpz", http_dep.module("httpz"));
    mod.addIncludePath(.{ .cwd_relative = "/usr/include" });

    const exe = b.addExecutable(.{
        .name = "nalarcore",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nalarcore", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    exe.linkSystemLibrary("sqlite3");
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");
    exe.linkLibC();

    const run_step = b.step("run", "Run the app");

    // TUI executable
    const tui_exe = b.addExecutable(.{
        .name = "nalarcore-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tui_exe.linkSystemLibrary("ssl");
    tui_exe.linkSystemLibrary("crypto");
    tui_exe.linkLibC();
    b.installArtifact(tui_exe);

    const tui_step = b.step("run:tui", "Run the TUI");
    const tui_cmd = b.addRunArtifact(tui_exe);
    tui_step.dependOn(&tui_cmd.step);
    tui_cmd.step.dependOn(b.getInstallStep());

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test step: only runs tests in root.zig (and everything it imports)
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.linkLibC();
    mod_tests.linkSystemLibrary("sqlite3");
    mod_tests.linkSystemLibrary("ssl");
    mod_tests.linkSystemLibrary("crypto");

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Platform-specific build steps
    const linux_step = b.step("install:linux", "Build for Linux x86_64");
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });
    const linux_exe = createPlatformExe(b, mod, linux_target, optimize, "nalarcore-linux-x86_64");
    linux_exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    const install_linux = b.addInstallArtifact(linux_exe, .{});
    linux_step.dependOn(&install_linux.step);

    const windows_step = b.step("install:windows", "Build for Windows x86_64");
    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const windows_exe = createPlatformExe(b, mod, windows_target, optimize, "nalarcore-windows-x86_64.exe");
    const install_windows = b.addInstallArtifact(windows_exe, .{});
    windows_step.dependOn(&install_windows.step);

    const macos_step = b.step("install:macos", "Build for macOS x86_64");
    const macos_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
    });
    const macos_exe = createPlatformExe(b, mod, macos_target, optimize, "nalarcore-macos-x86_64");
    const install_macos = b.addInstallArtifact(macos_exe, .{});
    macos_step.dependOn(&install_macos.step);

    const macos_arm_step = b.step("install:macos-arm", "Build for macOS aarch64 (Apple Silicon)");
    const macos_arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    const macos_arm_exe = createPlatformExe(b, mod, macos_arm_target, optimize, "nalarcore-macos-aarch64");
    const install_macos_arm = b.addInstallArtifact(macos_arm_exe, .{});
    macos_arm_step.dependOn(&install_macos_arm.step);

    const linux_system_step = b.step("install:linux:system", "Build for Linux x86_64 and install to system (/usr/local/bin - requires sudo)");
    const linux_system_exe = createPlatformExe(b, mod, target, optimize, "zigginagentic");
    linux_system_exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_system_exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    linux_system_step.dependOn(&linux_system_exe.step);
    const install_linux_system = b.addInstallArtifact(linux_system_exe, .{});
    linux_system_step.dependOn(&install_linux_system.step);
    const copy_to_system = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/zigginagentic",
        "/usr/local/bin/zigginagentic",
    });
    copy_to_system.step.dependOn(&install_linux_system.step);
    linux_system_step.dependOn(&copy_to_system.step);

    const tui_linux_system_step = b.step("install:tui:linux:system", "Build TUI for Linux x86_64 and install to system (/usr/local/bin - requires sudo)");
    const tui_linux_exe = b.addExecutable(.{
        .name = "zigginagentic-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tui_linux_exe.linkSystemLibrary("ssl");
    tui_linux_exe.linkSystemLibrary("crypto");
    tui_linux_exe.linkLibC();
    const install_tui_linux_system = b.addInstallArtifact(tui_linux_exe, .{});
    tui_linux_system_step.dependOn(&install_tui_linux_system.step);
    const copy_tui_to_system = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/zigginagentic-tui",
        "/usr/local/bin/zigginagentic-tui",
    });
    copy_tui_to_system.step.dependOn(&install_tui_linux_system.step);
    tui_linux_system_step.dependOn(&copy_tui_to_system.step);
}
