const std = @import("std");

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
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    exe.root_module.linkSystemLibrary("ssl", .{});
    exe.root_module.linkSystemLibrary("crypto", .{});
    exe.root_module.linkSystemLibrary("c", .{});
    return exe;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const http_dep = b.dependency("httpz", .{ .target = target, .optimize = optimize });

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

    exe.root_module.linkSystemLibrary("sqlite3", .{});
    exe.root_module.linkSystemLibrary("ssl", .{});
    exe.root_module.linkSystemLibrary("crypto", .{});
    exe.root_module.linkSystemLibrary("c", .{});

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
    tui_exe.root_module.linkSystemLibrary("ssl", .{});
    tui_exe.root_module.linkSystemLibrary("crypto", .{});
    tui_exe.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(tui_exe);

    const tui_step = b.step("run:tui", "Run the TUI");
    const tui_cmd = b.addRunArtifact(tui_exe);
    tui_step.dependOn(&tui_cmd.step);
    tui_cmd.step.dependOn(b.getInstallStep());

    const cli_step = b.step("run:cli", "Run the CLI");
    _ = cli_step;

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.root_module.linkSystemLibrary("c", .{});
    mod_tests.root_module.linkSystemLibrary("sqlite3", .{});
    mod_tests.root_module.linkSystemLibrary("ssl", .{});
    mod_tests.root_module.linkSystemLibrary("crypto", .{});

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const ai_workflow_tui_test_mod = b.addTest(.{
        .root_module = mod,
    });
    ai_workflow_tui_test_mod.root_module.linkSystemLibrary("c", .{});
    ai_workflow_tui_test_mod.root_module.linkSystemLibrary("sqlite3", .{});
    ai_workflow_tui_test_mod.root_module.linkSystemLibrary("ssl", .{});
    ai_workflow_tui_test_mod.root_module.linkSystemLibrary("crypto", .{});

    const run_ai_workflow_tui_tests = b.addRunArtifact(ai_workflow_tui_test_mod);
    const test_ai_workflow_tui_step = b.step("test:ai_workflow:tui", "Run AI workflow TUI tests");
    test_ai_workflow_tui_step.dependOn(&run_ai_workflow_tui_tests.step);

    const linux_step = b.step("install:linux", "Build for Linux x86_64");
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });
    const linux_exe = createPlatformExe(b, mod, linux_target, optimize, "nalarcore-linux-x86_64");
    linux_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
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

    const linux_system_step = b.step("install:linux:system", "Build for Linux x86_64 and install to system");
    const linux_system_exe = createPlatformExe(b, mod, target, optimize, "nalar");
    linux_system_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_system_exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
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

    const tui_linux_system_step = b.step("install:tui:linux:system", "Build TUI for Linux x86_64 and install to system");
    const tui_linux_exe = b.addExecutable(.{
        .name = "nalar-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/tui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    tui_linux_exe.root_module.linkSystemLibrary("ssl", .{});
    tui_linux_exe.root_module.linkSystemLibrary("crypto", .{});
    tui_linux_exe.root_module.linkSystemLibrary("c", .{});
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

    const test_desktop_step = b.step("test:desktop", "Run desktop app tests (bun test)");
    const run_bun_test = b.addSystemCommand(&.{"bun", "test"});
    run_bun_test.cwd = .{ .cwd_relative = "src/apps/desktop-bun" };
    test_desktop_step.dependOn(&run_bun_test.step);

    const lint_step = b.step("lint", "Run Biome linter on TypeScript/JS files");
    const run_biome_lint = b.addSystemCommand(&.{"bun", "run", "lint"});
    run_biome_lint.cwd = .{ .cwd_relative = "src/apps/desktop-bun" };
    lint_step.dependOn(&run_biome_lint.step);

    const lint_fix_step = b.step("lint:fix", "Run Biome linter with auto-fix on TypeScript/JS files");
    const run_biome_lint_fix = b.addSystemCommand(&.{"bun", "run", "lint:fix"});
    run_biome_lint_fix.cwd = .{ .cwd_relative = "src/apps/desktop-bun" };
    lint_fix_step.dependOn(&run_biome_lint_fix.step);

    const format_step = b.step("format", "Format TypeScript/JS files with Biome");
    const run_biome_format = b.addSystemCommand(&.{"bun", "run", "format"});
    run_biome_format.cwd = .{ .cwd_relative = "src/apps/desktop-bun" };
    format_step.dependOn(&run_biome_format.step);

    const dev_optimize: std.builtin.OptimizeMode = .Debug;

    const dev_linux_system_step = b.step("install:dev:linux:system", "Build nalar-dev (debug) for Linux x86_64 and install to system");
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
    dev_exe.root_module.linkSystemLibrary("sqlite3", .{});
    dev_exe.root_module.linkSystemLibrary("ssl", .{});
    dev_exe.root_module.linkSystemLibrary("crypto", .{});
    dev_exe.root_module.linkSystemLibrary("c", .{});
    const install_dev = b.addInstallArtifact(dev_exe, .{});
    dev_linux_system_step.dependOn(&install_dev.step);
    const copy_dev_to_system = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/nalar-dev",
        "/usr/local/bin/nalar-dev",
    });
    copy_dev_to_system.step.dependOn(&install_dev.step);
    dev_linux_system_step.dependOn(&copy_dev_to_system.step);

    const dev_tui_linux_system_step = b.step("install:dev:tui:linux:system", "Build nalar-dev-tui (debug) for Linux x86_64 and install to system");
    const dev_tui_exe = b.addExecutable(.{
        .name = "nalar-dev-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/tui/main.zig"),
            .target = target,
            .optimize = dev_optimize,
            .imports = &.{},
        }),
    });
    dev_tui_exe.root_module.linkSystemLibrary("ssl", .{});
    dev_tui_exe.root_module.linkSystemLibrary("crypto", .{});
    dev_tui_exe.root_module.linkSystemLibrary("c", .{});
    const install_dev_tui = b.addInstallArtifact(dev_tui_exe, .{});
    dev_tui_linux_system_step.dependOn(&install_dev_tui.step);
    const copy_dev_tui_to_system = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/nalar-dev-tui",
        "/usr/local/bin/nalar-dev-tui",
    });
    copy_dev_tui_to_system.step.dependOn(&install_dev_tui.step);
    dev_tui_linux_system_step.dependOn(&copy_dev_tui_to_system.step);
}