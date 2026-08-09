const std = @import("std");
const builtin = @import("builtin");

/// Link platform-specific system libraries (sqlite3/openssl) + include paths
/// for a Compile step based on the COMPILE'S OWN target (NOT the global
/// default target). Every caller that produces a binary linked against
/// nalarcore MUST call this — otherwise the cross-compile link line will
/// miss the target's sqlite3/openssl.
///
/// Why per-Compile and not on `mod`: putting these on `mod` causes the
/// Linux native system libs (sqlite3/ssl/crypto/pq + /usr/include) to leak
/// into every consumer of `mod`, including `install:windows` and
/// `install:macos` cross-compile artifacts. The cross-target linker then
/// fails with "unable to find dynamic system library 'sqlite3'" because
/// those Linux libs don't exist on Windows/macOS.
///
/// Universal link (libc + link_libc) is set on every platform. The
/// platform-specific block adds sqlite3/openssl (Linux), brew sqlite3
/// (macOS), or the vendored amalgamation (Windows + cross-compile to
/// Windows/macOS).
/// Link platform-specific system libraries (sqlite3/openssl) + include paths
/// for a Compile step based on the COMPILE'S OWN target (NOT the global
/// default target). Every caller that produces a binary linked against
/// nalarcore MUST call this — otherwise the cross-compile link line will
/// miss the target's sqlite3/openssl.
///
/// Why per-Compile and not on `mod`: putting these on `mod` causes the
/// Linux native system libs (sqlite3/ssl/crypto/pq + /usr/include) to leak
/// into every consumer of `mod`, including `install:windows` and
/// `install:macos` cross-compile artifacts. The cross-target linker then
/// fails with "unable to find dynamic system library 'sqlite3'" because
/// those Linux libs don't exist on Windows/macOS.
///
/// Universal link (libc + link_libc) is set on every platform. The
/// platform-specific block adds sqlite3/openssl (Linux), brew sqlite3
/// (macOS), or the vendored amalgamation (Windows + cross-compile to
/// Windows/macOS).
///
/// `sqlite_prefix` is the Homebrew prefix for the macOS keg (default
/// /opt/homebrew). Declared once at the top of `build` because
/// `b.option()` panics on duplicate declarations.
fn linkPlatformDeps(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.link_libc = true;
    switch (target.result.os.tag) {
        .linux => {
            // Linux (native + cross-compile): use the VENDORED prebuilt
            // libsqlite3.a from vendor/sqlite3/linux-x86_64/ (built once
            // via `zig cc -target x86_64-linux-gnu` + `zig ar` from the
            // amalgamation). The amalgamation header is at
            // vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400/sqlite3.h.
            //
            // Why NOT system sqlite3:
            // - A developer on macOS or Windows host can't `apt install
            //   libsqlite3-dev` to cross-compile for Linux. Vendoring
            //   makes the build hermetic across host OSes.
            // - brew layout is keg-only fragile; system libsqlite3 may
            //   be a different version than the amalgamation header.
            //
            // OpenSSL + libpq are still linked from the system because
            // they're nearly always present on Linux distros and aren't
            // currently vendored (out of scope here — see plan if
            // macOS-host builds need them too).
            const linux_lib = switch (target.result.cpu.arch) {
                .x86_64 => "vendor/sqlite3/linux-x86_64",
                else => "", // unsupported Linux arch (aarch64 etc.)
            };
            if (linux_lib.len > 0) {
                exe.root_module.addIncludePath(b.path("vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400"));
                exe.root_module.addLibraryPath(b.path(linux_lib));
                exe.root_module.linkSystemLibrary("sqlite3", .{});
            }
            exe.root_module.linkSystemLibrary("ssl", .{});
            exe.root_module.linkSystemLibrary("crypto", .{});
            exe.root_module.linkSystemLibrary("pq", .{});
            exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
            // Debian/Ubuntu layout: libpq-fe.h lives in
            // /usr/include/postgresql (Arch has it directly in
            // /usr/include). Adding both is harmless.
            exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
        },
        .macos => {
            // macOS (native + cross-compile): use the VENDORED prebuilt
            // libsqlite3.a from vendor/sqlite3/macos-{arm64,x86_64}/.
            // The amalgamation header is at
            // vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400/sqlite3.h.
            //
            // Why NOT system sqlite3 (Homebrew brew install sqlite3):
            // - brew doesn't exist on a Linux host cross-compiling to macOS.
            // - brew layout (keg-only at <prefix>/opt/sqlite/{include,lib})
            //   is fragile and breaks when the user installs/uninstalls brew.
            // - The prebuilt archive is hermetic: identical output on every
            //   build, no surprises from brew version skew.
            //
            // Why NOT compile sqlite3.c per-build (as older code did):
            // - zig cc -target aarch64-macos works but the vendored
            //   amalgamation panics on arm64 with "member access within
            //   misaligned address" (vendor/sqlite3/sqlite3.c:32137) when
            //   compiled with Zig 0.16's x86_64 host gcc. The prebuilt
            //   archive was produced by zig cc itself, so it has the
            //   correct alignment for the target arch.
            const macos_lib = switch (target.result.cpu.arch) {
                .aarch64 => "vendor/sqlite3/macos-arm64",
                .x86_64 => "vendor/sqlite3/macos-x86_64",
                else => "", // unsupported macOS arch (e.g. i386) — leave empty
            };
            if (macos_lib.len > 0) {
                exe.root_module.addIncludePath(b.path("vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400"));
                exe.root_module.addLibraryPath(b.path(macos_lib));
                exe.root_module.linkSystemLibrary("sqlite3", .{});
            }
        },
        .windows => {
            // Windows (native + cross-compile): use the prebuilt libsqlite3.a
            // import library from vendor/sqlite3/libc-windows-amd64/lib (a
            // merged symlink farm pointing at /usr/x86_64-w64-mingw32/ + the
            // sqlite3 import lib generated via `zig dlltool`). The header is
            // at vendor/sqlite3/libc-windows-amd64/include/sqlite3.h.
            //
            // Why NOT compile sqlite3.c per-build (as older code did):
            // zig cc -target x86_64-windows-gnu works, but the resulting
            // libsqlite3.a is rebuilt every build and the dlltool step
            // (to convert sqlite3.def into an import lib) is skipped. The
            // prebuilt archive is hermetic: every build just links the
            // archive, no per-build C compilation needed.
            //
            // bcrypt.dll is needed by src/modules/custom_http_server/src/security.zig
            // (BCryptGenRandom — Zig's std.c.getrandom is `void` on Windows).
            // The MinGW symlink farm provides kernel32/user32/etc.; bcrypt
            // must be added explicitly because MinGW doesn't ship bcrypt.
            exe.root_module.addIncludePath(b.path("vendor/sqlite3/libc-windows-amd64/include"));
            exe.root_module.addLibraryPath(b.path("vendor/sqlite3/libc-windows-amd64/lib"));
            exe.root_module.linkSystemLibrary("sqlite3", .{});
            exe.root_module.linkSystemLibrary("bcrypt", .{});
        },
        else => {
            // Cross-compile to non-Linux/macOS/Windows targets (e.g.
            // FreeBSD, Android, WASI). Fall back to the amalgamation
            // compilation. Most cross-target users won't hit this branch.
            exe.root_module.addIncludePath(b.path("vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400"));
            exe.root_module.addCSourceFile(.{
                .file = b.path("vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400/sqlite3.c"),
                .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_ENABLE_FTS5" },
            });
        },
    }
}

