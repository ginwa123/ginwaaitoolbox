# nalar — Cross-Compile Build Steps Are Blocked by Pre-Existing Issues

The `zig build install:windows`, `zig build install:macos`, and `zig build install:macos-arm` steps in this project's `build.zig` **cannot produce binaries** on a Linux host. This is a pre-existing issue, not a code bug.

## Symptom

All three cross-compile targets fail with the same error:

```
error: unable to find dynamic system library 'sqlite3' using strategy 'paths_first'. searched paths: none
       error: unable to find dynamic system library 'ssl' using strategy 'paths_first'. searched paths: none
       error: unable to find dynamic system library 'crypto' using strategy 'paths_first'. searched paths: none
```

`zig-out/bin/` is empty. The exit code is 1 (or 0 with the wrapper `--listen=-` quirk — check by running the actual `zig build-exe` command).

## Root Cause 1 — `build.zig` lacks cross-target library paths

`build.zig`'s `install:linux` step (around line 105) sets the Linux system library path:

```zig
linux_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
linux_exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
```

The `install:windows`, `install:macos`, `install:macos-arm` steps (lines 110-136) **do NOT** set any library path. The `linkSystemLibrary("sqlite3"/"ssl"/"crypto"/"c")` calls in `createPlatformExe` (line 3-24) then fail at config time because Zig searches `none` paths.

## Root Cause 2 — `bash_selfkill.zig` is not Windows-compatible

`src/modules/agent/tools/bash_selfkill.zig:8` declares:

```zig
pub fn get_self_pid() std.c.pid_t {
    return process.getCurrentProcessId();
}
```

On Linux/macOS, `std.c.pid_t` is `i32`. On Windows, `std.c.pid_t` is `*anyopaque` (Windows doesn't have a real PID concept). Then line 72:

```zig
if (parsePid(after_signal)) |target_pid| {
    if (target_pid == self_pid) {  // i32 == *anyopaque → compile error on Windows
```

This produces `incompatible types: 'i32' and '*anyopaque'` when targeting Windows. The file is NOT in scope for the bash-cross-platform plan (which explicitly says "bash_selfkill.zig is unchanged from its current state"), so this will block Windows compile regardless of how `bash.zig` is fixed.

## Why "the build never gets to compile"

`linkSystemLibrary` does its library search at **build configuration time**, not at link time. If the library can't be found, the build step fails before the compile step is attempted. So even code with `std.posix` references (which would fail to compile for Windows) is masked by the earlier link error.

## Workaround (not in scope for typical tasks)

To make cross-compile work:

1. **Add `addLibraryPath` + `addIncludePath` for cross targets** in `build.zig`, pointing at Windows/macOS sysroots. Requires installing cross-compile SDKs (e.g. `mingw-w64` for Windows, `osxcross` for macOS) and Zig's `-fsys=` integration.
2. **Fix `bash_selfkill.zig`** to handle Windows `pid_t` type (probably needs conditional compilation on `builtin.os.tag`).
3. **Consider statically linking** the C libraries via Zig's libc + libsqlite3-via-zig (e.g. `mach` package for OpenSSL replacement, `sqlite-vfs` or vendored sqlite3).

## When this bites

- Any task whose plan says "verify cross-compile to Windows/macOS succeeds" — the build will fail regardless of the code being changed.
- The plan author may have assumed the build.zig works; it doesn't, on a vanilla Linux host.
- If asked to make `bash.zig` cross-platform, verify the fix via a standalone `zig build-exe target=x86_64-windows-gnu` on a small test file that exercises the same APIs (`std.process.spawn`, `std.Io.File.readStreaming`, `std.Io.sleep`, `std.atomic.Mutex`, `std.atomic.Value`, `std.Thread.spawn`). If that test compiles, your bash.zig changes are correct — the `install:windows` step's failure is a build config problem, not your code.

## How to verify

If a task says "verify cross-compile to X" and `install:X` fails with `unable to find dynamic system library`:

1. Run `git stash` and re-run `install:X`. If it fails the SAME way, it's pre-existing.
2. Confirm by writing a minimal test that imports your changed module, build it for the target with `zig build-exe -target=X -fno-emit-bin`, and check whether YOUR code compiles. If yes, your changes are correct.

This is exactly what happened during the `feature/bash-cross-platform` task — `bash.zig` was successfully verified to compile for Windows via standalone test, but the `install:windows` build step failed due to the `linkSystemLibrary` issue.
