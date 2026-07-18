# nalar — infrastructure, build, and CI patterns

This file consolidates nalar CI/CD pipeline facts and vendored-library patterns. For frontend build patterns, see `nalar-frontend-patterns.md`. For Zig build/test patterns, see `zig-build-and-test.md`.

---

## CI/CD pipeline facts (updated after PR #71)

The `.github/workflows/ci.yml` workflow is a self-hosted-only matrix (after PR #71).

- **Baseline (pre-CI)**: 873/876 Zig tests pass on Linux x86_64 (3 skipped — require external network/binary).
- **CI matrix** (after 2026-07-04 plan): 2 self-hosted cells — `[self-hosted, Linux, X64]` and `[self-hosted, macOS, ARM64]`. The `exclude:` block filters the 2×2 cross-product down to those 2 native-target cells. Per-cell bun install, webkit/macos system deps, artifact renamed `nalar-${matrix.target.zig}-<sha>` so each cell produces a distinct artifact.
- **Frontend job was removed 2026-07-04.** The standalone `frontend:` job is gone from ci.yml. The Vue webapp is now bundled into nalar-desktop via `zig build codegen:webapp-assets` on BOTH cells. Type-check (`vue-tsc`) runs as part of `bun run build`. The 8 pre-existing vitest failures across 4 files (KanbanView, chatViewShowPreviewBubble, previewSidePanel, DiffView) are NOT gated now.
- **Frontend lint is non-blocking**: uses raw `bunx oxlint .` and `bunx eslint . --cache` (without `--fix`) because `bun run lint` uses `--fix` which would corrupt the working tree.
- **macOS openssl**: keg-only, must explicitly export `PKG_CONFIG_PATH=$(brew --prefix openssl@3)/lib/pkgconfig` for Zig's `linkSystemLibrary("ssl")` to find it.
- **Bun cache key**: hashes `src/apps/desktop/bun.lock` (NOT `package-lock.json` — that file does not exist; project uses Bun's binary lockfile).

## macOS CI quirks

- **Mac runner = Apple Silicon (aarch64-macos).** The matrix cell uses `install:macos-arm` (NOT `install:macos`, which hardcodes `x86_64-macos` in build.zig:394 and produces an x86_64 binary the ARM64 runner rejects with "Bad CPU type in executable").
- **Mac GitHub Actions runner image doesn't ship pkg-config.** The `brew install pkg-config openssl@3` line is needed for the "Show toolchain versions" diagnostic step.
- **Mac runner post-cleanup is slow** (~8 minutes idle before the final git cleanup logs fire). The runner service seems to enter a low-power / idle-throttle state when the actual CI work is done. This causes the job-level conclusion to be reported as "failure" even though all individual steps PASSED. **If you see Mac CI "failed" with all steps `success`, check the step conclusion first — don't trust the job-level outcome.** (PR #71 verified this pattern across 4 Mac CI runs.)
- **Mac runner: `ginwas-MacBook-Air`** (self-hosted, label `[self-hosted, macOS, ARM64]`). The `setup-zig@v2` action's built-in cache persists the Zig installation across runs.
- **Mac runner uses `aarch64-macos` target.** Cache key includes `${{ matrix.target.zig }}` so Mac and Linux caches are isolated.

## Linux CI resource-usage optimization (PR #71)

Originally the Linux step was `pacman -Syu && pacman -S --needed ...` where `-Syu` does a **full system upgrade** on every CI run (re-downloads ~1 GB of packages from the Arch repos even when nothing in the workflow changed). The runner is self-hosted and persistent — packages installed on one run stay installed for the next. PR #71 dropped the `pacman -Syu`; a plain `pacman -S --needed ...` is sufficient and reuses the on-disk packages.

- **Linux CI webview deps added 2026-07-04**: `pacman -S --needed` now also installs `webkit2gtk-4.1`, `gtk3`, `libsoup3` (the WebKitGTK runtime stack nalar-desktop links against). Already installed on the persistent Arch runner.

## macOS CI resource-usage optimization (PR #71)

Originally the macOS step was `brew update && brew install ...` — `brew update` re-downloads the entire homebrew/core + homebrew/bottle formula manifests (~30 MB and several seconds of network I/O) on every CI run. PR #71 dropped `brew update` and used the `HOMEBREW_NO_AUTO_UPDATE=1` env var.

## Windows pre-conditions (pre-existing)

Before the CI pipeline could include Windows (if a runner is added), two pre-existing compile errors had to be fixed:

1. **`src/modules/agent/tools/bash_selfkill.zig`** — `get_self_pid()` now returns `i32` via `helpers.process.getCurrentProcessId()` (was returning `std.c.pid_t` which is `*anyopaque` on Windows). Fixed in commit `04aa8f8a`.

2. **`src/modules/agent/Agent.zig apply_tcp_keepalive`** — gated behind `builtin.os.tag != .windows` because `std.posix.setsockopt` has `@compileError("use std.Io instead")` on Windows. Fixed in commit `9ef9d5fb`.

The only remaining Windows blocker is the **binary build** step (needs `vcpkg` wired into `build.zig` to provide sqlite3/openssl for the linker).

## When the CI runs

- **Push to main**: full matrix + frontend.
- **PR to main**: full matrix + frontend.
- **Manual trigger** (`workflow_dispatch`): same.
- **Concurrency**: same-branch in-progress runs are cancelled when a new commit is pushed.

---

## gitignore large vendored binaries + fetch on demand pattern

When a project vendors large C/C++ binaries (SQLite amalgamation, libxml2, zlib, etc.) into a `vendor/` directory for cross-platform builds, the ~10 MB of binary-like content bloats every git clone with no diffable substance. The proper fix is to gitignore the vendor dir and fetch it on demand.

### The pattern (5 files, +534/-284702 on the nalar SQLite case)

1. **`.gitignore`** — anchor to repo root:

   ```
   /vendor/
   ```

   The leading slash ensures it ONLY matches the repo-root `vendor/` dir, not nested `src/.../vendor/` directories of third-party code.

2. **`scripts/fetch-vendor-X.sh`** — idempotent downloader:
   - Skip if all files exist (idempotent)
   - `curl --retry 3 --connect-timeout 30` (network resilience)
   - Verify SHA3-256 (or SHA-256 if sha3sum isn't available) against the upstream download page
   - Extract via `python3 - zipfile` (primary, cross-platform) or `unzip` (fallback for minimal CI images)
   - Make it executable: `chmod +x scripts/fetch-vendor-X.sh`

3. **`.github/workflows/ci.yml`** — invoke on non-native runners:

   ```yaml
   - name: Fetch vendored X amalgamation (Windows / macOS)
     if: runner.os != 'Linux'
     shell: bash
     run: |
       chmod +x scripts/fetch-vendor-X.sh
       ./scripts/fetch-vendor-X.sh
   ```

   Add the vendor dir to the cache path + include the script in the cache key so version bumps invalidate the cache.

4. **`README.md`** + **`docs/ci.md`** — document the Linux (system library) vs Windows/macOS (fetch) flow, with a troubleshooting section for "unable to find file 'vendor/X/X.c'".

5. **Static-contract regression tests** — verify the contracts:
   - `.gitignore` contains the anchored rule (line-level, not substring — comment lines shouldn't count)
   - The script exists with shebang
   - The script pins specific version + URL + SHA
   - The script is idempotent ("skipping fetch" marker)
   - The script has python3 AND unzip extraction paths
   - CI workflow invokes the script on non-Linux runners
   - CI cache key includes the script

### Why this pattern

- **Removes ~285K lines of binary content from every clone** without breaking the build for fresh checkouts.
- **Linux users don't notice anything** — they continue using `linkSystemLibrary("X")` against the system library.
- **CI cells stay green** — the fetch step runs before any `zig build` call on Windows/macOS.
- **Red-green testable** — the static-contract tests catch every regression.

### Anti-patterns to avoid

- ❌ **Don't commit the amalgamation and rely on `git lfs`** — LFS pollutes the clone workflow.
- ❌ **Don't use `git submodule` for the amalgamation** — submodules add cloning complexity.
- ❌ **Don't just delete the vendor dir without a fetch step** — breaks the build for Windows/macOS users.
- ❌ **Don't add the rule as `vendor/` (no leading slash)** — matches nested `src/.../vendor/` directories and hides real source files from `git status`.

### Version-bump workflow

1. Update the version constants + URL + SHA3-256 in the fetch script.
2. Update the regression tests to match the new constants.
3. Delete the local `vendor/` dir and re-run the fetch script to verify the new SHA matches.
4. CI will detect the cache-key change and re-fetch on the next push.

---

## Custom HTTP server build pattern (memory / NALAR)

The custom HTTP server in `src/modules/custom_http_server/` is a separate module with its own build target. When making changes to it:

- Test changes don't propagate to the main nalar test binary — separate test target for the custom server exists.
- The `GinwaServer` lives in `src/modules/custom_http_server/src/http_server.zig`.
- Per-request arena allocator (see `nalar-backend-architecture.md`) is the project's HTTP handler convention.

---

## Related / cross-references

- `nalar-backend-architecture.md` — backend patterns, HTTP handler conventions
- `nalar-frontend-patterns.md` — frontend build patterns
- `zig-build-and-test.md` — Zig build/test patterns
- `zig-cross-platform.md` — cross-platform Zig 0.16 porting