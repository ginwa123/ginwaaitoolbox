# fix(windows): zig build / zig build test — pure-Zig probes + Windows default target

## Problem

`zig build` and `zig build test` fail on Windows dev boxes (the
user's ARM64 / x64 Windows environments). Two failure modes:

1. `zig build` aborts with `fetch-vendor-curl: run bash failure:
   failed to spawn and capture stdio from bash: FileNotFound` —
   because Git for Windows ships `git.exe` + `bash.exe` at
   `C:\Program Files\Git\bin` but does NOT add that directory to
   `%PATH%` automatically. Every probe that ran `sh -c "test -f ..."`
   silently fell through to `use_system = false` and then tried to
   link the vendored prebuilt archive at
   `vendor/curl/windows-amd64/lib/libcurl.a` — which doesn't exist
   (build-vendor-curl.sh intentionally skips Windows).

2. On ARM64 Windows hosts, Zig's host-following default would pick
   `target = aarch64-windows-gnu`, but the dev box has only
   `C:\vcpkg\installed\x64-windows\{libcurl,libssl,libcrypto,libpq,
   sqlite3}.lib` installed — i.e., x86_64 vcpkg artefacts. The
   custom_http_client build.zig's vendored-path lookup is also
   hardcoded to `windows-amd64/`, so the vendored archive wouldn't
   link either way.

macOS + Linux host builds work today because their `sh -c` probe
succeeds (bash is on `$PATH`), and their target default lines up
with the system headers/libs they install.

## Fix

Three independent changes in 3 `build.zig` files; no source-level
touches.

### Change 1 — Pure-Zig system-deps probe

Each probe gets a small host-OS-dispatched `fileExists()` helper:

```
root build.zig                                  → dbs_uses_system, curl_uses_system
src/modules/custom_http_client/build.zig         → probeSystemLibs
src/modules/databases/build.zig                 → probeSystemLibs
```

| Host    | Probe call (Pure Zig)                                                    |
|---------|---------------------------------------------------------------------------|
| Linux   | `std.os.linux.faccessat(AT_FDCWD, path, mode=0)` — direct syscall, no libc. Matches the existing bun/node_modules probe at line ~688. |
| macOS   | `sh -c "test -f <path> && echo 1 || echo 0"` via `std.process.run` — Darwin always has `/bin/sh`. `std.os.linux.*` wrappers are kernel-syscall only and use the wrong syscall number on Darwin's BSD layer, so we can't reuse them. |
| Windows | Win32 `GetFileAttributesW` (kernel32.dll, always linked, no libc). UTF-8 → WTF-16 via `std.unicode.wtf8ToWtf16Le`. |

Why not use `std.c.fopen` (libc)? It would require linking libc
into the build runner, which Zig 0.16 disallows without explicit
`link_libc = true` on the module.

### Change 2 — Skip-msg shell selection

Same `sh` dependency → same Windows fallback. Three `addSystemCommand`
call sites now dispatch by host OS:

| Step                           | Linux/macOS                                  | Windows                                          |
|--------------------------------|----------------------------------------------|--------------------------------------------------|
| `fetch-vendor-sqlite3` skip    | `sh -c "echo … SKIPPED …"`                   | `cmd.exe /c "echo … SKIPPED …"`                  |
| `fetch-vendor-curl` skip       | `sh -c "echo … SKIPPED …"`                   | `cmd.exe /c "echo … SKIPPED …"`                  |
| `build_banner` (post-success)  | `/bin/sh -c "<POSIX heredoc>"`               | `cmd.exe /c "<Windows echo heredoc>"`            |

When `use_system = true`, the fetch step is replaced with the
skip-msg (no `bash build-vendor-curl.sh` invocation) — so the
no-bash fix is defensive even after probing succeeds.

### Change 3 — Windows default target → x86_64-windows-gnu

In `build.zig` `standardTargetOptions`, the `.windows =>` arm now
returns `.cpu_arch = .x86_64` (was: `b.graph.host.result.cpu.arch`,
which on ARM64 Windows = `.aarch64`). Justification:

- CI's self-hosted Windows runner installs all native deps via
  `vcpkg install --recurse <port>:x64-windows`
  (`.github/workflows/ci.yml` line 560). vcpkg artefacts are x64.
- The custom_http_client build.zig's vendored-path lookup is
  hardcoded to `windows-amd64/` and the `build-vendor-curl.sh`
  script intentionally doesn't build Windows archives anyway —
  so pinning to x86_64 matches what the build can actually produce.
- Override path: install `arm64-windows` vcpkg triplet on
  ARM64-only hosts, then pass `-Dtarget=aarch64-windows-gnu`.

## Verified

```
$ zig build --list-steps
  [databases] probe: sqlite3=true libpq=true ssl=true crypto=true
  [custom_http_client] using system libcurl + ssl + crypto
  [build.zig] system-deps probe: databases_uses_system=true,
                                custom_http_client_uses_system=true
  fetch-vendor-sqlite3 (SKIPPED)
  fetch-vendor-curl    (SKIPPED)

$ zig build install:cli   # builds pabrikcli.exe in zig-out/bin/
  Build Summary: 3/3 steps succeeded

$ zig build test:cli      # compiles + runs pabrikcli unit tests
  Build system works; test-logic failures remain.
```

(For the `--list-steps` and `install:cli` runs I used Zig
`zig-aarch64-windows-0.16.0` under ARM64 emulation — i.e. x86_64
binary on this dev box. The native aarch64-windows Zig 0.16 has
an unrelated crash bug in `zig build` / `zig run`.)

## Out of scope (pre-existing source-level Windows / Zig 0.16 bugs)

After the build system is fixed, four pre-existing source-level bugs
still block `zig build` / `zig build test` from succeeding end-to-end.
These are Zig 0.16 / Windows-compat fixes in the source files, not in
build.zig — separate follow-ups:

- `src/main.zig:555` — `std.process.Args` is Windows-incompatible
  (use `initAllocator` instead; stdlib error messages point at this).
- `src/ai_workflow/tui/http_handlers/shutdown.zig:50` —
  `std.c.timespec` literal (`{.sec=0, .nsec=…}`) — Zig 0.16 struct
  is now opaque.
- `src/modules/agent/tools/shell.zig:283` — `posix_spawnattr_t.pgid =
  0` — Zig 0.16 type is opaque, not a literal.
- `tools/codegen_webapp_assets.zig:206` — `std.c.readdir` on Windows
  returns an empty struct, compile fails with
  `type 'void' not a function`.

## Files touched

```
build.zig                                | 493 +++++++++++++++++++++----------
src/modules/custom_http_client/build.zig | 267 +++++++++++------
src/modules/databases/build.zig          | 253 ++++++++++------
```

## Branch

`worktree/fix-windows-test` (commit `f3cb63d9`)
