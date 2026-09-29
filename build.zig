const std = @import("std");
const builtin = @import("builtin");

// Win32 GetFileAttributesW — declared locally because std.os.windows
// 0.16 doesn't expose it (std.os.windows.kernel32 only ships the
// functions the std lib's own files need). Win32 kernel32.lib exports
// it natively, so a single `extern` decl is enough — no libc linkage,
// no `link_libc = true` on the build runner.
extern "kernel32" fn GetFileAttributesW(lpPathName: [*:0]const u16) callconv(.winapi) u32;
// NTSTATUS-like sentinel: when the path is missing/inaccessible,
// GetFileAttributesW returns `INVALID_FILE_ATTRIBUTES` (0xFFFFFFFF).
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
// File-sys flag bit (0x10 = bit 4) indicating the path is a directory,
// not a regular file. Probe mirrors `test -f <path>` semantics, so
// directories count as NOT-a-file.
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x00000010;

/// Cross-platform, pure-Zig "does this file exist" check.
///
/// Used by the system-deps probe (`dbs_uses_system`, `curl_uses_system`)
/// below. Earlier revisions ran `sh -c "test -f ..."` here, which is
/// unreliable on Windows dev boxes: Git for Windows ships git.exe +
/// bash.exe but doesn't add `C:\Program Files\Git\bin` or
/// `C:\Program Files\Git\usr\bin` to PATH automatically, so the probe
/// silently fell through to "vendor fallback" even when vcpkg had the
/// libraries installed. The pure-Zig version works on every host
/// regardless of which shells (if any) are on PATH.
///
/// Implementation: host-OS-specific direct syscalls, not `std.c`,
/// because build.zig itself doesn't link libc by default (Zig 0.16
/// requires an explicit `link_libc = true` on the build runner's
/// module for `std.c` to resolve `fopen` etc.).
///
///   - Linux:    `faccessat(AT_FDCWD, path, mode=0)` — direct POSIX
///              syscall via `std.os.linux.faccessat`. Matches the
///              inline node_modules probe used by the pnpm install
///              gate in the webapp chain (same host syscall). Linux
///              is the dev/CI primary; we don't pay a shell-out
///              cost here.
///   - macOS:    POSIX `faccessat` via `std.process.run` + `/bin/sh`
///              shelling out to `test -f`. The `std.os.linux.*`
///              wrappers are kernel-syscall-only — `.faccessat`'s
///              Linux syscall number is meaningless on Darwin's BSD
///              layer — so we shell-out instead. Darwin always has
///              `/bin/sh` on PATH (POSIX-required), so this is safe.
///   - Windows:  `GetFileAttributesW` returns INVALID_FILE_ATTRIBUTES
///              on missing; existence = attrs != invalid AND attrs
///              doesn't have the DIRECTORY bit set (mirror `test -f`).
fn fileExists(absolute_path: []const u8) bool {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (absolute_path.len >= buf.len) return false;
    @memcpy(buf[0..absolute_path.len], absolute_path);
    buf[absolute_path.len] = 0;
    return switch (builtin.os.tag) {
        .linux => blk: {
            const rc = std.os.linux.faccessat(std.os.linux.AT.FDCWD, &buf, 0, 0);
            break :blk rc == 0;
        },
        // macOS: libc `access()` — same F_OK check as `test -f`.
        // (The build runner links libc, so the extern is always
        // resolvable; no shell-out needed. Zig 0.16 removed
        // std.posix.access / made it Io-based, and the old shell-out
        // used std.heap.GeneralPurposeAllocator + a pre-0.16
        // std.process.run signature that no longer compile.)
        .macos => blk: {
            const rc = std.c.access(&buf, 0); // F_OK = 0
            break :blk rc == 0;
        },
        .windows => blk: {
            // WTF-8 (Zig's UTF-8 with surrogate-half support) → WTF-16
            // little-endian (Win32's wide-char path) for the Win32 API
            // call. `wtf8ToWtf16Le` writes the wide path into the
            // saturated caller-provided buffer and RETURNS the count
            // of u16 units written (`usize`), not a slice. We append
            // a NUL because the Win32 API takes NUL-terminated wide
            // strings.
            var wide: [std.fs.max_path_bytes]u16 = undefined;
            const written = std.unicode.wtf8ToWtf16Le(&wide, absolute_path) catch break :blk false;
            if (written >= wide.len) break :blk false;
            wide[written] = 0;
            const attrs = GetFileAttributesW(@ptrCast(&wide));
            if (attrs == INVALID_FILE_ATTRIBUTES) break :blk false;
            if ((attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

/// Return the first entry of `candidates` that exists as a file, or null
/// when none match. Used by the system-deps probe to handle Homebrew
/// keg-only paths (`/opt/homebrew/opt/<name>/...`) AND fallback
/// `/usr/include/...` paths in either order.
fn pickFirstExisting(candidates: []const []const u8) ?[]const u8 {
    for (candidates) |p| {
        if (fileExists(p)) return p;
    }
    return null;
}

/// Locate MSVC's C++ standard-library headers (used by nalar-desktop's
/// nalar_webview.cpp on Windows). The headers ship with Visual Studio's
/// Build Tools — specifically the `INCLUDE` env var that `vcvars64.bat`
/// sets (e.g. `C:\Program Files (x86)\Microsoft Visual Studio\2022\
/// BuildTools\VC\Tools\MSVC\14.x\include`). Without them, the .cpp shim's
/// `#include <wrl/client.h>` fails with "cstddef file not found" because
/// WRL's first include is `<cstddef>` (a C++ stdlib header, not a C
/// header). On dev boxes that haven't installed MSVC Build Tools, the
/// .cpp can't compile — return `null` so we can gate the .cpp build on
/// "do you have a C++ toolchain?".
///
/// We check the env var first (vcvars64.bat sets it), then fall back to
/// probing the canonical MSVC install location. Returns `true` if any
/// `cstddef` candidate resolves to an existing file.
fn hasMsvcCppStllib(b: *std.Build, io: std.Io) bool {
    if (b.graph.host.result.os.tag != .windows) return false;

    // vcvars64.bat sets these. `INCLUDE` is the primary env var that
    // lists C/C++ system header search paths.
    if (b.graph.environ_map.get("INCLUDE")) |inc| {
        // Quick check: does the INCLUDE list mention the MSVC `include/`
        // directory? Even a partial match (any path under `VC\Tools\MSVC`)
        // is good enough — we don't need to verify cstddef specifically.
        if (std.mem.indexOf(u8, inc, "MSVC") != null) return true;
    }

    // Fallback: probe the canonical install path. This catches CI runners
    // that sourced vcvars64.bat into a different env (some workflows
    // import just INCLUDE; others also set VCToolsInstallDir).
    const candidates = [_][]const u8{
        "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC",
        "C:/Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC",
        "C:/Program Files (x86)/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC",
        "C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC",
    };
    for (candidates) |root| {
        // Any subdir under `MSVC/` (e.g. `14.44.35207/`) means MSVC is
        // installed. Don't recurse — just check if the MSVC root dir
        // contains at least one subdir.
        //
        // `OpenOptions.iterate` MUST be true here: iterating a handle
        // opened without it fails with `error.AccessDenied` on Windows
        // (verified live — `openDir` succeeds, first `it.next` fails),
        // which the `else |_| {}` below would swallow as "not installed"
        // and silently force the webview-stub fallback.
        const d = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        // `it.next` returns `Error!?Entry` (error union of optional).
        // Return true if the read succeeded AND there's an entry. Any
        // other outcome (error or end-of-stream) means "not installed".
        if (it.next(io)) |maybe_entry| {
            if (maybe_entry) |_| return true;
        } else |_| {} // readdir error — assume not installed
    }
    return false;
}

/// Locate the MSVC include dirs needed by `zig cc` when compiling
/// `platform/windows/nalar_webview.cpp`. The .cpp includes `<wrl.h>`,
/// which transitively pulls in `<cstddef>` from the MSVC C++ stdlib;
/// without `-isystem` flags pointing at the right places, `zig cc`
/// fails with `fatal error: 'cstddef' file not found`.
///
/// Resolution order (matches `hasMsvcCppStllib`):
///   1. `$VCToolsInstallDir` (set by `vcvars64.bat`) — most reliable
///      on CI runners that sourced vcvars.
///   2. The first canonical install path under `Microsoft Visual
///      Studio/2022/{BuildTools,Community}/VC/Tools/MSVC/<version>/`
///      — fallback for runners that only set INCLUDE (without
///      VCToolsInstallDir).
///
/// Returns the `include/` subdir plus the Windows SDK include roots
/// (`ucrt`, `um`, `shared`, `winrt`). On non-Windows hosts the helper
/// returns empty strings — but `zig cc` is only invoked when
/// `target.result.os.tag == .windows`, so the caller is responsible
/// for that gate.
const MsvcIncludePaths = struct {
    c_stddef: []const u8,
    msvc_include: []const u8,
    ucrt_include: []const u8,
    um_include: []const u8,
    shared_include: []const u8,
    winrt_include: []const u8,
};

fn findMsvcInclude(b: *std.Build) MsvcIncludePaths {
    // Empty defaults — used if everything below fails so the caller
    // still has well-typed string handles (even if empty).
    const empty = &[_]u8{};
    var result = MsvcIncludePaths{
        .c_stddef = empty,
        .msvc_include = empty,
        .ucrt_include = empty,
        .um_include = empty,
        .shared_include = empty,
        .winrt_include = empty,
    };
    if (b.graph.host.result.os.tag != .windows) return result;

    // Find the MSVC root (the dir under `.../VC/Tools/MSVC/<version>/`).
    // 1. Prefer `VCToolsInstallDir` env var (e.g.
    //    `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207`).
    const vc_root: []const u8 = if (b.graph.environ_map.get("VCToolsInstallDir")) |p|
        p
    else
        // 2. Fallback: enumerate the canonical install locations and pick
        // the first one with a `<ver>/include/` subdir. The version
        // directory name is opaque (e.g. `14.44.35207`), so we don't
        // hard-code it.
        firstMsvcRoot(b) orelse &[_]u8{};

    if (vc_root.len == 0) {
        // No MSVC STL root resolved (e.g. standalone Windows SDK
        // install without VS). The Windows SDK dirs are independent of
        // VS — still resolve them instead of bailing with six empties.
        fillWindowsSdkIncludes(b, &result);
        return result;
    }
    result.c_stddef = b.fmt("{s}/include", .{vc_root});        // MSVC C++ stdlib (cstddef, etc.)
    result.msvc_include = result.c_stddef;
    fillWindowsSdkIncludes(b, &result);
    return result;
}

/// Populate the four Windows SDK include subdirs in `result` (`ucrt`,
/// `um`, `shared`, `winrt`). Resolution order:
///   1. `$INCLUDE` entries (set by vcvars64.bat / VS dev shells) whose
///      last path component is exactly one of the four leaf dirs.
///   2. Canonical `Windows Kits/10/include/<version>/<leaf>` probe.
///
/// Fields that resolve to nothing stay empty — the caller must skip
/// `-isystem` for empty values (a bare `-isystem ""` is at best a
/// confusing no-op; it previously leaked into the CI compile line as
/// `-isystem -isystem -isystem -isystem`).
fn fillWindowsSdkIncludes(b: *std.Build, result: *MsvcIncludePaths) void {
    if (b.graph.environ_map.get("INCLUDE")) |inc| {
        var it = std.mem.splitScalar(u8, inc, ';');
        while (it.next()) |entry_raw| {
            const entry = std.mem.trim(u8, entry_raw, " \t\"");
            if (entry.len == 0) continue;
            const leaf = std.fs.path.basename(entry);
            if (std.mem.eql(u8, leaf, "ucrt") and result.ucrt_include.len == 0) {
                result.ucrt_include = entry;
            } else if (std.mem.eql(u8, leaf, "um") and result.um_include.len == 0) {
                result.um_include = entry;
            } else if (std.mem.eql(u8, leaf, "shared") and result.shared_include.len == 0) {
                result.shared_include = entry;
            } else if (std.mem.eql(u8, leaf, "winrt") and result.winrt_include.len == 0) {
                // Exact basename match — "cppwinrt" deliberately does NOT land here.
                result.winrt_include = entry;
            }
        }
    }

    const kit_roots = [_][]const u8{
        "C:/Program Files (x86)/Windows Kits/10/include",
        "C:/Program Files/Windows Kits/10/include",
    };
    const leaves = [_]struct { leaf: []const u8, field: *[]const u8 }{
        .{ .leaf = "ucrt", .field = &result.ucrt_include },
        .{ .leaf = "um", .field = &result.um_include },
        .{ .leaf = "shared", .field = &result.shared_include },
        .{ .leaf = "winrt", .field = &result.winrt_include },
    };
    for (kit_roots) |root| {
        const ver_root = firstSubdir(b, root) orelse continue;
        for (leaves) |l| {
            if (l.field.*.len != 0) continue;
            const candidate = b.fmt("{s}/{s}", .{ ver_root, l.leaf });
            if (dirExists(b, candidate)) l.field.* = candidate;
        }
    }
}

/// Stage a pruned copy of MSVC's `msvcrt.lib` into the NuGet staging
/// dir: satisfies `/DEFAULTLIB:MSVCRT` (emitted by msvcprt.lib members)
/// without the CFG/TLS startup members that collide with mingw's
/// (`duplicate symbol` on `__guard_*_icall_fptr` et al). Always
/// re-copies fresh first (8 MB, milliseconds) so `ar d` below applies
/// to a known-good baseline. IO failures return silently (best-effort:
/// the link then fails loudly on the missing lib); prune failure
/// fatals via `b.run` (a half-pruned CRT would mislink silently).
fn stagePrunedMsvcrt(b: *std.Build, msvc_lib_root: []const u8, stage_dir: []const u8) void {
    const src_path = b.fmt("{s}/msvcrt.lib", .{msvc_lib_root});
    const dst_path = b.fmt("{s}/msvcrt.lib", .{stage_dir});
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, src_path, b.allocator, .unlimited) catch return;
    defer b.allocator.free(bytes);
    std.Io.Dir.cwd().writeFile(b.graph.io, .{ .sub_path = dst_path, .data = bytes }) catch return;
    // Prune list is evidence-driven: guard_support.obj (proven dup —
    // lld names it against mingw's mingw_cfguard_support.obj) + the
    // TLS-init family (dup set from the full-lib link). The
    // CFG-dispatch members (guard_dispatch, guard_xfg_dispatch,
    // cfg_fo) STAY: they define no mingw-colliding storage, and the
    // XFG/dummy symbols they provide are referenced by msvcprt
    // members with no other provider (else `undefined symbol`).
    const prune_members = [_][]const u8{
        "guard_support.obj",
        "dyn_tls_init.obj",     "dyn_tls_dtor.obj",
        "tlsdtor.obj",          "tlsdyn.obj",
        "tlssup.obj",
    };
    var ar_argv: [4 + prune_members.len][]const u8 = undefined;
    ar_argv[0] = b.graph.zig_exe;
    ar_argv[1] = "ar";
    ar_argv[2] = "d";
    ar_argv[3] = dst_path;
    for (prune_members, 0..) |m, i| ar_argv[4 + i] = m;
    _ = b.run(ar_argv[0 .. 4 + prune_members.len]);
}

/// True when `dst` is missing or its size differs from `src` (used
/// for the config-time MSVC runtime-lib staging copy). Size-only
/// comparison: cheap, no hashing, and exact for these
/// never-edited-in-place import libs.
fn staleOrMissing(b: *std.Build, src_path: []const u8, dst_path: []const u8) bool {    const src_stat = std.Io.Dir.cwd().statFile(b.graph.io, src_path, .{}) catch return true;
    const dst_stat = std.Io.Dir.cwd().statFile(b.graph.io, dst_path, .{}) catch return true;
    return src_stat.size != dst_stat.size;
}

/// Return true when `abs_path` exists and is a directory. Mirrors the
/// openDir probe pattern used by `hasMsvcCppStllib` (fileExists only
/// matches files — it explicitly rejects FILE_ATTRIBUTE_DIRECTORY).
fn dirExists(b: *std.Build, abs_path: []const u8) bool {
    const d = std.Io.Dir.cwd().openDir(b.graph.io, abs_path, .{}) catch return false;
    d.close(b.graph.io);
    return true;
}

/// Resolve the MSVC toolset version root (`.../VC/Tools/MSVC/<ver>`)
/// for the `-include` compat header below. Prefers `$VCToolsInstallDir`
/// (CI sets it), else the first enumerated install (same fallback as
/// `findMsvcInclude`). Returns null when nothing resolves.
fn msvcVersionRoot(b: *std.Build) ?[]const u8 {
    if (b.graph.host.result.os.tag != .windows) return null;
    if (b.graph.environ_map.get("VCToolsInstallDir")) |p| {
        if (dirExists(b, p)) return p;
    }
    return firstMsvcRoot(b);
}

/// Walk the canonical VS install locations and return the first
/// `<root>/VC/Tools/MSVC/<ver>` dir we find. Returns null on miss.
/// Non-Windows always returns null.
fn firstMsvcRoot(b: *std.Build) ?[]const u8 {
    if (b.graph.host.result.os.tag != .windows) return null;
    const roots = [_][]const u8{
        "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC",
        "C:/Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC",
        "C:/Program Files (x86)/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC",
        "C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC",
    };
    for (roots) |msvc_root| {
        // Open the MSVC root and pick the first subdir (the version
        // dir like `14.44.35207`). Without that subdir, MSVC isn't
        // installed at this root. `OpenOptions.iterate` is required —
        // without it the first `it.next` fails with AccessDenied on
        // Windows (see hasMsvcCppStllib).
        const d = std.Io.Dir.openDirAbsolute(b.graph.io, msvc_root, .{ .iterate = true }) catch continue;
        defer d.close(b.graph.io);
        var it = d.iterate();
        while (it.next(b.graph.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            return b.fmt("{s}/{s}", .{ msvc_root, entry.name });
        }
    }
    return null;
}

/// Numeric dotted-version compare: true when `a` is a HIGHER version than
/// `b`.
///
/// String ordering is wrong for these directory names: `"10.0.10240.0" <
/// "10.0.26100.0"` lexicographically, so a `lessThan` on the raw name picks
/// the OLDER SDK. Components are compared as integers, left to right; a
/// missing component counts as 0 (so `10.0.26100` == `10.0.26100.0`).
fn versionGreater(a: []const u8, b: []const u8) bool {
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const an = ai.next();
        const bn = bi.next();
        if (an == null and bn == null) return false;
        const av = if (an) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        const bv = if (bn) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        if (av != bv) return av > bv;
    }
}

/// Return `<root>/<highest-versioned subdirectory that actually contains
/// every name in `required_files`, or null when none does.
///
/// Do NOT use `firstSubdir` for the Windows SDK. `Windows Kits/10/Lib` on
/// the windows-2022 image holds several decoy version directories next to
/// the real one, and `Dir.iterate` order is undefined, so `firstSubdir`
/// hands back whichever wins the race:
///   * `10.0.10240.0`  — no `um/x64` at all
///   * `wdf0.26100.0`  — has an `um/x64`, but it is EMPTY (WDF stub)
/// Either one costs the link uuid / shlwapi / version, which is exactly
/// what `-luuid -lshlwapi -lversion` below need:
///   warning: unable to open library directory
///     '...\Lib\10.0.10240.0\um\x64': FileNotFound
///   error: lld-link: could not open 'libuuid.a': No such file or directory
///
/// Hence the probe checks the real `.lib` FILES, not just the directory.
fn newestSubdirWith(b: *std.Build, root: []const u8, required_files: []const []const u8) ?[]const u8 {
    if (b.graph.host.result.os.tag != .windows) return null;
    const d = std.Io.Dir.openDirAbsolute(b.graph.io, root, .{ .iterate = true }) catch return null;
    defer d.close(b.graph.io);
    var best_name: ?[]const u8 = null;
    var it = d.iterate();
    while (it.next(b.graph.io) catch null) |entry| {
        // `.sym_link` counts: the real SDK leaves ship as links (the image
        // has `wdf0.26100.0` alongside a plain `wdf`), and a dangling one
        // is rejected by the file probe below anyway.
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        const candidate = b.fmt("{s}/{s}", .{ root, entry.name });
        var complete = true;
        for (required_files) |f| {
            if (!fileExists(b.fmt("{s}/{s}", .{ candidate, f }))) {
                complete = false;
                break;
            }
        }
        if (!complete) continue;
        if (best_name == null or versionGreater(entry.name, best_name.?)) {
            // MUST dupe: `entry.name` points into the iterator's name buffer,
            // which the next `it.next()` overwrites. Storing the slice made
            // `best_name` a dangling view that later read as a FRANKENSTEIN
            // name ("wdf0.26100.0" — the next entry's bytes over the tail of
            // "10.0.26100.0"), so the resolver returned a path to a
            // directory that does not exist.
            best_name = b.dupe(entry.name);
        }
    }
    return if (best_name) |n| b.fmt("{s}/{s}", .{ root, n }) else null;
}

/// Return `<root>/<first-subdirectory>`, or null when `root` doesn't
/// exist or contains no subdirectories. Used to resolve opaque version
/// directories (`14.44.35207`, `10.0.22621.0`) without hard-coding them.
fn firstSubdir(b: *std.Build, root: []const u8) ?[]const u8 {
    if (b.graph.host.result.os.tag != .windows) return null;
    // `OpenOptions.iterate` is required — without it `it.next` fails
    // with AccessDenied on Windows (see hasMsvcCppStllib).
    const d = std.Io.Dir.openDirAbsolute(b.graph.io, root, .{ .iterate = true }) catch return null;
    defer d.close(b.graph.io);
    var it = d.iterate();
    while (it.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        return b.fmt("{s}/{s}", .{ root, entry.name });
    }
    return null;
}

/// Find the system libstdc++ include directory on Linux. Different
/// distros (Arch: gcc 16, Ubuntu 22.04: gcc 12, Ubuntu 24.04: gcc 13,
/// Fedora 41: gcc 14) install libstdc++ headers under
/// `/usr/include/c++/<version>` — the version varies.
///
/// Why we need this: zig c++ bundles its own libc++ which on Arch
/// lacks `__config_site`, and on CI runners collides with glibc's
/// `<math.h>`/`<cwchar.h>` typedefs (`wint_t`, `FP_NAN`, `errno`).
/// Pointing at the system libstdc++ headers avoids both.
///
/// Resolution order (first hit wins):
///   1. $NALAR_LIBSTDCXX_INCLUDE env var (escape hatch for any distro
///      whose path doesn't match the defaults — just set it to
///      `/usr/include/c++/<X`>`).
///   2. Hardcoded distro defaults probed in order: 16, 15, 14, 13, 12,
///      11, 10. First one that exists wins. (This skips zig 0.16's
///      std.Io.Dir API which has been observed to crash with `BADF`
///      at build-configure time — the iteration works fine in user
///      code, but the configure-time path triggers a kernel fd close
///      race that's been a recurring zig 0.16 issue.)
///   3. null → caller falls back to the bundled libc++ + a warning.
fn findLibstdcxxInclude(b: *std.Build) ?[]const u8 {
    if (b.graph.host.result.os.tag != .linux) return null;

    // Run a small shell snippet via b.run() to find the highest-version
    // gcc c++ include dir. b.run() is std.Build's synchronous
    // configure-time exec helper — it returns stdout bytes and
    // fails the build with a clear message on error. We use
    // `sort -V` (version-aware) so e.g. `10` sorts after `9`.
    //
    // Why we use the shell instead of std.fs / std.Io.Dir:
    //   - std.fs.cwd() and std.fs.openDirAbsolute() don't exist in
    //     zig 0.16 (the legacy std.fs API was removed).
    //   - std.Io.Dir.openDirAbsolute() + iterate() exists but crashes
    //     with `BADF` at build-configure time when called from
    //     build.zig (the iterator's close-on-exhaust races with the
    //     configure-time cleanup). Both findMsvcInclude / firstSubdir
    //     in this file have the same latent bug — they just never get
    //     exercised on hosts where the MSVC dir is absent.
    //   - A shellout is bulletproof and adds ~10ms to the configure
    //     step (acceptable for a one-shot discovery).
    //
    // The shell snippet:
    //   ls -1 /usr/include/c++ 2>/dev/null   — list installed c++ dirs
    //     | sort -V                            — version-aware sort
    //     | tail -1                            — pick highest
    //     | tr -d '\n'                         — strip trailing newline
    //                                                (b.run returns the
    //                                                stdout bytes
    //                                                verbatim).
    const stdout = b.run(&.{
        "/bin/sh", "-c",
        \\ls -1 /usr/include/c++ 2>/dev/null | sort -V | tail -1 | tr -d '\n'
    });
    if (stdout.len == 0) return null;
    return b.allocator.dupe(u8, stdout) catch null;
}

/// Check that ALL WebView2 NuGet prerequisites sit next to
/// nalar_webview.cpp. Returns null when complete; otherwise a
/// human-readable name of the first missing file (for the
/// stub-fallback warning).
///
/// Why EventToken.h is checked explicitly: Microsoft's WebView2.h does
/// `#include "EventToken.h"` from its own directory, so a partial NuGet
/// extraction that copies WebView2.h alone compiles fine right up until
/// clang dies deep inside Microsoft's header with
/// `fatal error: 'EventToken.h' file not found`
/// (seen on the self-hosted Windows CI runner, 2026-08-22).
fn webview2MissingPrereq(b: *std.Build) ?[]const u8 {
    const prereqs = [_][]const u8{
        "WebView2.h",
        "EventToken.h",
        "WebView2Loader.h",
        "WebView2Loader.lib",
        // Runtime DLL (NuGet-staged). Without it the link succeeds (import
        // lib only records the dependency) but the exe dies at load time
        // and the CI zip ships broken. Requiring it here forces the
        // stub-fallback warning to name the DLL explicitly instead of
        // silently building a no-webview exe.
        "WebView2Loader.dll",
    };
    for (prereqs) |name| {
        const full = b.fmt("src/apps/desktop_app/platform/windows/{s}", .{name});
        if (!fileExists(full)) return name;
    }
    return null;
}

/// Vendored Lua 5.4 sources compiled into a module.
///
/// Hooks embed Lua on EVERY target (Linux/macOS/Windows) with no system
/// dependency: `vendor/lua/` carries the upstream library C files
/// (see vendor/lua/README.vendor). Compiled per-target by Zig's bundled
/// C compiler, so cross-compiles Just Work. Excludes lua.c/luac.c
/// (standalone mains). No platform `-D` defines: the core language +
/// the stdlib subset hooks need is define-free (dynamic C-module loading
/// via require() is unavailable — hooks are plain scripts).
fn linkVendoredLua(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFiles(.{
        .root = b.path("vendor/lua"),
        .files = &.{
            "lapi.c",     "lauxlib.c", "lbaselib.c", "lcode.c",
            "lcorolib.c", "lctype.c",  "ldblib.c",   "ldebug.c",
            "ldo.c",      "ldump.c",   "lfunc.c",    "lgc.c",
            "linit.c",    "liolib.c",  "llex.c",     "lmathlib.c",
            "lmem.c",     "loadlib.c", "lobject.c",  "lopcodes.c",
            "loslib.c",   "lparser.c", "lstate.c",   "lstring.c",
            "lstrlib.c",  "ltable.c",  "ltablib.c",  "ltm.c",
            "lundump.c",  "lutf8lib.c", "lvm.c",     "lzio.c",
        },
        .flags = &.{ "-std=c99", "-O2" },
    });
}

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
///   - macOS:     (nothing — curl is universal via kabelweb_mod)
///   - Windows:   bcrypt (for kabelweb repo src/server/security.zig)
///
/// What used to live here: per-platform sqlite3 amalgamation/archives
/// + brew paths. Those moved to the ruangsql package's build.zig
/// (github.com/ginwa123/ruangsql), which
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
            // along via kabelweb_mod).
        },
        .windows => {
            // Everything database-related (sqlite3 amalgamation + bcrypt)
            // is handled by the `databases` package. bcrypt.dll is needed
            // by kabelweb repo src/server/security.zig
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
    helpers_mod: *std.Build.Module,
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
            .imports = &.{
                .{ .name = "nalarcore", .module = mod },
                .{ .name = "helpers", .module = helpers_mod },
            },
        }),
    });
    linkPlatformDeps(b, exe, target);
    return exe;
}

