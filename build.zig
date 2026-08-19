const std = @import("std");
const builtin = @import("builtin");

/// Link platform-specific system libraries + include paths for a Compile
/// step based on the COMPILE'S OWN target (NOT the global default target).
/// Every caller that produces a binary linked against nalarcore MUST
/// call this — otherwise the cross-compile link line will miss the
/// target's per-platform deps.
///
/// What lives here (post-`databases` package extraction):
///   - universal: libc + link_libc
///   - Linux:     ssl / crypto / pq + /usr/include (sqlite3 lives in the
///                `databases` package — propagated via the module graph)
///   - macOS:     (nothing — curl is universal via custom_http_client_mod)
///   - Windows:   bcrypt (for src/modules/custom_http_server/src/security.zig)
///
/// What used to live here: per-platform sqlite3 amalgamation/archives
/// + brew paths. Those moved to src/modules/databases/build.zig, which
/// runs once per target the consumer passes via `b.dependency("databases",
/// .{ .target = ... })` and emits the right sqlite3 deps for that target.
fn linkPlatformDeps(
    _b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    _ = _b;
    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.link_libc = true;
    switch (target.result.os.tag) {
        .linux => {
            // Everything database-related (sqlite3 amalgamation + openssl +
            // crypto + libpq + /usr/include + /usr/include/postgresql) is
            // handled by the `databases` package — propagated to this
            // Compile via mod.addImport → databases_mod.
            //
            // ALSO add /usr/lib to the library search path. With glibc 2.38
            // (the global default target), the linker default search path
            // doesn't include /usr/lib in some contexts — the `linkSystemLibrary("ssl", "crypto", "pq")`
            // calls inside the `databases` package surface this with
            // "unable to find dynamic system library 'ssl' using strategy 'paths_first'. searched paths: none".
            // Forcing the path here makes the linker find the system libs.
            exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        },
        .macos => {
            // Everything database-related (sqlite3 amalgamation) is handled
            // by the `databases` package. macOS doesn't need openssl/pq
            // here (libpq is not currently used on macOS; openssl rides
            // along via custom_http_client_mod).
        },
        .windows => {
            // Everything database-related (sqlite3 amalgamation + bcrypt)
            // is handled by the `databases` package. bcrypt.dll is needed
            // by src/modules/custom_http_server/src/security.zig
            // (BCryptGenRandom — Zig's std.c.getrandom is `void` on Windows).
        },
        else => {
            // Cross-compile to non-Linux/macOS/Windows targets. The
            // `databases` package covers everything — nothing extra to add.
        },
    }
}

