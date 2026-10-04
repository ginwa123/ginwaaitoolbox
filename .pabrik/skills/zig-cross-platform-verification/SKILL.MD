---
name: zig-cross-platform-verification
description: "How to prove Zig code actually compiles for Linux + macOS + Windows from a Linux box — the compile-only cross-check, and the two traps that make a \"green\" check lie (unreachable code is never analysed; `builtin.os.tag` guards can disagree with the type the expression resolves against)."
---
---
name: zig-cross-platform-verification
description: How to prove Zig code actually compiles for Linux + macOS + Windows from a Linux box — the compile-only cross-check, and the two traps that make a "green" check lie (unreachable code is never analysed; `builtin.os.tag` guards can disagree with the type the expression resolves against).
tags: [zig, workflow, cross-platform, verification, environment]
---

## When to Use

Any change in this repo (or any Zig repo) that must build on more than one OS —
new modules, platform-specific syscalls/winsock, comptime OS gates, anything
touching socket, file or process APIs. Trigger phrases: "make sure it supports
mac/windows/linux", "cross-platform", before opening a PR that adds platform code.

## Context

* Zig 0.16 on Linux; macOS/Windows SDKs and their libraries are **not** available
  locally, so only the *compile/link-graph* can be verified, not the artifact.
* `std.posix` resolves to different types per target: on Linux `std.posix.TCP` is
  the Linux struct; on Darwin/Windows it is `std.c.TCP`, which may lack fields
  Linux has (e.g. `KEEPIDLE`).

## Procedure

1. **Subsystem-level compile check (fast, no SDK needed).** For a module with its
   own test aggregator:
   ```bash
   cd src/modules/<mod>
   for T in x86_64-linux-gnu x86_64-windows-gnu x86_64-macos aarch64-macos; do
     zig test -lc --test-no-exec -target "$T" src/test_runner.zig || echo "FAILED $T"
   done
   ```
   `--test-no-exec` compiles (analyses `test` blocks too) without running.
2. **App-level build for the real entry point.** The subsystem check does NOT
   cover code that only the application reaches:
   ```bash
   zig build install:windows  --summary all
   zig build install:macos-arm --summary all
   ```
   On a Linux host these normally **fail at the link step** (missing
   `sqlite3/ssl/crypto/curl` for the foreign target, or Apple "failed to parse TBD
   file"). That is expected. What matters is *which* step failed and *what* the
   diagnostics say.
3. **Classify the failure honestly.** Read the `--summary all` step tree:
   * `compile exe ... failure` + only library-lookup/TBD messages → code compiled,
     environment cannot link. Report it as such (do not claim "builds on macOS").
   * any `error:` pointing at a source file → a real portability bug; fix it.
4. **Guard platform-only APIs by DECL, not by `builtin.os.tag`:**
   ```zig
   if (@hasDecl(std.c.TCP, "KEEPIDLE")) {
       posix.setsockopt(fd, posix.IPPROTO.TCP, std.c.TCP.KEEPIDLE, std.mem.asBytes(&keepidle)) catch {};
   }
   ```
   `builtin.os.tag == .linux` is not reliable here: a cross-compile build graph can
   compile the same file for several targets in one invocation (the app module for
   the requested target, sibling modules for the host), so `builtin.os.tag` may
   disagree with the `std.c.*` type the expression actually resolves against.
5. Keep every foreign-platform branch in the file behind `comptime`/`@hasDecl`
   so it is compiled for the other targets (it will be analysed — that is the
   point) while never being emitted.

## Pitfalls

* **Unreachable code is never analysed.** `zig test --test-no-exec` only analyses
  what the test root can *reach*. A bug in `acceptClient`/`listen` — code no unit
  test calls — passes the subsystem check and only surfaces in step 2. Real
  example: an h2 integration was reported as "cross-compiles for macOS" while
  `install:macos-arm` failed on a Linux-only `TCP_KEEPIDLE` inside `acceptClient`.
  Always do both steps, and say which one proved what.
* **`-target` in a mixed build command.** `zig build-exe` lines in the log can
  contain several `-target` flags (one per module). Read the one attached to the
  module you care about before believing a failure is "for macOS".
* **Don't fingerprint your own work as pre-existing without checking.** Compare
  the failing line against `git show HEAD:<file>` and against your own diff
  (`git diff HEAD -- <file> | grep <symbol>`); line numbers shift, so match the
  code, not the number.
* Shell heredocs with backticks/quotes mangle easily in agent tooling — write long
  commit messages and PR bodies to a temp file and use `git commit -F` /
  `gh pr edit --body-file`.

## Verification

* `echo $?`‑style: every target in step 1 compiles with no `error:` lines, and the
  module's own test suite is green on the host (`zig build test --summary all`).
* For step 2, the summary line must show the failure confined to a link step, with
  zero source-line diagnostics.
* After fixing a platform bug, re-run step 1 for ALL targets — an `@hasDecl` gate
  that fixes Darwin can silently stop setting the option on Linux.