/// Prepend `C:\vcpkg\installed\x64-windows\bin` to the test process's
/// PATH so the Windows DLL loader can find the runtime DLLs that the
/// test executable depends on (`libcurl.dll`, `sqlite3.dll`,
/// `libssl-3-x64.dll`, `libcrypto-3-x64.dll`, `libpq.dll`, …).
///
/// WHY: when the `databases` + `kabelweb` packages link the
/// system-installed copies of these libs (probed at config time),
/// they pull in the import `.lib` from `C:\vcpkg\installed\x64-windows\
/// lib\`, but the actual `.dll` implementations live one level up at
/// `C:\vcpkg\installed\x64-windows\bin\`. vcpkg's installer does NOT
/// add `bin\` to `%PATH%` — only `lib\` and `include\` are wired into
/// the MSVC env. So a freshly-built `test.exe` runs, the Windows
/// process loader walks its DLL search order, doesn't find
/// `libcurl.dll`, and the process aborts with
/// `STATUS_ENTRYPOINT_NOT_FOUND` (0xC0000139) before main() runs.
///
/// CI works around this in `.github/workflows/ci.yml` step
/// `Test + build (single zig invocation, Windows)` by literally
/// appending `C:\vcpkg\installed\x64-windows\bin;` to `$env:PATH`
/// before the `zig build test nalar-desktop` line (see the comment
/// block "vcpkg bin dir — libcurl.dll, libssl-3.dll, libcrypto-3.dll,
/// sqlite3.dll live here and the test binary needs them at runtime.").
/// Local dev boxes don't have that env setup, so without this fix the
/// same crash happens the moment you run `zig build test` outside CI.
///
/// We apply the PATH prepend here at build.zig config time, so the
/// fix is host-transparent: any dev box that has the vcpkg-installed
/// libs (which the `system-deps probe` already required to be present)
/// Just Works. Non-Windows targets are no-ops (`linkSystemLibrary`
/// on Linux/macOS resolves to the system's `.so` / `.dylib` directly,
/// which IS on the runtime search path).
///
/// Edge case: if vcpkg lives at a non-default path, `dirExists`
/// returns false and the function is a no-op (PATH is left alone).
/// Dev boxes with non-standard vcpkg layouts should add the bin dir
/// to their system PATH manually.
fn prependVcpkgBinToPath(b: *std.Build, run: *std.Build.Step.Run) void {
    if (b.graph.host.result.os.tag != .windows) return;
    const vcpkg_bin = "C:/vcpkg/installed/x64-windows/bin";
    // Only prepend if the dir actually exists — otherwise leave PATH
    // alone (so we don't accidentally shadow a real vcpkg on PATH with
    // a bogus one on a host that doesn't have vcpkg installed).
    if (!dirExists(b, vcpkg_bin)) return;
    const env_map = run.getEnvMap();
    const current = env_map.get("PATH") orelse "";
    // Windows convention: separate paths with `;`, prepend the new one.
    // If PATH is empty (rare), just use the new dir verbatim.
    const new_path = if (current.len == 0) vcpkg_bin else b.fmt("{s};{s}", .{ vcpkg_bin, current });
    env_map.put("PATH", new_path) catch @panic("OOM");
}

/// Bundle vcpkg runtime DLLs next to the exe so Explorer double-click works.
///
/// WHY: `databases` + `kabelweb` link the vcpkg IMPORT `.lib`
/// files (`sqlite3.lib`, `libcurl.lib`, `libssl.lib`, ...) on Windows.
/// At runtime the Windows loader must find the matching `.dll`
/// (`sqlite3.dll`, `libcurl.dll`, `libssl-3-x64.dll`, ...) via the
/// standard search order (exe dir first, then PATH). vcpkg does NOT add
/// `C:\vcpkg\installed\x64-windows\bin\` to the system PATH, and
/// prependVcpkgBinToPath only fixes zig build test processes -- not
/// a user double-clicking `zig-out/bin/nalar-desktop.exe` in Explorer
/// (clean env, no vcpkg on PATH) vs running from a dev `cmd` where the
/// user already exported vcpkg bin. Result: double-click dies with
/// "libcurl.dll / sqlite3.dll not found" while cmd works.
///
/// FIX: copy every vcpkg runtime DLL that our import libs can pull in
/// next to the exe at install time (same pattern as the existing
/// `WebView2Loader.dll` install). The loader checks the exe dir FIRST,
/// so a fresh `zig-out/bin/` Just Works from Explorer with no PATH
/// setup. Missing files are skipped (dev box without vcpkg = no-op).
/// Non-Windows hosts are no-ops.
fn installVcpkgDlls(b: *std.Build, parent: *std.Build.Step) void {
    if (b.graph.host.result.os.tag != .windows) return;
    const vcpkg_bin = "C:/vcpkg/installed/x64-windows/bin";
    if (!dirExists(b, vcpkg_bin)) return;
    const dlls = [_][]const u8{
        "libcurl.dll",
        "sqlite3.dll",
        "libssl-3-x64.dll",
        "libcrypto-3-x64.dll",
        "libpq.dll",
        "z.dll",
        "lz4.dll",
        "legacy.dll",
        "libecpg.dll",
        "libecpg_compat.dll",
        "libpgtypes.dll",
    };
    for (dlls) |dll| {
        const src = b.fmt("{s}/{s}", .{ vcpkg_bin, dll });
        if (!fileExists(src)) continue;
        const install = b.addInstallBinFile(.{ .cwd_relative = src }, dll);
        parent.dependOn(&install.step);
    }
}