/// Resolve the active macOS SDK path via `xcrun --show-sdk-path`.
///
/// WHY THIS EXISTS: this build.zig's `target` (see `standardTargetOptions`
/// below) always fills in an explicit `.os_tag` in its default_target query
/// — even on native builds, where Zig would normally leave it null. Zig's
/// automatic macOS-SDK autodetection (the thing that fills in framework
/// search paths for `linkFramework` calls) only fires when it can tell the
/// target query is genuinely native (i.e. os_tag left unset). Because this
/// file always sets os_tag explicitly, that autodetection path never runs,
/// and `linkFramework("Cocoa")` / `linkFramework("WebKit")` fail with
/// "searched paths: none" — there's no SDK path filled in at all.
///
/// The fix: resolve the SDK path ourselves via `xcrun` and wire the
/// framework/include/library search paths manually before linking.
///
/// NOTE: this only works when building ON a macOS host (xcrun is an Xcode/
/// CLT tool). If this project ever needs to cross-compile TO macOS from a
/// non-mac host, this will need a vendored SDK instead, following the same
/// pattern as the vendored curl/sqlite3 fetch steps elsewhere in this file.
fn getMacosSdkPath(b: *std.Build) []const u8 {
    const result = std.process.run(
        b.allocator,
        b.graph.io,
        .{
            .argv = &.{ "xcrun", "--show-sdk-path" },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(1024),
        },
    ) catch @panic("`xcrun --show-sdk-path` failed — is Xcode or the Command Line Tools installed? Run `xcode-select --install` or `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.");
    return std.mem.trim(u8, result.stdout, " \n\r\t");
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
    // Target glibc 2.38 on Linux hosts — needed for vendored curl's
    // references to `__isoc23_*` (glibc 2.38+) and `arc4random`
    // (glibc 2.36+ in weak-symbol form). Older glibc versions fail to
    // link with "undefined reference to __isoc23_strtol" etc. The
    // minimum version can be overridden with `-Dtarget=...` for hosts
    // running older glibc.
    //
    // On non-Linux hosts (macOS, Windows), the default target follows
    // the HOST OS so `zig build` and `zig build test` don't try to
    // cross-compile to Linux. Previously this default was hardcoded to
    // `.os_tag = .linux`, which made the macOS self-hosted runner
    // (an Apple-Silicon MacBook) cross-compile to `aarch64-linux-gnu.2.38`
    // and then look for `vendor/curl/linux-aarch64/lib/libcurl.a` —
    // a target the curl bootstrap script never builds. Override with
    // `-Dtarget=x86_64-linux-gnu.2.38` (etc.) to explicitly cross-compile
    // from a macOS/Windows host.
    const target = b.standardTargetOptions(.{ .default_target = switch (b.graph.host.result.os.tag) {
        .linux => .{
            .cpu_arch = b.graph.host.result.cpu.arch,
            .os_tag = .linux,
            .abi = .gnu,
            .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 },
        },
        else => .{
            .cpu_arch = b.graph.host.result.cpu.arch,
            .os_tag = b.graph.host.result.os.tag,
            .abi = b.graph.host.result.abi,
        },
    } });
    const optimize = b.standardOptimizeOption(.{});

    // Cross-platform Homebrew / vcpkg prefix options. Declared ONCE here
    // so `b.option()`'s anti-duplicate rule isn't violated when the same
    // value feeds multiple link sites (linux_exe / windows_exe / macos_exe
    // / dev_exe / tests).
    //
    // Note: `sqlite-prefix` is gone — sqlite3 wiring lives in the
    // `databases` package's own build.zig. The package picks up
    // system sqlite3 via `linkSystemLibrary` / amalgamation compile
    // based on the target the consumer passes via b.dependency().
    //
    // Note: `-Dcurl-prefix` / `-Dcurl-vcpkg-root` are gone — curl wiring
    // now lives in the `custom_http_client` package's own build.zig,
    // which links the vendored prebuilt archive from
    // vendor/curl/<target>/lib/libcurl.a. The package picks up the
    // right archive based on the target the consumer passes via
    // b.dependency(). See src/modules/custom_http_client/build.zig for
    // the full rationale.

    const mod = b.addModule("nalarcore", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.addImport("nalarcore", mod);

    // === Self-contained `databases` package (sqlite3 + openssl + libpq) ===
    // The package (at src/modules/databases/) carries its own build.zig
    // that wires sqlite3 / openssl / libpq + the vendored sqlite3.c
    // amalgamation based on the TARGET passed in. Every Compile that
    // imports `mod` (and therefore the `databases` module via
    // mod.addImport below) inherits those deps — no per-Compile
    // linkPlatformDeps branch for sqlite3 anymore.
    //
    // The `vendor-dir` option passes through to the package's build.zig
    // so the package can locate vendor/sqlite3/ relative to its own
    // location. Default `../../vendor/sqlite3` resolves to the project
    // root's vendor/sqlite3/ — works for the default layout. Override
    // with `-Dvendor-dir=...` if you move either side.
    const databases_dep = b.dependency("databases", .{
        .target = target,
        .optimize = optimize,
    });
    const databases_mod = databases_dep.module("databases");
    mod.addImport("databases", databases_mod);

    // === Self-contained `custom_http_client` package (vendored libcurl) ===
    // Mirrors the `databases` package pattern. The package's own build.zig
    // wires the vendored prebuilt archive from vendor/curl/<target>/lib/
    // libcurl.a based on the TARGET we pass in below. Consumers (mod,
    // mod_tests_module, cli_module, every install:* cross-compile exe)
    // get the right archive + include path automatically via Zig's
    // module-graph dep propagation.
    //
    // Required glibc version bumped to 2.38 — curl's source uses
    // `__isoc23_*` (glibc 2.38+) and `arc4random` (glibc 2.36+ in
    // weak-symbol form). Older glibc versions fail to link with
    // "undefined reference to __isoc23_strtol" etc. The custom
    // http_client target overrides glibc when needed.
    const custom_http_client_dep = b.dependency("custom_http_client", .{
        .target = target,
        .optimize = optimize,
    });
    const custom_http_client_mod = custom_http_client_dep.module("custom_http_client");
    mod.addImport("custom_http_client", custom_http_client_mod);

    // === custom_http_client module (libcurl-backed HTTP) ===
    // Exposed as a separate module so Agent2.zig (in src/modules/agent/)
    // can `@import("custom_http_client")`. Same libcurl deps as the
    // sibling build at src/modules/custom_http_client/build.zig.
    //
    // Self-contained package — mirrors the `databases` package pattern.
    // The package's own build.zig wires the vendored prebuilt archive
    // from vendor/curl/<target>/lib/libcurl.a based on the TARGET we
    // pass in below. Consumers (mod, mod_tests_module, cli_module, every
    // install:* cross-compile exe) get the right archive + include path
    // automatically via Zig's module-graph dep propagation.
    //
    // No more `-Dcurl-prefix` / `-Dcurl-vcpkg-root` options, no more
    // `linkSystemLibrary("curl", .{})` calls in this file, no more
    // `linkCurlIncludePath()` helper. The package owns its own deps.

    // === System-deps probe ===
    // Run the same probe as the `databases` and `custom_http_client`
    // packages to decide whether to attach the vendor fetch steps.
    // The packages ALSO run their own probes (to decide their own
    // link line). Running the probe twice is intentional — keeps
    // each package self-contained (no API dependency on the root
    // build.zig's probe result). ~50 ms total per `zig build` —
    // negligible.
    //
    // The fetch steps themselves are idempotent (no-op when vendor
    // dir is populated), but the CROSS-COMPILE cost on a fresh
    // checkout is ~30 min for curl + openssl. On a host with system
    // libs, we don't need any of that — skipping the fetch steps
    // saves ~30 min on first build.
    //
    // Implementation: we duplicate the probe here (in root build.zig)
    // because Zig's package API doesn't expose build.zig helpers
    // across the module-graph boundary. The probe is ~30 lines; the
    // duplication is acceptable.
    // Probe host for system sqlite3 + libpq + openssl.
    //
    // Linux native (target == host == linux): looks at /usr/include
    // + /usr/lib (Arch / Debian / Ubuntu / Fedora layouts).
    //
    // macOS native (target == host == macos): Homebrew ships keg-only
    // libs under /opt/homebrew/opt/<name>/{include,lib}. The CI yml
    // already installs `pkg-config openssl@3 coreutils` on Mac runners
    // and exports LDFLAGS/CPPFLAGS pointing at $(brew --prefix
    // openssl@3). We look at the same paths the CI relies on:
    //   /opt/homebrew/opt/curl/{include,lib}/curl/curl.h + libcurl.dylib
    //   /opt/homebrew/opt/openssl@3/{include,lib}/openssl/ssl.h + .dylib
    // Cross-compile (Linux host → macOS target) falls back to vendor —
    // the host's libs are Linux .so, can't link into a Mach-O binary.
    const dbs_uses_system = blk: {
        if (target.result.os.tag != b.graph.host.result.os.tag) break :blk false;
        const probe_script = switch (b.graph.host.result.os.tag) {
            .linux =>
            \\{ \
            \\  s=$(test -f /usr/include/sqlite3.h && echo 1 || echo 0); \
            \\  q=$(test -f /usr/include/postgresql/libpq-fe.h -o -f /usr/include/libpq-fe.h && echo 1 || echo 0); \
            \\  h=$(test -f /usr/include/openssl/ssl.h && echo 1 || echo 0); \
            \\  echo "use_system=$s$q$h"; \
            \\}
            ,
            .macos =>
            // Homebrew keg-only: every keg under /opt/homebrew/opt/<name>/
            // has both include/ and lib/ subdirs (symlinked into the
            // cellar). curl.h is bundled inside the curl keg at
            // /opt/homebrew/opt/curl/include/curl/curl.h. libpq isn't
            // usually installed via brew on a dev Mac (the project doesn't
            // use it on macOS today), so we treat pq as optional on macos.
            \\{ \
            \\  s=$(test -f /opt/homebrew/opt/curl/include/curl/curl.h -o -f /usr/include/curl/curl.h && echo 1 || echo 0); \
            \\  q=$(test -f /opt/homebrew/opt/libpq/include/libpq-fe.h -o -f /usr/include/postgresql/libpq-fe.h -o -f /usr/include/libpq-fe.h && echo 1 || echo 0); \
            \\  h=$(test -f /opt/homebrew/opt/openssl@3/include/openssl/ssl.h -o -f /opt/homebrew/opt/openssl/include/openssl/ssl.h -o -f /usr/include/openssl/ssl.h && echo 1 || echo 0); \
            \\  echo "use_system=$s$q$h"; \
            \\}
            ,
            else =>
            // Windows: probe vcpkg-installed headers at the canonical
            // `C:/vcpkg/installed/x64-windows/include/` path. The CI
            // installs sqlite3, openssl, libpq, curl via
            // `vcpkg install --recurse <port>:x64-windows` — the
            // package-level probes verify each header separately,
            // this top-level probe just decides whether to skip the
            // `fetch-vendor-{sqlite3,curl}` build steps. Probe runs
            // under `sh -c` (git-bash on the self-hosted Windows runner)
            // and forward-slash paths work natively there.
            //
            // Header-only probe (3 bits, no separate lib check): the
            // package-level probes also check only headers, so they
            // stay consistent with this top-level one. Lib presence
            // is verified at link time by the linker (a missing .lib
            // gives `file not found`, which is a clear diagnostic).
            \\{ \
            \\  VCPKG=/c/vcpkg/installed/x64-windows/include; \
            \\  s=$(test -f "$VCPKG/sqlite3.h" && echo 1 || echo 0); \
            \\  q=$(test -f "$VCPKG/libpq-fe.h" && echo 1 || echo 0); \
            \\  h=$(test -f "$VCPKG/openssl/ssl.h" && echo 1 || echo 0); \
            \\  echo "use_system=$s$q$h"; \
            \\}
            ,
        };
        const result = std.process.run(
            b.allocator,
            b.graph.io,
            .{
                .argv = &.{ "sh", "-c", probe_script },
                .stdout_limit = .limited(256),
                .stderr_limit = .limited(256),
            },
        ) catch break :blk false;
        defer b.allocator.free(result.stdout);
        defer b.allocator.free(result.stderr);
        // All three: sqlite3 + libpq + openssl headers. Library files
        // (.lib) are resolved at link time against the vcpkg sysroot
        // added by the package-level build.zig's `.windows =>` arm.
        break :blk std.mem.indexOf(u8, result.stdout, "use_system=111") != null;
    };

    // Probe host for system libcurl + openssl. Same probe layout as
    // dbs_uses_system but checks curl.h + openssl/ssl.h instead of
    // sqlite3/libpq. On macOS we additionally verify a libcurl.dylib
    // exists — having the header without the library (rare) would fail
    // at consumer link time.
    const curl_uses_system = blk: {
        if (target.result.os.tag != b.graph.host.result.os.tag) break :blk false;
        const probe_script = switch (b.graph.host.result.os.tag) {
            .linux =>
            \\{ \
            \\  c=$(test -f /usr/include/curl/curl.h && echo 1 || echo 0); \
            \\  h=$(test -f /usr/include/openssl/ssl.h && echo 1 || echo 0); \
            \\  echo "use_system=$c$h"; \
            \\}
            ,
            .macos =>
            // Homebrew keg-only curl: /opt/homebrew/opt/curl/{include,lib}/.
            // Also accept the LDFLAGS/CPPFLAGS env vars the CI yml sets
            // (`brew install pkg-config openssl@3 coreutils` + export
            // LDFLAGS/CPPFLAGS/PKG_CONFIG_PATH from `brew --prefix
            // openssl@3`). The CI installs openssl@3 + coreutils but
            // NOT curl by default — brew install openssl@3 alone doesn't
            // pull in libcurl. So curl probe = curl.h present (any of the
            // three locations) AND libcurl.dylib present. If brew install
            // curl is added to CI later, the probe finds it; until then,
            // the Mac runner needs `brew install curl` for system libcurl
            // to be picked up here.
            \\{ \
            \\  HDR=$(test -f /opt/homebrew/opt/curl/include/curl/curl.h -o -f /usr/include/curl/curl.h && echo 1 || echo 0); \
            \\  LIB=$(test -f /opt/homebrew/opt/curl/lib/libcurl.dylib -o -f /usr/lib/libcurl.dylib && echo 1 || echo 0); \
            \\  SSL=$(test -f /opt/homebrew/opt/openssl@3/include/openssl/ssl.h -o -f /opt/homebrew/opt/openssl/include/openssl/ssl.h -o -f /usr/include/openssl/ssl.h && echo 1 || echo 0); \
            \\  echo "use_system=$HDR$LIB$SSL"; \
            \\}
            ,
            else =>
            // Windows: vcpkg at `C:/vcpkg/installed/x64-windows/include/`.
            // Both curl.h + openssl/ssl.h must be present. Library
            // files (.lib) are resolved at link time against the vcpkg
            // sysroot added by custom_http_client/build.zig's
            // `.windows =>` arm.
            \\{ \
            \\  VCPKG=/c/vcpkg/installed/x64-windows/include; \
            \\  c=$(test -f "$VCPKG/curl/curl.h" && echo 1 || echo 0); \
            \\  h=$(test -f "$VCPKG/openssl/ssl.h" && echo 1 || echo 0); \
            \\  echo "use_system=$c$h"; \
            \\}
            ,
        };
        const result = std.process.run(
            b.allocator,
            b.graph.io,
            .{
                .argv = &.{ "sh", "-c", probe_script },
                .stdout_limit = .limited(256),
                .stderr_limit = .limited(256),
            },
        ) catch break :blk false;
        defer b.allocator.free(result.stdout);
        defer b.allocator.free(result.stderr);
        // Both: curl.h + openssl/ssl.h. On macOS we also require
        // libcurl.dylib (header+lib both present). libssl/libcrypto
        // verification is done by the package's own probe.
        break :blk std.mem.indexOf(u8, result.stdout, "use_system=") != null and
            std.mem.indexOf(u8, result.stdout, "use_system=000") == null and
            // linux shape: "use_system=11" (curl + openssl)
            // macos shape: "use_system=111" (curl_hdr + libcurl.dylib + openssl)
            (std.mem.indexOf(u8, result.stdout, "use_system=11") != null or
            std.mem.indexOf(u8, result.stdout, "use_system=111") != null);
    };

    std.debug.print(
        "[build.zig] system-deps probe: databases_uses_system={}, custom_http_client_uses_system={}\n",
        .{ dbs_uses_system, curl_uses_system },
    );

    // === Auto-fetch vendor/sqlite3 if missing ===
    // The amalgamation (`src/modules/databases/vendor/sqlite3/sqlite3.c`
    // ~10 MB + 2 headers) is gitignored (per .gitignore — the
    // `src/modules/databases/vendor/` path is excluded). Fresh checkouts
    // need the fetch to happen BEFORE any Compile step that links the
    // amalgamation. The script (`src/modules/databases/scripts/fetch-vendor-sqlite3.sh`)
    // downloads + verifies the SHA3-256 of the official amalgamation ZIP
    // and writes it to the package's own vendor dir. Idempotent: skips
    // if the files already exist.
    //
    // The `fetch-vendor-sqlite3` step is depended on by `test_step` (and
    // every `install:*` cross-compile target) so a fresh checkout Just
    // Works without a separate `bash bootstrap-vendor.sh` invocation.
    //
    // SKIP-WHEN-SYSTEM-PRESENT: when the probe above detects system
    // sqlite3 (the typical Arch / Debian / Ubuntu / Fedora dev host),
    // the fetch step is replaced with a no-op so `zig build` doesn't
    // spend ~30 s downloading + verifying the amalgamation on a fresh
    // checkout. The databases package's `build.zig` already uses
    // `linkSystemLibrary("sqlite3")` instead of compiling the .c.
    const vendor_sqlite3_step = b.step(
        "fetch-vendor-sqlite3",
        "Fetch the sqlite3 amalgamation into src/modules/databases/vendor/sqlite3/ (idempotent). Auto-runs before `zig build test` and every `install:*` target on a fresh checkout. SKIPPED when the host has system sqlite3 (see system-deps probe output).",
    );
    if (dbs_uses_system) {
        // System sqlite3 present — replace the fetch with a no-op
        // message so `zig build --verbose` shows WHY the step was
        // skipped. The step still exists in --list-steps so any
        // external automation that depends on it doesn't break.
        const skip_msg = b.addSystemCommand(&.{
            "sh", "-c",
            \\echo "[fetch-vendor-sqlite3] SKIPPED — host has system sqlite3 + libpq + openssl (probe detected)."
        ,
        });
        vendor_sqlite3_step.dependOn(&skip_msg.step);
    } else {
        const vendor_sqlite3_fetch = b.addSystemCommand(&.{
            "bash", "src/modules/databases/scripts/fetch-vendor-sqlite3.sh",
        });
        vendor_sqlite3_fetch.setCwd(b.path(""));
        vendor_sqlite3_step.dependOn(&vendor_sqlite3_fetch.step);
    }

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

    // === fetch-vendor-curl build step ===
    // Cross-compile to macOS/Windows AND native Linux builds need
    // the vendored libcurl.a archive in
    // src/modules/custom_http_client/vendor/curl/<target>/lib/. The
    // script (src/modules/custom_http_client/scripts/build-vendor-curl.sh
    // — co-located with the package) cross-compiles from source. It's
    // idempotent — re-running on a populated vendor/ is fast (no-op
    // after first build).
    //
    // MUST be defined BEFORE `b.installArtifact(exe)` below — the
    // default `install` step (which `zig build` runs) depends on
    // the installed artifact's step, which we're about to add a
    // dependency on. Defining fetch_vendor_curl_step after
    // b.installArtifact would mean the default install doesn't
    // trigger the fetch, leaving the build broken on fresh checkouts
    // (where vendor/curl/ is gitignored + empty).
    //
    // SKIP-WHEN-SYSTEM-PRESENT: same pattern as fetch-vendor-sqlite3.
    // On a Linux host with system libcurl + openssl, the fetch step
    // is replaced with a no-op so `zig build` doesn't spend ~30 min
    // cross-compiling curl + openssl from source.
    const fetch_vendor_curl_step = b.step(
        "fetch-vendor-curl",
        "Build src/modules/custom_http_client/vendor/curl/<target>/ from source (cross-compiles libcurl for Linux + macOS; idempotent). " ++
            "Auto-runs on `zig build` or any install:* target when the vendor dir is missing. SKIPPED when the host has system libcurl + ssl + crypto (see system-deps probe output).",
    );
    if (curl_uses_system) {
        const skip_msg = b.addSystemCommand(&.{
            "sh", "-c",
            \\echo "[fetch-vendor-curl] SKIPPED — host has system libcurl + ssl + crypto (probe detected)."
        ,
        });
        fetch_vendor_curl_step.dependOn(&skip_msg.step);
    } else {
        const fetch_vendor_curl_run = b.addSystemCommand(&.{
            "bash", "src/modules/custom_http_client/scripts/build-vendor-curl.sh",
        });
        fetch_vendor_curl_run.setCwd(b.path(""));
        fetch_vendor_curl_step.dependOn(&fetch_vendor_curl_run.step);
    }

    b.installArtifact(exe);
    // Make the default `install` step (which `zig build` runs)
    // depend on fetch_vendor_curl — this is what makes `zig build`
    // work on a fresh checkout where vendor/curl/ is empty.
    b.getInstallStep().dependOn(fetch_vendor_curl_step);

    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.link_libc = true;
    // Per-target platform deps (sqlite3/openssl/vendored amalgamation).
    // linkPlatformDeps handles all 4 targets in one switch — replaces the
    // old if/else chain that leaked Linux libs into cross-compile artifacts.
    linkPlatformDeps(b, exe, target);
    // libcurl is linked via custom_http_client_mod's transitive deps
    // (the vendored prebuilt archive is added in the package's own
    // build.zig). No need to call linkSystemLibrary("curl", ...) or
    // addIncludePath here — the module graph handles it.
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
            // Cross-compile for the same target as the main binary (NOT
            // b.graph.host) to avoid the Zig 0.16 + GCC 16 host-native
            // link failure: GCC 16's crt1.o has a `.sframe` section with
            // R_X86_64_PC64 relocations that Zig 0.16's bundled LLD does
            // not support ("unhandled relocation type R_X86_64_PC64 at
            // offset 0x1c, in /usr/lib/.../crt1.o:.sframe"). CI failed on
            // this with the host target — the target's glibc 2.38
            // crt1.o doesn't have the sframe section, so the cross-
            // compile link succeeds. The tool is a one-shot CLI that
            // uses std.c (libc), so cross-compiling is safe.
            .target = target,
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
            // Cross-compile for the same target as the main binary (NOT
            // b.graph.host) to avoid the Zig 0.16 + GCC 16 host-native
            // link failure (see the webapp_rebuild_codegen step above
            // for the full rationale).
            .target = target,
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
            .link_libc = true,
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
            //
            // Library search path: with glibc 2.38 target, the linker's
            // default search path doesn't include /usr/lib in some contexts.
            // Add it explicitly so `linkSystemLibrary` finds the SO files
            // (otherwise we get "unable to find dynamic system library
            // 'webkit2gtk-4.1' using strategy 'paths_first'. searched paths: none").
            // Note: don't add `/usr/lib/x86_64-linux-gnu` — that's a
            // Debian/Ubuntu multi-arch path that doesn't exist on Arch /
            // Fedora, and Zig treats a missing library dir as a fatal error.
            // /usr/lib alone catches both layouts (Debian symlinks .so files
            // at /usr/lib too).
            desktop_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
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
            //
            // FIX: Zig doesn't auto-detect the macOS SDK here because
            // `target`'s query has an explicit .os_tag (see the
            // standardTargetOptions default_target block near the top of
            // `build`), which disables Zig's native-SDK autodetection
            // fast path — that path only runs when os_tag is left null.
            // Without it, `linkFramework` has nowhere to look and fails
            // with "unable to find framework 'Cocoa'. searched paths: none".
            // We resolve the SDK path ourselves via `xcrun` and wire the
            // framework/include/library search paths manually before
            // linking. See `getMacosSdkPath` above for more detail.
            const sdk_path = getMacosSdkPath(b);
            desktop_exe.root_module.addSystemFrameworkPath(.{
                .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk_path}),
            });
            desktop_exe.root_module.addSystemIncludePath(.{
                .cwd_relative = b.fmt("{s}/usr/include", .{sdk_path}),
            });
            desktop_exe.root_module.addLibraryPath(.{
                .cwd_relative = b.fmt("{s}/usr/lib", .{sdk_path}),
            });

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
    // Note: don't add to `b.getInstallStep()` here — that's the default
    // `install` step, and `build_all_step` re-uses it via `getInstallStep().dependOn(...)`
    // already. Adding it twice causes the desktop install to be skipped
    // when `zig build` runs (some kind of graph dedup issue).
    const desktop_install = b.addInstallArtifact(desktop_exe, .{});

    // Make the desktop binary depend on the codegen step. The codegen runs
    // `bun run build` first (via build_webapp_step) and then walks dist/ to
    // emit webapp_assets.zig, so by the time desktop_exe compiles the
    // embedded/ directory is populated with the latest assets.
    desktop_exe.step.dependOn(&codegen.step);

    // `zig build nalar-desktop` alias — depends on:
    //   - the install step (which includes `nalar` via b.installArtifact
    //     above, so the nalar service binary that nalar-desktop would
    //     auto-spawn ends up in zig-out/bin/)
    //   - desktop_install (the nalar-desktop binary itself, captured
    //     separately because adding b.installArtifact(desktop_exe)
    //     directly to getInstallStep() would put it in the default
    //     `zig build` install path too — the comment at desktop_install
    //     explains why we don't want that).
    // Without this, `zig build nalar-desktop` only produces the `nalar`
    // binary — the desktop binary is skipped because it's only attached
    // to `build_all_step`. CI's "Verify desktop + service binaries (Linux)"
    // step checks both exist after `zig build nalar-desktop`, so this
    // would fail with "✗ zig-out/bin/nalar-desktop missing".
    const build_nalar_desktop = b.step("nalar-desktop", "Build the nalar-desktop binary (and the nalar service binary it auto-spawns)");
    build_nalar_desktop.dependOn(b.getInstallStep());
    build_nalar_desktop.dependOn(&desktop_install.step);

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
    // Same linkPlatformDeps treatment as the main exe: on Linux
    // native builds, the linker needs `/usr/lib` on its search path
    // to find the system libcurl / libssl / libcrypto .so files
    // (the ones added by `custom_http_client_mod` going system via
    // its probe). Without this, the CLI link fails with
    // "unable to find dynamic system library 'curl'" (same as the
    // main exe's pre-probe behavior). Vendored path didn't need this
    // because the static archive was embedded directly via
    // addObjectFile — no dynamic linker search required.
    linkPlatformDeps(b, cli_exe, target);
    // libcurl is linked via custom_http_client_mod's transitive deps
    // (the vendored prebuilt archive is added in the package's own
    // build.zig). No need to call linkCurlIncludePath here — the
    // module graph handles it.
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
    // libcurl is wired via custom_http_client_mod's transitive deps.
    const cli_tests = b.addTest(.{ .root_module = cli_module });
    cli_tests.root_module.linkSystemLibrary("c", .{});
    cli_tests.root_module.link_libc = true;
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
    // sqlite3 / openssl / libpq + vendor/sqlite3 amalgamation paths are
    // NO LONGER on `mod` — they live in src/modules/databases/build.zig
    // and propagate to `mod` via the `databases` module's addImport graph.
    // Adding them here would re-leak Linux native system libs into every
    // Compile that imports `mod` (including cross-compile artifacts) —
    // the exact bug the per-Compile linkPlatformDeps pattern was designed
    // to prevent.

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
    // Same `databases` import as `mod` — tests that touch sqlite3 get
    // the package's deps (link_libc + sqlite3.c amalgamation + openssl +
    // libpq) via the module-graph dep propagation. No need to re-link
    // them on `mod_tests_module` directly.
    mod_tests_module.addImport("databases", databases_mod);
    // Apply platform deps directly on the module (modules accumulate
    // deps additively). Using a throwaway Compile step here would be
    // cleaner, but b.addTest({...}).root_module IS the module, so we
    // mutate it in place before b.addTest captures it.
    //
    // After the `databases` package extraction: sqlite3 amalgamation +
    // openssl + crypto + libpq + /usr/include + /usr/include/postgresql
    // are ALL propagated via mod.addImport above. We only need libc here
    // — libcurl is fully wired via custom_http_client_mod's transitive
    // deps (the vendored prebuilt archive handles the link line; the
    // portable C headers handle the @cImport include path on every host).
    //
    // With glibc 2.38 target, the test module's `linkSystemLibrary("ssl", "crypto", "pq")`
    // (added by the `databases` package) needs the system's `/usr/lib`
    // to be on the linker search path. The `databases` package only adds
    // /usr/include for headers, not the library path — so we add it here.
    {
        mod_tests_module.linkSystemLibrary("c", .{});
        mod_tests_module.link_libc = true;
        if (test_target.result.os.tag == .linux) {
            mod_tests_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
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
    // Fresh checkouts need both vendor dirs populated before any
    // Compile step can link the vendored libcurl archive or compile
    // the sqlite3 amalgamation. Without these deps, `zig build test`
    // on a clean checkout fails with "file not found" for
    // vendor/sqlite3/sqlite3.c (databases package) and/or
    // vendor/curl/<target>/lib/libcurl.a (custom_http_client package).
    //
    // The deps MUST be on the COMPILE step (`mod_tests.step`), not
    // just on `test_step` or on the wrap step (`run_mod_tests.step`).
    // `addRunArtifact(mod_tests)` wraps the Compile step in a Run
    // step; the Compile step and any deps we attach to the Run step
    // become siblings under that Run step. Zig's build runner
    // dispatches siblings of a parent step in parallel (see
    // `compiler/build_runner.zig:1408-1410`), so attaching the fetch
    // deps to `run_mod_tests.step` makes them parallel to the compile
    // step — the compile then races the curl build script and loses
    // (failure observed on CI run 31706196476: `error: .../vendor/curl/
    // linux_x86_64/lib/libcurl.a: file not found`). Attaching the deps
    // to `mod_tests.step` (the Compile step itself) makes them
    // ordering constraints of the Compile step — the build runner's
    // `pending_deps` counter (see compiler/build_runner.zig:1413-1418)
    // gates the compile on fetch completion.
    test_step.dependOn(&run_mod_tests.step);
    mod_tests.step.dependOn(fetch_vendor_curl_step);
    mod_tests.step.dependOn(vendor_sqlite3_step);

    const ai_workflow_tui_test_mod = b.addTest(.{
        .root_module = mod_tests_module,
    });

    const run_ai_workflow_tui_tests = b.addRunArtifact(ai_workflow_tui_test_mod);
    const test_ai_workflow_tui_step = b.step("test:ai_workflow:tui", "Run AI workflow TUI tests");
    // Same race-condition fix as `test_step` above — the TUI test
    // reuses `mod_tests_module` (which transitively imports the
    // vendored libcurl.a + sqlite3.c), so the COMPILE step
    // (`ai_workflow_tui_test_mod.step`) must wait for the fetch
    // steps to complete. Attaching to the Run step (the wrap) is
    // wrong — it would make the fetch a sibling of the compile, not
    // a prerequisite.
    test_ai_workflow_tui_step.dependOn(&run_ai_workflow_tui_tests.step);
    ai_workflow_tui_test_mod.step.dependOn(fetch_vendor_curl_step);
    ai_workflow_tui_test_mod.step.dependOn(vendor_sqlite3_step);

    const linux_step = b.step("install:linux", "Build for Linux x86_64");
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
        .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 },
    });
    const linux_exe = createPlatformExe(b, mod, linux_target, optimize, "nalarcore-linux-x86_64");
    linux_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    // libcurl is linked via custom_http_client_mod's transitive deps
    // (the vendored prebuilt archive is added in the package's own
    // build.zig). No need to call linkSystemLibrary("curl", ...) or
    // linkCurlIncludePath here — the module graph handles it.
    linux_exe.root_module.link_libc = true;
    linux_step.dependOn(fetch_vendor_curl_step);
    // Race-condition fix: depend on the fetch steps from the COMPILE
    // step (not just the parent step) so the build runner's
    // pending_deps counter gates the compile on the fetch completion.
    // Same rationale as the comment on `test_step` above.
    linux_exe.step.dependOn(fetch_vendor_curl_step);
    linux_exe.step.dependOn(vendor_sqlite3_step);
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
    // libcurl is linked via custom_http_client_mod's transitive deps.
    // NOTE: src/modules/custom_http_client/vendor/curl/windows-amd64/
    // is NOT built yet (MinGW setup pending — see the curl build
    // script for the gap).
    windows_exe.root_module.link_libc = true;
    // Fresh checkout: src/modules/databases/vendor/sqlite3/ doesn't
    // exist yet. Depend on the auto-fetch step so the cross-target
    // linker sees sqlite3.c.
    // Also depend on fetch-vendor-curl so the windows-amd64/ vendor
    // dir gets built (currently fails — see MinGW note above).
    windows_step.dependOn(fetch_vendor_curl_step);
    windows_step.dependOn(vendor_sqlite3_step);
    // Race-condition fix: depend on the fetch steps from the COMPILE
    // step. See the `test_step` comment for the full rationale.
    windows_exe.step.dependOn(fetch_vendor_curl_step);
    windows_exe.step.dependOn(vendor_sqlite3_step);
    const install_windows = b.addInstallArtifact(windows_exe, .{});
    windows_step.dependOn(&install_windows.step);

    // Native-only macos step: only enabled when the build host IS macos.
    // A Linux/Windows host running `zig build install:macos-arm` does
    // cross-compile — the system-deps probe (in root build.zig AND in
    // each package) returns use_system=false for cross-compile (because
    // /usr/lib/libcurl.so can't link into a Mach-O binary), and the
    // fetch-vendor-curl step is wired in to build the cross-target
    // libcurl.a archive. On a Mac runner, the probe returns
    // use_system=true (brew keg-only libcurl is present), so
    // fetch-vendor-curl is skipped.
    //
    // We use a runtime gate (`b.graph.host.result.os.tag == .macos`) to
    // decide which behavior to take at config time. On a Linux host,
    // `install:macos-arm` proceeds with cross-compile (existing path).
    // On a Mac host, the same step proceeds with native macOS build.
    const is_native_macos = b.graph.host.result.os.tag == .macos;

    const macos_step = b.step("install:macos", "Build for macOS x86_64");
    const macos_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
    });
    const macos_exe = createPlatformExe(b, mod, macos_target, optimize, "nalarcore-macos-x86_64");
    // libcurl is linked via custom_http_client_mod's transitive deps.
    macos_exe.root_module.link_libc = true;
    macos_step.dependOn(fetch_vendor_curl_step);
    macos_step.dependOn(vendor_sqlite3_step);
    // Race-condition fix: depend on the fetch steps from the COMPILE
    // step. See the `test_step` comment for the full rationale.
    macos_exe.step.dependOn(fetch_vendor_curl_step);
    macos_exe.step.dependOn(vendor_sqlite3_step);
    // When the host is macOS, the system-deps probe already short-
    // circuited fetch_vendor_curl_step to a no-op. When the host is
    // Linux/Windows (cross-compile), the probe returned use_system=false
    // AND the package's vendored-archive path was selected — so we
    // ALSO need the fetch to actually run. The `dependOn` above
    // covers both.
    const install_macos = b.addInstallArtifact(macos_exe, .{});
    macos_step.dependOn(&install_macos.step);

    const macos_arm_step = b.step("install:macos-arm", "Build for macOS aarch64 (Apple Silicon)");
    const macos_arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    const macos_arm_exe = createPlatformExe(b, mod, macos_arm_target, optimize, "nalarcore-macos-aarch64");
    // libcurl is linked via custom_http_client_mod's transitive deps.
    macos_arm_exe.root_module.link_libc = true;
    macos_arm_step.dependOn(fetch_vendor_curl_step);
    macos_arm_step.dependOn(vendor_sqlite3_step);
    // Race-condition fix: depend on the fetch steps from the COMPILE
    // step. See the `test_step` comment for the full rationale.
    macos_arm_exe.step.dependOn(fetch_vendor_curl_step);
    macos_arm_exe.step.dependOn(vendor_sqlite3_step);
    const install_macos_arm = b.addInstallArtifact(macos_arm_exe, .{});
    macos_arm_step.dependOn(&install_macos_arm.step);
    _ = is_native_macos;

    const linux_system_step = b.step("install:linux:system", "Build for Linux x86_64 and install to system");
    const linux_system_exe = createPlatformExe(b, mod, target, optimize, "nalar");
    linux_system_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_system_exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    // libcurl is linked via custom_http_client_mod's transitive deps.
    linux_system_exe.root_module.link_libc = true;
    linux_system_step.dependOn(fetch_vendor_curl_step);
    linux_system_step.dependOn(vendor_sqlite3_step);
    // Race-condition fix: depend on the fetch steps from the COMPILE
    // step. See the `test_step` comment for the full rationale.
    linux_system_exe.step.dependOn(fetch_vendor_curl_step);
    linux_system_exe.step.dependOn(vendor_sqlite3_step);
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
    // libcurl is linked via custom_http_client_mod's transitive deps.
    dev_exe.root_module.link_libc = true;
    dev_linux_system_step.dependOn(fetch_vendor_curl_step);
    // Race-condition fix: depend on the fetch steps from the COMPILE
    // step. See the `test_step` comment for the full rationale.
    dev_exe.step.dependOn(fetch_vendor_curl_step);
    dev_exe.step.dependOn(vendor_sqlite3_step);
    linkPlatformDeps(b, dev_exe, target);
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
    // Host-aware binary name (replaces the previous hardcoded
    // `nalarcore-linux-x86_64`). `zig build` on a macOS host should
    // produce `nalarcore-macos-aarch64` (or `...-x86_64` for Intel),
    // on a Windows host should produce `nalarcore-windows-x86_64.exe`,
    // etc. Cross-compile artifacts remain available via explicit
    // `zig build install:<target>` (linux / macos / macos-arm / windows).
    const host_binary_name = switch (b.graph.host.result.os.tag) {
        .linux => "nalarcore-linux-x86_64",
        .macos => if (b.graph.host.result.cpu.arch == .aarch64)
            "nalarcore-macos-aarch64"
        else
            "nalarcore-macos-x86_64",
        .windows => "nalarcore-windows-x86_64.exe",
        else => "nalarcore-unknown",
    };
    const desktop_binary_name = switch (b.graph.host.result.os.tag) {
        .windows => "nalar-desktop.exe",
        else => "nalar-desktop",
    };
    const cli_binary_name = switch (b.graph.host.result.os.tag) {
        .windows => "nalarcli.exe",
        else => "nalarcli",
    };

    // Build the banner script with host-specific binary names spliced in
    // via std.fmt.allocPrint. The script is a heredoc body; binary names
    // come from the const declarations above. On exotic hosts
    // (`host_binary_name` = "nalarcore-unknown") the banner still prints
    // correctly — the user just sees the placeholder name.
    //
    // Note: std.fmt.comptimePrint would be cleaner, but `b.graph.host`
    // values aren't comptime-known in build.zig context, so we have to
    // use the runtime allocPrint + b.allocator. The script slice is
    // leaked (b.allocator is the build-graph arena; everything is freed
    // when the build runner exits).
    const banner_script = std.fmt.allocPrint(
        b.allocator,
        \\
        \\D=zig-out/bin
        \\echo ""
        \\echo "[zig build success]"
        \\echo ""
        \\echo "  nalar service binary  →  $D/{s}"
        \\echo "  nalar desktop binary  →  $D/{s}"
        \\echo "  nalarcli binary       →  $D/{s}"
        \\echo ""
        \\echo '  (If a binary is missing, run "rm -rf $D && zig build"'
        \\echo "   to force a fresh install — the cache sometimes hides"
        \\echo "   manual deletions.)"
        \\echo ""
        \\echo "  Run with:  $D/{s} service start --port 8080"
        \\echo "             $D/{s} --devtools"
        \\echo "             $D/{s} sessions list"
        \\echo ""
    ,
        .{
            host_binary_name,
            desktop_binary_name,
            cli_binary_name,
            host_binary_name,
            desktop_binary_name,
            cli_binary_name,
        },
    ) catch @panic("OOM allocating build banner");

    const build_banner = b.addSystemCommand(&.{ "/bin/sh", "-c", banner_script });
    const build_all_step = b.step("build:all", "Build nalar service + nalar-desktop, with end-of-build summary");
    // The binaries live on different top-level install steps:
    //   - host-specific nalarcore binary → install:<host> (Linux / macOS-arm / macOS / Windows)
    //   - nalar-desktop                   → install (native target, includes
    //                                                  b.installArtifact(desktop_exe))
    //   - nalarcli                        → cli_install (manual addInstallArtifact;
    //                                                  see note above `cli_install`
    //                                                  for why we don't use the
    //                                                  default `install` step)
    //
    // `zig build` (the default) picks the install step matching the HOST
    // — so a macOS host gets `nalarcore-macos-aarch64`, a Linux host gets
    // `nalarcore-linux-x86_64`, a Windows host gets
    // `nalarcore-windows-x86_64.exe`. Cross-compile to other targets is
    // still available via explicit `zig build install:<target>`.
    //
    // The native `nalar` binary is also in `install`. We want all in
    // one command, so depend on the inner install steps (not just the
    // outer top-level wrappers). Depending on the outer wrappers would
    // race against cache-hit skipping: when the binary's source hasn't
    // changed, InstallArtifact.make() returns early without copying the
    // file — so my banner would see a stale (possibly deleted) bin/ and
    // print missing-file lines.
    //
    // `dependOn` takes `*Step` not `*const *Step` — each `install_*` is
    // an `*InstallArtifact` whose `.step` field is what `dependOn` needs.
    const host_install_step = switch (b.graph.host.result.os.tag) {
        .linux => &install_linux.step,
        .macos => if (b.graph.host.result.cpu.arch == .aarch64)
            &install_macos_arm.step
        else
            &install_macos.step,
        .windows => &install_windows.step,
        else => &install_linux.step, // safest default for exotic hosts
    };
    build_all_step.dependOn(host_install_step);
    build_all_step.dependOn(&desktop_install.step);
    build_all_step.dependOn(&cli_install.step);
    build_all_step.dependOn(&build_banner.step);
    // Make `zig build` (default) auto-fetch the vendored curl archive
    // when missing. The fetch script is idempotent — re-running on a
    // populated vendor/ is a fast no-op.
    build_all_step.dependOn(fetch_vendor_curl_step);

    // Default: same as `build:all`. Without this, `zig build` (no args)
    // runs the `install` step alone, which prints no summary on success.
    // Zig 0.16's `Build.default_step: *Step` — `b.step()` already
    // returns `*Step`, so we assign the pointer directly.
    b.default_step = build_all_step;
}
