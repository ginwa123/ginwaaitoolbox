const std = @import("std");
const builtin = @import("builtin");

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
    exe.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        exe.root_module.linkSystemLibrary("sqlite3", .{});
        exe.root_module.linkSystemLibrary("ssl", .{});
        exe.root_module.linkSystemLibrary("crypto", .{});
    } else if (target.result.os.tag == .windows or target.result.os.tag == .macos) {
        // Vendor sqlite3 amalgamation for Windows + macOS — compile from
        // source so the binary has sqlite3 support without relying on
        // system package layout. On macOS Sonoma+ the system sqlite3
        // dylib lives outside Zig's default `-lsqlite3` search paths,
        // so even when it's installed we get 13 undefined-symbol link
        // errors. Static linking via the amalgamation sidesteps this.
        exe.root_module.addIncludePath(b.path("vendor/sqlite3"));
        exe.root_module.addCSourceFile(.{
            .file = b.path("vendor/sqlite3/sqlite3.c"),
            .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION" },
        });
    }
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
    if (target.result.os.tag == .linux) {
        mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    }

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

    exe.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        exe.root_module.linkSystemLibrary("sqlite3", .{});
        exe.root_module.linkSystemLibrary("ssl", .{});
        exe.root_module.linkSystemLibrary("crypto", .{});
    } else if (target.result.os.tag == .windows or target.result.os.tag == .macos) {
        // Vendor sqlite3 amalgamation for Windows + macOS — same
        // reasoning as createPlatformExe.
        exe.root_module.addIncludePath(b.path("vendor/sqlite3"));
        exe.root_module.addCSourceFile(.{
            .file = b.path("vendor/sqlite3/sqlite3.c"),
            .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION" },
        });
    }
    // === Build the Vue webapp (bun) ===
    // Chunk 3: this step is a dependency of the desktop_exe build so the
    // embedded webapp_assets.zig is regenerated on every build. The step
    // itself runs `bun run build` in src/apps/desktop, which is the
    // project's standard webapp build (vue-tsc + vite in parallel — see
    // src/apps/desktop/package.json).
    const build_webapp_step = b.step("build:webapp", "Build the Vue webapp with bun");

    const webapp_dir = "src/apps/desktop";

    // Check if node_modules exists — if so, skip `bun install` (saves 1-2s
    // per build). Uses platform-specific syscalls: faccessat(2) on Linux,
    // std.fs.cwd().openDir on other platforms (the build runner doesn't
    // have libc linked, so std.fs.cwd() only works via the Io runtime
    // path on non-Linux hosts).
    const node_modules_path = b.pathJoin(&.{ webapp_dir, "node_modules" });
    const node_modules_exists = switch (builtin.os.tag) {
        .linux => blk: {
            var buf: [std.fs.max_path_bytes:0]u8 = undefined;
            if (node_modules_path.len >= buf.len) break :blk false;
            @memcpy(buf[0..node_modules_path.len], node_modules_path);
            buf[node_modules_path.len] = 0;
            const rc = std.os.linux.faccessat(std.os.linux.AT.FDCWD, &buf, 0, 0);
            break :blk rc == 0;
        },
        else => false, // On non-Linux, always run `bun install` (safe no-op)
    };

    if (!node_modules_exists) {
        const install_cmd = b.addSystemCommand(&.{ "bun", "install" });
        install_cmd.setCwd(b.path(webapp_dir));
        build_webapp_step.dependOn(&install_cmd.step);
    }

    const bun_build = b.addSystemCommand(&.{ "bun", "run", "build" });
    bun_build.setCwd(b.path(webapp_dir));
    build_webapp_step.dependOn(&bun_build.step);

    // === Codegen: walk dist/, emit webapp_assets.zig ===
    // Chunk 3: this step runs the small Zig tool at tools/codegen_webapp_assets.zig
    // to walk src/apps/desktop/dist/ and emit a Zig source file with every
    // asset's bytes embedded as string literals. The generated file lives at
    // src/apps/desktop_app/embedded/webapp_assets.zig (gitignored) and is
    // imported by extraction.zig. desktop_exe depends on this so a fresh
    // build always has up-to-date assets.
    const codegen_step = b.step("codegen:webapp-assets", "Generate webapp_assets.zig from the built dist/");
    codegen_step.dependOn(build_webapp_step);

    const codegen = b.addRunArtifact(b.addExecutable(.{
        .name = "codegen_webapp_assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/codegen_webapp_assets.zig"),
            .target = b.graph.host,
        }),
    }));
    codegen.addArg(b.pathJoin(&.{ webapp_dir, "dist" }));
    codegen.addArg(b.pathJoin(&.{ "src", "apps", "desktop_app", "embedded", "webapp_assets.zig" }));
    codegen_step.dependOn(&codegen.step);

    // === nalar-desktop (native webview wrapper) ===
    // Chunk 1: hello-world binary + build wiring. The real entry point lands
    // in Chunk 8 (lifecycle wiring: parse CLI → spawn nalar → open webview).
    // Platform-specific deps (WebKitGTK, WKWebView, WebView2) are added in
    // Chunks 5-7 when the webview implementations land.
    const desktop_exe = b.addExecutable(.{
        .name = "nalar-desktop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/desktop_app/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nalarcore", .module = mod },
            },
        }),
    });
    desktop_exe.root_module.linkSystemLibrary("c", .{});

    // Platform-specific system libraries (Chunks 5-7 add the real deps).
    // Switch kept here so the pattern is validated by the Chunk 1 build.
    switch (target.result.os.tag) {
        .linux => {
            // Chunk 5: gtk-3, webkit2gtk-4.1, soup-3.0
            //
            // The implementation in src/apps/desktop_app/platform/linux.zig
            // uses manual `extern "c"` declarations (no @cImport) because
            // @cImport's parser chokes on GLib's `_Pragma` constructs inside
            // `G_GNUC_BEGIN_IGNORE_DEPRECATIONS` (used by `G_DECLARE_FINAL_TYPE`
            // throughout soup/webkit headers). The C shim
            // platform/webview_linux.c is compiled with cc and pulls in the
            // GTK/WebKit headers — cc handles _Pragma correctly. The Zig
            // extern declarations trust the signatures and link against
            // libwebkit2gtk-4.1 / libgtk-3 / libsoup-3.0 / libglib-2.0.
            desktop_exe.root_module.linkSystemLibrary("webkit2gtk-4.1", .{});
            desktop_exe.root_module.linkSystemLibrary("gtk-3", .{});
            desktop_exe.root_module.linkSystemLibrary("soup-3.0", .{});
            desktop_exe.root_module.linkSystemLibrary("glib-2.0", .{});
            desktop_exe.root_module.linkSystemLibrary("javascriptcoregtk-4.1", .{});
            // C source file — compiled with cc, which handles the GTK/
            // WebKit headers (including _Pragma) correctly. The method
            // lives on *Build.Module in Zig 0.16 (not on *Build.Step.Compile
            // like in older versions).
            desktop_exe.root_module.addCSourceFile(.{
                .file = b.path("src/apps/desktop_app/platform/webview_linux.c"),
                .flags = &.{
                    "-I/usr/include/webkitgtk-4.1",
                    "-I/usr/include/gtk-3.0",
                    "-I/usr/include/pango-1.0",
                    "-I/usr/include/cairo",
                    "-I/usr/include/gdk-pixbuf-2.0",
                    "-I/usr/include/atk-1.0",
                    "-I/usr/include/libsoup-3.0",
                    "-I/usr/include/glib-2.0",
                    "-I/usr/lib/glib-2.0/include",
                },
            });
        },
        .macos => {
            // Chunk 6: Cocoa, WebKit (via .mm shim)
            //
            // The Objective-C++ shim at platform/macos/nalar_webview.mm
            // implements the 3 C ABI functions (nalar_webview_create,
            // _run, _destroy) using AppKit + WebKit. We compile it with
            // the host's clang via `addCSourceFile` and `-ObjC++`, then
            // link the Cocoa + WebKit frameworks. Note: `addCSourceFile`
            // and `linkFramework` are both methods on `root_module` in
            // Zig 0.16 (not on the Compile step like in older versions) —
            // see the Linux branch above for the matching addCSourceFile
            // pattern.
            const mm_file = b.path("src/apps/desktop_app/platform/macos/nalar_webview.mm");
            desktop_exe.root_module.addCSourceFile(.{ .file = mm_file, .flags = &.{"-ObjC++"} });
            desktop_exe.root_module.linkFramework("Cocoa", .{});
            desktop_exe.root_module.linkFramework("WebKit", .{});
        },
        .windows => {
            // Chunk 7: ole32, user32, WebView2Loader (via .cpp shim)
            //
            // The C++ shim at platform/windows/nalar_webview.cpp implements
            // the 3 C ABI functions (nalar_webview_create, _run, _destroy)
            // using Win32 (HWND/WndProc) + WebView2 (ICoreWebView2, etc.).
            // We compile it with the host's MSVC clang via `addCSourceFile`
            // and `/std:c++17 /EHsc` flags, then link the system libraries
            // that Win32 + COM + WebView2 need at link time.
            //
            // Build-time prerequisite: the WebView2 NuGet package's headers
            // (WebView2.h, WebView2Loader.h) must be extracted into the
            // same directory as the .cpp. The NuGet DLL (WebView2Loader.dll)
            // must ship alongside nalar-desktop.exe at runtime. The .cpp
            // file documents this in its top comment; see also:
            //   https://www.nuget.org/packages/Microsoft.Web.WebView2/
            //
            // Zig 0.16: `addCSourceFile` and `linkSystemLibrary` are both
            // methods on `root_module` (not on the Compile step like in
            // older versions) — see the Linux branch above for the matching
            // addCSourceFile pattern.
            const cpp_file = b.path("src/apps/desktop_app/platform/windows/nalar_webview.cpp");
            desktop_exe.root_module.addCSourceFile(.{
                .file = cpp_file,
                .flags = &.{ "/std:c++17", "/EHsc" },
            });
            desktop_exe.root_module.linkSystemLibrary("ole32", .{});
            desktop_exe.root_module.linkSystemLibrary("user32", .{});
            desktop_exe.root_module.linkSystemLibrary("WebView2Loader", .{});
        },
        else => {},
    }

    b.installArtifact(desktop_exe);

    // Make the desktop binary depend on the codegen step. The codegen runs
    // `bun run build` first (via build_webapp_step) and then walks dist/ to
    // emit webapp_assets.zig, so by the time desktop_exe compiles the
    // embedded/ directory is populated with the latest assets.
    desktop_exe.step.dependOn(&codegen.step);

    // `zig build nalar-desktop` alias — depends on the install step (which
    // already includes desktop_exe via b.installArtifact above), so the
    // binary ends up in zig-out/bin/.
    const build_nalar_desktop = b.step("nalar-desktop", "Build the nalar-desktop binary");
    build_nalar_desktop.dependOn(b.getInstallStep());

    const run_desktop = b.step("run:desktop-app", "Run the nalar desktop wrapper");
    const run_desktop_cmd = b.addRunArtifact(desktop_exe);
    run_desktop.dependOn(&run_desktop_cmd.step);
    if (b.args) |args| run_desktop_cmd.addArgs(args);

    const test_desktop = b.step("test:desktop-app", "Run nalar-desktop unit tests");
    const desktop_tests = b.addTest(.{
        .root_module = desktop_exe.root_module,
    });
    desktop_tests.root_module.linkSystemLibrary("c", .{});
    const run_desktop_tests = b.addRunArtifact(desktop_tests);
    test_desktop.dependOn(&run_desktop_tests.step);

    const run_step = b.step("run", "Run the app");

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
    if (target.result.os.tag == .linux) {
        mod_tests.root_module.linkSystemLibrary("sqlite3", .{});
        mod_tests.root_module.linkSystemLibrary("ssl", .{});
        mod_tests.root_module.linkSystemLibrary("crypto", .{});
    }
    // NB: For windows + macOS, sqlite3.c is added to `mod` ONCE below —
    // see the shared-module block. If we'd added it per-test here,
    // Zig 0.16's link step would emit two copies of sqlite3.o and
    // fail with "duplicate symbol definition" (the addCSourceFile
    // call accumulates per target on the shared `mod` instance).

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const ai_workflow_tui_test_mod = b.addTest(.{
        .root_module = mod,
    });
    ai_workflow_tui_test_mod.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        ai_workflow_tui_test_mod.root_module.linkSystemLibrary("sqlite3", .{});
        ai_workflow_tui_test_mod.root_module.linkSystemLibrary("ssl", .{});
        ai_workflow_tui_test_mod.root_module.linkSystemLibrary("crypto", .{});
    }
    // See comment in mod_tests above — sqlite3.c is shared via `mod`.

    // Shared post-setup: add vendor sqlite3 amalgamation once to `mod`
    // so it covers BOTH test Compiles. This avoids the duplicate-symbol
    // error that fires when each Compile adds the same .c file to the
    // shared `mod` instance (which is what we did before this fix).
    if (target.result.os.tag == .windows or target.result.os.tag == .macos) {
        mod.addIncludePath(b.path("vendor/sqlite3"));
        mod.addCSourceFile(.{
            .file = b.path("vendor/sqlite3/sqlite3.c"),
            .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION" },
        });
    }

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
    dev_exe.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) {
        dev_exe.root_module.linkSystemLibrary("sqlite3", .{});
        dev_exe.root_module.linkSystemLibrary("ssl", .{});
        dev_exe.root_module.linkSystemLibrary("crypto", .{});
    } else if (target.result.os.tag == .windows or target.result.os.tag == .macos) {
        // Vendor sqlite3 amalgamation for Windows + macOS — same reason
        // as createPlatformExe.
        dev_exe.root_module.addIncludePath(b.path("vendor/sqlite3"));
        dev_exe.root_module.addCSourceFile(.{
            .file = b.path("vendor/sqlite3/sqlite3.c"),
            .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION" },
        });
    }
    const install_dev = b.addInstallArtifact(dev_exe, .{});
    dev_linux_system_step.dependOn(&install_dev.step);
    const copy_dev_to_system = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/nalar-dev",
        "/usr/local/bin/nalar-dev",
    });
    copy_dev_to_system.step.dependOn(&install_dev.step);
    dev_linux_system_step.dependOn(&copy_dev_to_system.step);

    // ============================================================
    // Custom HTTP Server (TCP) - build step
    // ============================================================
    const tcp_exe = b.addExecutable(.{
        .name = "custom-http-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/modules/custom_http_server/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tcp_exe.root_module.linkSystemLibrary("c", .{});

    const run_tcp_step = b.step("run:custom_tcp", "Run the custom TCP echo server");
    const run_tcp_cmd = b.addRunArtifact(tcp_exe);
    run_tcp_step.dependOn(&run_tcp_cmd.step);
}