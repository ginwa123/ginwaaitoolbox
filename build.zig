const std = @import("std");
const fs = std.fs;
const mem = std.mem;

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
            .imports = &.{.{ .name = "tree1", .module = mod }},
        }),
    });
    exe.linkSystemLibrary("sqlite3");
    exe.linkLibC();
    return exe;
}

/// Discovers and adds all *_test.zig files in the src/ directory to the test step.
/// Uses an arena allocator for the directory walk, which is freed after the build graph is constructed.
fn addDiscoveredTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    mod: *std.Build.Module,
) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Walk the src/ directory recursively to find test files
    var src_dir = fs.cwd().openDir("src", .{ .iterate = true }) catch |err| {
        std.log.warn("Failed to open src directory: {s}", .{@errorName(err)});
        return;
    };
    defer src_dir.close();

    var walker = src_dir.walk(allocator) catch |err| {
        std.log.warn("Failed to create directory walker: {s}", .{@errorName(err)});
        return;
    };
    defer walker.deinit();

    const test_suffix = "_test.zig";
    var test_count: usize = 0;

    while (true) {
        const entry = walker.next() catch |err| {
            std.log.warn("Error walking directory: {s}", .{@errorName(err)});
            break;
        } orelse break;

        // Check if this is a file ending with _test.zig
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, test_suffix)) continue;

        // Construct the full path relative to project root
        const rel_path = std.fs.path.join(allocator, &.{ "src", entry.path }) catch continue;

        // Determine if this test needs sqlite3 (database tests)
        const needs_sqlite = mem.indexOf(u8, rel_path, "/databases/sqlite/") != null or
                     mem.indexOf(u8, rel_path, "/ai_workflow/") != null;

        // Create a test module that can import tree1
        const test_mod = b.createModule(.{
            .root_source_file = b.path(rel_path),
            .target = mod.resolved_target orelse b.standardTargetOptions(.{}),
            .optimize = .Debug,
            .imports = &.{.{ .name = "tree1", .module = mod }},
        });

        // Create the test executable
        const test_exe = b.addTest(.{
            .root_module = test_mod,
        });

        // Link required libraries
        test_exe.linkLibC();
        if (needs_sqlite) {
            test_exe.linkSystemLibrary("sqlite3");
        }

        // Create run step for this test
        const run_test = b.addRunArtifact(test_exe);

        // Add to test step
        test_step.dependOn(&run_test.step);

        test_count += 1;
        std.log.info("Discovered test: {s}", .{rel_path});
    }

    std.log.info("Total test files discovered: {d}", .{test_count});
}

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("tree1", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Allow the tree1 module to import itself (for internal files like ai_workflow)
    mod.addImport("tree1", mod);

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "tree1",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "tree1" is the name you will use in your source code to
                // import this module (e.g. `@import("tree1")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "tree1", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    //
    b.installArtifact(exe);

    exe.linkSystemLibrary("sqlite3");
    exe.linkLibC();

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // TUI executable
    const tui_exe = b.addExecutable(.{
        .name = "tree1-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tui_exe.linkLibC();
    b.installArtifact(tui_exe);

    const tui_step = b.step("run:tui", "Run the TUI");
    const tui_cmd = b.addRunArtifact(tui_exe);
    tui_step.dependOn(&tui_cmd.step);
    tui_cmd.step.dependOn(b.getInstallStep());

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.linkLibC();

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Discover and add all *_test.zig files automatically
    addDiscoveredTests(b, test_step, mod);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.

    // Platform-specific build steps
    // Linux x86_64 - uses host target to find system sqlite3
    const linux_step = b.step("install:linux", "Build for Linux x86_64");
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });
    const linux_exe = createPlatformExe(b, mod, linux_target, optimize, "tree1-linux-x86_64");
    // Add common library paths for sqlite3
    linux_exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    const install_linux = b.addInstallArtifact(linux_exe, .{});
    linux_step.dependOn(&install_linux.step);

    // Windows x86_64 (GNU ABI for MinGW compatibility)
    const windows_step = b.step("install:windows", "Build for Windows x86_64");
    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const windows_exe = createPlatformExe(b, mod, windows_target, optimize, "tree1-windows-x86_64.exe");
    const install_windows = b.addInstallArtifact(windows_exe, .{});
    windows_step.dependOn(&install_windows.step);

    // macOS x86_64
    const macos_step = b.step("install:macos", "Build for macOS x86_64");
    const macos_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
    });
    const macos_exe = createPlatformExe(b, mod, macos_target, optimize, "tree1-macos-x86_64");
    const install_macos = b.addInstallArtifact(macos_exe, .{});
    macos_step.dependOn(&install_macos.step);

    // macOS aarch64 (Apple Silicon)
    const macos_arm_step = b.step("install:macos-arm", "Build for macOS aarch64 (Apple Silicon)");
    const macos_arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    const macos_arm_exe = createPlatformExe(b, mod, macos_arm_target, optimize, "tree1-macos-aarch64");
    const install_macos_arm = b.addInstallArtifact(macos_arm_exe, .{});
    macos_arm_step.dependOn(&install_macos_arm.step);

    // Linux x86_64 - Install to system (/usr/local/bin)
    const linux_system_step = b.step("install:linux:system", "Build for Linux x86_64 and install to system (/usr/local/bin - requires sudo)");
    const linux_system_exe = createPlatformExe(b, mod, linux_target, optimize, "zigginagentic");
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

    // TUI for Linux x86_64 - Install to system (/usr/local/bin)
    const tui_linux_system_step = b.step("install:tui:linux:system", "Build TUI for Linux x86_64 and install to system (/usr/local/bin - requires sudo)");
    const tui_linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });
    const tui_linux_exe = b.addExecutable(.{
        .name = "zigginagentic-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/main.zig"),
            .target = tui_linux_target,
            .optimize = optimize,
        }),
    });
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