/// Detect the Zig 0.16 aarch64-windows crash bug and abort the build
/// early with a clear, actionable message.
///
/// WHY: the native `zig-aarch64-windows-0.16.x` binary has a crash
/// bug in `zig build` / `zig run` (see AGENTS.md "Recent changes" —
/// the same issue documented in
/// docs/superpowers/plans/2026-08-20-fix-windows-build-zig.md §"Out
/// of scope"). When it crashes mid-write, it truncates the global ZIR
/// cache files at `%LOCALAPPDATA%\zig\z\…`, which then surfaces on
/// every subsequent build as:
///
///     warning(zcu): unexpected EOF reading cached ZIR for
///         ...zig-aarch64-windows-0.16.0\lib\std\fs\path.zig
///
/// (plus similar warnings for every other stdlib file it was parsing
/// at crash time). Clearing `%LOCALAPPDATA%\zig` only papers over the
/// symptom — the warning reappears as soon as the next crash happens.
///
/// The fix is the same one used on CI: use the
/// `zig-x86_64-windows-0.16.x` binary instead (same Zig version, no
/// crash bug, runs natively on ARM64 Windows via emulation).
/// `.github/workflows/ci.yml` uses `mlugg/setup-zig@v2` with the
/// x86_64-windows-gnu variant; most dev boxes already have it
/// installed alongside the WinGet one (WinGet's `zig.zig` package id
/// ships both arches; the x86_64 dir usually lands at
/// `C:\Users\<you>\zig_x64\zig-x86_64-windows-0.16.0\zig.exe` or
/// wherever you extracted it manually).
///
/// Detection: WinGet names the install dir `zig-aarch64-windows-0.16.0\`
/// (and the future `zig-aarch64-windows-0.17.0\` etc.). We match BOTH
/// `aarch64` (binary is the wrong arch) AND `0.16` (this specific bug
/// series) — so a hypothetical 0.17+ aarch64 fix doesn't false-positive,
/// and a custom-dir aarch64 install that doesn't follow the WinGet
/// naming convention is let through (the user clearly knows what
/// they're doing in that case).
///
/// Returns void. On match, prints an error to stderr and `exit(1)`s
/// the build runner before any work is done — so the global ZIR cache
/// is left untouched (no partial writes, no `unexpected EOF` next run).
fn detectAarch64ZigBug(b: *std.Build) void {
    if (b.graph.host.result.os.tag != .windows) return;
    const exe = b.graph.zig_exe;
    const is_aarch64 = std.mem.indexOf(u8, exe, "aarch64") != null;
    const is_0_16 = std.mem.indexOf(u8, exe, "0.16") != null;
    if (!(is_aarch64 and is_0_16)) return;
    std.log.err(
        "FATAL: Zig 0.16 aarch64-windows binary detected:\n" ++
            "    {s}\n" ++
            "\n" ++
            "  This binary has a known crash bug in `zig build` / `zig run`\n" ++
            "  (see AGENTS.md 'Recent changes'). When it crashes mid-write, it\n" ++
            "  truncates the global ZIR cache files under %LOCALAPPDATA%\\zig\\\n" ++
            "  z\\, which surfaces on every subsequent build as:\n" ++
            "\n" ++
            "      warning(zcu): unexpected EOF reading cached ZIR for\n" ++
            "          ...zig-aarch64-windows-0.16.0\\lib\\std\\fs\\path.zig\n" ++
            "\n" ++
            "  (and similar lines for every other stdlib file it was parsing\n" ++
            "  at crash time). Clearing %LOCALAPPDATA%\\zig only papers over the\n" ++
            "  symptom — the warning reappears as soon as the next crash.\n" ++
            "\n" ++
            "  FIX: use the x86_64-windows Zig 0.16 binary instead — same Zig\n" ++
            "  version, no crash bug, runs natively on ARM64 Windows via\n" ++
            "  emulation. CI uses exactly this setup (.github/workflows/ci.yml\n" ++
            "  uses mlugg/setup-zig@v2 with the x86_64-windows-gnu variant).\n" ++
            "\n" ++
            "  Most dev boxes already have the x86_64 binary installed\n" ++
            "  alongside the WinGet aarch64 one (WinGet's zig.zig package id\n" ++
            "  ships both arches). The x86_64 dir usually lands at:\n" ++
            "    C:\\Users\\<you>\\zig_x64\\zig-x86_64-windows-0.16.0\\\n" ++
            "  or wherever you extracted it manually.\n" ++
            "\n" ++
            "  Quick test:\n" ++
            "    C:\\Users\\<you>\\zig_x64\\zig-x86_64-windows-0.16.0\\zig.exe build --list-steps\n" ++
            "  should list steps without this error.\n" ++
            "\n" ++
            "  To make it permanent, move the x86_64 install dir ahead of\n" ++
            "  the WinGet shim dir (C:\\Users\\<you>\\AppData\\Local\\Microsoft\\\n" ++
            "  WinGet\\Links) in your PATH environment variable.",
        .{exe},
    );
    std.process.exit(1);
}

pub fn build(b: *std.Build) void {
    // Hard-fail at config time if the active Zig binary is the
    // known-bugged aarch64-windows 0.16.x variant. Without this, the
    // build starts, crashes mid-write, and leaves the global ZIR cache
    // truncated — every subsequent build then emits
    // `warning(zcu): unexpected EOF reading cached ZIR for ...path.zig`
    // until the cache is cleared (and the next crash re-truncates it).
    // Calling this BEFORE standardTargetOptions / probeSystemLibs /
    // addSystemCommand etc. means we never touch the cache when the
    // binary is wrong — the fix has a chance to take effect on the
    // next run.
    detectAarch64ZigBug(b);

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
        .windows => blk: {
            // === Why default to x86_64-windows-gnu on Windows ===
            //
            // The CI's self-hosted Windows runner installs all native deps
            // (libcurl, libssl, libcrypto, libpq, sqlite3) via
            //     vcpkg install --recurse ...:x64-windows
            // (see .github/workflows/ci.yml:560). vcpkg emits artefacts as
            // x64 — `libcurl.lib`/`libssl.lib`/etc. live at
            // `C:\vcpkg\installed\x64-windows\...`. The kabelweb
            // and databases packages wire those exact paths into the link
            // line.
            //
            // On ARM64 Windows (Snapdragon X dev machines) Zig's stock
            // host-following default would produce target = aarch64-windows-
            // gnu, which can't link x64 vcpkg artefacts — every Compile
            // step would fail with "file not found" for the .lib files
            // (and the vendored curl target_subdir is hardcoded
            // "windows-amd64" anyway, so vendored archives don't exist for
            // the aarch64 path either).
            //
            // Pinning Windows to x86_64-windows-gnu aligns dev boxes with
            // the CI's binary layout, so `zig build` Just Works on both
            // X64 and ARM64 Windows hosts when vcpkg x64 is present.
            //
            // To target aarch64-windows-gnu natively, install the matching
            // vcpkg triplet first:
            //     vcpkg install ... --triplet=arm64-windows
            // then pass `-Dtarget=aarch64-windows-gnu`.
            break :blk .{
                .cpu_arch = .x86_64,
                .os_tag = .windows,
                .abi = .gnu,
            };
        },
        else => .{
            .cpu_arch = b.graph.host.result.cpu.arch,
            .os_tag = b.graph.host.result.os.tag,
            .abi = b.graph.host.result.abi,
        },
    } });
    const optimize = b.standardOptimizeOption(.{});

    // CLI flag: `--no-webapp-rebuild` / `-Dno-webapp-rebuild` skips the
    // webapp-rebuild + mcp-hello-world chains. Used by Windows CI runners
    // with ~2-3 GB usable RAM where the vite build and pnpm installs OOM.
    // Defined EARLY so the mcp and webapp sections below can be gated.
    const no_webapp_rebuild = b.option(bool, "no-webapp-rebuild", "Skip the webapp-rebuild + mcp-hello-world chains (Windows CI OOM / no-pnpm workaround)") orelse false;

    // CLI flag: `-Drequire-real-webview` turns the no-op webview stub
    // fallback (see use_real_webview below) into a hard config-time error.
    // CI passes this on the Windows nalar-desktop build so a runner without
    // MSVC + WebView2 NuGet staging fails loudly instead of shipping a
    // nalar-desktop.exe whose webview_create() always returns NULL
    // (surface symptom: WebviewCreateFailed + evergreen-runtime prompt on a
    // machine that HAS the runtime — the binary is stub, not the runtime
    // missing). Dev boxes omit it and keep the warn-and-stub behavior.
    const require_real_webview = b.option(bool, "require-real-webview", "Fail the build instead of falling back to the no-op webview stub") orelse false;

    // `helpers` package (`src/helpers/`): project-wide portable sleep /
    // time / file-existence helpers. Created EARLY (before any
    // `b.addExecutable(...)` or `b.createModule(...)` calls below) so
    // every downstream Compile can include it in its `imports` list
    // via `.module = helpers_mod`.
    //
    // We promote `helpers` to its own Zig package (declared in
    // `build.zig.zon`) instead of creating a top-level `helpers`
    // module from a plain `b.createModule` so multiple sub-packages
    // (kabelweb, databases, …) can all reach it through a
    // single shared module instance. In Zig 0.16 every `.zig` file
    // belongs to exactly one module, so duplicating the helpers
    // module from each sub-build.zig would collide on the file
    // ownership of `helpers/mod.zig`. Declaring it as a package via
    // `b.dependency("helpers", ...)` gives it a single owner and
    // lets every consumer reference it as `@import("helpers")`.
    const helpers_dep = b.dependency("helpers", .{
        .target = target,
        .optimize = optimize,
    });
    const helpers_mod = helpers_dep.module("helpers");

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
    // now lives in the `kabelweb` package's own build.zig,
    // which links the vendored prebuilt archive from
    // vendor/curl/<target>/lib/libcurl.a. The package picks up the
    // right archive based on the target the consumer passes via
    // b.dependency(). See the kabelweb repo build.zig for
    // the full rationale.

    const mod = b.addModule("nalarcore", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "helpers", .module = helpers_mod },
        },
    });

    mod.addImport("nalarcore", mod);

    // === Self-contained `databases` package (sqlite3 + openssl + libpq) ===
    // The package (ruangsql, github.com/ginwa123/ruangsql, pinned by
    // URL + hash in build.zig.zon) carries its own build.zig
    // that wires sqlite3 / openssl / libpq + the vendored sqlite3.c
    // amalgamation based on the TARGET passed in. Every Compile that
    // imports `mod` (and therefore the `databases` module via
    // mod.addImport below) inherits those deps — no per-Compile
    // linkPlatformDeps branch for sqlite3 anymore.
    //
    // === Database backend list (APP-CONTROLLED) ===
    // The app decides here and forwards the list verbatim to the
    // `databases` package, which parses it (single place). `db_used`
    // is comma-separated because the build runner only passes strings
    // on the CLI (no array-of-string option kind exists).
    // Default `"sqlite"` = sqlite-only: Postgres.zig stays on disk but
    // is never @imported, libpq is never linked, pg tests are skipped.
    // Pass `-Ddb_used=sqlite,postgres` to opt in to postgres as well
    // (needs libpq-fe.h + libpq.so). This project only uses sqlite
    // today, so postgres is ignored unless explicitly listed here.
    const db_used = b.option(
        []const u8,
        "db_used",
        "Comma-separated database backends to compile: 'sqlite' (default, no libpq), add 'postgres' to also compile postgres (needs libpq)",
    ) orelse "sqlite";
    const databases_dep = b.dependency("databases", .{
        .target = target,
        .optimize = optimize,
        .@"db_used" = db_used,
    });
    const databases_mod = databases_dep.module("databases");
    mod.addImport("databases", databases_mod);

    // === Self-contained `kabelweb` package (vendored libcurl) ===
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
    // "undefined reference to __isoc23_strtol" etc. The kabelweb
    // http-client target overrides glibc when needed.
    const kabelweb_dep = b.dependency("kabelweb", .{
        .target = target,
        .optimize = optimize,
    });
    const kabelweb_mod = kabelweb_dep.module("kabelweb");
    mod.addImport("kabelweb", kabelweb_mod);

    // === Vendored Lua 5.4 (single-file hooks) ===
    // Compiled into `mod` for every target, so all exes (native +
    // install:* cross-compiles) embed Lua with no system dependency.
    linkVendoredLua(b, mod);

    // === kabelweb module (libcurl-backed HTTP) ===
    // Exposed as a separate module so Agent2.zig (in src/modules/agent/)
    // can `@import("kabelweb")`. Same libcurl deps as the
    // sibling build in the kabelweb repo.
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
    // Run the same probe as the `databases` and `kabelweb`
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
        // Pure-Zig header probe (no shell, no `bash` dependency).
        //
        // Earlier revisions ran `sh -c "test -f ..."` here, which silently
        // failed on Windows dev boxes without `bash` / `sh` on PATH
        // (Git for Windows ships git.exe + bash.exe but doesn't add
        // Git\bin or Git\usr\bin to PATH automatically). The probe then
        // fell through to `use_system=false`, the build went on to look
        // for the vendored libcurl archive, and `zig build` failed with
        // "file not found" — even though vcpkg had the libs installed at
        // `C:\vcpkg\installed\x64-windows\`. See commit history for the
        // PR that switched to std.fs.cwd().openFile (build-script-safe
        // across hosts).
        //
        // Probe checks: sqlite3.h AND libpq-fe.h AND openssl/ssl.h.
        // Missing any one → vendor fallback. Lib presence is verified
        // separately by the linker (a missing .lib gives a clear "file
        // not found" diagnostic).
        const sqlite_h = switch (b.graph.host.result.os.tag) {
            .linux => "/usr/include/sqlite3.h",
            .macos => pickFirstExisting(&.{
                "/opt/homebrew/opt/sqlite3/include/sqlite3.h",
                "/usr/include/sqlite3.h",
            }) orelse break :blk false,
            .windows => "C:/vcpkg/installed/x64-windows/include/sqlite3.h",
            else => break :blk false,
        };
        const libpq_h = switch (b.graph.host.result.os.tag) {
            .linux => pickFirstExisting(&.{
                "/usr/include/postgresql/libpq-fe.h",
                "/usr/include/libpq-fe.h",
            }) orelse break :blk false,
            .macos => pickFirstExisting(&.{
                "/opt/homebrew/opt/libpq/include/libpq-fe.h",
                "/usr/include/postgresql/libpq-fe.h",
                "/usr/include/libpq-fe.h",
            }) orelse break :blk false,
            .windows => "C:/vcpkg/installed/x64-windows/include/libpq-fe.h",
            else => break :blk false,
        };
        const openssl_h = switch (b.graph.host.result.os.tag) {
            .linux => "/usr/include/openssl/ssl.h",
            .macos => pickFirstExisting(&.{
                "/opt/homebrew/opt/openssl@3/include/openssl/ssl.h",
                "/opt/homebrew/opt/openssl/include/openssl/ssl.h",
                "/usr/include/openssl/ssl.h",
            }) orelse break :blk false,
            .windows => "C:/vcpkg/installed/x64-windows/include/openssl/ssl.h",
            else => break :blk false,
        };
        break :blk fileExists(sqlite_h) and fileExists(libpq_h) and fileExists(openssl_h);
    };

    // Probe host for system libcurl + openssl. Same probe layout as
    // dbs_uses_system but checks curl.h + openssl/ssl.h instead of
    // sqlite3/libpq. On macOS we additionally verify a libcurl.dylib
    // exists — having the header without the library (rare) would fail
    // at consumer link time.
    const curl_uses_system = blk: {
        if (target.result.os.tag != b.graph.host.result.os.tag) break :blk false;
        // Pure-Zig probe mirroring the dbs_uses_system helper above.
        // No shell, no bash dependency.
        //
        // On macOS we additionally verify a libcurl.dylib exists — having
        // only the header (rare) would fail at consumer link time.
        // The CI installs openssl@3 + coreutils via brew but NOT curl, so
        // the Mac runner needs `brew install curl` for system libcurl to
        // be picked up.
        const curl_h = switch (b.graph.host.result.os.tag) {
            .linux => "/usr/include/curl/curl.h",
            .macos => pickFirstExisting(&.{
                "/opt/homebrew/opt/curl/include/curl/curl.h",
                "/usr/include/curl/curl.h",
            }) orelse break :blk false,
            .windows => "C:/vcpkg/installed/x64-windows/include/curl/curl.h",
            else => break :blk false,
        };
        const openssl_h = switch (b.graph.host.result.os.tag) {
            .linux => "/usr/include/openssl/ssl.h",
            .macos => pickFirstExisting(&.{
                "/opt/homebrew/opt/openssl@3/include/openssl/ssl.h",
                "/opt/homebrew/opt/openssl/include/openssl/ssl.h",
                "/usr/include/openssl/ssl.h",
            }) orelse break :blk false,
            .windows => "C:/vcpkg/installed/x64-windows/include/openssl/ssl.h",
            else => break :blk false,
        };
        if (!fileExists(curl_h) or !fileExists(openssl_h)) break :blk false;
        // macOS extra check: libcurl.dylib present (header+lib pair).
        if (b.graph.host.result.os.tag == .macos) {
            const libcurl_dylib = pickFirstExisting(&.{
                "/opt/homebrew/opt/curl/lib/libcurl.dylib",
                "/usr/lib/libcurl.dylib",
            }) orelse break :blk false;
            _ = libcurl_dylib;
        }
        break :blk true;
    };

    std.debug.print(
        "[build.zig] system-deps probe: databases_uses_system={}, kabelweb_uses_system={}\n",
        .{ dbs_uses_system, curl_uses_system },
    );

    // === sqlite3 amalgamation: owned by the external `databases` package ===
    // The package (ruangsql, github.com/ginwa123/ruangsql) probes the host
    // for system sqlite3 + libpq + openssl and falls back to its own
    // vendored amalgamation (populated via its scripts/fetch-vendor-sqlite3.sh).
    // There is no in-tree fetch step anymore — same as kabelweb's
    // fetch-vendor-curl removal. Hosts without system libs must install
    // them (apt/brew/vcpkg) or populate the package's vendor dir manually.

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
                .{ .name = "helpers", .module = helpers_mod },
            },
        }),
    });

    // NOTE: there is no fetch-vendor-curl step anymore. kabelweb is an
    // external URL dependency — its own package + CI own the vendored
    // curl archive (see the kabelweb repo's scripts/build-vendor-curl.sh).
    // nalar builds link system curl/ssl/crypto through the module graph
    // (kabelweb's system probe), so no fetch is needed here.

    b.installArtifact(exe);

    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.link_libc = true;
    // Per-target platform deps (sqlite3/openssl/vendored amalgamation).
    // linkPlatformDeps handles all 4 targets in one switch — replaces the
    // old if/else chain that leaked Linux libs into cross-compile artifacts.
    linkPlatformDeps(b, exe, target);
    // libcurl is linked via kabelweb_mod's transitive deps
    // (the vendored prebuilt archive is added in the package's own
    // build.zig). No need to call linkSystemLibrary("curl", ...) or
    // addIncludePath here — the module graph handles it.
    // If we ended up on the Windows / cross-compile branch, depend on
    // the auto-fetch step so a fresh checkout Just Works.
    if (target.result.os.tag == .windows) {
    }
    // === mcp-hello-world: TypeScript test MCP server ===
    // Self-test target for the MCP stdio transport. Built from
    // src/apps/mcp_hello_world/index.ts (TypeScript + @modelcontextprotocol/sdk
    // + zod). The build chain is pnpm-based (2026-08-28 — pnpm migration,
    // previously npm; the lockfile is now pnpm-lock.yaml):
    //   1. `pnpm install --frozen-lockfile` — installs dev + prod deps
    //      exactly as the lockfile specifies (equivalent of `npm ci`).
    //      `--frozen-lockfile` fails the build if the lockfile would
    //      be modified, so a stale lockfile never silently re-resolves.
    //   2. `pnpm test` — TDD: vitest runs the 7 tool-handler unit tests
    //   3. `pnpm run build` — tsc compiles index.ts → dist/index.js
    //   4. Install a shell wrapper at zig-out/bin/mcp-hello-world that
    //      exec's `node dist/index.js` (the compiled binary).
    //
    // The functional tests (tests/functional/mcp_stdio_test.py) locate
    // this binary via harness.mcp_hello_world_bin() — same pattern as
    // the nalar binary.
    const mcp_hello_world_dir = "src/apps/mcp_hello_world";
    const mcp_hello_world_step = b.step("mcp-hello-world", "Build the mcp-hello-world test MCP server");

    // Always run `pnpm install` — pnpm's content-addressed store makes
    // this fast (~1s) when node_modules is already present. We avoid a
    // statFile check because std.fs.cwd was removed in Zig 0.16.
    // `--frozen-lockfile` is pnpm's equivalent of `npm ci`: fail
    // closed if the lockfile would be touched, so a stale lockfile
    // never silently re-resolves under CI.
    const mcp_pnpm_install = b.addSystemCommand(&.{ "pnpm", "install", "--frozen-lockfile" });
    mcp_pnpm_install.setCwd(b.path(mcp_hello_world_dir));
    mcp_hello_world_step.dependOn(&mcp_pnpm_install.step);

    // TDD: run the unit tests first. If they fail, the build fails
    // before we waste time on the TS compile.
    const mcp_test = b.addSystemCommand(&.{ "pnpm", "test" });
    mcp_test.setCwd(b.path(mcp_hello_world_dir));
    mcp_test.step.dependOn(&mcp_pnpm_install.step);
    mcp_hello_world_step.dependOn(&mcp_test.step);

    const mcp_build = b.addSystemCommand(&.{ "pnpm", "run", "build" });
    mcp_build.setCwd(b.path(mcp_hello_world_dir));
    mcp_build.step.dependOn(&mcp_test.step);
    mcp_hello_world_step.dependOn(&mcp_build.step);

    // Install the shell wrapper. The wrapper resolves the dist/index.js
    // path relative to itself via a `dirname $0` lookup so it works
    // whether installed at zig-out/bin/mcp-hello-world or in a
    // sandboxed test environment. We use a two-step pattern:
    //   1. `addWriteFile` produces a `LazyPath` to the cached wrapper
    //      body in .zig-cache (mode 0644, no chmod yet)
    //   2. `addInstallBinFile` installs that LazyPath to bin/ with the
    //      default mode — but Zig's `installFile` (Step.zig:525) does
    //      NOT set the executable bit, so the wrapper would land on
    //      disk as 0644.
    // The fix: after `addInstallBinFile` runs, a small chmod step sets
    // 0755 on the installed path. This keeps the install step as the
    // single source of truth for placement (clean re-installs) and
    // only adds the chmod on top.
    const wrapper_body =
        "#!/bin/sh\n" ++
        \\# mcp-hello-world — nalar's MCP stdio self-test target.
        \\# Auto-generated by build.zig. Invokes the compiled TypeScript
        \\# output (dist/index.js) via node. Resolves the install path
        \\# relative to this script so the binary works from anywhere.
        \\set -e
        \\SCRIPT_DIR=$(dirname "$0")
        \\# zig-out/bin/mcp-hello-world -> zig-out/bin/. We need to reach
        \\# <repo-root>/src/apps/mcp_hello_world/dist/index.js. From
        \\# zig-out/bin, `..` is zig-out, `../..` is the repo root.
        \\exec node "$SCRIPT_DIR/../../src/apps/mcp_hello_world/dist/index.js" "$@"
    ;
    const wrapper_cache_name = "mcp-hello-world-wrapper.sh";
    const mcp_wrapper_write = b.addWriteFiles();
    const wrapper_lazy_path = mcp_wrapper_write.add(wrapper_cache_name, wrapper_body);
    mcp_wrapper_write.step.dependOn(&mcp_build.step);

    const mcp_wrapper_install = b.addInstallBinFile(
        wrapper_lazy_path,
        "mcp-hello-world",
    );
    mcp_wrapper_install.step.dependOn(&mcp_wrapper_write.step);

    // chmod 0755 on the installed path so `node dist/index.js` actually
    // runs when invoked as `zig-out/bin/mcp-hello-world`. POSIX-only —
    // Windows has no `chmod` on PATH (chmod lives at `/usr/bin/chmod`
    // inside Git Bash, which isn't guaranteed to be on PATH for zig's
    // `addSystemCommand` spawn). Windows file permissions are a no-op
    // anyway (every .exe / .cmd / .bat is executable by default), so
    // skipping the chmod step on Windows is the right behavior.
    if (target.result.os.tag != .windows) {
        const mcp_wrapper_chmod = b.addSystemCommand(&.{
            "chmod",
            "755",
            b.pathJoin(&.{ b.install_path, "bin", "mcp-hello-world" }),
        });
        mcp_wrapper_chmod.step.dependOn(&mcp_wrapper_install.step);
        mcp_hello_world_step.dependOn(&mcp_wrapper_chmod.step);
    } else {
        mcp_hello_world_step.dependOn(&mcp_wrapper_install.step);
    }

    // Make `zig build` (the default) include mcp-hello-world so
    // functional tests can rely on it being present. Skipped when
    // -Dno-webapp-rebuild (Windows CI: pnpm FileNotFound + OOM).
    if (!no_webapp_rebuild) {
        b.getInstallStep().dependOn(mcp_hello_world_step);
    }

    // === mcp-http-hello-world: TypeScript test MCP server (Streamable HTTP) ===
    // Sibling of mcp-hello-world: same 3 tools, different transport.
    // Self-test target for the nalar MCP Streamable HTTP client.
    // Built from src/apps/mcp_http_hello_world/index.ts (TypeScript +
    // @modelcontextprotocol/sdk + zod). The build chain mirrors the
    // mcp-hello-world chain: pnpm install → pnpm test → pnpm run build
    // → install shell wrapper. Migrated to pnpm (2026-08-28) to match
    // the rest of the project (see PR #370) — `pnpm-workspace.yaml`
    // in this dir approves esbuild's postinstall (pnpm 11 requires
    // explicit approval for build scripts). Per the user's "one binary
    // per transport" preference, this is a SEPARATE binary, not a
    // --http flag on mcp-hello-world. See plan:
    // docs/superpowers/plans/2026-08-28-mcp-streamable-http.md.
    const mcp_http_hello_world_dir = "src/apps/mcp_http_hello_world";
    const mcp_http_hello_world_step = b.step("mcp-http-hello-world", "Build the mcp-http-hello-world Streamable HTTP test MCP server");

    const mcp_http_npm_install = b.addSystemCommand(&.{ "pnpm", "install", "--no-frozen-lockfile" });
    mcp_http_npm_install.setCwd(b.path(mcp_http_hello_world_dir));
    mcp_http_hello_world_step.dependOn(&mcp_http_npm_install.step);

    // Build first (tsc → dist/index.js), THEN run the tests. The test
    // imports from `./index.js` (NodeNext module resolution) and
    // readsFileSync(BINARY_PATH) where BINARY_PATH = `dist/index.js`
    // — the test FAILS with 'binary not found' if dist/ doesn't
    // exist yet. The build must precede the test, not the other way
    // around. The earlier 'test before build' order worked locally
    // only because dist/ happened to exist from a previous build;
    // CI starts clean and breaks.
    const mcp_http_build = b.addSystemCommand(&.{ "pnpm", "run", "build" });
    mcp_http_build.setCwd(b.path(mcp_http_hello_world_dir));
    mcp_http_build.step.dependOn(&mcp_http_npm_install.step);
    mcp_http_hello_world_step.dependOn(&mcp_http_build.step);

    // Now run the unit tests — the build output (dist/index.js) is in place.
    const mcp_http_test = b.addSystemCommand(&.{ "pnpm", "test" });
    mcp_http_test.setCwd(b.path(mcp_http_hello_world_dir));
    mcp_http_test.step.dependOn(&mcp_http_build.step);
    mcp_http_hello_world_step.dependOn(&mcp_http_test.step);

    // Install the shell wrapper. Mirrors the mcp-hello-world pattern:
    // write the wrapper to .zig-cache, install it to bin/, chmod 0755.
    const http_wrapper_body =
        "#!/bin/sh\n" ++
        \\# mcp-http-hello-world — nalar's MCP Streamable HTTP self-test target.
        \\# Auto-generated by build.zig. Invokes the compiled TypeScript
        \\# output (dist/index.js) via node. Resolves the install path
        \\# relative to this script so the binary works from anywhere.
        \\# Usage: mcp-http-hello-world <port>  (port is a CLI positional arg,
        \\# default 3000 if omitted).
        \\set -e
        \\SCRIPT_DIR=$(dirname "$0")
        \\# zig-out/bin/mcp-http-hello-world -> zig-out/bin/. We need to
        \\# reach <repo-root>/src/apps/mcp_http_hello_world/dist/index.js.
        \\exec node "$SCRIPT_DIR/../../src/apps/mcp_http_hello_world/dist/index.js" "$@"
    ;
    const http_wrapper_cache_name = "mcp-http-hello-world-wrapper.sh";
    const mcp_http_wrapper_write = b.addWriteFiles();
    const http_wrapper_lazy_path = mcp_http_wrapper_write.add(http_wrapper_cache_name, http_wrapper_body);
    mcp_http_wrapper_write.step.dependOn(&mcp_http_build.step);

    const mcp_http_wrapper_install = b.addInstallBinFile(
        http_wrapper_lazy_path,
        "mcp-http-hello-world",
    );
    mcp_http_wrapper_install.step.dependOn(&mcp_http_wrapper_write.step);

    // chmod 0755 on the installed path. POSIX-only — same rationale
    // as the mcp-hello-world chain above: Windows has no `chmod` on
    // PATH for zig's `addSystemCommand` spawn (it resolves via
    // CreateProcess, not Git Bash), and Windows file permissions are
    // a no-op anyway (every .exe / .cmd / .bat is executable by
    // default). Without this guard `zig build mcp-http-hello-world`
    // (and therefore `zig build functional-test`, which depends on
    // this step) fails on Windows with "failed to spawn chmod".
    if (target.result.os.tag != .windows) {
        const mcp_http_wrapper_chmod = b.addSystemCommand(&.{
            "chmod",
            "755",
            b.pathJoin(&.{ b.install_path, "bin", "mcp-http-hello-world" }),
        });
        mcp_http_wrapper_chmod.step.dependOn(&mcp_http_wrapper_install.step);
        mcp_http_hello_world_step.dependOn(&mcp_http_wrapper_chmod.step);
    } else {
        mcp_http_hello_world_step.dependOn(&mcp_http_wrapper_install.step);
    }

    // Don't include mcp-http-hello-world in the default `zig build` —
    // it's not needed by the desktop binary. Users invoke it explicitly
    // via `zig build mcp-http-hello-world`. The functional-test step
    // picks it up via the explicit `dependOn` added further down (see
    // where run_functional is constructed).

    // === Build the Vue webapp (pnpm) ===
    // Chunk 3: this step is a dependency of the desktop_exe build so the
    // embedded webapp_assets.zig is regenerated on every build. The step
    // itself runs `pnpm run build` in src/apps/desktop, which is the
    // project's standard webapp build (vue-tsc + vite in parallel — see
    // src/apps/desktop/package.json). pnpm migration (2026-08-28):
    // previously npm; the lockfile is now pnpm-lock.yaml and the
    // workspace `.npmrc` pins `node-linker=hoisted` so node_modules
    // is laid out the same way npm did it (vite, vue-tsc, and the
    // eslint plugin chain all resolve sibling deps directly).
    const build_webapp_step = b.step("build:webapp", "Build the Vue webapp with pnpm");

    const webapp_dir = "src/apps/desktop";

    // === Pre-flight: vue-tsc needs real Node, and pnpm must be on PATH ===
    //
    // `pnpm run build` invokes `vue-tsc --build` (via the type-check
    // script) + `vite build` in parallel. vue-tsc 3.x relies on
    // @volar/typescript monkey-patching `fs.readFileSync` to register
    // `.vue` as a TypeScript source-file extension and inject the Vue
    // language plugin. A JS-runtime shim whose native CJS loader bypasses
    // `fs.readFileSync` silently defeats that patch — no `.vue` extension
    // gets registered, and `vue-tsc --build` exits with hundreds of
    // `TS2307: Cannot find module '.../*.vue'` errors that vite never
    // sees. (This bit us under bun; pnpm always invokes real Node for
    // each script so it cannot recur.)
    //
    // node + pnpm must be on PATH so the developer (or CI) can invoke
    // vue-tsc via Node's real CJS loader. We fail fast with a clear
    // error rather than letting vue-tsc's cryptic TS2307 noise leak out.