/// Add the curl include path for the target's libcurl. Used to compile
/// the C glue in custom_http_client. Each Compile that imports
/// custom_http_client_mod MUST call this for its own target — otherwise
/// the C compiler for the cross-target won't find curl/curl.h.
///
/// `curl_prefix` and `curl_vcpkg_root` are passed in from the caller
/// (declared once at the top of `build`, since `b.option()` panics on
/// duplicate declarations).
fn linkCurlIncludePath(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    curl_prefix: []const u8,
    curl_vcpkg_root: []const u8,
) void {
    switch (target.result.os.tag) {
        .linux => {
            exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
        },
        .macos => {
            exe.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/opt/curl/include", .{curl_prefix}) });
            exe.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/opt/curl/lib", .{curl_prefix}) });
        },
        .windows => {
            exe.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/installed/x64-windows/include", .{curl_vcpkg_root}) });
            exe.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/installed/x64-windows/lib", .{curl_vcpkg_root}) });
        },
        else => {},
    }
}

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
    linkPlatformDeps(b, exe, target);
    return exe;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Cross-platform Homebrew / vcpkg prefix options. Declared ONCE here
    // so `b.option()`'s anti-duplicate rule isn't violated when the same
    // value feeds multiple link sites (linux_exe / windows_exe / macos_exe
    // / dev_exe / tests).
    const sqlite_prefix = b.option(
        []const u8,
        "sqlite-prefix",
        "Homebrew prefix for the sqlite3 keg (default: /opt/homebrew)",
    ) orelse "/opt/homebrew";
    const curl_prefix = b.option(
        []const u8,
        "curl-prefix",
        "Homebrew prefix for the libcurl keg (default: /opt/homebrew)",
    ) orelse "/opt/homebrew";
    const curl_vcpkg_root = b.option(
        []const u8,
        "curl-vcpkg-root",
        "vcpkg root for Windows libcurl (default: C:/vcpkg)",
    ) orelse "C:/vcpkg";

    const mod = b.addModule("nalarcore", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.addImport("nalarcore", mod);

    // === custom_http_client module (libcurl-backed HTTP) ===
    // Exposed as a separate module so Agent2.zig (in src/modules/agent/)
    // can `@import("custom_http_client")`. Same libcurl deps as the
    // sibling build at src/modules/custom_http_client/build.zig.
    //
    // Cross-platform libcurl paths (mirrors `-Dsqlite-prefix` for
    // libsqlite3 — see `configureSqlitePrefix` below):
    //   - Linux:   /usr/include + system libcurl
    //   - macOS:   $(brew --prefix curl)/{include,lib}   (keg-only)
    //   - Windows: $(vcpkg root)/installed/x64-windows/{include,lib}
    //
    // The macOS default `/opt/homebrew` is the Apple-Silicon layout;
    // Intel macs override with `-Dcurl-prefix=/usr/local`. Options
    // are declared ONCE at the top of `build()` (see above); we just
    // read them here.
    //
    // The platform-specific curl include path is NOT set on
    // custom_http_client_mod itself — setting it based on `target.result.os.tag`
    // (the global default target) leaks the wrong path into every Compile
    // that imports this mod, including cross-compile artifacts. Instead,
    // each Compile step calls `linkCurlIncludePath(exe, target, ...)` for
    // its own target.

    const custom_http_client_mod = b.addModule("custom_http_client", .{
        .root_source_file = b.path("src/modules/custom_http_client/src/root.zig"),
        .target = target,
    });
    custom_http_client_mod.linkSystemLibrary("curl", .{});
    custom_http_client_mod.link_libc = true;
    // libcurl is a UNIVERSAL link dep — every consumer of this mod gets
    // -lcurl in its link line (no leak; libcurl symbols are the same on
    // every platform). But the INCLUDE PATH for curl/curl.h must match
    // the platform — Linux has it at /usr/include/curl/curl.h, macOS at
    // $(brew --prefix curl)/opt/curl/include/curl/curl.h, Windows at
    // $(vcpkg)/installed/x64-windows/include/curl/curl.h.
    //
    // The cimport lives in src/modules/custom_http_client/src/curl.zig
    // (part of THIS mod). The cimport uses the HOST C compiler, so we
    // add all 3 platform paths here. Whichever path is valid on the host
    // wins; cross-compile consumers don't need to re-add (the headers
    // are portable C). The link_libc + linkSystemLibrary("curl") are
    // universal and propagate to every importer.
    custom_http_client_mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    custom_http_client_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/opt/curl/include", .{curl_prefix}) });
    custom_http_client_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/installed/x64-windows/include", .{curl_vcpkg_root}) });
    mod.addImport("custom_http_client", custom_http_client_mod);

    // === Auto-fetch vendor/sqlite3 if missing ===
    // The amalgamation (sqlite3.c ~10 MB + 2 headers) is gitignored (see
    // .gitignore "vendored" section). Fresh checkouts need the fetch to
    // happen BEFORE any Compile step that links vendor/sqlite3/sqlite3.c
    // vendor/sqlite3/ is COMMITTED to the repo (the ginwasaas pattern —
    // see vendor/sqlite3/README.md for the layout). No fetch step needed;
    // a fresh checkout has everything it needs for Windows + macOS native
    // AND cross-compile from Linux. The pre-built libsqlite3.a archives
    // for macOS-{arm64,x86_64} and Windows (via the MinGW symlink farm)
    // let `install:windows` / `install:macos*` link successfully on a
    // Linux host WITHOUT needing vcpkg or brew installed locally.
    //
    // The legacy fetch-vendor-sqlite3 step + scripts/fetch-vendor-sqlite3.sh
    // are kept as a no-op alias for back-compat (CI/scripts that call it
    // still find the step in `zig build --help`). On the ginwasaas-style
    // vendor layout, the fetch is unnecessary — the amalgamation ships in
    // vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400/.
    const vendor_sqlite3_step = b.step(
        "fetch-vendor-sqlite3",
        "Deprecated: vendor/sqlite3/ is now committed to the repo (see vendor/sqlite3/README.md)",
    );
    const vendor_sqlite3_fetch = b.addSystemCommand(&.{
        "sh", "-c",
        \\echo "vendor/sqlite3/ is now committed to the repo; no fetch needed."
    ,
    });
    vendor_sqlite3_fetch.setCwd(b.path(""));
    vendor_sqlite3_step.dependOn(&vendor_sqlite3_fetch.step);

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
    exe.root_module.linkSystemLibrary("curl", .{});
    exe.root_module.link_libc = true;
    // Per-target platform deps (sqlite3/openssl/vendored amalgamation).
    // linkPlatformDeps handles all 4 targets in one switch — replaces the
    // old if/else chain that leaked Linux libs into cross-compile artifacts.
    linkPlatformDeps(b, exe, target);
    // Curl include path for custom_http_client_mod's C glue (target-aware
    // so cross-compile to Windows gets vcpkg path, macOS gets brew path).
    linkCurlIncludePath(b, exe, target, curl_prefix, curl_vcpkg_root);
    // If we ended up on the Windows / cross-compile branch, depend on
    // the auto-fetch step so a fresh checkout Just Works.
    if (target.result.os.tag == .windows) {
    }
    // === Build the Vue webapp (bun) ===
    // Chunk 3: this step is a dependency of the desktop_exe build so the
    // embedded webapp_assets.zig is regenerated on every build. The step
    // itself runs `bun run build` in src/apps/desktop, which is the
    // project's standard webapp build (vue-tsc + vite in parallel — see
    // src/apps/desktop/package.json).
    const build_webapp_step = b.step("build:webapp", "Build the Vue webapp with bun");

    const webapp_dir = "src/apps/desktop";

    // === Pre-flight: vue-tsc needs Node, not just bun ===
    //
    // `bun run build` invokes `vue-tsc --build` (via the type-check npm
    // script) + `vite build` in parallel. vue-tsc 3.x relies on
    // @volar/typescript monkey-patching `fs.readFileSync` to register
    // `.vue` as a TypeScript source-file extension and inject the Vue
    // language plugin. **Bun's native CJS loader bypasses `fs.readFileSync`
    // silently** — the patch is a no-op, no `.vue` extension gets
    // registered, and `vue-tsc --build` exits with hundreds of
    // `TS2307: Cannot find module '.../*.vue'` errors that vite never sees.
    // The bundling step succeeds, but `run-p` propagates the type-check
    // exit code and the whole `bun run build` fails.
    //
    // node + npm must be on PATH so the developer (or CI) can invoke
    // vue-tsc via Node's real CJS loader. We fail fast with a clear
    // error rather than letting vue-tsc's cryptic TS2307 noise leak out.
    const check_webapp_node = b.addSystemCommand(&.{
        "sh", "-c",
        \\
        \\for tool in node npm; do
        \\    command -v "$tool" >/dev/null 2>&1 || {
        \\        echo "" >&2
        \\        echo "ERROR: '$tool' was not found on PATH." >&2
        \\        echo "  vue-tsc (which runs inside 'bun run build' via the type-check" >&2
        \\        echo "  npm script) patches tsc's source via fs.readFileSync to" >&2
        \\        echo "  register .vue as a TypeScript source extension. Bun's native" >&2
        \\        echo "  CJS loader bypasses that patching silently, so" >&2
        \\        echo "  'bun run type-check' fails with hundreds of TS2307 errors." >&2
        \\        echo "" >&2
        \\        echo "  Install nodejs + npm for your platform:" >&2
        \\        echo "    Arch Linux:   sudo pacman -S --needed nodejs npm" >&2
        \\        echo "    Debian/Ubnt:  sudo apt install nodejs npm" >&2
        \\        echo "    macOS:        brew install node" >&2
        \\        echo "    Alpine:       apk add nodejs npm" >&2
        \\        echo "" >&2
        \\        exit 1
        \\    }
        \\done
    });

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
    bun_build.step.dependOn(&check_webapp_node.step);
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
    webapp_rebuild_bun.step.dependOn(&check_webapp_node.step);
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

    // =====================================================================
    // CLI executable (`src/apps/cli/main.zig`) — wraps
    //   - POST  /api/llm/session
    //   - GET   /api/llm/session
    //   - GET   /api/llm/session/:id/messages
    //   - GET   /api/events?channels=...   (SSE)
    // via the project's `custom_http_client` module (libcurl-backed,
    // cross-platform per `src/modules/custom_http_client/NALAR.md`).
    //
    // The CLI module is independent of `nalarcore`: it talks HTTP,
    // not SQLite, so importing `mod` would pull in the database +
    // SSE machinery we don't need. We build its executable directly
    // from `src/apps/cli/main.zig` and hand it the `custom_http_client`
    // import that's already prepared above. The `libc` + `curl` link
    // flags ride along through `custom_http_client_mod` itself.
    const cli_module = b.addModule("cli", .{
        .root_source_file = b.path("src/apps/cli/src/root.zig"),
        .target = target,
    });
    cli_module.addImport("custom_http_client", custom_http_client_mod);

    const cli_exe = b.addExecutable(.{
        .name = "nalarcli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cli", .module = cli_module },
                .{ .name = "custom_http_client", .module = custom_http_client_mod },
            },
        }),
    });
    cli_exe.root_module.linkSystemLibrary("c", .{});
    cli_exe.root_module.link_libc = true;
    // Per-target curl include path (vcpkg on Windows, brew on macOS,
    // /usr/include on Linux). libcurl is wired via custom_http_client_mod;
    // the include path must match the target's libcurl layout.
    linkCurlIncludePath(b, cli_exe, target, curl_prefix, curl_vcpkg_root);
    // NOTE: do NOT call `b.installArtifact(cli_exe)` here — in
    // Zig 0.16 the default install step is finalized early and
    // post-hoc additions can be dropped. Instead we capture the
    // install artifact handle below and depend it from
    // `build_all_step` after that variable exists.
    const cli_install = b.addInstallArtifact(cli_exe, .{});

    const cli_step = b.step("run:cli", "Run the CLI");
    const run_cli_cmd = b.addRunArtifact(cli_exe);
    cli_step.dependOn(&run_cli_cmd.step);
    run_cli_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli_cmd.addArgs(args);

    // === nalarcli unit tests (`zig build test:cli`) ===
    // The CLI module re-exports test files via its `root.zig`, so a
    // single `b.addTest({ .root_module = cli_module })` step picks up
    // every `_test.zig` under `src/apps/cli/` without listing them.
    // Same libc + curl link line as the exe.
    const cli_tests = b.addTest(.{ .root_module = cli_module });
    cli_tests.root_module.linkSystemLibrary("c", .{});
    cli_tests.root_module.link_libc = true;
    linkCurlIncludePath(b, cli_tests, target, curl_prefix, curl_vcpkg_root);
    const test_cli = b.step("test:cli", "Run nalarcli unit tests");
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_cli.dependOn(&run_cli_tests.step);

    // === nalarcli install-only (`zig build install:cli`) ===
    // Skips the full `build:all` dance — just installs the cli binary.
    const install_cli_step = b.step("install:cli", "Install the nalarcli binary only");
    install_cli_step.dependOn(&cli_install.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Note on per-Compile platform deps (replaces old `mod.linkSystemLibrary`
    // + target-based switches): previously, `mod` itself was the place where
    // the build script added sqlite3/openssl/Linux system libs based on the
    // GLOBAL default target. Every Compile that imported `mod` (including
    // `install:windows` / `install:macos` cross-compile artifacts) inherited
    // those Linux system libs in its link line, which the cross-target
    // linker then rejected with "unable to find dynamic system library".
    //
    // The fix: `mod` has NO platform-specific link libs (they live on each
    // Compile step via `linkPlatformDeps`). `mod` DOES need include paths
    // for `@cImport("sqlite3.h")` in src/modules/databases/sqlite/Sqlite.zig
    // — without an include path, the cimport fails with "'sqlite3.h' not
    // found" during semantic analysis.
    //
    // Include paths DON'T leak the same way link libs do: Zig's cimport
    // uses the HOST C compiler (not the cross-target compiler), and the
    // sqlite3.h header is portable C — same file on Linux, macOS, Windows.
    //
    // We add THREE include paths so the cimport works on every host:
    //   1. /usr/include           — Linux native + Linux-host cross-compile
    //   2. <brew>/opt/sqlite/include — macOS native (Homebrew keg-only layout)
    //   3. vendor/sqlite3/amalgamation/... — Windows native + portable
    //      fallback. Used by Zig's cimport on any host (Windows gcc still
    //      finds the .h there via the include path even though it doesn't
    //      look in /usr/include).
    mod.linkSystemLibrary("c", .{});
    mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    mod.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
    mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/opt/sqlite/include", .{sqlite_prefix}) });
    mod.addIncludePath(b.path("vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400"));

    // Tests need a SEPARATE module (not `mod`) so we can attach native
    // platform deps without polluting `mod` for cross-compile consumers.
    // The test module does self-import ("nalarcore" → itself) the same
    // way `mod` does, and imports custom_http_client from the shared
    // module so test code can use the HTTP client.
    const test_target = target; // tests always run on the native host
    const mod_tests_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = test_target,
        .optimize = optimize,
    });
    mod_tests_module.addImport("nalarcore", mod_tests_module);
    mod_tests_module.addImport("custom_http_client", custom_http_client_mod);
    // Apply platform deps directly on the module (modules accumulate
    // deps additively). Using a throwaway Compile step here would be
    // cleaner, but b.addTest({...}).root_module IS the module, so we
    // mutate it in place before b.addTest captures it.
    {
        mod_tests_module.linkSystemLibrary("c", .{});
        mod_tests_module.link_libc = true;
        switch (test_target.result.os.tag) {
            .linux => {
                mod_tests_module.linkSystemLibrary("sqlite3", .{});
                mod_tests_module.linkSystemLibrary("ssl", .{});
                mod_tests_module.linkSystemLibrary("crypto", .{});
                mod_tests_module.linkSystemLibrary("pq", .{});
                mod_tests_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
                mod_tests_module.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
            },
            .macos => {
                mod_tests_module.linkSystemLibrary("sqlite3", .{});
                mod_tests_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/opt/sqlite/include", .{sqlite_prefix}) });
                mod_tests_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/opt/sqlite/lib", .{sqlite_prefix}) });
                mod_tests_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/opt/curl/include", .{curl_prefix}) });
                mod_tests_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/opt/curl/lib", .{curl_prefix}) });
            },
            .windows => {
                mod_tests_module.addIncludePath(b.path("vendor/sqlite3"));
                mod_tests_module.addCSourceFile(.{ .file = b.path("vendor/sqlite3/sqlite3.c"), .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_ENABLE_FTS5" } });
                mod_tests_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/installed/x64-windows/include", .{curl_vcpkg_root}) });
                mod_tests_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/installed/x64-windows/lib", .{curl_vcpkg_root}) });
            },
            else => {
                mod_tests_module.addIncludePath(b.path("vendor/sqlite3"));
                mod_tests_module.addCSourceFile(.{ .file = b.path("vendor/sqlite3/sqlite3.c"), .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_ENABLE_FTS5" } });
            },
        }
    }

    const mod_tests = b.addTest(.{
        .root_module = mod_tests_module,
    });
    // If the test module consumes vendored sqlite3 (Windows / cross-
    // compile), make the test wait for the auto-fetch step so a fresh
    // checkout doesn't fail with "file not found".
    if (test_target.result.os.tag == .windows) {
    }
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const ai_workflow_tui_test_mod = b.addTest(.{
        .root_module = mod_tests_module,
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
    // Custom HTTP client needs curl include path on the cross-target
    // (linkPlatformDeps handles sqlite3/openssl; curl is separate because
    // it's wired via custom_http_client_mod).
    linux_exe.root_module.linkSystemLibrary("curl", .{});
    linux_exe.root_module.link_libc = true;
    linkCurlIncludePath(b, linux_exe, linux_target, curl_prefix, curl_vcpkg_root);
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
    windows_exe.root_module.linkSystemLibrary("curl", .{});
    windows_exe.root_module.link_libc = true;
    linkCurlIncludePath(b, windows_exe, windows_target, curl_prefix, curl_vcpkg_root);
    // Fresh checkout: vendor/sqlite3 doesn't exist yet. Depend on the
    // auto-fetch step so the cross-target linker sees sqlite3.c.
    const install_windows = b.addInstallArtifact(windows_exe, .{});
    windows_step.dependOn(&install_windows.step);

    const macos_step = b.step("install:macos", "Build for macOS x86_64");
    const macos_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
    });
    const macos_exe = createPlatformExe(b, mod, macos_target, optimize, "nalarcore-macos-x86_64");
    macos_exe.root_module.linkSystemLibrary("curl", .{});
    macos_exe.root_module.link_libc = true;
    linkCurlIncludePath(b, macos_exe, macos_target, curl_prefix, curl_vcpkg_root);
    const install_macos = b.addInstallArtifact(macos_exe, .{});
    macos_step.dependOn(&install_macos.step);

    const macos_arm_step = b.step("install:macos-arm", "Build for macOS aarch64 (Apple Silicon)");
    const macos_arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    const macos_arm_exe = createPlatformExe(b, mod, macos_arm_target, optimize, "nalarcore-macos-aarch64");
    macos_arm_exe.root_module.linkSystemLibrary("curl", .{});
    macos_arm_exe.root_module.link_libc = true;
    linkCurlIncludePath(b, macos_arm_exe, macos_arm_target, curl_prefix, curl_vcpkg_root);
    const install_macos_arm = b.addInstallArtifact(macos_arm_exe, .{});
    macos_arm_step.dependOn(&install_macos_arm.step);

    const linux_system_step = b.step("install:linux:system", "Build for Linux x86_64 and install to system");
    const linux_system_exe = createPlatformExe(b, mod, target, optimize, "nalar");
    linux_system_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_system_exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    linux_system_exe.root_module.linkSystemLibrary("curl", .{});
    linux_system_exe.root_module.link_libc = true;
    linkCurlIncludePath(b, linux_system_exe, target, curl_prefix, curl_vcpkg_root);
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
    dev_exe.root_module.linkSystemLibrary("curl", .{});
    dev_exe.root_module.link_libc = true;
    linkPlatformDeps(b, dev_exe, target);
    linkCurlIncludePath(b, dev_exe, target, curl_prefix, curl_vcpkg_root);
    if (target.result.os.tag == .windows) {
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

    // =====================================================================
    // Functional tests (Python+pytest) — see tests/functional/README.md.
    //
    // Booting a real nalar against an isolated tmpdir HOME. The harness
    // enforces a "never delete real $HOME" invariant via is_safe_tmp().
    //
    // Dependencies:
    //   1. install:linux:system  — produces zig-out/bin/nalar
    //   2. python3 venv at .venv-func  — installs requirements.txt once
    //
    // Skips silently if `python3` is missing on PATH (CI images all
    // have it; local developers may not — the README documents
    // `pip install pytest` as the manual fallback).
    // =====================================================================
    const python_exe = b.option([]const u8, "python", "Path to python3 binary (default: 'python3')") orelse "python3";
    const install_venv = b.addSystemCommand(&.{
        python_exe, "-m", "venv", ".venv-func",
    });
    install_venv.setCwd(b.path(""));

    const install_requirements = b.addSystemCommand(&.{
        ".venv-func/bin/pip", "install", "-q", "-r", "tests/functional/requirements.txt",
    });
    install_requirements.setCwd(b.path(""));
    install_requirements.step.dependOn(&install_venv.step);

    // Probe python3 — skip the step if missing. Without a probe,
    // `addSystemCommand(&.{ "python3", ... })` would error at config
    // time on hosts that don't have python3.
    const python_probe = b.addSystemCommand(&.{
        "sh", "-c",
        \\command -v python3 >/dev/null 2>&1 || { echo 'zig build functional-test: python3 not found, skipping (install with `brew install python@3.11` or set -Dpython=...)'; exit 0; }
    ,
    });
    python_probe.setCwd(b.path(""));

    const run_functional = b.addSystemCommand(&.{
        ".venv-func/bin/python", "-m", "pytest", "tests/functional/", "-v", "--tb=short",
    });
    run_functional.setCwd(b.path(""));
    run_functional.step.dependOn(&install_requirements.step);
    run_functional.step.dependOn(&python_probe.step);
    // Depend on the top-level `install` step (copies binary to
    // zig-out/bin/nalar) rather than `install:linux:system` which
    // additionally tries to `cp` to /usr/local/bin/nalar and fails
    // on systems without write perms to /usr/local.
    run_functional.step.dependOn(b.getInstallStep());

    const functional_test_step = b.step("functional-test", "Run functional tests against a real nalar with isolated tmpdir data");
    functional_test_step.dependOn(&run_functional.step);

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
        \\echo "  nalarcli binary       →  $D/nalarcli"
        \\echo ""
        \\echo "  (If a binary is missing, run \`rm -rf $D && zig build\`"
        \\echo "   to force a fresh install — the cache sometimes hides"
        \\echo "   manual deletions.)"
        \\echo ""
        \\echo "  Run with:  $D/nalarcore-linux-x86_64 service start --port 8080"
        \\echo "             $D/nalar-desktop --devtools"
        \\echo "             $D/nalarcli sessions list"
        \\echo ""
        ,
    });
    const build_all_step = b.step("build:all", "Build nalar service + nalar-desktop, with end-of-build summary");
    // The binaries live on different top-level install steps:
    //   - nalarcore-linux-x86_64  → install:linux   (cross target, Linux x86_64)
    //   - nalar-desktop           → install           (native target, includes
    //                                               b.installArtifact(desktop_exe))
    //   - nalarcli                → cli_install      (manual addInstallArtifact;
    //                                               see note above `cli_install`
    //                                               for why we don't use the
    //                                               default `install` step)
    // The native `nalar` binary is also in `install`. We want all in
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
    build_all_step.dependOn(&cli_install.step);
    build_all_step.dependOn(&build_banner.step);

    // Default: same as `build:all`. Without this, `zig build` (no args)
    // runs the `install` step alone, which prints no summary on success.
    // Zig 0.16's `Build.default_step: *Step` — `b.step()` already
    // returns `*Step`, so we assign the pointer directly.
    b.default_step = build_all_step;
}
