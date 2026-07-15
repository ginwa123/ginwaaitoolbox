# nalar — CI/CD pipeline facts (2026-07-03, updated after PR #71)

The `.github/workflows/ci.yml` workflow is now a self-hosted-only
matrix (after PR #71). Key facts that will surface in future work:

- **Baseline (pre-CI)**: 873/876 Zig tests pass on Linux x86_64 (3
  skipped). The 3 skipped are tests that require external
  network/external binary.
- **CI matrix** (after 2026-07-04 plan / docs/superpowers/plans/2026-07-04-nalar-desktop-ci-cd.md):
  2 self-hosted cells — `[self-hosted, Linux, X64]` (native Linux build, ELF
  x86_64) and `[self-hosted, macOS, ARM64]` (native Apple Silicon build,
  Mach-O arm64). The `exclude:` block filters the 2×2 cross-product down
  to those 2 native-target cells. Same architecture as the pre-plan state
  from PR #71; what's new is per-cell bun install, webkit/macos system
  deps, and the artifact renamed `nalar-${matrix.target.zig}-<sha>` so
  each cell produces a distinct artifact that coexists on the same
  commit. No Windows cell (still no self-hosted Windows runner).
- **Frontend job was removed 2026-07-04.** The standalone `frontend:` job
  (`bun install` + `bun run build` + oxlint + eslint + vitest) is gone from
  ci.yml. The Vue webapp is now bundled into nalar-desktop via the build-time
  `zig build codegen:webapp-assets` step that runs as part of
  `zig build nalar-desktop` on BOTH cells (Linux + macOS). Type-check
  (vue-tsc) runs as part of `bun run build`. The 8 pre-existing vitest
  failures across 4 files (KanbanView, chatViewShowPreviewBubble,
  previewSidePanel, DiffView) are NOT gated now (they were already
  non-blocking under `continue-on-error: true`).
- **Frontend lint is non-blocking**: uses raw `bunx oxlint .` and
  `bunx eslint . --cache` (without `--fix`) because the package.json
  `bun run lint` script uses `--fix` which would corrupt the working
  tree in a fresh CI checkout.
- **macOS openssl**: keg-only, must explicitly export
  `PKG_CONFIG_PATH=$(brew --prefix openssl@3)/lib/pkgconfig` for
  Zig's `linkSystemLibrary("ssl")` to find it (only relevant when
  build.zig actually links openssl — currently only on Linux, so
  this is only there for parity).
- **Bun cache key**: hashes `src/apps/desktop/bun.lock` (NOT
  `package-lock.json` — that file does not exist; the project uses
  Bun's binary lockfile).

## macOS CI quirks (learned while fixing Mac CI in PR #71)

- **Mac runner = Apple Silicon (aarch64-macos).** The matrix cell
  uses `install:macos-arm` (NOT `install:macos`, which hardcodes
  `x86_64-macos` in build.zig:394 and produces an x86_64 binary the
  ARM64 runner rejects with "Bad CPU type in executable").
- **Mac GitHub Actions runner image doesn't ship pkg-config.** The
  `brew install pkg-config openssl@3` line is needed for the
  "Show toolchain versions" diagnostic step, which calls
  `pkg-config --modversion sqlite3/openssl`. The `pkg-config` queries
  in that step use `|| echo "<not installed>"` so a missing `.pc`
  file is reported gracefully (build.zig uses the vendored sqlite3
  amalgamation on Mac and never links ssl, so on Mac neither
  `sqlite3.pc` nor `openssl.pc` is on disk).
- **Mac runner post-cleanup is slow** (~8 minutes idle before the
  final git cleanup logs fire). The runner service seems to enter a
  low-power / idle-throttle state when the actual CI work is done.
  This causes the job-level conclusion to be reported as "failure"
  even though all individual steps PASSED. The CI is functionally
  correct; the noisy conclusion is a runner-side issue. **If you
  see Mac CI "failed" with all steps `success`, check the step
  conclusion first — don't trust the job-level outcome.** (PR #71
  verified this pattern across 4 Mac CI runs.)
- **Mac runner: `ginwas-MacBook-Air`** (self-hosted, label
  `[self-hosted, macOS, ARM64]`). The `setup-zig@v2` action's
  built-in cache (per its `use-cache: true` default) persists the
  Zig installation across runs.
- **Mac runner uses `aarch64-macos` target.** Cache key includes
  `${{ matrix.target.zig }}` so Mac and Linux caches are isolated.

## Linux CI resource-usage optimization (PR #71)

Originally the Linux step was `pacman -Syu && pacman -S --needed ...`
where the `-Syu` does a **full system upgrade** on every CI run
(re-downloads ~1 GB of packages from the Arch repos even when nothing
in the workflow changed). The runner is self-hosted and persistent —
packages installed on one run stay installed for the next. PR #71
dropped the `pacman -Syu`; a plain `pacman -S --needed ...` is
sufficient and reuses the on-disk packages. If the runner image ever
actually needs updating, run `pacman -Syu` once on the runner host
(out of band) and the `--needed` flag will pick up the new versions
on the next CI run.

- **Linux CI webview deps added 2026-07-04**: `pacman -S --needed` now also
  installs `webkit2gtk-4.1`, `gtk3`, `libsoup3` (the WebKitGTK runtime stack
  nalar-desktop links against). These are needed for the linker step —
  without them the build fails with "unable to find dynamic system library
  'webkit2gtk-4.1'". They're already installed on the persistent Arch
  runner, so the `--needed` flag is a no-op there — matters only when
  setting up a fresh runner.

## macOS CI resource-usage optimization (PR #71)

Originally the macOS step was `brew update && brew install ...` —
`brew update` re-downloads the entire homebrew/core + homebrew/bottle
formula manifests (~30 MB and several seconds of network I/O) on
every CI run. PR #71 dropped `brew update` and used the
`HOMEBREW_NO_AUTO_UPDATE=1` env var. `brew install` is still
idempotent (skips formulas already at the requested version). If a
formula needs a version bump, bump the version pin explicitly in
the `brew install` line.

## Windows pre-conditions (pre-existing)

Before the CI pipeline could include Windows (if a runner is added),
two pre-existing compile errors had to be fixed:

1. **`src/modules/agent/tools/bash_selfkill.zig`** — `get_self_pid()`
   now returns `i32` via `helpers.process.getCurrentProcessId()` (was
   returning `std.c.pid_t` which is `*anyopaque` on Windows). Fixed
   in commit `04aa8f8a` (earlier cross-platform work, not part of
   this plan).

2. **`src/modules/agent/Agent.zig apply_tcp_keepalive`** — gated
   behind `builtin.os.tag != .windows` because `std.posix.setsockopt`
   has `@compileError("use std.Io instead")` on Windows. This is a
   temporary workaround; the proper fix is a `std.Io.Net` migration
   of Agent.zig's streaming sockets (out of scope; tracked as
   follow-up). Fixed in commit `9ef9d5fb`.

The only remaining Windows blocker is the **binary build** step (needs
`vcpkg` wired into `build.zig` to provide sqlite3/openssl for the linker).

## When the CI runs

- **Push to main**: full matrix + frontend.
- **PR to main**: full matrix + frontend.
- **Manual trigger** (`workflow_dispatch`): same.
- **Concurrency**: same-branch in-progress runs are cancelled when a
  new commit is pushed.
