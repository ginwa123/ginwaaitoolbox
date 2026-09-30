# CI/CD Pipeline

The pipeline lives at `.github/workflows/ci.yml` and runs on **GitHub-hosted
(public) runners**. The repository is public, so GitHub-hosted minutes are
free.

**Toolchain policy:** pnpm, not npm and not bun. `src/apps/desktop/pnpm-lock.yaml`
is the canonical lockfile, `pnpm/action-setup@v4` pins pnpm 11, and the
webapp build is `pnpm install --frozen-lockfile` + `pnpm run build`.

## Runners

Three pinned images, one matrix cell each. They are deliberately **not**
`-latest`, so a GitHub image bump cannot change what a green pipeline built:

| Cell | `runs-on` | Why this one |
|---|---|---|
| `backend (Linux X64)` | `ubuntu-24.04` | glibc 2.39, which satisfies the `.glibc_version = 2.38` that `build.zig` pins for the Linux target. (`ubuntu-22.04`'s glibc 2.35 would not.) |
| `backend (macOS ARM64)` | `macos-15` | The arm64 image, matching the `aarch64-macos` target and the arm64 Mach-O assertion in the verify step. (`macos-latest` currently resolves to macOS 26 arm64.) |
| `backend (Windows X64)` | `windows-2022` | VS 2022 + Windows 11 SDK, which the Windows build branch is validated against. (`windows-latest` currently resolves to Server 2025 / VS 2026.) |
| `functional-test (ubuntu-24.04)` | `ubuntu-24.04` | API + Playwright UI suites, one pytest run. |
| `functional-test (macos-15)` | `macos-15` | Same suites, arm64. |
| `functional-test (windows-2022)` | `windows-2022` | Same suites. Needs vcpkg + MSVC exactly like the backend cell (the service binary links curl/openssl/libpq/sqlite3), but no WebView2 — this job builds the service only. |

Bump these one cell at a time. The macOS cell in particular must stay on an
**arm64** image: `build.zig`'s `install:macos` step hardcodes `x86_64-macos`
and the resulting binary is rejected by an arm64 runner with "Bad CPU type in
executable". The matrix therefore uses the `install:macos-arm` label.

The matrix is `include:`-only — each entry is a complete cell, so there is no
3×3 cross-product to prune and no way for a mistyped `exclude` to silently run
an unintended cell (it did once: CI run 31838283325 ran 5 cells instead of 3).

### What a GitHub-hosted runner gives you for free

These used to be bootstrap steps in `ci.yml`; they are deleted because the
images already have them:

- `pwsh` (PowerShell 7) on `PATH` — the old step downloaded 7.4.6 by hand.
- Git for Windows at `C:\Program Files\Git` — so `shell: bash` steps work.
- Visual Studio Enterprise 2022 with the C++ workload, and vcpkg already
  bootstrapped at `C:\vcpkg`. The workflow only has to export MSVC's
  environment; `vswhere.exe` locates the toolset in milliseconds, replacing a
  `Get-ChildItem C:\ -Filter vcvars64.bat -Recurse` walk that took minutes.

Every Windows step uses `shell: pwsh`. `shell:` accepts no `${{ }}`
expressions, so per-OS shells need twin steps gated on
`if: runner.os == 'Windows'` — the repo's long-standing convention.

### What a GitHub-hosted runner does NOT give you

A fresh VM **per job**. On the old self-hosted fleet the Linux box was
persistent, so packages installed by the `backend` cell were still there when
`functional-test` landed on the same machine. Every Linux job now installs its
own dependencies by calling `scripts/ci-install-linux-deps.sh` — the same
script, not three copy-pasted lists. macOS cells `brew install` the keg-only
libs and export their paths; Windows cells export the MSVC env and
`vcpkg install` the four ports in ONE invocation (vcpkg takes an exclusive
lock, so parallel per-port installs fail three times out of four).

That script also asserts, after installing, that `pkg-config` can actually
resolve `sqlite3`, `openssl`, `libpq`, `libcurl` and `webkit2gtk-4.1`, and
that `rg` is on `PATH`. Without that, an under-install shows up much later as
an opaque zig link error, or — worse — as a silent fallback to the vendored
sources and a 10-minute cross-compile.

## What the backend job does

Each cell runs the same sequence and produces the artifact native to its
image:

1. `mlugg/setup-zig@v2` — Zig 0.16.0; `actions/setup-node@v4` — Node 24;
   `pnpm/action-setup@v4` — pnpm 11.
2. Per-OS system deps:
   - **Linux**: `scripts/ci-install-linux-deps.sh` (apt).
   - **macOS**: `brew install pkg-config openssl@3 curl coreutils ripgrep`
     with `HOMEBREW_NO_AUTO_UPDATE=1` (no `brew update`, which re-downloads
     ~30 MB of formula manifests per run). `openssl@3` and `curl` are
     keg-only, so their prefixes are exported to `$GITHUB_ENV`; `coreutils`
     supplies `timeout` and GNU `stat -c%s`, which the verify steps use.
   - **Windows**: vcpkg ports `curl openssl libpq sqlite3[fts5]` in one
     `vcpkg install` call, plus WebView2 NuGet staging. All four ports go in
     a single invocation because vcpkg takes an exclusive lock on
     `.vcpkg-running.lock`, so parallel installs fail.
3. Caches (see below).
4. `zig build test --summary all -Dno-webapp-rebuild`, then per-OS
   `zig build nalar-desktop`:
   - Linux additionally runs `zig build check:desktop-cross` — compiling the
     desktop app's Windows and macOS branches *from Linux*. A per-OS branch is
     otherwise only ever compiled on its own OS's runner, which is the only
     cheap place to catch e.g. a Windows-only type error.
   - Windows builds the webapp bundle in its own step (vite alone, no
     vue-tsc, no zig LLVM link in flight) and then installs with
     `-Dno-webapp-rebuild -Drequire-real-webview`.
5. Per-platform binary verification:
   - **Linux**: `file` says `ELF 64-bit LSB executable, x86-64`, and `ldd`
     shows `webkit2gtk-4.1`.
   - **macOS**: `file` says `Mach-O 64-bit executable arm64`, and `otool -L`
     shows `WebKit.framework` + `AppKit.framework`.
   - **Windows**: both `.exe`s exist and start with the `MZ` stub.
6. Smoke tests:
   - `scripts/ci-smoke-test.sh` on port 18080 — boots the service binary
     against an isolated temp `HOME` (so all 54 migrations run from a fresh
     DB), hits `/health` and `/api/workspaces`, and shuts down cleanly.
   - `nalar-desktop --smoke-test` — exercises the webview's asset-extraction
     path without opening a window.
7. Binary publish — each cell stages its binaries under target-triple names
   (`nalar-<target>`, `nalar-desktop-<target>`). On merges to `main` (and
   manual dispatch) they are published as assets on the rolling `ci-latest`
   GitHub Release. **PR builds stage only — nothing is stored.**

## Caches

| What | Key | Why keyed that way |
|---|---|---|
| `.zig-cache` + `src/modules/databases/vendor` | `v4-zig-<image>-<zig target>-<hash(build.zig, build.zig.zon, fetch-vendor-sqlite3.sh)>` | **By image, not `runner.os`.** `runner.os` is the bare string `Linux`/`macOS`/`Windows` on *both* self-hosted and GitHub-hosted runners, so an `runner.os` key would have restored the old Arch box's `.zig-cache` into an Ubuntu runner and mixed two distros' object hashes — a failure that surfaces as random corrupt-cache errors with no diagnostic trail. Keying on the image label also invalidates on an image bump. |
| pnpm store (`runner.temp/pnpm-store`) | `v1-pnpm-<image>-<hash(pnpm-lock.yaml)>` | All three backend cells run a full `pnpm install`. The self-hosted cells shared one `$HOME`, so whichever ran first warmed the store for the others; each GitHub-hosted job gets a fresh `$HOME`, so without this the largest download in the pipeline is cold every run. The path is forced via `npm_config_store_dir` because pnpm's default differs per platform and `actions/cache` paths do not expand shell variables. |
| pytest venv + Playwright Chromium | `v3-py-<image>-py312-<hash(both requirements.txt)>` | **By image.** The venv is a directory of scripts + site-packages whose layout is platform-specific (Windows uses `Scripts/`, not `bin/`), so a Linux venv restored onto a Windows runner is a broken interpreter path, not a slow cache hit. Three cells means three caches — the price of running the suites on three platforms. |
| pnpm store (`functional-test`) | `v3-pnpm-<image>-<hash(pnpm-lock.yaml)>` | Same image scoping: pnpm's store holds platform-tagged optional dependencies. Separate prefix from the backend's `v1-pnpm-` because the path differs (`runner.temp/pnpm-store` vs the backend's per-cell choice) and the jobs no longer share a machine. |

`zig-out` and `webapp_assets.zig` are deliberately **not** cached: they are
build output, regenerable from `.zig-cache` in seconds, and caching them cost
~124 MB of archive I/O per run.

## Functional tests

Three build steps, and CI uses the third:

| Step | Runs | Used by |
|---|---|---|
| `zig build functional-test` | `pytest tests/functional/` (API only) | local iteration on one suite |
| `zig build functional-test-ui` | `pytest tests/functional_ui/` (Playwright only) | local iteration on one suite |
| `zig build functional-test-all` | **both directories, one pytest process** | the `functional-test` CI matrix |

`functional-test-all` exists because the two suites share every expensive
input — the venv, `pip install -r`, `playwright install chromium` (~150 MB),
and the `zig build install` walk for the nalar binary. As separate jobs that
was paid twice per PR, for two reports and two verdicts. One process pays it
once and answers "are the functional suites green?" with one exit code.
`pytest.ini`'s `testpaths` lists both directories, so a bare local `pytest`
runs the same set CI does — the two lists cannot drift.

**No `-n auto`.** pytest-xdist is the obvious way to make this faster and it
is wrong here: the port picker binds a probe socket, closes it, and hands the
number to the nalar child, which binds tens of ms later. That gap is the
documented reason the random range lives at 20k-32k, and widening it does not
help when N workers draw from it simultaneously. Under `-n` the suite trades
a deterministic ~15 min for intermittent `BindFailed` at boot.

### Platform gates

The suites run on all three platforms, and a test that cannot run on one is
skipped **with a reason**, not silently or with a collection error about a
missing `termios`. Every gate is one row in `tests/platform_gates.py`, applied
by each suite's `conftest.py`. Two kinds, and the distinction matters:

- **`collect_ignore`** — the file cannot be *imported* on that platform
  (module-level `import pty`). A skip marker never runs, because collection
  dies first.
- **skip marker** — the file imports fine; its tests are skipped. The reason
  shows up on the test id in the report.

Two rules keep the table honest: a row is a statement about the *platform*
("`pty` does not exist on Windows"), never about a test being annoying; and a
row whose test has since been made portable must be **deleted**, because a
stale skip hides the next regression. Most rows are structural — the product
has no pty backend on Windows (`terminal_session.zig`'s
`is_pty_os = linux || macos`), which is also why the frontend hides the
terminal panel there.

Anything a path could break is a `harness.harness_path()` call instead of a
literal: the server validates `path`/`file_path`/`cwd` with
`std.fs.path.isAbsolute`, which is *platform-relative*, so a `"/tmp/a.md"`
literal that is correct on ubuntu-24.04 400s on windows-2022.

The harness enforces a **"never delete real `$HOME`"** invariant via three
defensive layers (see `tests/functional/harness.py` for the banner comment):

1. **`is_safe_tmp(path, orig_home)` allow-list validator** — runs before every
   `shutil.rmtree`. Returns True only if the path starts with `/tmp/`,
   `/private/tmp/`, `/private/var/folders/`, or `tempfile.gettempdir() + "/"`,
   AND contains `nalar-func-`, AND does not resolve to the real `$HOME`.
2. **Captured `Path` attribute** — `temp_dir` is set once at boot;
   `teardown()` rmtree's THIS attribute, never `os.environ["HOME"]`.
3. **`ORIG_HOME` snapshot + restore** — captured before `os.environ["HOME"]`
   is shadowed, restored as the first step of teardown.

`NALAR_FUNCTIONAL_DRY_RUN=1` skips the rmtree and prints what would have been
deleted — useful for paranoia-debugging.

If a CI run ever deletes the runner's real `$HOME`, that is a P0 incident in
the harness, not a bug to fix in the test. The 12 negative tests in
`harness_safety_test.py` guard the invariants.

## What does NOT run

- **No separate frontend job.** The Vue webapp is bundled into nalar-desktop
  via `zig build codegen:webapp-assets` → `pnpm run build` →
  `src/apps/desktop/dist/` → generated `webapp_assets.zig` → embedded bytes.
  vue-tsc runs as part of `pnpm run build` (project convention: the build is
  the type-check). The 8 pre-existing vitest failures across 4 files are not
  gating.

## Downloading binaries

Binaries are **not** uploaded as Actions artifacts — artifact storage is
quota-metered and the repo hit the cap ("Artifact storage quota has been hit",
2026-08-23). Releases do not count against that quota, so every green `main`
build publishes to the rolling release instead:

  https://github.com/ginwa123/ginwaaitoolbox/releases/tag/ci-latest

Assets (names carry the zig target triple):

  nalar-x86_64-linux-gnu          + nalar-desktop-x86_64-linux-gnu
  nalar-aarch64-macos             + nalar-desktop-aarch64-macos
  nalar-desktop-x86_64-windows-gnu.zip   (self-contained: both exes, every
                                          runtime DLL, WebView2Loader.dll,
                                          html/ and Install-Nalar.ps1)

macOS also ships `Nalar-aarch64-macos.zip` holding `Nalar.app`.

Or via the `gh` CLI:

```bash
gh release download ci-latest --repo ginwa123/ginwaaitoolbox \
  --pattern 'nalar-desktop-x86_64-linux-gnu'
```

The release is marked prerelease and not-latest so it never shadows real
versioned releases; each main merge replaces the assets in place, so
`ci-latest` always tracks the newest green build. PR builds never publish.

Install with `sudo scripts/install-nalar-desktop.sh` after downloading (the
script handles `chmod +x` and copying to `/usr/local/bin/`).

## Running the same checks locally

```bash
zig build test --summary all                    # the backend test suite
zig build nalar-desktop --summary all           # produce both binaries
zig build check:desktop-cross --summary all     # Linux-only cross-compile check
./zig-out/bin/nalar-desktop --smoke-test        # desktop asset-extraction smoke
./scripts/ci-smoke-test.sh                      # boots the service end-to-end
zig build functional-test                       # pytest suites
zig build functional-test-ui                    # Playwright suites
bash scripts/ci-install-linux-deps.sh           # what CI installs on Ubuntu
```

Local webapp deps: `cd src/apps/desktop && pnpm install --frozen-lockfile`
(or let `zig build` run it when `node_modules` is missing).

## Editing ci.yml

Run `actionlint` on the workflow before pushing. GitHub rejects invalid
workflow syntax at **parse** time: the run appears for 0 seconds, has zero
jobs, and produces no logs to debug from, so a mistake costs a full push
cycle. "The YAML parses" is not a check — `actionlint` is stricter and knows
the expression contexts each key accepts (e.g. `runner` is available in step
`env:` but *not* in job-level `env:`; `shell:` accepts no `${{ }}` at all).
