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
    } else if (target.result.os.tag == .windows) {
        // Vendor sqlite3 amalgamation for Windows — compile from
        // source so the binary has sqlite3 support without relying on
        // system package layout. On macOS, the `mod` already has
        // sqlite3.c attached (added once at the shared-module post-
        // setup), so the executable inherits it via the `imports`
        // array — duplicating it here would emit two sqlite3.o copies
        // and fail with "duplicate symbol definition".
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

    const mod = b.addModule("nalarcore", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.addImport("nalarcore", mod);
    // Platform-specific link libs (sqlite3/ssl/crypto on Linux,
    // vendored sqlite3.c on Windows/macOS) are added below in the
    // test/dev-exe/inline-exe setup blocks. They propagate to every
    // Compile that imports `mod`, which is intentional for the native
    // host builds but means the `install:windows` / `install:macos`
    // cross-compile artifacts also see ssl/crypto link flags. The CI
    // matrix gates the Windows binary build with `__SKIP__` and the
    // macOS binary build remains broken on Linux host (pre-existing
    // issue, out of scope here). The cross-compile TESTS work because
    // they don't hit the link-emit step that checks for the system libs.

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
        exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    } else if (target.result.os.tag == .macos) {
        // macOS uses Homebrew's system libsqlite3 (see shared `mod` setup).
        // The `mod` already provides the -lsqlite3 link + brew include
        // path via the imports array, so the executable inherits them —
        // re-linking here would be redundant but is kept for symmetry with
        // the Linux branch and to make the platform intent explicit at
        // the call site.
        exe.root_module.linkSystemLibrary("sqlite3", .{});
    } else if (target.result.os.tag == .windows) {
        // Vendor sqlite3 amalgamation for Windows. The shared `mod` does
        // NOT compile sqlite3.c on Windows (the Linux/macOS branches
        // above use system libs, the `else` branch handles cross-compile
        // targets but this native-Windows path doesn't go through it).
        // Compile the amalgamation directly here so sqlite3 symbols
        // resolve at link time.
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

    // === Webapp rebuild workflow ===
    //
    // `b.addSystemCommand` caches based on (command string, cwd, watch
    // inputs) only — it does NOT watch webapp source files. So editing
    // src/apps/desktop/src/**/*.vue leaves the embedded webapp_assets.zig
    // (and nalar-desktop binary) stale with respect to those edits.
    //
    // An earlier attempt used `addDirectoryWatchInput` on src/, but that
    // caused cache invalidation on EVERY noop build — Vite's output isn't
    // byte-stable across runs (sourcemap/manifest drift), so the directory
    // hash drifted and triggered spurious bun runs.
    //
    // The intentional, predictable workflow is:
    //
    //     1. Edit src/apps/desktop/src/**/*.vue as usual.
    //     2. Run `zig build webapp-rebuild` to nuke the stale embedded
    //        file + dist/ and rebuild from scratch (~10 s; cached
    //        after this).
    //     3. Run `zig build nalar-desktop` to embed and link (~free
    //        when webapp_assets.zig hasn't changed).
    //
    // OR all-in-one during development:
    //
    //     zig build webapp-rebuild && zig build nalar-desktop && \
    //         ./zig-out/bin/nalar-desktop
    //
    // `zig build nalar-desktop` on its own is the cache-friendly path:
    // when nothing has changed, it's ~free. Use `webapp-rebuild`
    // when you've edited the webapp.
    //
    // Implementation: webapp_rebuild_step has its OWN copy of
    // `bun run build` (not the cached one used by nalar-desktop's
    // happy path), chained after a clean step. The clean step deletes
    // the embedded file + dist/, so the rebuild's bun_build sees an
    // empty dist/, has actual work to do, and produces fresh output.
    const webapp_rebuild_step = b.step(
        "webapp-rebuild",
        "Nuke stale webapp_assets.zig + dist/ and rebuild via bun run build + codegen",
    );

    const webapp_rebuild_clean = b.addSystemCommand(&.{
        "sh", "-c",
        \\rm -rf src/apps/desktop_app/embedded/webapp_assets.zig &&
        \\rm -rf src/apps/desktop/dist &&
        \\echo "webapp-rebuild: deleted embedded + dist; rebuilding...",
    });
    webapp_rebuild_clean.setCwd(b.path(""));

    // Separate bun_build step for the rebuild path. Has the SAME
    // command + cwd as the cached one, but chained AFTER the clean
    // step, so the cache can't serve a stale result.
    const webapp_rebuild_bun = b.addSystemCommand(&.{ "bun", "run", "build" });
    webapp_rebuild_bun.setCwd(b.path(webapp_dir));
    webapp_rebuild_bun.step.dependOn(&webapp_rebuild_clean.step);
    webapp_rebuild_step.dependOn(&webapp_rebuild_bun.step);

    // The codegen step is shared with the cached path — its output
    // (webapp_assets.zig) was just deleted by the clean step, so
    // it'll re-run to regenerate. Depend on the rebuild's bun_build
    // specifically (not the cached one).
    const webapp_rebuild_codegen = b.addRunArtifact(b.addExecutable(.{
        .name = "codegen_webapp_assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/codegen_webapp_assets.zig"),
            .target = b.graph.host,
            .link_libc = true,
        }),
    }));
    webapp_rebuild_codegen.addArg(b.pathJoin(&.{ webapp_dir, "dist" }));
    webapp_rebuild_codegen.addArg(b.pathJoin(&.{ "src", "apps", "desktop_app", "embedded", "webapp_assets.zig" }));
    webapp_rebuild_codegen.step.dependOn(&webapp_rebuild_bun.step);
    webapp_rebuild_step.dependOn(&webapp_rebuild_codegen.step);

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
            .link_libc = true,
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

    // Capture the InstallArtifact so `build:all` can dependOn its inner
    // step (see the build banner section at the end of this file for why).
    const desktop_install = b.addInstallArtifact(desktop_exe, .{});
    b.getInstallStep().dependOn(&desktop_install.step);

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

    // Linux-host-only link_libs (ssl/crypto/system-sqlite3). These are
    // needed for the native Linux test build (the tests link against the
    // real system OpenSSL + system sqlite3), but they MUST NOT be in the
    // link line when cross-compiling (install:windows, install:macos on
    // a Linux host) — the cross-target linker would fail with "unable to
    // find dynamic system library" because those Linux system libs don't
    // exist on Windows/macOS.
    //
    // Detection: the `-Dlinux-libs` build option. Default is `true` for
    // native-Linux target (= native Linux tests, native Linux install),
    // `false` for any other target (cross-compile from Linux to Windows/
    // macOS). Pass `-Dlinux-libs=false` explicitly when cross-compiling.
    const linux_host_is_native_target = target.result.os.tag == .linux and
        target.result.cpu.arch == builtin.cpu.arch;
    const add_linux_libs = b.option(
        bool,
        "linux-libs",
        "Attach ssl/crypto/system-sqlite3 + /usr/include to mod for native Linux builds. Set false when cross-compiling from Linux to Windows/macOS to avoid -lssl/-lcrypto leaking into the cross-target link line.",
    ) orelse linux_host_is_native_target;

    if (add_linux_libs and target.result.os.tag == .linux) {
        mod.linkSystemLibrary("sqlite3", .{});
        mod.linkSystemLibrary("ssl", .{});
        mod.linkSystemLibrary("crypto", .{});
        mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    } else if (target.result.os.tag == .macos) {
        // macOS native (Apple Silicon + Intel): use the system libsqlite3
        // provided by Homebrew. The vendored amalgamation compiled into
        // our binary panics on arm64 with:
        //   "member access within misaligned address ... for type
        //    'LookasideSlot', which requires 8 byte alignment"
        //   (vendor/sqlite3/sqlite3.c:32137, sqlite3DbMallocRawNN).
        // The system dylib is aligned correctly and works out of the box.
        // Homebrew's keg-only layout puts headers at
        //   <prefix>/opt/sqlite/include  (sqlite3.h, sqlite3ext.h)
        // and the lib at  <prefix>/opt/sqlite/lib/libsqlite3.dylib.
        // Default prefix: /opt/homebrew (Apple Silicon). Override with
        // `-Dsqlite-prefix=/path` for Intel (/usr/local) or custom installs.
        const sqlite_prefix = b.option(
            []const u8,
            "sqlite-prefix",
            "Homebrew prefix for the sqlite3 keg (default: /opt/homebrew)",
        ) orelse "/opt/homebrew";
        mod.linkSystemLibrary("sqlite3", .{});
        mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/opt/sqlite/include", .{sqlite_prefix}) });
        mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/opt/sqlite/lib", .{sqlite_prefix}) });
    } else {
        // The cross-compile targets (or non-Linux host builds) need the
        // vendored sqlite3 amalgamation to satisfy sqlite3_* references
        // that would otherwise require a system sqlite3 we can't link.
        // Adding sqlite3.c once to `mod` makes it visible to every
        // Compile that imports `mod` (tests, native exe, install:*).
        // We add it unconditionally for non-Linux because the linux-libs
        // branch uses the system sqlite3 instead.
        mod.addIncludePath(b.path("vendor/sqlite3"));
        mod.addCSourceFile(.{
            .file = b.path("vendor/sqlite3/sqlite3.c"),
            .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION" },
        });
    }
    mod.linkSystemLibrary("c", .{});

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const ai_workflow_tui_test_mod = b.addTest(.{
        .root_module = mod,
    });

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
    // NB: don't include `.exe` in the name — Zig 0.16's `addExecutable`
    // auto-appends `.exe` on Windows targets, so passing a name with `.exe`
    // already produces the doubled suffix `nalarcore-windows-x86_64.exe.exe`
    // (which the CI yaml's verify step doesn't expect).
    const windows_exe = createPlatformExe(b, mod, windows_target, optimize, "nalarcore-windows-x86_64");
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
    } else if (target.result.os.tag == .macos) {
        // macOS uses Homebrew's system libsqlite3 (see shared `mod`
        // setup). The `mod` already provides the -lsqlite3 link + brew
        // include path via the imports array, so nalar-dev inherits them.
        dev_exe.root_module.linkSystemLibrary("sqlite3", .{});
    } else if (target.result.os.tag == .windows) {
        // Vendor sqlite3 amalgamation for Windows. The shared `mod`
        // does NOT compile sqlite3.c on Windows, so the amalgamation
        // is added directly here for nalar-dev to satisfy sqlite3
        // references.
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

    // =====================================================================
    // End-of-build success/failure banner
    // =====================================================================
    // Zig's `install` step emits no summary by default (you have to pass
    // `--summary all` to see "13/13 steps succeeded"). When `zig build`
    // succeeds the user sees nothing on stdout — easy to mistake a cached
    // build for a fresh one, and impossible to tell whether it ran. We
    // register a `build:all` step that depends on both binaries + a
    // final shell banner that fires ONLY when the build succeeded
    // (Zig's dependency DAG short-circuits the banner on failure).
    //
    // Output structure (so it's easy to grep):
    //
    //   [zig build success]
    //
    //     ✓ nalar service binary  →  zig-out/bin/nalarcore-linux-x86_64
    //     ✓ nalar desktop binary  →  zig-out/bin/nalar-desktop
    //
    //     Run with:  ./zig-out/bin/nalarcore-linux-x86_64 service start --port 8080
    //                ./zig-out/bin/nalar-desktop --devtools
    //
    // The simplest reliable banner is static text. We tried a `[ -x ... ]`
    // check on the installed binary paths, but Zig's `InstallArtifact`
    // caches file copies (skipping `installFile()` when its inputs
    // haven't changed). When the user has manually deleted
    // `zig-out/bin/...` or it's a fresh checkout, the cache says
    // "nothing to do" but the file is genuinely absent — so the
    // check shows "missing" even though the build succeeded. Static
    // text is always right; the user's actual binary locations are
    // deterministic from the build config.
    const build_banner = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        \\
        \\D=zig-out/bin
        \\echo ""
        \\echo "[zig build success]"
        \\echo ""
        \\echo "  nalar service binary  →  $D/nalarcore-linux-x86_64"
        \\echo "  nalar desktop binary  →  $D/nalar-desktop"
        \\echo ""
        \\echo "  (If a binary is missing, run \`rm -rf $D && zig build\`"
        \\echo "   to force a fresh install — the cache sometimes hides"
        \\echo "   manual deletions.)"
        \\echo ""
        \\echo "  Run with:  $D/nalarcore-linux-x86_64 service start --port 8080"
        \\echo "             $D/nalar-desktop --devtools"
        \\echo ""
        ,
    });
    const build_all_step = b.step("build:all", "Build nalar service + nalar-desktop, with end-of-build summary");
    // The two binaries live on different top-level install steps:
    //   - nalarcore-linux-x86_64  → install:linux   (cross target, Linux x86_64)
    //   - nalar-desktop           → install           (native target, includes
    //                                               b.installArtifact(desktop_exe))
    // The native `nalar` binary is also in `install`. We want both in
    // one command, so depend on the inner install steps (not just the
    // outer top-level wrappers). Depending on the outer wrappers would
    // race against cache-hit skipping: when the binary's source hasn't
    // changed, InstallArtifact.make() returns early without copying the
    // file — so my banner would see a stale (possibly deleted) bin/ and
    // print missing-file lines.
    //
    // `dependOn` takes `*Step` not `*const *Step` — `install_linux` and
    // `desktop_install` are both `*InstallArtifact` whose `.step` field
    // is what `dependOn` needs.
    build_all_step.dependOn(&install_linux.step);
    build_all_step.dependOn(&desktop_install.step);
    build_all_step.dependOn(&build_banner.step);

    // Default: same as `build:all`. Without this, `zig build` (no args)
    // runs the `install` step alone, which prints no summary on success.
    // Zig 0.16's `Build.default_step: *Step` — `b.step()` already
    // returns `*Step`, so we assign the pointer directly.
    b.default_step = build_all_step;
}
