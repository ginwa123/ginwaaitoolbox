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
        .name = "nalar",
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

    const tui_exe = b.addExecutable(.{
        .name = "nalarcore-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/tui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
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

    const cli_step = b.step("run:cli", "Run the CLI");
    _ = cli_step; // CLI has been removed. Use 'zig build run' for HTTP server or 'zig build run:tui' for TUI.

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

    // AI Workflow TUI tests step - using root.zig as test source to avoid module conflicts
    const ai_workflow_tui_test_mod = b.addTest(.{
        .root_module = mod,
    });
    ai_workflow_tui_test_mod.linkLibC();
    ai_workflow_tui_test_mod.linkSystemLibrary("sqlite3");
    ai_workflow_tui_test_mod.linkSystemLibrary("ssl");
    ai_workflow_tui_test_mod.linkSystemLibrary("crypto");

    const run_ai_workflow_tui_tests = b.addRunArtifact(ai_workflow_tui_test_mod);
    const test_ai_workflow_tui_step = b.step("test:ai_workflow:tui", "Run AI workflow TUI tests");
    test_ai_workflow_tui_step.dependOn(&run_ai_workflow_tui_tests.step);

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
    const linux_system_exe = createPlatformExe(b, mod, target, optimize, "nalar");
    linux_system_exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_system_exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    linux_system_step.dependOn(&linux_system_exe.step);
    const install_linux_system = b.addInstallArtifact(linux_system_exe, .{});
    linux_system_step.dependOn(&install_linux_system.step);
    const copy_to_system = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/nalar",
        "/usr/local/bin/nalar",
    });
    copy_to_system.step.dependOn(&install_linux_system.step);
    linux_system_step.dependOn(&copy_to_system.step);

    const tui_linux_system_step = b.step("install:tui:linux:system", "Build TUI for Linux x86_64 and install to system (/usr/local/bin - requires sudo)");
    const tui_linux_exe = b.addExecutable(.{
        .name = "nalar-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/tui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    tui_linux_exe.linkSystemLibrary("ssl");
    tui_linux_exe.linkSystemLibrary("crypto");
    tui_linux_exe.linkLibC();
    const install_tui_linux_system = b.addInstallArtifact(tui_linux_exe, .{});
    tui_linux_system_step.dependOn(&install_tui_linux_system.step);
    const copy_tui_to_system = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/nalar-tui",
        "/usr/local/bin/nalar-tui",
    });
    copy_tui_to_system.step.dependOn(&install_tui_linux_system.step);
    tui_linux_system_step.dependOn(&copy_tui_to_system.step);

    _ = b.step("run:kerjabot", "Kerjabot has been removed");

    // Desktop Bun tests step - runs bun test in src/apps/desktop-bun
    const test_desktop_step = b.step("test:desktop", "Run desktop app tests (bun test)");
    const run_bun_test = b.addSystemCommand(&.{"bun", "test"});
    run_bun_test.cwd = .{ .cwd_relative = "src/apps/desktop-bun" };
    test_desktop_step.dependOn(&run_bun_test.step);

    // Dev builds - optimized for development with debug symbols
    const dev_optimize: std.builtin.OptimizeMode = .Debug;

    const dev_linux_system_step = b.step("install:dev:linux:system", "Build nalar-dev (debug) for Linux x86_64 and install to system (/usr/local/bin - requires sudo)");
    const dev_exe = b.addExecutable(.{
        .name = "nalar-dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = dev_optimize,
            .imports = &.{
                .{ .name = "nalarcore", .module = mod },
            },
        }),
    });
    dev_exe.linkSystemLibrary("sqlite3");
    dev_exe.linkSystemLibrary("ssl");
    dev_exe.linkSystemLibrary("crypto");
    dev_exe.linkLibC();
    const install_dev = b.addInstallArtifact(dev_exe, .{});
    dev_linux_system_step.dependOn(&install_dev.step);
    const copy_dev_to_system = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/nalar-dev",
        "/usr/local/bin/nalar-dev",
    });
    copy_dev_to_system.step.dependOn(&install_dev.step);
    dev_linux_system_step.dependOn(&copy_dev_to_system.step);

    const dev_tui_linux_system_step = b.step("install:dev:tui:linux:system", "Build nalar-dev-tui (debug) for Linux x86_64 and install to system (/usr/local/bin - requires sudo)");
    const dev_tui_exe = b.addExecutable(.{
        .name = "nalar-dev-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/tui/main.zig"),
            .target = target,
            .optimize = dev_optimize,
            .imports = &.{},
        }),
    });
    dev_tui_exe.linkSystemLibrary("ssl");
    dev_tui_exe.linkSystemLibrary("crypto");
    dev_tui_exe.linkLibC();
    const install_dev_tui = b.addInstallArtifact(dev_tui_exe, .{});
    dev_tui_linux_system_step.dependOn(&install_dev_tui.step);
    const copy_dev_tui_to_system = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/nalar-dev-tui",
        "/usr/local/bin/nalar-dev-tui",
    });
    copy_dev_tui_to_system.step.dependOn(&install_dev_tui.step);
    dev_tui_linux_system_step.dependOn(&copy_dev_tui_to_system.step);

    // Desktop executable disabled - desktop source files not present
    // Uncomment when desktop files are added back
    // const desktop_exe = b.addExecutable(.{
    //     .name = "nalarcore-desktop",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/apps/desktop/main.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //         .imports = &.{},
    //     }),
    // });
    // desktop_exe.linkSystemLibrary("ssl");
    // desktop_exe.linkSystemLibrary("crypto");
    // desktop_exe.linkSystemLibrary("raylib");
    // desktop_exe.linkLibC();
    // desktop_exe.addIncludePath(.{ .cwd_relative = "src/apps/desktop" });
    // desktop_exe.addIncludePath(.{ .cwd_relative = "src/apps/desktop/renderer" });
    // desktop_exe.addCSourceFile(.{
    //     .file = b.path("src/apps/desktop/renderer/clay.c"),
    // });
    // desktop_exe.addCSourceFile(.{
    //     .file = b.path("src/apps/desktop/renderer/clay_renderer_raylib.c"),
    // });
    // b.installArtifact(desktop_exe);
    //
    // const desktop_step = b.step("run:desktop", "Run the Desktop app (requires raylib)");
    // const desktop_cmd = b.addRunArtifact(desktop_exe);
    // desktop_step.dependOn(&desktop_cmd.step);
    // desktop_cmd.step.dependOn(b.getInstallStep());
}