const check_webapp_node = b.addSystemCommand(switch (b.graph.host.result.os.tag) {
        // Windows: `sh` isn't on PATH (Git for Windows ships it under
        // C:\Program Files\Git\bin\, not auto-added). Use cmd.exe with the
        // equivalent `where` lookup + a label + goto for the same
        // print-and-exit-1 logic. The user-facing error message is
        // slightly shorter on Windows (no "Install for your platform"
        // list) since CI installs Node 24 via actions/setup-node@v4 and
        // Windows dev boxes get Node via the standard nvm-windows /
        // winget / Chocolatey channels.
        .windows => &.{
            "cmd.exe", "/c",
            \\
            \\@echo off
            \\for %%t in (node pnpm) do (
            \\    where %%t >nul 2>&1 || (
            \\        echo.
            \\        echo ERROR: '%%t' was not found on PATH.
            \\        echo   vue-tsc (which runs inside 'pnpm run build' via the type-check
            \\        echo   script) patches tsc's source via fs.readFileSync to register
            \\        echo   .vue as a TypeScript source extension; a JS-runtime shim whose
            \\        echo   loader bypasses fs.readFileSync breaks that patching and
            \\        echo   fails with hundreds of TS2307 errors.
            \\        echo   pnpm is the project's package manager (replaced npm on
            \\        echo   2026-08-28) — see the workspace .npmrc + build.zig.
            \\        echo.
            \\        echo   Install Node.js + pnpm for Windows:
            \\        echo     winget install OpenJS.NodeJS.LTS
            \\        echo     OR nvm-windows / Chocolatey / the official msi.
            \\        echo.
            \\        exit /b 1
            \\    )
            \\)
        },
        // Linux + macOS: POSIX `command -v` loop. Same error message as
        // the original pre-Windows-fix check.
        else => &.{
            "sh", "-c",
            \\
            \\for tool in node pnpm; do
            \\    command -v "$tool" >/dev/null 2>&1 || {
            \\        echo "" >&2
            \\        echo "ERROR: '$tool' was not found on PATH." >&2
            \\        echo "  vue-tsc (which runs inside 'pnpm run build' via the type-check" >&2
            \\        echo "  script) patches tsc's source via fs.readFileSync to register" >&2
            \\        echo "  .vue as a TypeScript source extension; a JS-runtime shim whose" >&2
            \\        echo "  loader bypasses fs.readFileSync breaks that patching and" >&2
            \\        echo "  fails with hundreds of TS2307 errors." >&2
            \\        echo "  pnpm is the project's package manager (replaced npm on" >&2
            \\        echo "  2026-08-28) — see the workspace .npmrc + build.zig." >&2
            \\        echo "" >&2
            \\        echo "  Install nodejs + pnpm for your platform:" >&2
            \\        echo "    Arch Linux:   sudo pacman -S --needed nodejs pnpm" >&2
            \\        echo "    Debian/Ubnt:  sudo apt install nodejs && corepack enable && corepack prepare pnpm@latest --activate" >&2
            \\        echo "    macOS:        brew install node pnpm" >&2
            \\        echo "    Alpine:       apk add nodejs pnpm" >&2
            \\        echo "" >&2
            \\        exit 1
            \\    }
            \\done
        },
    });

    // Check if node_modules exists — if so, skip `pnpm install` (saves
    // seconds per build). Uses platform-specific syscalls: faccessat(2)
    // on Linux, std.fs.cwd().openDir on other platforms (the build
    // runner doesn't have libc linked, so std.fs.cwd() only works via
    // the Io runtime path on non-Linux hosts).
    //
    // pnpm with `node-linker=hoisted` (workspace .npmrc) lays the
    // top-level deps out at the same path npm did, so the probe's path
    // is unchanged. The .pnpm/ store dir is created on first install
    // but we don't gate on it — node_modules alone is the contract.
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
        else => false, // On non-Linux, always run `pnpm install` (safe no-op)
    };

    if (!node_modules_exists) {
        const install_cmd = b.addSystemCommand(&.{ "pnpm", "install", "--frozen-lockfile" });
        install_cmd.setCwd(b.path(webapp_dir));
        build_webapp_step.dependOn(&install_cmd.step);
    }

    // Hoisted so the webapp-rebuild path can also depend on it (fresh
    // checkout → `zig build nalar-desktop` needs node_modules too).
    // Declared unconditionally; the dependency edge is attached further
    // down, after webapp_rebuild_bun exists.
    const rebuild_install_cmd = b.addSystemCommand(&.{ "pnpm", "install", "--frozen-lockfile" });
    rebuild_install_cmd.setCwd(b.path(webapp_dir));
    if (node_modules_exists) {
        // Mirror the cached path's skip: node_modules already present,
        // so the install would be a wasted 1-2 s. Keep the step in the
        // graph but never reached — nothing depends on it.
        _ = &rebuild_install_cmd;
    }

    const pnpm_build = b.addSystemCommand(&.{ "pnpm", "run", "build" });
    pnpm_build.setCwd(b.path(webapp_dir));
    pnpm_build.step.dependOn(&check_webapp_node.step);
    build_webapp_step.dependOn(&pnpm_build.step);

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
    // hash drifted and triggered spurious webapp rebuilds.
    //
    // The workflow is now FRESH ASSETS BY DEFAULT:
    //
    //     `zig build nalar-desktop` always runs
    //       clean → `pnpm run build` → codegen → compile + link,
    //
    // so the embedded webapp matches the current .vue sources every
    // time. Cost: every nalar-desktop build pays the vite build
    // (~10 s+) plus an exe relink (the generated webapp_assets.zig is
    // not byte-stable across vite runs). This is intentional — the
    // user asked for fresh assets over cache-friendliness.
    //
    // `zig build webapp-rebuild` remains as a standalone alias for the
    // same chain (useful when you want to rebuild ONLY the webapp assets
    // without also compiling the desktop binary).
    //
    // Implementation: webapp_rebuild_step has its OWN copy of
    // `pnpm run build` (not the cached one used by the standalone
    // codegen path), chained after a clean step. The clean step deletes
    // the embedded file + dist/, so the rebuild's pnpm_build sees an
    // empty dist/, has actual work to do, and produces fresh output.
    const webapp_rebuild_step = b.step(
        "webapp-rebuild",
        "Nuke stale webapp_assets.zig + dist/ and rebuild via pnpm run build + codegen",
    );

    // Clean step — a small Zig CLI instead of `sh -c 'rm -rf ...'` so it
    // works with native Windows shells too (no Git Bash dependency).
    const webapp_rebuild_clean = b.addRunArtifact(b.addExecutable(.{
        .name = "clean_webapp_cache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/clean_webapp_cache.zig"),
            // Same cross-compile rationale as codegen_webapp_assets below:
            // avoid the Zig 0.16 + GCC 16 host-native link failure by using
            // the main target's glibc (no .sframe section in its crt1.o).
            .target = target,
            .link_libc = true,
        }),
    }));

    // Separate pnpm_build step for the rebuild path. Has the SAME
    // command + cwd as the cached one, but chained AFTER the clean
    // step, so the cache can't serve a stale result.
    const webapp_rebuild_pnpm = b.addSystemCommand(&.{ "pnpm", "run", "build" });
    webapp_rebuild_pnpm.setCwd(b.path(webapp_dir));
    webapp_rebuild_pnpm.step.dependOn(&webapp_rebuild_clean.step);
    webapp_rebuild_pnpm.step.dependOn(&check_webapp_node.step);
    // Fresh-checkout fix: the cached path gets a conditional
    // `pnpm install` via the node_modules_exists probe above, but that
    // only attaches to build_webapp_step. Attach the same install here
    // so a fresh checkout running straight into `zig build
    // nalar-desktop` doesn't fail with "vite: not found" inside the
    // rebuild's pnpm run build. (The rebuild_install_cmd step is
    // declared next to install_cmd above.)
    if (!node_modules_exists) {
        webapp_rebuild_pnpm.step.dependOn(&rebuild_install_cmd.step);
    }
    webapp_rebuild_step.dependOn(&webapp_rebuild_pnpm.step);

    // The codegen step is shared with the cached path — its output
    // (webapp_assets.zig) was just deleted by the clean step, so
    // it'll re-run to regenerate. Depend on the rebuild's pnpm_build
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
    webapp_rebuild_codegen.step.dependOn(&webapp_rebuild_pnpm.step);
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
                .{ .name = "helpers", .module = helpers_mod },
            },
        }),
    });
    desktop_exe.root_module.linkSystemLibrary("c", .{});

    // Set by the `.windows` prong below when the real WebView2 build is
    // taken: install step copying WebView2Loader.dll next to the exe.
    // Declared here (outside the switch) because `desktop_install` —
    // the step that must depend on it — is declared after the switch.
    var webview2_dll_install_step: ?*std.Build.Step = null;
    // Platform-specific system libraries (Chunks 5-7 add the real deps).
    // Switch kept here so the pattern is validated by the Chunk 1 build.
    switch (target.result.os.tag) {
        .linux => {
            // Linux webview: vendored webview/webview library
            // (vendor/webview/webview.{h,cc}, upstream 0.12.0).
            //
            // webview.cc is a one-line TU that includes webview.h with
            // WEBVIEW_IMPLEMENTATION semantics — the whole engine
            // (GTK3 + WebKitGTK 4.1) lives in the header. Compiled here
            // with zig c++ (C++11; the header uses _Pragma-heavy GLib
            // headers which zig c++ handles fine, unlike zig's @cImport).
            //
            // The library applies its own WebKit DMA-BUF/NVIDIA
            // workaround (apply_webkit_dmabuf_workaround in webview.h),
            // enables javascript_can_access_clipboard, and enables
            // developer extras when webview_create(debug=1) — all the
            // behaviors our old hand-rolled linux.zig provided.
            //
            // Library search path: with glibc 2.38 target, the linker's
            // default search path doesn't include /usr/lib in some contexts.
            // Add it explicitly so `linkSystemLibrary` finds the SO files.
            // Note: don't add `/usr/lib/x86_64-linux-gnu` — that's a
            // Debian/Ubuntu multi-arch path that doesn't exist on Arch /
            // Fedora, and Zig treats a missing library dir as a fatal error.
            desktop_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            desktop_exe.root_module.linkSystemLibrary("webkit2gtk-4.1", .{});
            desktop_exe.root_module.linkSystemLibrary("gtk-3", .{});
            desktop_exe.root_module.linkSystemLibrary("soup-3.0", .{});
            desktop_exe.root_module.linkSystemLibrary("glib-2.0", .{});
            desktop_exe.root_module.linkSystemLibrary("javascriptcoregtk-4.1", .{});
            // C++ runtime for webview.o (operator new, __cxa_begin_catch,
            // ...). link_libcpp pulls in zig's bundled libc++/libc++abi.
            desktop_exe.root_module.link_libcpp = true;

            // Resolve system libstdc++ include dir once. Different
            // distros install under different versioned paths:
            //   Arch (gcc 16):  /usr/include/c++/16
            //   Ubuntu 22.04 (gcc 12): /usr/include/c++/12
            //   Ubuntu 24.04 (gcc 13): /usr/include/c++/13
            //   Fedora 41 (gcc 14): /usr/include/c++/14
            // findLibstdcxxInclude picks the highest-version subdir.
            // null on a dev box without system libstdc++ (we then fall
            // back to zig's bundled libc++).
            const libstdc_dir = findLibstdcxxInclude(b);

            // Build the cflags array. -nostdlibinc is always on (we
            // explicitly choose the stdlib below). When libstdc_dir is
            // non-null we add the distro-versioned -isystem flags; when
            // null we fall back to zig's bundled libc++ via -I (same
            // recipe the macOS branch uses, where there's no system
            // C++ stdlib to fight over).
            var cflags: [32][]const u8 = undefined;
            var cn: usize = 0;
            cflags[cn] = "-std=c++11"; cn += 1;
            cflags[cn] = "-DWEBVIEW_STATIC"; cn += 1;
            cflags[cn] = "-DWEBVIEW_GTK"; cn += 1;
            cflags[cn] = "-Ivendor/webview"; cn += 1;
            cflags[cn] = "-nostdlibinc"; cn += 1;
            // System C headers MUST come via -isystem (not -I) so they
            // sort AFTER the C++ stdlib headers — with plain
            // -I/usr/include, clang's <cerrno> wrapper finds glibc's
            // errno.h first and errors with "didn't find libc++'s
            // <errno.h> header".
            const isystem_c_args = [_][]const u8{
                "-isystem/usr/include",
                // Full pkg-config cflags for webkit2gtk-4.1 (zig c++ is
                // stricter about transitive includes than the system cc
                // was for the old C shim — e.g. pango's pango-coverage.h
                // includes <hb.h> from the harfbuzz include dir, and
                // gdkx.h includes <X11/Xlib.h>).
                "-isystem/usr/include/webkitgtk-4.1",
                "-isystem/usr/include/gtk-3.0",
                "-isystem/usr/include/pango-1.0",
                "-isystem/usr/include/cloudproviders",
                "-isystem/usr/include/cairo",
                "-isystem/usr/include/gdk-pixbuf-2.0",
                "-isystem/usr/include/at-spi2-atk/2.0",
                "-isystem/usr/include/at-spi-2.0",
                "-isystem/usr/include/atk-1.0",
                "-isystem/usr/include/dbus-1.0",
                "-isystem/usr/lib/dbus-1.0/include",
                "-isystem/usr/include/fribidi",
                "-isystem/usr/include/pixman-1",
                "-isystem/usr/include/harfbuzz",
                "-isystem/usr/include/freetype2",
                "-isystem/usr/include/libpng16",
                "-isystem/usr/include/gio-unix-2.0",
                "-isystem/usr/include/libsoup-3.0",
                "-isystem/usr/include/glib-2.0",
                "-isystem/usr/lib/glib-2.0/include",
            };
            for (isystem_c_args) |a| {
                if (cn >= cflags.len) break;
                cflags[cn] = a;
                cn += 1;
            }
            // Debian/Ubuntu keep the glibc headers in a multiarch subdir
            // and ship NO /usr/include/bits symlink, so with only
            // /usr/include on the path the system headers' own
            // `#include <bits/types.h>` resolves to nothing.
            //
            // That is invisible until a C++ TU reaches <ctime>: Zig's
            // generic-glibc/time.h shim pulls in the system
            // bits/types/time_t.h, which uses `__time64_t` under
            // __USE_TIME_BITS64 — and `__time64_t` is defined in
            // bits/types.h, the header that silently did not resolve.
            // Result: "unknown type name '__time64_t'" in
            // bits/types/struct_timeval.h, then an undeclared
            // `__ts_sec` in libcxx's condition_variable.h.
            //
            // Arch and Fedora keep these headers flat in /usr/include,
            // which is why this never showed up until CI left the Arch
            // runner. Added conditionally so those distros are
            // untouched — a non-existent -isystem dir is harmless, but
            // being explicit keeps the flag list honest.
            const multiarch_include = b.fmt("/usr/include/{s}-linux-gnu", .{@tagName(target.result.cpu.arch)});
            if (dirExists(b, multiarch_include)) {
                if (cn < cflags.len) {
                    cflags[cn] = b.fmt("-isystem{s}", .{multiarch_include});
                    cn += 1;
                }
            }
            if (libstdc_dir) |cxx| {
                // System libstdc++: pin to the highest-version c++
                // directory + its target-specific c++config.h. Both
                // paths go via -isystem so they sort AFTER glibc's
                // <math.h>/<cwchar.h> in the search order.
                if (cn < cflags.len) { cflags[cn] = b.fmt("-isystem{s}", .{cxx}); cn += 1; }
                if (cn < cflags.len) { cflags[cn] = b.fmt("-isystem{s}/x86_64-pc-linux-gnu", .{cxx}); cn += 1; }
                if (cn < cflags.len) { cflags[cn] = b.fmt("-isystem{s}/backward", .{cxx}); cn += 1; }
            } else {
                std.log.warn(
                    "nalar-desktop: no /usr/include/c++/* found — falling back to zig's bundled libc++. " ++
                        "Expect <wint_t>/<errno>/<FP_NAN> typedef conflicts on hosts with a glibc <math.h>. " ++
                        "Install gcc-libs to silence this.",
                    .{},
                );
            }
            desktop_exe.root_module.addCSourceFile(.{
                .file = b.path("vendor/webview/webview.cc"),
                .flags = cflags[0..cn],
            });
        },
        .macos => {
            // macOS webview: vendored webview/webview library (same as
            // the Linux branch above). webview.h auto-selects its
            // Cocoa/WKWebView backend on __APPLE__ — no WEBVIEW_COCOA
            // define needed. The old Objective-C++ shim
            // (platform/macos/nalar_webview.mm) is deleted: it
            // implemented the old nalar_webview_* C ABI which main.zig
            // no longer calls (the webview-lib swap moved main.zig to
            // webview_create/webview_run directly).
            //
            // SDK paths: Zig doesn't auto-detect the macOS SDK here
            // because `target`'s query has an explicit .os_tag (see the
            // standardTargetOptions default_target block near the top of
            // `build`), which disables Zig's native-SDK autodetection
            // fast path. We resolve the SDK path ourselves via `xcrun`
            // and wire the framework/include/library search paths
            // manually before linking. See `getMacosSdkPath` above.
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

            desktop_exe.root_module.addCSourceFile(.{
                .file = b.path("vendor/webview/webview.cc"),
                .flags = &.{
                    "-std=c++11",
                    "-DWEBVIEW_STATIC",
                    "-Ivendor/webview",
                },
            });
            // C++ runtime for webview.o (operator new, __cxa_begin_catch,
            // ...). On macOS the SDK's libc++ is used via the SDK lib
            // path added above.
            desktop_exe.root_module.link_libcpp = true;
            desktop_exe.root_module.linkFramework("Cocoa", .{});
            desktop_exe.root_module.linkFramework("WebKit", .{});
            // AppKit: linked explicitly so `otool -L` shows AppKit.framework
            // (the vendored webview/webview library fetches NSApplication
            // / NSWindow via runtime objc_getClass + dlopen, so without
            // this explicit link the framework only shows up transitively
            // under the Cocoa umbrella and the CI smoke step's
            // `otool -L | grep AppKit.framework` check fails). No runtime
            // behavior change — AppKit is already loaded by the Cocoa
            // umbrella at startup; this just forces a direct link entry.
            desktop_exe.root_module.linkFramework("AppKit", .{});
        },
        .windows => {
            // Windows webview: vendored webview/webview library (same as
            // the Linux + macOS branches above). webview.h auto-selects
            // its WebView2 backend on _WIN32 — no WEBVIEW_EDGE define
            // needed. The old C++ shim (platform/windows/nalar_webview.cpp)
            // implemented the old nalar_webview_* C ABI which main.zig
            // no longer calls (webview-lib swap moved main.zig to
            // webview_create/run directly). Its prerequisite gate
            // (MSVC C++ stdlib + WebView2 NuGet) was a separate concern;
            // for the vendored lib we still need MSVC's STL headers
            // (wrl/client.h transitively pulls <cstddef>) and the
            // WebView2 NuGet's headers (WebView2.h, EventToken.h).
            //
            // We compile vendor/webview/webview.cc with zig cc using
            // MSVC's include dirs (resolved from VCToolsInstallDir).
            // Two gates: the MSVC C++ stdlib must be available, AND
            // the WebView2 NuGet headers must be staged next to the .cpp.
            // If either is missing, fall back to a stub that exports
            // the symbols as no-ops so `zig build nalar-desktop` still
            // succeeds on dev boxes without MSVC + NuGet extraction.
            const use_real_webview = blk: {
                // NOTE: -Dno-webapp-rebuild does NOT force the stub — it
                // only skips the vite/pnpm chain (the OOM source). The
                // cl.exe single-TU compile below is cheap. Forcing stub here
                // used to ship CI zips whose webview_create() always returns
                // NULL (WebviewCreateFailed on machines WITH the runtime).
                if (!hasMsvcCppStllib(b, b.graph.io)) break :blk false;
                // cl.exe path + MSVC lib dir below need the resolved
                // version root (hasMsvc alone doesn't bind it, e.g.
                // INCLUDE-env-only setups with custom install paths).
                if (msvcVersionRoot(b) == null) break :blk false;
                if (webview2MissingPrereq(b)) |missing| {
                    std.log.warn(
                        "nalar-desktop: MSVC C++ toolchain found, but WebView2 prerequisite {s} is missing under " ++
                            "src/apps/desktop_app/platform/windows/ — using the no-op webview stub instead. " ++
                            "Extract build/native/include/* + runtimes/win-x64/native/WebView2Loader.dll from the " ++
                            "Microsoft.Web.WebView2 NuGet package there to enable the real webview.",
                        .{missing},
                    );
                    break :blk false;
                }
                break :blk true;
            };
            if (require_real_webview and !use_real_webview) {
                std.log.err(
                    "nalar-desktop: -Drequire-real-webview is set but the real webview/webview build is unavailable on this host " ++
                        "(missing MSVC C++ toolchain or WebView2 NuGet staging under src/apps/desktop_app/platform/windows/) — " ++
                        "refusing to build the no-op stub whose webview_create() always returns NULL. See the warnings above for the missing piece.",
                    .{},
                );
                std.process.exit(1);
            }
            if (use_real_webview) {
            // Compile vendor/webview/webview.cc with the REAL cl.exe
            // (MSVC), not `zig cc`.
            //
            // Why not clang: MSVC 14.44 headers + COM + MS C++ ABI cannot
            // be satisfied by clang-on-windows-gnu, verified through a
            // full round of attempts (2026-09-05, see git history):
            // mingw `yvals.h` shadowing (`-nostdinc` + `-I` ordering
            // fixes that) → `__int64` needs `-fms-extensions` →
            // UCRT/winnt arch gates need `_M_X64`/`_M_AMD64`/`_AMD64_` →
            // COM `DECLSPEC_UUID` needs `_MSC_VER`, which `zig cc`
            // cannot express (`-D_MSC_VER=` dies with bogus
            // `FileNotFound`; `-fms-compatibility-version` ignored;
            // `-include` header works) → Itanium ABI object references
            // `__cxa_*`/`__gxx_personality_seh0`, unsatisfiable since
            // msvcprt.lib is MS-mangled → `-mabi=ms` is silently
            // IGNORED by `zig cc` (proven via strings on the output) →
            // `-fms-compatibility` flips the ABI but kills the
            // `char16_t`/`char32_t` keywords with no recourse.
            // cl.exe is installed alongside the detected MSVC (same box
            // that provides the headers) and needs no vcvars env for a
            // `/c` compile — explicit `/I` covers everything. Only the
            // `extern "C"` boundary crosses into the gnu-ABI exe (x64
            // has no leading-underscore decoration), so the MSVC-compiled
            // object links cleanly. `/MD` (DLL runtime) keeps one shared
            // heap with the rest of the exe; `/Z7` embeds debug info in
            // the obj (no mspdb server needed).
            const ver_root = msvcVersionRoot(b) orelse unreachable; // gate above guarantees this
            const cl_exe = b.fmt("{s}/bin/Hostx64/x64/cl.exe", .{ver_root});
            const cpp_src = "vendor/webview/webview.cc";
            const msvc_include = findMsvcInclude(b);
            // Skip dirs that failed to resolve (same rationale as
            // before: a bare `/I ""` is a confusing no-op).
            const candidate_dirs = [_][]const u8{
                msvc_include.c_stddef,
                msvc_include.msvc_include,
                msvc_include.ucrt_include,
                msvc_include.um_include,
                msvc_include.shared_include,
                msvc_include.winrt_include,
            };
            var cpp_args: [32][]const u8 = undefined;
            var n: usize = 0;
            cpp_args[n] = cl_exe;
            n += 1;
            cpp_args[n] = "/nologo";
            n += 1;
            cpp_args[n] = "/c";
            n += 1;
            cpp_args[n] = "/std:c++17";
            n += 1;
            cpp_args[n] = "/EHsc";
            n += 1;
            cpp_args[n] = "/MD";
            n += 1;
            cpp_args[n] = "/Z7";
            n += 1;
            // No Control Flow Guard in this TU (`/guard:cf-`; cl.exe
            // enables it by default since VS2022). CFG-instrumented code
            // references the `__guard_*_icall_fptr` dispatch tables,
            // which would pull vcruntime.lib's table object into a link
            // where mingw's startup objects already define them
            // (`duplicate symbol`). The TU's indirect calls go through
            // WebView2 COM vtables resolved at runtime anyway; the rest
            // of the exe keeps its own guard posture unchanged.
            cpp_args[n] = "/guard:cf-";
            n += 1;
            cpp_args[n] = "/DWEBVIEW_STATIC";
            n += 1;
            cpp_args[n] = "/Ivendor/webview";
            n += 1;
            // WebView2.h + EventToken.h (NuGet-staged). webview.h pulls
            // `"WebView2.h"` as a quoted include.
            cpp_args[n] = "/Isrc/apps/desktop_app/platform/windows";
            n += 1;
            for (candidate_dirs) |dir| {
                if (dir.len == 0) continue;
                cpp_args[n] = "/I";
                n += 1;
                cpp_args[n] = dir;
                n += 1;
            }
            // NOTE: cl.exe only accepts the GLUED form (`/Fopath`, no
            // space — the separate form warns D9027 `source file
            // ignored` and emits nothing where addOutputFileArg
            // expects it). The tree path is gitignored
            // (`vendor/webview/webview.obj`) and the step re-runs
            // whenever argv changes, so no stale-object hazard.
            cpp_args[n] = "/Fovendor/webview/webview.obj";
            n += 1;
            cpp_args[n] = cpp_src;
            n += 1;
            const cpp_compile = b.addSystemCommand(cpp_args[0..n]);
            cpp_compile.setCwd(b.path(""));
            desktop_exe.step.dependOn(&cpp_compile.step);
            desktop_exe.root_module.addObjectFile(.{ .cwd_relative = "vendor/webview/webview.obj" });
            // Win32 / COM / WebView2 link deps (same as the old shim used).
            desktop_exe.root_module.linkSystemLibrary("ole32", .{});
            desktop_exe.root_module.linkSystemLibrary("user32", .{});
            // Zig's MinGW (gnu) link line doesn't auto-pull kernel32.dll /
            // ws2_32.dll for raw `extern "kernel32"` / `extern "ws2_32"`
            // decls in Zig code. Add them explicitly so the Win32 externs
            // in extraction.zig / subprocess.zig resolve at link time.
            desktop_exe.root_module.linkSystemLibrary("kernel32", .{});
            desktop_exe.root_module.linkSystemLibrary("ws2_32", .{});
            // WebView2Loader.lib lives next to nalar_webview.cpp in the
            // old layout; webview.h includes <WebView2.h> from
            // src/apps/desktop_app/platform/windows/ (NuGet-staged
            // location). Add that dir to the include + library search
            // paths so the compile finds the header and LLD finds the
            // import library.
            desktop_exe.root_module.addIncludePath(.{
                .cwd_relative = "src/apps/desktop_app/platform/windows",
            });
            desktop_exe.root_module.addLibraryPath(.{
                .cwd_relative = "src/apps/desktop_app/platform/windows",
            });
            // WebView2Loader.lib back in place: the bisection proved it
            // innocent (same 2 duplicates without it — the CFG-table
            // references come from msvcprt.lib's own members).
            desktop_exe.root_module.linkSystemLibrary("WebView2Loader", .{});            // Link deps for the real webview object. `#pragma
            // comment(lib, ...)` directives embedded in the TU (MSVC
            // headers auto-link the C++ runtime; webview.h links ole32 /
            // shell32 / shlwapi / version / advapi32 / user32) name libs
            // lld must resolve: `msvcprt` (DLL C++ runtime — see -D_DLL),
            // `uuid`, `shlwapi`, `version` (ole32/shell32/user32/advapi32
            // already resolve via zig's mingw libs). MSVC's `lib/x64`
            // provides msvcprt; the SDK's `Lib/<ver>/um/x64` provides
            // uuid/shlwapi/version. Without these the link fails with
            // `lld-link: could not open 'lib<name>.a'`.
            // MSVC C++ runtime libs WITHOUT the shadowing hazard below.
            // `msvcprt.lib` + `vcruntime.lib` are COPIED from the MSVC
            // install into the NuGet staging dir (already on the search
            // path for WebView2Loader) instead of adding MSVC's
            // `lib/x64` to the search paths. Reason: that dir also
            // contains `msvcrt.lib`, and lld resolves the name `msvcrt`
            // to MSVC's copy INSTEAD OF mingw's `libmsvcrt.a` — MSVC's
            // copy drags in `guard_support.obj` whose CFG dispatch
            // tables (`__guard_*_icall_fptr`) collide with mingw's
            // `mingw_cfguard_support.obj` (`duplicate symbol`; lld names
            // both). The two copied libs have no mingw counterparts, so
            // no shadowing is possible. Copy-if-missing-or-stale at
            // config time (few MB, one-time cost).
            {
                const runtime_libs = [_][]const u8{ "msvcprt.lib", "vcruntime.lib", "oldnames.lib" };
                const msvc_lib_root = b.fmt("{s}/lib/x64", .{ver_root});
                const stage_dir = "src/apps/desktop_app/platform/windows";
                for (runtime_libs) |lib_name| {
                    const src_path = b.fmt("{s}/{s}", .{ msvc_lib_root, lib_name });
                    const dst_path = b.fmt("{s}/{s}", .{ stage_dir, lib_name });
                    if (staleOrMissing(b, src_path, dst_path)) {
                        const bytes = std.Io.Dir.cwd().readFileAlloc(
                            b.graph.io,
                            src_path,
                            b.allocator,
                            .unlimited,
                        ) catch break;
                        defer b.allocator.free(bytes);
                        std.Io.Dir.cwd().writeFile(
                            b.graph.io,
                            .{ .sub_path = dst_path, .data = bytes },
                        ) catch break;
                    }
                }
                // `msvcrt.lib`: PRUNE the CFG-table + TLS startup members
                // that collide with mingw's (`duplicate symbol` with a
                // full copy). Everything else in the archive (C-runtime
                // imports used by msvcprt members) stays. Always re-copy
                // fresh first (8 MB, milliseconds) so the prune list
                // below applies to a known-good baseline — `ar d` on an
                // already-absent member would fail the configure. Prune list is
                // evidence-driven: guard_support.obj (proven dup, lld
                // names it) + the TLS-init family (dup set from the
                // full-lib link). Cookie members stay: no dup evidence
                // (they resolve via mingw today).
                // Best-effort: any IO failure skips staging (the link
                // will then fail loudly on the missing lib).
                stagePrunedMsvcrt(b, msvc_lib_root, stage_dir);
            }
            // The exact libs `-luuid -lshlwapi -lversion` below need. Probing
            // the FILES (not just the `um/x64` dir) is what skips the
            // `wdf0.26100.0` decoy, whose um/x64 exists but is empty.
            // See newestSubdirWith's doc comment.
            const kit_lib_root = newestSubdirWith(
                b,
                "C:/Program Files (x86)/Windows Kits/10/Lib",
                &.{ "um/x64/uuid.lib", "um/x64/shlwapi.lib", "um/x64/version.lib" },
            ) orelse newestSubdirWith(
                b,
                "C:/Program Files/Windows Kits/10/Lib",
                &.{ "um/x64/uuid.lib", "um/x64/shlwapi.lib", "um/x64/version.lib" },
            );
            if (kit_lib_root) |kl| {
                desktop_exe.root_module.addLibraryPath(.{
                    .cwd_relative = b.fmt("{s}/um/x64", .{kl}),
                });
                // ucrt.lib lives in its own leaf (Lib/<ver>/ucrt/x64),
                // NOT under um/ — without this dir the link fails with
                // `unable to find dynamic system library 'ucrt'`.
                desktop_exe.root_module.addLibraryPath(.{
                    .cwd_relative = b.fmt("{s}/ucrt/x64", .{kl}),
                });
            }
            desktop_exe.root_module.linkSystemLibrary("msvcprt", .{});
            desktop_exe.root_module.linkSystemLibrary("uuid", .{});
            desktop_exe.root_module.linkSystemLibrary("shlwapi", .{});
            desktop_exe.root_module.linkSystemLibrary("version", .{});
            // vcruntime: sole provider of `__CxxFrameHandler4` +
            // `__security_cookie` for the cl.exe object. DLL import —
            // no static-CRT heap risk.
            desktop_exe.root_module.linkSystemLibrary("vcruntime", .{});
            // Guard-table stubs (5 CFG/XFG symbols nothing else defines
            // — see guard_tables_stub.c). Plain C, no includes: compiles
            // through the normal Zig CC path, no MSVC involvement.
            desktop_exe.root_module.addCSourceFile(.{
                .file = b.path("src/apps/desktop_app/platform/windows/guard_tables_stub.c"),
                .flags = &.{},
            });            // The import lib only records the dependency — at RUNTIME the
            // Windows loader resolves WebView2Loader.dll via the standard
            // search order (exe dir first). Install the NuGet-staged copy
            // next to the exe so a fresh `zig-out/bin/nalar-desktop.exe`
            // starts without requiring the DLL on PATH. Wired into
            // `desktop_install` after the switch (it doesn't exist yet
            // here).
            const wv2_dll_install = b.addInstallBinFile(
                b.path("src/apps/desktop_app/platform/windows/WebView2Loader.dll"),
                "WebView2Loader.dll",
            );
            webview2_dll_install_step = &wv2_dll_install.step;
            } else {
                // === Dev-box fallback: no MSVC + WebView2 ===
                //
                // The webview/webview library hard-requires MSVC's C++
                // STL (webview.h's win32 path includes <wrl/client.h>
                // which transitively pulls <cstddef>) AND the
                // Microsoft.Web.WebView2 NuGet headers (WebView2.h +
                // EventToken.h, staged under
                // src/apps/desktop_app/platform/windows/). Without both,
                // `zig cc vendor/webview/webview.cc` fails deep inside
                // Microsoft's headers.
                //
                // The previous design (bf008b4d) called
                // `std.process.exit(1)` here at config time — killing
                // every `zig build` invocation (including `zig build
                // test`, which doesn't need nalar-desktop at all) on a
                // Windows dev box without MSVC + WebView2. That broke
                // the test-only workflow on Windows.
                //
                // Fix: link a no-op C stub (webview_stub.c) instead of
                // bailing out. The stub provides empty implementations
                // of every webview_* C symbol declared in
                // webview_lib.zig; webview_create() returns NULL,
                // main.zig's runWindow surfaces
                // `error.WebviewCreateFailed`, and the user sees a
                // clear log line. nalar-desktop.exe compiles + links +
                // the `--smoke-test` path runs cleanly, but the window
                // can't actually open (no WebView2 runtime).
                //
                // This matches Linux/macOS semantics: on Linux, a
                // dev box without webkit2gtk-4.1 still produces a
                // nalar-desktop binary that fails at runtime when it
                // tries to call webview_create; on macOS, the same with
                // Cocoa/WebKit missing. The Windows path now matches.
                //
                // The CI runner installs MSVC + WebView2 NuGet and
                // takes the real webview.cc compile path above. This
                // stub is only for dev boxes without those
                // prerequisites.
                std.log.warn(
                    "nalar-desktop: MSVC C++ toolchain and/or Microsoft.Web.WebView2 " ++
                        "NuGet headers not found on this host — using no-op stub " ++
                        "(nalar-desktop will build but cannot open a webview window). " ++
                        "Install Visual Studio Build Tools + extract the " ++
                        "Microsoft.Web.WebView2 NuGet to get a real webview.",
                    .{},
                );
                desktop_exe.root_module.addCSourceFile(.{
                    .file = b.path("src/apps/desktop_app/platform/windows/webview_stub.c"),
                    .flags = &.{},
                });
                // Win32 / WinSock2 deps for Zig's std extern decls
                // (extraction.zig / subprocess.zig). Zig's MinGW (gnu)
                // link line doesn't auto-pull kernel32.dll / ws2_32.dll
                // for raw `extern "kernel32"` / `extern "ws2_32"` decls
                // in Zig code. Add them explicitly so the Win32 externs
                // resolve at link time. Same as the real-webview branch
                // above.
                desktop_exe.root_module.linkSystemLibrary("kernel32", .{});
                desktop_exe.root_module.linkSystemLibrary("ws2_32", .{});
            }
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
    // Real-WebView2 Windows builds need WebView2Loader.dll beside the
    // exe at runtime (see the `.windows` prong above). DependOn pulls
    // the dll install into `build:all` via desktop_install's edge.
    if (webview2_dll_install_step) |dll_step| desktop_install.step.dependOn(dll_step);
    // Windows: bundle vcpkg runtime DLLs (libcurl.dll, sqlite3.dll, ...)
    // next to nalar-desktop.exe AND the nalar service exe so Explorer
    // double-click works with a clean PATH (see installVcpkgDlls doc).
    installVcpkgDlls(b, &desktop_install.step);
    installVcpkgDlls(b, b.getInstallStep());
    // Windows-only shipped webapp (persistent, no temp extraction):
    // copy src/apps/desktop/dist → zig-out/bin/html so the Windows
    // release zip can bundle it and Install-Nalar.ps1 can install it to
    // %LOCALAPPDATA%\nalar\html. The desktop (Windows-only, see
    // path_resolve.findInstalledWebapp) prefers that persistent dir and
    // only falls back to embedded-asset temp extraction when it is
    // missing (dev runs, broken installs). Linux/macOS ignore this dir
    // and keep the embedded flow unchanged.
    //
    // Configure-time guard: dist/ is gitignored and only exists after a
    // webapp build. Windows CI builds with -Dno-webapp-rebuild (the full
    // vite+vue-tsc+zig-link chain OOMs on the small runner) and receives
    // dist/ from a dedicated preceding vite-only step -- when dist/ is
    // absent the install step must be skipped, not failed (InstallDir.make
    // errors on a missing source and would break the previously-working
    // stub-embedded flow). Ordered after the webapp rebuild codegen so
    // a fresh dist is copied; with -Dno-webapp-rebuild we install
    // whatever dist is on disk and skip the codegen edge so the flag
    // keeps its meaning.
    if (fileExists("src/apps/desktop/dist/index.html")) {
        const webapp_dir_install = b.addInstallDirectory(.{
            .source_dir = b.path("src/apps/desktop/dist"),
            .install_dir = .bin,
            .install_subdir = "html",
        });
        if (!no_webapp_rebuild) {
            webapp_dir_install.step.dependOn(&webapp_rebuild_codegen.step);
        }
        desktop_install.step.dependOn(&webapp_dir_install.step);
    } else {
        std.log.warn("webapp dist/index.html missing -- skipping zig-out/bin/html (desktop falls back to embedded extraction)", .{});
    }
    // Late alias kept for comment continuity — actual flag is defined
    // early (near target/optimize) so mcp/webapp sections could be gated.
    // Reuse the early `no_webapp_rebuild` value here; do not re-parse.

    // Make the desktop binary depend on the FRESH-ASSETS codegen chain:
    // clean → `bun run build` → codegen. Every nalar-desktop build
    // rebuilds the webapp from current sources and re-embeds it, so the
    // binary always matches the .vue files on disk (user-requested
    // behavior; see the "Webapp rebuild workflow" comment above for the
    // cost trade-off).
    if (!no_webapp_rebuild) {
        desktop_exe.step.dependOn(&webapp_rebuild_codegen.step);
    } else {
        // When skipping the webapp rebuild, ensure a stub exists so the
        // @import("embedded/webapp_assets.zig") in main.zig doesn't fail
        // with FileNotFound on a fresh checkout (gitignored file).
        // Do it synchronously at configure time — b.addWriteFiles would
        // only place the file in .zig-cache, not in the source tree where
        // the import resolves.
        const stub_path = "src/apps/desktop_app/embedded/webapp_assets.zig";
        if (!fileExists(stub_path)) {
            const stub_content =
                \\// GENERATED stub — webapp rebuild skipped (-Dno-webapp-rebuild)
                \\const std = @import("std");
                \\pub const Asset = struct { path: []const u8, content: []const u8, mime: []const u8 };
                \\pub const assets: []const Asset = &.{};
                \\
            ;
            // Use std.Io (Zig 0.16) — create parent dirs + file.
            const io = b.graph.io;
            // Ensure parent dir exists.
            std.Io.Dir.cwd().createDirPath(io, "src/apps/desktop_app/embedded") catch {};
            if (std.Io.Dir.cwd().createFile(io, stub_path, .{ .truncate = true })) |file| {
                defer file.close(io);
                std.Io.File.writeStreamingAll(file, io, stub_content) catch |err| {
                    std.log.warn("failed to write stub {s}: {any}", .{ stub_path, err });
                };
            } else |err| {
                std.log.warn("failed to create stub {s}: {any}", .{ stub_path, err });
            }
        }
    }

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
    // The test compile shares `desktop_exe.root_module`, which imports the
    // gitignored `embedded/webapp_assets.zig`. Without the same codegen edge
    // `desktop_exe` has, a fresh checkout fails to even compile the tests
    // ("unable to load 'webapp_assets.zig': FileNotFound") — which is why
    // this step was unrunnable from a clean tree. With -Dno-webapp-rebuild
    // the stub was already written at configure time by the desktop_exe
    // block above, so the edge is skipped there (same as desktop_exe).
    if (!no_webapp_rebuild) {
        desktop_tests.step.dependOn(&webapp_rebuild_codegen.step);
    }
    const run_desktop_tests = b.addRunArtifact(desktop_tests);
    // Windows: ensure vcpkg bin (libcurl.dll, sqlite3.dll, …) is on PATH
    // at test runtime — see `prependVcpkgBinToPath` doc comment.
    prependVcpkgBinToPath(b, run_desktop_tests);
    test_desktop.dependOn(&run_desktop_tests.step);

    // === Cross-target compile check (desktop app's per-OS branches) ===
    // `extraction.zig` / `subprocess.zig` fork on `builtin.os.tag`, and Zig
    // only analyses the branch matching the TARGET — so running
    // `test:desktop-app` on Linux cannot see a type error in the Windows or
    // macOS paths. That hole shipped a real Windows-only compile error
    // (`MoveFileW` returns a typed BOOL enum; `!= 0` on it) which only CI's
    // Windows runner caught, 20 minutes in.
    //
    // This step compiles `cross_compile_check.zig` (an `export fn` that calls
    // those modules' public API) as an OBJECT for each target, forcing full
    // semantic analysis + codegen. Objects only — no linking, no SDK, no
    // webview/vcpkg deps — so it is cheap enough to run on every CI job.
    const check_desktop_cross = b.step(
        "check:desktop-cross",
        "Compile-check the desktop app's per-OS branches for Windows/macOS/Linux",
    );
    const cross_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    };
    for (cross_targets, 0..) |query, i| {
        const resolved = b.resolveTargetQuery(query);
        // A per-TARGET `helpers` module. Reusing the project-wide
        // `helpers_mod` here would be a host-target module inside a
        // foreign-target build, which makes Zig compile the host's
        // `std.os.<host>` against the foreign target and die on the calling
        // convention (observed on the Windows runner: `aarch64_aapcs_win` not
        // supported by compiler backend `stage2_llvm`, blamed on
        // helpers/mod.zig's `extern "kernel32" fn Sleep`). `src/helpers` is
        // self-contained (std + local files only), so a fresh module per
        // target is safe — and it lets the check cover subprocess.zig's
        // winsock branch too.
        const cross_helpers = b.createModule(.{
            .root_source_file = b.path("src/helpers/mod.zig"),
            .target = resolved,
            .optimize = optimize,
        });
        const obj = b.addObject(.{
            .name = b.fmt("desktop-cross-check-{d}", .{i}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/apps/desktop_app/cross_compile_check.zig"),
                .target = resolved,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "helpers", .module = cross_helpers },
                },
            }),
        });
        check_desktop_cross.dependOn(&obj.step);
    }

    // =====================================================================
    // CLI executable (`src/apps/cli/main.zig`) — wraps
    //   - POST  /api/llm/session
    //   - GET   /api/llm/session
    //   - GET   /api/llm/session/:id/messages
    //   - GET   /api/events?channels=...   (SSE)
    // via the project's `kabelweb` module (libcurl-backed,
    // cross-platform per the kabelweb repo docs).
    //
    // The CLI module is independent of `nalarcore`: it talks HTTP,
    // not SQLite, so importing `mod` would pull in the database +
    // SSE machinery we don't need. We build its executable directly
    // from `src/apps/cli/main.zig` and hand it the `kabelweb`
    // import that's already prepared above. The `libc` + `curl` link
    // flags ride along through `kabelweb_mod` itself.
    const cli_module = b.addModule("cli", .{
        .root_source_file = b.path("src/apps/cli/src/root.zig"),
        .target = target,
    });
    cli_module.addImport("kabelweb", kabelweb_mod);

    const cli_exe = b.addExecutable(.{
        .name = "nalarcli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cli", .module = cli_module },
                .{ .name = "kabelweb", .module = kabelweb_mod },
                .{ .name = "helpers", .module = helpers_mod },
            },
        }),
    });
    cli_exe.root_module.linkSystemLibrary("c", .{});
    cli_exe.root_module.link_libc = true;
    // Same linkPlatformDeps treatment as the main exe: on Linux
    // native builds, the linker needs `/usr/lib` on its search path
    // to find the system libcurl / libssl / libcrypto .so files
    // (the ones added by `kabelweb_mod` going system via
    // its probe). Without this, the CLI link fails with
    // "unable to find dynamic system library 'curl'" (same as the
    // main exe's pre-probe behavior). Vendored path didn't need this
    // because the static archive was embedded directly via
    // addObjectFile — no dynamic linker search required.
    linkPlatformDeps(b, cli_exe, target);
    // libcurl is linked via kabelweb_mod's transitive deps
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
    // libcurl is wired via kabelweb_mod's transitive deps.
    const cli_tests = b.addTest(.{ .root_module = cli_module });
    cli_tests.root_module.linkSystemLibrary("c", .{});
    cli_tests.root_module.link_libc = true;
    const test_cli = b.step("test:cli", "Run nalarcli unit tests");
    const run_cli_tests = b.addRunArtifact(cli_tests);
    // Windows: ensure vcpkg bin (libcurl.dll, …) is on PATH at test
    // runtime — see `prependVcpkgBinToPath` doc comment.
    prependVcpkgBinToPath(b, run_cli_tests);
    test_cli.dependOn(&run_cli_tests.step);

    // === nalarcli install-only (`zig build install:cli`) ===
    // Skips the full `build:all` dance — just installs the cli binary.
    const install_cli_step = b.step("install:cli", "Install the nalarcli binary only");
    install_cli_step.dependOn(&cli_install.step);

    // =====================================================================
    // TUI executable (`src/apps/cli/src/tui_main.zig`) — an interactive,
    // streaming, Claude-Code-style chat client over the same backend
    // endpoints as `nalarcli`. Powered by the from-scratch `tui` module
    // (Bubble-Tea-style Model/update/view architecture) that lives at
    // `src/apps/cli/src/tui/`. Same libcurl transport via
    // `kabelweb_mod`; no new dependencies.
    const tui_module = b.addModule("tui", .{
        .root_source_file = b.path("src/apps/cli/src/tui/root.zig"),
        .target = target,
    });
    tui_module.addImport("kabelweb", kabelweb_mod);
    // Let the app model reach the transport helpers through the same
    // import surface used by nalarcli.
    tui_module.addImport("cli", cli_module);

    const tui_exe = b.addExecutable(.{
        .name = "nalar-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/cli/src/tui_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tui", .module = tui_module },
                .{ .name = "cli", .module = cli_module },
                .{ .name = "kabelweb", .module = kabelweb_mod },
                .{ .name = "helpers", .module = helpers_mod },
            },
        }),
    });
    tui_exe.root_module.linkSystemLibrary("c", .{});
    tui_exe.root_module.link_libc = true;
    linkPlatformDeps(b, tui_exe, target);
    const tui_install = b.addInstallArtifact(tui_exe, .{});

    const run_tui_step = b.step("run:tui", "Run the interactive chat TUI");
    const run_tui_cmd = b.addRunArtifact(tui_exe);
    run_tui_step.dependOn(&run_tui_cmd.step);
    run_tui_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tui_cmd.addArgs(args);

    // === nalar-tui unit tests (`zig build test:tui`) ===
    // The tui module re-exports its test files via `tui/root.zig`, so a
    // single addTest on the module picks up every test in the tree.
    const tui_tests = b.addTest(.{ .root_module = tui_module });
    tui_tests.root_module.linkSystemLibrary("c", .{});
    tui_tests.root_module.link_libc = true;
    const test_tui = b.step("test:tui", "Run nalar-tui unit tests");
    const run_tui_tests = b.addRunArtifact(tui_tests);
    test_tui.dependOn(&run_tui_tests.step);

    // === nalar-tui install-only (`zig build install:tui`) ===
    const install_tui_step = b.step("install:tui", "Install the nalar-tui binary only");
    install_tui_step.dependOn(&tui_install.step);

    // === nalar-tui user-local install (`zig build install-tui`) ===
    // Builds nalar-tui and copies it to the per-user bin directory:
    //   Linux:   $HOME/.local/bin/nalar-tui
    //   macOS:   $HOME/.local/bin/nalar-tui
    //   Windows: %LOCALAPPDATA%\nalar\bin\nalar-tui.exe
    //            (fallback: %APPDATA%, %USERPROFILE%, $HOME)
    // The copy is done by a small Zig helper (tools/install_tui.zig) so it
    // works without shell dependencies (no `cp`, no `sh`).
    const install_tui_tool = b.addExecutable(.{
        .name = "install_tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/install_tui.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });
    const install_tui_run = b.addRunArtifact(install_tui_tool);
    const tui_bin_name = if (b.graph.host.result.os.tag == .windows) "nalar-tui.exe" else "nalar-tui";
    install_tui_run.addArg(b.pathJoin(&.{ b.install_path, "bin", tui_bin_name }));
    install_tui_run.step.dependOn(&tui_install.step);

    const install_tui_user_step = b.step("install-tui", "Build nalar-tui and install to user bin (~/.local/bin on Linux/macOS, %LOCALAPPDATA%\\nalar\\bin on Windows)");
    install_tui_user_step.dependOn(&install_tui_run.step);

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
    // for `@cImport("sqlite3.h")` in the ruangsql package's
    // src/sqlite/Sqlite.zig — without an include path, the cimport fails with "'sqlite3.h' not
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
    // NO LONGER on `mod` — they live in the ruangsql package's build.zig
    // and propagate to `mod` via the `databases` module's addImport graph.
    // Adding them here would re-leak Linux native system libs into every
    // Compile that imports `mod` (including cross-compile artifacts) —
    // the exact bug the per-Compile linkPlatformDeps pattern was designed
    // to prevent.

    // Tests need a SEPARATE module (not `mod`) so we can attach native
    // platform deps without polluting `mod` for cross-compile consumers.
    // The test module does self-import ("nalarcore" → itself) the same
    // way `mod` does, and imports kabelweb from the shared
    // module so test code can use the HTTP client.
    const test_target = target; // tests always run on the native host
    const mod_tests_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = test_target,
        .optimize = optimize,
    });
    mod_tests_module.addImport("nalarcore", mod_tests_module);
    mod_tests_module.addImport("kabelweb", kabelweb_mod);
    mod_tests_module.addImport("helpers", helpers_mod);
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
    // — libcurl is fully wired via kabelweb_mod's transitive
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
        // Vendored Lua for hooks tests (same sources as `mod` above;
        // this is a separate root module so it needs its own attach).
        linkVendoredLua(b, mod_tests_module);
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
    // Windows: ensure vcpkg bin (libcurl.dll, sqlite3.dll, libssl-3-x64.dll,
    // libcrypto-3-x64.dll, libpq.dll, …) is on PATH at test runtime —
    // see `prependVcpkgBinToPath` doc comment. Without this the test
    // process aborts with STATUS_ENTRYPOINT_NOT_FOUND (0xC0000139)
    // before main() runs.
    prependVcpkgBinToPath(b, run_mod_tests);

    const test_step = b.step("test", "Run tests");
    // sqlite3 comes from the external `databases` package (ruangsql) via
    // the module graph — no in-tree fetch step needed. (libcurl likewise:
    // kabelweb is an external URL dependency now — its own package + CI
    // own the vendored curl archive, and nalar builds link system
    // curl/ssl/crypto via the module graph. See the kabelweb repo.)
    test_step.dependOn(&run_mod_tests.step);

    // kabelweb's own suites (server + client) run in the kabelweb
    // repo's CI (github.com/ginwa123/kabelweb), not here — it's an
    // external URL dependency, and a consumer build never runs a
    // dependency's test blocks.

    const ai_workflow_tui_test_mod = b.addTest(.{
        .root_module = mod_tests_module,
    });

    const run_ai_workflow_tui_tests = b.addRunArtifact(ai_workflow_tui_test_mod);
    // Windows: ensure vcpkg bin (libcurl.dll, sqlite3.dll, …) is on
    // PATH at test runtime — see `prependVcpkgBinToPath` doc comment.
    prependVcpkgBinToPath(b, run_ai_workflow_tui_tests);
    const test_ai_workflow_tui_step = b.step("test:ai_workflow:tui", "Run AI workflow TUI tests");
    // The TUI test reuses `mod_tests_module` (which transitively imports
    // the external `databases` package) — no fetch wiring needed.
    test_ai_workflow_tui_step.dependOn(&run_ai_workflow_tui_tests.step);

    const linux_step = b.step("install:linux", "Build for Linux x86_64");
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
        .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 },
    });
    const linux_exe = createPlatformExe(b, mod, helpers_mod, linux_target, optimize, "nalarcore-linux-x86_64");
    linux_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    // libcurl is linked via kabelweb_mod's transitive deps
    // (the vendored prebuilt archive is added in the package's own
    // build.zig). No need to call linkSystemLibrary("curl", ...) or
    // linkCurlIncludePath here — the module graph handles it.
    linux_exe.root_module.link_libc = true;
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
    const windows_exe = createPlatformExe(b, mod, helpers_mod, windows_target, optimize, "nalarcore-windows-x86_64");
    // libcurl is linked via kabelweb_mod's transitive deps (kabelweb
    // package owns its Windows/vcpkg wiring).
    windows_exe.root_module.link_libc = true;
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
    const macos_exe = createPlatformExe(b, mod, helpers_mod, macos_target, optimize, "nalarcore-macos-x86_64");
    // libcurl is linked via kabelweb_mod's transitive deps.
    macos_exe.root_module.link_libc = true;
    const install_macos = b.addInstallArtifact(macos_exe, .{});
    macos_step.dependOn(&install_macos.step);

    const macos_arm_step = b.step("install:macos-arm", "Build for macOS aarch64 (Apple Silicon)");
    const macos_arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    const macos_arm_exe = createPlatformExe(b, mod, helpers_mod, macos_arm_target, optimize, "nalarcore-macos-aarch64");
    // libcurl is linked via kabelweb_mod's transitive deps.
    macos_arm_exe.root_module.link_libc = true;
    const install_macos_arm = b.addInstallArtifact(macos_arm_exe, .{});
    macos_arm_step.dependOn(&install_macos_arm.step);
    _ = is_native_macos;

    const linux_system_step = b.step("install:linux:system", "Build for Linux x86_64 and install to system");
    const linux_system_exe = createPlatformExe(b, mod, helpers_mod, target, optimize, "nalar");
    linux_system_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    linux_system_exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    // libcurl is linked via kabelweb_mod's transitive deps.
    linux_system_exe.root_module.link_libc = true;
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

    // =====================================================================
    // install:linux:app — Linux desktop launcher entry (GNOME/KDE search)
    //
    // `zig build nalar-desktop` only drops `zig-out/bin/nalar-desktop`,
    // which the launcher never indexes. The freedesktop launcher only
    // searches `*.desktop` files under `/usr/share/applications` (system)
    // or `~/.local/share/applications` (user). This step installs the
    // system-wide entry so Super-key search finds Nalar:
    //
    //   zig-out/bin/nalar-desktop        → /usr/local/bin/nalar-desktop
    //   zig-out/bin/nalar (service)      → /usr/local/bin/nalar
    //   packaging/linux/nalar.desktop    → /usr/share/applications/nalar.desktop
    //   packaging/linux/nalar-browser.desktop → /usr/share/applications/nalar-browser.desktop
    //   src/apps/desktop/public/favicon.ico → /usr/share/pixmaps/nalar.ico
    //
    // The service copy is REQUIRED, not optional: the desktop resolves
    // its backend as `--nalar-path` → next-to-self → $PATH
    // (src/apps/desktop_app/attach.zig). Without /usr/local/bin/nalar,
    // next-to-self misses, $PATH misses, auto-spawn returns
    // NalarNotFound to stderr (invisible from a launcher click — "nothing
    // happens"), and only a manually pre-started `nalar service` lets the
    // desktop attach. Installing both side-by-side restores one-click launch.
    //
    // Requires sudo (same as `install:linux:system` which writes to
    // /usr/local/bin): `sudo zig build install:linux:app`.
    // Database/icon-cache refreshes are best-effort (`|| true`) so a box
    // without `update-desktop-database` still succeeds — the entry
    // appears after next login regardless. The Quickshell `qs-glauncher`
    // daemon (if running) scans .desktop files once at startup and serves
    // every popup query from that warm cache, so a newly installed entry
    // is invisible until it restarts — `pkill -x qs-glauncher || true`
    // asks shell.qml's crash-only restart timer (1s) to respawn it fresh.
    // Non-Quickshell boxes don't have the process; the `|| true` no-ops.
    // =====================================================================
    const linux_app_step = b.step("install:linux:app", "Build nalar-desktop and install launcher entry so it appears in GNOME/KDE search (requires sudo)");
    linux_app_step.dependOn(&desktop_install.step);
    linux_app_step.dependOn(b.getInstallStep());
    const copy_desktop_bin = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/nalar-desktop",
        "/usr/local/bin/nalar-desktop",
    });
    copy_desktop_bin.step.dependOn(&desktop_install.step);
    linux_app_step.dependOn(&copy_desktop_bin.step);
    const copy_nalar_svc = b.addSystemCommand(&.{
        "cp",
        "zig-out/bin/nalar",
        "/usr/local/bin/nalar",
    });
    copy_nalar_svc.step.dependOn(b.getInstallStep());
    linux_app_step.dependOn(&copy_nalar_svc.step);
    const install_desktop_file = b.addSystemCommand(&.{
        "/bin/sh", "-c",
        "mkdir -p /usr/share/applications && cp packaging/linux/nalar.desktop /usr/share/applications/nalar.desktop && chmod 644 /usr/share/applications/nalar.desktop && cp packaging/linux/nalar-browser.desktop /usr/share/applications/nalar-browser.desktop && chmod 644 /usr/share/applications/nalar-browser.desktop",
    });
    install_desktop_file.step.dependOn(&copy_desktop_bin.step);
    install_desktop_file.step.dependOn(&copy_nalar_svc.step);
    linux_app_step.dependOn(&install_desktop_file.step);
    const install_desktop_icon = b.addSystemCommand(&.{
        "/bin/sh", "-c",
        "mkdir -p /usr/share/pixmaps && cp src/apps/desktop/public/favicon.ico /usr/share/pixmaps/nalar.ico && chmod 644 /usr/share/pixmaps/nalar.ico",
    });
    install_desktop_icon.step.dependOn(&install_desktop_file.step);
    linux_app_step.dependOn(&install_desktop_icon.step);
    const refresh_desktop_db = b.addSystemCommand(&.{
        "/bin/sh", "-c",
        "update-desktop-database /usr/share/applications || true; gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true; pkill -x qs-glauncher || true",
    });
    refresh_desktop_db.step.dependOn(&install_desktop_icon.step);
    linux_app_step.dependOn(&refresh_desktop_db.step);

    // =====================================================================
    // install:windows:app — Windows user-local app install (Start Menu search)
    //
    // Windows-only (invoking on Linux/macOS fails at the powershell spawn
    // with a clear error — the step still configures cleanly everywhere).
    // Builds both binaries, then runs packaging/windows/Install-Nalar.ps1
    // with -SourceDir zig-out/bin. The script copies
    // nalar-desktop.exe + nalar.exe + *.dll (vcpkg runtimes +
    // WebView2Loader.dll via installVcpkgDlls) to %LOCALAPPDATA%\nalar\bin
    // and creates Nalar.lnk in the per-user Start Menu — Win-key search
    // finds it. All user-local: no Program Files, no HKLM, no admin.
    //
    // The service exe ships alongside for the same reason as Linux (see
    // above): the desktop auto-spawns `nalar.exe` next to itself, and a
    // lone desktop exe silently fails to start its backend.
    // =====================================================================
    const windows_app_step = b.step("install:windows:app", "Build nalar-desktop + service and install user-local with Start Menu shortcut (Windows-only, no admin)");
    windows_app_step.dependOn(&desktop_install.step);
    windows_app_step.dependOn(b.getInstallStep());
    const run_windows_app_install = b.addSystemCommand(&.{
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "packaging/windows/Install-Nalar.ps1",
        "-SourceDir", "zig-out/bin",
    });
    run_windows_app_install.step.dependOn(&desktop_install.step);
    run_windows_app_install.step.dependOn(b.getInstallStep());
    windows_app_step.dependOn(&run_windows_app_install.step);

    // =====================================================================
    // install:macos:app — macOS user-local app install (Spotlight/Launchpad)
    //
    // macOS-only at runtime (invoking on Linux/Windows fails at the sh
    // spawn with a clear error — the step still configures cleanly
    // everywhere). Builds both binaries, then runs
    // packaging/macos/install-nalar-app.sh with zig-out/bin: assembles
    // ~/Applications/Nalar.app (Contents/MacOS/{nalar-desktop,nalar} +
    // Info.plist), clears quarantine and ad-hoc signs (best-effort).
    // All user-local: never /Applications, no sudo. Spotlight indexes
    // ~/Applications, so Win-key-equivalent (Cmd+Space) finds "Nalar".
    //
    // The service binary ships inside the bundle for the same reason as
    // Linux/Windows (see above): the desktop auto-spawns `nalar` next to
    // itself, and a lone desktop binary silently fails its backend.
    // No custom icon in v1 (only favicon.ico exists; .icns needs macOS
    // iconutil) — the bundle still indexes by name.
    // =====================================================================
    const macos_app_step = b.step("install:macos:app", "Build nalar-desktop + service and install Nalar.app to ~/Applications (macOS-only, no sudo)");
    macos_app_step.dependOn(&desktop_install.step);
    macos_app_step.dependOn(b.getInstallStep());
    const run_macos_app_install = b.addSystemCommand(&.{
        "/bin/sh", "packaging/macos/install-nalar-app.sh", "zig-out/bin",
    });
    run_macos_app_install.step.dependOn(&desktop_install.step);
    run_macos_app_install.step.dependOn(b.getInstallStep());
    macos_app_step.dependOn(&run_macos_app_install.step);

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
                .{ .name = "helpers", .module = helpers_mod },
            },
        }),
    });
    dev_exe.root_module.linkSystemLibrary("c", .{});
    // libcurl is linked via kabelweb_mod's transitive deps.
    dev_exe.root_module.link_libc = true;
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
    // Venv location override (2026-08-25): CI relocates the venv OUTSIDE
    // the workspace via NALAR_FUNC_VENV_DIR because self-hosted runners
    // `git clean` the workspace between runs — a workspace-relative
    // .venv-func is recreated + pip-installed from scratch on every run.
    // Pointing it at ~/.cache/nalar-ci-venv lets actions/cache persist it.
    // Unset (the default) keeps the historical `.venv-func` behavior for
    // local developers. NOTE: this must be read at CONFIG time so the
    // literal path can be baked into the addSystemCommand argv below.
    const venv_dir_raw = b.graph.environ_map.get("NALAR_FUNC_VENV_DIR") orelse ".venv-func";
    // Normalize Windows mixed separators (runner.temp is C:\...\ _temp + "/nalar-ci-venv" → "C:\...\ _temp/nalar-ci-venv").
    // Use forward slashes internally; Python on Windows handles both.
    const venv_dir = blk: {
        const dup = b.allocator.dupe(u8, venv_dir_raw) catch unreachable;
        for (dup) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        break :blk dup;
    };
    const is_windows_host = b.graph.host.result.os.tag == .windows;
    const venv_bin = if (is_windows_host)
        std.fmt.allocPrint(b.allocator, "{s}/Scripts", .{venv_dir}) catch unreachable
    else
        std.fmt.allocPrint(b.allocator, "{s}/bin", .{venv_dir}) catch unreachable;
    // On Windows, `python` is the canonical exe; `python3` is often a shim.
    const default_python = if (is_windows_host) "python" else "python3";
    const effective_python = if (std.mem.eql(u8, python_exe, "python3") and is_windows_host) default_python else python_exe;
    // Windows venv creation must survive the Microsoft Store `python`
    // stub ("Python was not found") and must not redo an existing venv:
    //   1. If the venv interpreter already exists, the step is a no-op
    //      (`pip install -r` below still runs every time).
    //   2. Else pick an interpreter at config time: explicit `-Dpython`
    //      wins; otherwise scan PATH for python.exe/python3.exe
    //      (skipping 0-byte Store stubs), then the `py` launcher.
    //      Nothing found → bare `python` (loud Store-stub failure, same
    //      as before this change).
    // Everything is direct argv (no cmd.exe shell), so paths with
    // spaces work and there is no shell-quoting to get wrong.
    const venv_python_name = if (is_windows_host) "python.exe" else "python";
    const venv_python_rel = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ venv_bin, venv_python_name }) catch unreachable;
    const have_venv = blk: {
        _ = std.Io.Dir.cwd().statFile(b.graph.io, venv_python_rel, .{}) catch break :blk false;
        break :blk true;
    };
    const install_venv = blk: {
        if (have_venv) {
            if (is_windows_host) break :blk b.addSystemCommand(&.{ "cmd.exe", "/c", "exit", "0" });
            break :blk b.addSystemCommand(&.{"true"});
        }
        if (!is_windows_host) break :blk b.addSystemCommand(&.{
            effective_python, "-m", "venv", venv_dir,
        });
        var chosen: ?[]const u8 = null;
        var chosen_args: []const []const u8 = &.{};
        if (!std.mem.eql(u8, python_exe, "python3")) {
            chosen = python_exe; // explicit -Dpython: trust it (old behavior)
        } else if (b.graph.environ_map.get("PATH")) |path_var| {
            var it = std.mem.splitScalar(u8, path_var, ';');
            const probes = [_][]const u8{ "python.exe", "python3.exe", "py.exe" };
            outer: while (it.next()) |dir| {
                if (dir.len == 0) continue;
                for (probes) |name| {
                    const cand = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ dir, name }) catch unreachable;
                    // Absolute sub_path: the cwd handle is ignored.
                    const st = std.Io.Dir.cwd().statFile(b.graph.io, cand, .{}) catch continue;
                    if (st.size == 0) continue; // Microsoft Store stub
                    chosen = cand;
                    if (std.mem.eql(u8, name, "py.exe")) chosen_args = &.{"-3"};
                    break :outer;
                }
            }
        }
        var argv: std.ArrayList([]const u8) = .empty;
        argv.append(b.allocator, chosen orelse "python") catch unreachable;
        argv.appendSlice(b.allocator, chosen_args) catch unreachable;
        argv.appendSlice(b.allocator, &.{ "-m", "venv", venv_dir }) catch unreachable;
        break :blk b.addSystemCommand(argv.items);
    };
    install_venv.setCwd(b.path(""));

    const pip_exe = if (is_windows_host) "pip.exe" else "pip";
    const install_requirements = b.addSystemCommand(&.{
        b.fmt("{s}/{s}", .{ venv_bin, pip_exe }), "install", "-q", "-r", "tests/functional/requirements.txt",
    });
    install_requirements.setCwd(b.path(""));
    install_requirements.step.dependOn(&install_venv.step);

    // Probe python — skip the step if missing. Without a probe,
    // `addSystemCommand` would error at config time on hosts that don't have python.
    //
    // Shell selection (cross-platform fix): use cmd.exe with `where` on
    // Windows (the previous `sh -c` failed because Git for Windows
    // doesn't add its bin/ to PATH automatically). Check both `python`
    // and `python3` on Windows.
    const python_probe = b.addSystemCommand(switch (b.graph.host.result.os.tag) {
        .windows => &.{
            "cmd.exe", "/c",
            \\@where python >nul 2>&1 || @where python3 >nul 2>&1 || echo zig build functional-test: python not found, skipping (install Python from python.org or set -Dpython=...)
        },
        else => &.{
            "sh", "-c",
            \\command -v python3 >/dev/null 2>&1 || { echo 'zig build functional-test: python3 not found, skipping (install with `brew install python@3.11` or set -Dpython=...)'; exit 0; }
        },
    });
    python_probe.setCwd(b.path(""));

    const python_venv_exe = if (is_windows_host) "python.exe" else "python";
    const run_functional = b.addSystemCommand(&.{
        b.fmt("{s}/{s}", .{ venv_bin, python_venv_exe }), "-m", "pytest", "tests/functional/", "-v", "--tb=short",
    });
    run_functional.setCwd(b.path(""));
    run_functional.step.dependOn(&install_requirements.step);
    run_functional.step.dependOn(&python_probe.step);
    // Depend on the top-level `install` step (copies binary to
    // zig-out/bin/nalar) rather than `install:linux:system` which
    // additionally tries to `cp` to /usr/local/bin/nalar and fails
    // on systems without write perms to /usr/local.
    run_functional.step.dependOn(b.getInstallStep());
    // Depend on the mcp-http-hello-world build step so the HTTP
    // test server is at zig-out/bin/mcp-http-hello-world when the
    // functional tests run. Without this, mcp_http_test.py fails
    // to spawn the binary. (The mcp-hello-world stdio fixture is
    // already in the default install via line ~1116.)
    run_functional.step.dependOn(mcp_http_hello_world_step);

    const functional_test_step = b.step("functional-test", "Run functional tests against a real nalar with isolated tmpdir data");
    functional_test_step.dependOn(&run_functional.step);

    // =====================================================================
    // Functional UI tests (Python+Playwright) — see tests/functional_ui/README.md.
    //
    // Boots a real nalar backend + Vite dev server against isolated
    // tempdirs, then drives the running web app with Playwright Python.
    // Inherits isolation guarantees from the API-only functional suite
    // (``is_safe_tmp``, captured ``temp_dir``, ``ORIG_HOME`` snapshot).
    //
    // Dependencies:
    //   1. install:linux:system  — produces zig-out/bin/nalar
    //   2. python3 venv at .venv-func — installs requirements.txt + playwright
    //   3. playwright install chromium — one-time browser download (~150 MB)
    //
    // Skips silently if `python3` is missing on PATH. The chromium
    // download is also a probe-based step: if it fails (e.g. no
    // internet), the suite still tries to run and skips per-test on
    // missing browser.
    // =====================================================================
    const install_ui_requirements = b.addSystemCommand(&.{
        b.fmt("{s}/{s}", .{ venv_bin, pip_exe }), "install", "-q", "-r", "tests/functional_ui/requirements.txt",
    });
    install_ui_requirements.setCwd(b.path(""));
    install_ui_requirements.step.dependOn(&install_requirements.step);

    // Install Playwright Chromium browser. ``playwright install chromium``
    // is idempotent — re-running it is a no-op if the browser is already
    // cached. We run it as a separate step so CI logs surface the
    // ~150 MB download progress.
    const install_playwright_browsers = b.addSystemCommand(&.{
        b.fmt("{s}/{s}", .{ venv_bin, python_venv_exe }), "-m", "playwright", "install", "chromium",
    });
    install_playwright_browsers.setCwd(b.path(""));
    install_playwright_browsers.step.dependOn(&install_ui_requirements.step);

    const run_functional_ui = b.addSystemCommand(&.{
        b.fmt("{s}/{s}", .{ venv_bin, python_venv_exe }), "-m", "pytest", "tests/functional_ui/", "-v", "--tb=short",
    });
    run_functional_ui.setCwd(b.path(""));
    run_functional_ui.step.dependOn(&install_playwright_browsers.step);
    run_functional_ui.step.dependOn(&python_probe.step);
    // Depend on the same binary install as the API suite.
    run_functional_ui.step.dependOn(b.getInstallStep());

    const functional_test_ui_step = b.step("functional-test-ui", "Run UI functional tests (Playwright Python) against nalar + Vite dev server");
    functional_test_ui_step.dependOn(&run_functional_ui.step);

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
    //
    // Cross-platform shell: Linux/macOS use `/bin/sh -c` (POSIX echo,
    // $D variable). Windows uses `cmd /c` with explicit `echo` lines
    // (no $D-variable interpolation; each line spells the directory
    // literally). Earlier revisions hardcoded `/bin/sh -c ...` which
    // failed silently on Windows dev boxes where `/bin/sh` doesn't
    // exist (Git for Windows ships bash at `C:\Program Files\Git\bin`
    // but the canonical `/bin/sh` path is on Cygwin / MSYS only).
    //
    // WORKAROUND: Zig 0.16 compiler bug — capturing the result of
    //   `const x = switch (rt) { .a => &.{...}, .b => &.{...} };`
    //   where each arm is an anonymous tuple with heterogeneous string
    //   lengths returns the FIRST arm's value regardless of which arm
    //   matched. We sidestep it with `if/else` + an explicit slice type.
    //   See plan `2026-08-22-fix-zig-0.16-switch-capture-bug.md` for the
    //   8-line repro. DO NOT REVERT TO `switch` — re-introduces the
    //   Windows `cmd.exe` spawn on Linux/macOS hosts.
    var banner_args: []const []const u8 = &.{};
    if (b.graph.host.result.os.tag == .windows) {
        const script = std.fmt.allocPrint(
            b.allocator,
            \\
            \\echo.
            \\echo [zig build success]
            \\echo.
            \\echo   nalar service binary  ---^> zig-out\\bin\\{s}
            \\echo   nalar desktop binary  ---^> zig-out\\bin\\{s}
            \\echo   nalarcli binary       ---^> zig-out\\bin\\{s}
            \\echo.
            \\echo   (If a binary is missing, run "rmdir /s /q zig-out && zig build"
            \\echo    to force a fresh install -- the cache sometimes hides
            \\echo    manual deletions.)
            \\echo.
            \\echo   Run with:  zig-out\\bin\\{s} service start --port 8080
            \\echo              zig-out\\bin\\{s} --devtools
            \\echo              zig-out\\bin\\{s} sessions list
            \\echo.
            \\
        ,
            .{
                host_binary_name,
                desktop_binary_name,
                cli_binary_name,
                host_binary_name,
                desktop_binary_name,
                cli_binary_name,
            },
        ) catch @panic("OOM allocating Windows build banner");
        banner_args = &.{ "cmd.exe", "/c", script };
    } else {
        const script = std.fmt.allocPrint(
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
        ) catch @panic("OOM allocating POSIX build banner");
        banner_args = &.{ "/bin/sh", "-c", script };
    }

    const build_banner = b.addSystemCommand(banner_args);
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
    // nalar-tui is POSIX-only: src/apps/cli/src/tui/terminal.zig passes
    // integer fds (std.posix.STDIN_FILENO) where Windows' fd_t is
    // *anyopaque, so it cannot compile on Windows. Skip it in
    // `build:all` there so `zig build` stays green; explicit
    // `zig build install:tui` still attempts the build (and fails the
    // same way) until the TUI is ported.
    if (b.graph.host.result.os.tag != .windows) {
        build_all_step.dependOn(&tui_install.step);
    }
    build_all_step.dependOn(&build_banner.step);
    // Make `zig build` (default) auto-fetch the vendored curl archive
    // when missing. The fetch script is idempotent — re-running on a
    // populated vendor/ is a fast no-op.

    // Default: same as `build:all`. Without this, `zig build` (no args)
    // runs the `install` step alone, which prints no summary on success.
    // Zig 0.16's `Build.default_step: *Step` — `b.step()` already
    // returns `*Step`, so we assign the pointer directly.
    b.default_step = build_all_step;
}
