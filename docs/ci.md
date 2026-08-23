# CI/CD Pipeline

The pipeline lives at `.github/workflows/ci.yml` and runs on GitHub Actions
self-hosted runners.

## What runs

A 2-cell matrix on self-hosted runners (`[self-hosted, Linux, X64]` and
`[self-hosted, macOS, ARM64]`) — both cells run the same sequence and
each produces the artifact native to its host platform:

1. `mlugg/setup-zig@v2` — installs Zig 0.16.0
2. Per-cell system deps:
   - **Linux (Arch)**: `pacman -S --needed` installs `webkit2gtk-4.1`,
     `gtk3`, `libsoup3` (the WebKitGTK runtime stack the desktop links
     against), plus `openssl`, `sqlite`, `pkgconf`, `base-devel`.
   - **macOS (Homebrew)**: `brew install pkg-config openssl@3` with
     `HOMEBREW_NO_AUTO_UPDATE=1` (no `brew update` to save ~30 MB of
     formula DB refresh per run; pkg-config is for the diagnostic step;
     openssl@3 is keg-only so env vars are exported for the linker).
3. **`oven-sh/setup-bun@v2`** — installs Bun 1.3.11 on both cells
   (needed for the embedded Vue webapp build that `zig build nalar-desktop`
   triggers via the codegen dependency chain)
4. Caches (Bun `node_modules`, Zig build artifacts incl. the generated
   `webapp_assets.zig`); per-cell isolation via `${{ runner.os }}` and
   `${{ matrix.target.zig }}` keys
5. `zig build test` — full backend test suite
6. `zig build nalar-desktop --summary all` — produces `zig-out/bin/nalar`
   (~58 MB on Linux; varies on macOS) and `zig-out/bin/nalar-desktop`
   (~34 MB on Linux). The `step: install:linux:system` /
   `step: install:macos-arm` matrix entry is the cross-target build used
   by the smoke test path; the deliverable artifacts come from the
   `install` step that `build_nalar_desktop.dependOn(getInstallStep())`
   wires up at `build.zig:280`.
7. Per-platform binary verification:
   - **Linux**: `file ELF 64-bit LSB executable, x86-64`, `ldd | grep
     webkit2gtk-4.1`, sane binary size (~30-60 MB).
   - **macOS**: `file Mach-O 64-bit executable arm64`,
     `otool -L | grep WebKit.framework + AppKit.framework`, sane size.
8. Smoke tests:
   - `scripts/ci-smoke-test.sh` — boots nalar service binary, hits
     `/health`, shuts down cleanly (cross-platform; the script handles the
     SIGTERM / `$GITHUB_ENV` differences internally).
   - `./zig-out/bin/nalar-desktop --smoke-test` — exercises desktop binary's
     webapp-asset extraction path (no GTK init, no display server needed
     on either platform).
   - `zig build functional-test` — runs `tests/functional/` (8 suites,
     ~55 tests, ~5 min). Each test boots a fresh `nalar` against an
     isolated `mktemp` HOME; the Python harness enforces
     `is_safe_tmp()` so the real `$HOME` is never touched. See
     `tests/functional/README.md` for details.
9. Binary publish — each cell stages its binaries under target-triple
   names (`nalar-<target>`, `nalar-desktop-<target>`). On merges to main
   (+ manual dispatch) they're published as assets on the rolling
   `ci-latest` GitHub Release. PR builds stage only — nothing is stored.

## Functional tests

`zig build functional-test` is the systematic-functional-coverage step.
It runs `pytest tests/functional/` (8 suites, ~55 tests, ~5 min wall-clock).

The harness enforces a **"never delete real `$HOME`"** invariant via
three defensive layers (see `tests/functional/harness.py` for the
banner comment):

1. **`is_safe_tmp(path, orig_home)` allow-list validator** — runs before
   every `shutil.rmtree`. Returns True only if the path starts with
   `/tmp/`, `/private/tmp/`, `/private/var/folders/`, or
   `tempfile.gettempdir() + "/"`, AND contains `nalar-func-`, AND
   doesn't resolve to the real `$HOME`.
2. **Captured `Path` attribute** — `temp_dir` is set once at boot;
   `teardown()` rmtree's THIS attribute, never `os.environ["HOME"]`.
3. **`ORIG_HOME` snapshot + restore** — captured before
   `os.environ["HOME"]` is shadowed, restored as the first step of
   teardown.

`NALAR_FUNCTIONAL_DRY_RUN=1` skips the rmtree and prints what would
have been deleted — useful for paranoia-debugging.

If a CI run ever deletes the runner's real `$HOME`, that's a P0
incident in the harness, not a bug to fix in the test. The 12
negative tests in `harness_safety_test.py` guard the invariants.

## What does NOT run

- **No frontend job.** The Vue webapp is bundled into nalar-desktop via
  `zig build codegen:webapp-assets` → `bun run build` →
  `src/apps/desktop/dist/` → generated `webapp_assets.zig` → embedded bytes.
  vue-tsc runs as part of `bun run build` (project convention: build is the
  type-check). The 8 pre-existing vitest failures across 4 files are not
  gating.
- **No Windows cell.** PR #70's smoke-test cleanup kept the option, but no
  self-hosted Windows runner is registered. Pre-existing compile-blockers
  in `src/modules/agent/tools/bash_selfkill.zig` and `Agent.zig`'s
  `apply_tcp_keepalive` are now resolved (commits `04aa8f8a` + `9ef9d5fb`);
  remaining work to add Windows is runner-registration + `vcpkg` sysroot
  wiring in `build.zig` (separate task).

## Downloading binaries

Binaries are NOT uploaded as Actions artifacts anymore — artifact storage
is quota-metered and the repo hit the cap ("Artifact storage quota has
been hit", 2026-08-23). Releases don't count against that quota, so every
green `main` build publishes to the rolling release instead:

  https://github.com/ginwa123/ginwaaitoolbox/releases/tag/ci-latest

Assets (names carry the zig target triple):
  nalar-x86_64-linux-gnu          + nalar-desktop-x86_64-linux-gnu
  nalar-aarch64-macos             + nalar-desktop-aarch64-macos
  nalar-x86_64-windows-gnu.exe    + nalar-desktop-x86_64-windows-gnu.exe

Or via the `gh` CLI:
  gh release download ci-latest --repo ginwa123/ginwaaitoolbox \
    --pattern 'nalar-desktop-x86_64-linux-gnu'

The release is marked prerelease + not-latest so it never shadows real
versioned releases; each main merge replaces the assets in place, so
`ci-latest` always tracks the newest green build. PR builds never publish.

Install with `sudo scripts/install-nalar-desktop.sh` after downloading
(the script handles `chmod +x` + copying to `/usr/local/bin/`).

## Adding Windows

Pre-existing compile-blockers are fixed (commits `04aa8f8a` + `9ef9d5fb`).
Remaining work: register a `[self-hosted, windows]` runner, then add it
to the matrix `os:` list. The `install:windows` build step is blocked at
link time by missing `sqlite3` / `ssl` / `crypto` system libraries — needs
`vcpkg` sysroot wiring in `build.zig` and is a separate task.

## Running the same checks locally

```bash
zig build test              # equivalent to step 5
zig build nalar-desktop     # equivalent to step 6
./zig-out/bin/nalar-desktop --smoke-test   # equivalent to step 8
./scripts/ci-smoke-test.sh  # boots nalar service end-to-end
```
