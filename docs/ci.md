# CI/CD Pipeline

The pipeline runs on **GitHub-hosted (public) runners**. The repository is
public, so GitHub-hosted minutes are free.

**Toolchain policy:** pnpm, not npm and not bun. `src/apps/desktop/pnpm-lock.yaml`
is the canonical lockfile, `pnpm/action-setup@v4` pins pnpm 11, and the
webapp build is `pnpm install --frozen-lockfile` + `pnpm run build`.

## The graph

```text
changes ──▶ lint ──┬─▶ backend (Linux X64)   ──▶ functional Linux X64   · shard 1,2,3 ──┐
                   ├─▶ backend (macOS ARM64) ──▶ functional macOS ARM64 · shard 1,2,3 ──┤
                   ├─▶ backend (Windows X64) ──▶ functional Windows X64 · shard 1,2,3 ──┼─▶ ci-ok
                   └─▶ android-apk ──▶ android-test ──────────────────────────────────┘
```

| File | Role |
|---|---|
| `.github/workflows/ci.yml` | the graph and nothing else — 17 jobs, all wiring |
| `.github/workflows/reusable/backend.yml` | one platform's build + backend tests + release publish |
| `.github/workflows/reusable/functional.yml` | one platform's + one shard's pytest run |
| `.github/workflows/ci-cancel-on-merge.yml` | kills a merged PR's still-running jobs |

The two reusable workflows live in a **subdirectory** on purpose: GitHub only
auto-discovers the *top level* of `.github/workflows`, so `reusable/*.yml` can
never start a run of its own. They are reachable only via `uses:`.

### Why the graph looks like that

- **Per-platform chains, not a matrix.** `functional-test` used to
  `needs: backend`, and `backend` was a 3-cell matrix — which means it waited
  for *all three* platforms, including two whose artifacts it does not use.
  A matrix has no per-cell dependency edge; a **workflow call** does. Each
  backend is now a separate job, and each functional shard `needs:` exactly
  the backend cell for its own platform. Linux shards start when Linux is
  green, not when the slowest platform is.
- **Android starts immediately.** Both android jobs used to
  `needs: backend` as well, for the same no-artifact reason. They now hang off
  `lint` alone.
- **`ci-ok` is the only required check.** Branch protection lists one context
  instead of thirteen, so the shard count can change without editing a
  ruleset. The price is that a new heavy job must be added to `ci-ok`'s
  `needs:` list as well as to the graph — see `ci-ok`'s own comment.

Two things the reusable workflows deliberately **do not** have:

- **No `concurrency:` block.** Inside a *called* workflow `github.workflow`
  resolves to the **caller's** workflow name, so all three per-platform calls
  would compute the same group and `cancel-in-progress: true` would let
  whichever cell started last cancel the other two. The single group lives in
  `ci.yml`, and `ci-cancel-on-merge.yml` mirrors that literal.
- **No `strategy:`.** `uses:` jobs cannot use a matrix anyway; the repetition
  in `ci.yml` is the price of the per-platform `needs:` edges.

### Wasted runs

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

Per-ref, so a new push to a PR cancels the PR's own in-flight run while the
`refs/heads/main` run survives untouched. `ci-cancel-on-merge.yml` exists
because a `pull_request` run and the post-merge `push` run sit in *different*
groups and `cancel-in-progress` can never link them — that second workflow
joins the merged PR's group to evict it.

**Every job has a `timeout-minutes`.** The backend job used to have none at
all, so a wedged runner held a machine for the default 6 hours. Current
budgets: `changes` 5, `lint` 15, backend 120, a functional shard 75,
`android-apk` 30, `android-test` 45, `ci-ok` 5.

## The gate: `changes` then `lint`

`changes` classifies the diff in ~15 s and emits `heavy: true|false`.
`lint` runs `oxlint . && eslint . --cache` in `src/apps/desktop` on
`ubuntu-latest` — about 3 minutes warm. Both heavy (20-50 min each) and lint
wait on them:

```yaml
if: ${{ needs.lint.result == 'success' && needs.changes.outputs.heavy == 'true' && !cancelled() }}
```

- `needs.lint.result == 'success'` — a red lint skips 20-50 minute jobs. That
  is the "fails fast on obvious problems" half.
- `needs.changes.outputs.heavy == 'true'` — documentation-only.
- `!cancelled()` — a superseded run releases its machines instead of starting
  fresh ones. Because the `if:` is explicit it **replaces** the implicit
  `success()`, so a red *backend* no longer turns the functional suites into
  "skipped" instead of a verdict (run 36555002552 failed
  `backend (Windows X64)` on a one-line compile error and all three functional
  jobs reported skipped).

### Why not `on: paths-ignore`

The zero-code way to skip heavy jobs on a docs-only change is
`on: pull_request: paths-ignore: [...]`. It is wrong here because it makes
GitHub skip the **whole workflow**: there would be no run, so no `ci-ok`
check, so the PR sits on a required check that can never report. Gating
*inside* the workflow keeps one green run that says "nothing to build here".

### The classifier

`scripts/ci-change-filter.sh <base-sha>` prints `heavy=true|false` and traces
each changed file to stderr. Two pattern lists:

- **FORCE HEAVY** — anything that changes what is built *or* what the pipeline
  is: `.github/workflows/**`, `.husky/**`, `build.zig`, `build.zig.zon`,
  `scripts/ci-*`, any `requirements.txt`, any lockfile, any `package.json`,
  Gradle/AGP files. A CI-only diff is the case people forget: skipping the
  build because the diff is "only .github" means a typo'd `runs-on:` ships
  unbuilt.
- **DOC ONLY** — `*.md`, `docs/**`, `LICENSE*`, `.nalar/**`,
  `.github/ISSUE_TEMPLATE/**`, `*.svg`/`*.png`/`*.jpg`, `.gitignore`,
  `.gitattributes`. Deliberately narrow: `*.txt` is *not* here, because
  `tests/functional/requirements.txt` decides which pytest plugins exist.

It **fails open, always**: an unreadable diff, a base ref that is not in the
shallow clone, a new branch, or a path matching no pattern all return
`heavy=true`. A wrong `true` is a slow green run; a wrong `false` is a broken
build that ships. `bash scripts/ci-change-filter.sh --selftest` classifies 13
fixtures and is run by the `changes` job on every invocation, so a classifier
that has stopped classifying cannot go unnoticed.

### What is deliberately NOT a gate

- **`zig fmt --check`.** The tree is not fmt-clean today (many files under
  `src/`), so adding it would turn every PR red on a change nobody made in
  that PR. Run it locally on files you touch.
- **vue-tsc.** It runs inside `pnpm run build` in the backend cells. Project
  convention: the build is the type-check. Duplicating it in the lint job would
  add ~2 minutes to every run for a check that already runs.

## Runners

Three pinned images for the builds, one for the cheap jobs. Deliberately
**not** `-latest`, so a GitHub image bump cannot change what a green pipeline
built.

| Job | `runs-on` | Why this one |
|---|---|---|
| `changes`, `lint`, `ci-ok` | `ubuntu-latest` | Platform-independent and cheap; nothing here compiles zig. |
| `backend (Linux X64)` | `ubuntu-24.04` | glibc 2.39, which satisfies the `.glibc_version = 2.38` that `build.zig` pins for the Linux target. (`ubuntu-22.04`'s glibc 2.35 would not.) |
| `backend (macOS ARM64)` | `macos-15` | The arm64 image, matching the `aarch64-macos` target and the arm64 Mach-O assertion in the verify step. (`macos-latest` currently resolves to macOS 26 arm64.) |
| `backend (Windows X64)` | `windows-2022` | VS 2022 + Windows 11 SDK, which the Windows build branch is validated against. (`windows-latest` currently resolves to Server 2025 / VS 2026.) |
| `functional-*` | same image as its backend cell | Needs the same toolchain; the service binary links curl/openssl/libpq/sqlite3 everywhere. |
| `android-apk`, `android-test` | `ubuntu-24.04` | JDK 17 + Gradle + the Android SDK are only worth standing up here. |

Bump these one cell at a time. The macOS cell in particular must stay on an
**arm64** image: `build.zig`'s `install:macos` step hardcodes `x86_64-macos`
and the resulting binary is rejected by an arm64 runner with "Bad CPU type in
executable". The workflow therefore passes `install:macos-arm`.

### What a GitHub-hosted runner gives you for free

These used to be bootstrap steps in `ci.yml`; they are deleted because the
images already have them:

- `pwsh` (PowerShell 7) on `PATH` — the old step downloaded 7.4.6 by hand.
- Git for Windows at `C:\Program Files\Git` — so `shell: bash` steps work.
- Visual Studio Enterprise 2022 with the C++ workload, and vcpkg already
  bootstrapped at `C:\vcpkg`. The workflow only has to export MSVC's
  environment; `vswhere.exe` locates the toolset in milliseconds, replacing a
  `Get-ChildItem C:\ -Filter vcvars64.bat -Recurse` walk that took minutes.

Every Windows step uses `shell: pwsh` unless it is deliberately `shell: bash`
(the Windows cell's test/install steps and the release-body render, which all
run under Git Bash). `shell:` accepts no `${{ }}` expressions, so per-OS
shells need twin steps gated on `if: runner.os == 'Windows'` — the repo's
long-standing convention.

### What a GitHub-hosted runner does NOT give you

A fresh VM **per job**. On the old self-hosted fleet the Linux box was
persistent, so packages installed by the backend cell were still there when a
functional job landed on the same machine. Every Linux job now installs its
own dependencies by calling `scripts/ci-install-linux-deps.sh` — the same
script, not three copy-pasted lists. macOS cells `brew install` the keg-only
libs and export their paths; Windows cells export the MSVC env and
`vcpkg install` the four ports in ONE invocation (vcpkg takes an exclusive
lock, so parallel installs fail).

That script also asserts, after installing, that `pkg-config` can actually
resolve `sqlite3`, `openssl`, `libpq`, `libcurl` and `webkit2gtk-4.1`, and
that `rg` is on `PATH`. Without that, an under-install shows up much later as
an opaque zig link error, or — worse — as a silent fallback to the vendored
sources and a 10-minute cross-compile.

## What the backend job does

One call of `reusable/backend.yml` per platform. Each cell runs the same
sequence and produces the artifact native to its image:

1. `mlugg/setup-zig@v2` — Zig 0.16.0; `actions/setup-node@v4` — Node 24;
   `pnpm/action-setup@v4` — pnpm 11.
2. Per-OS system deps:
   - **Linux**: `scripts/ci-install-linux-deps.sh` (apt).
   - **macOS**: `brew install pkg-config openssl@3 curl ripgrep` with
     `HOMEBREW_NO_AUTO_UPDATE=1` (no `brew update`, which re-downloads
     ~30 MB of formula manifests per run). `openssl@3` and `curl` are
     keg-only, so their prefixes are exported to `$GITHUB_ENV`.
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

`target_step` is a **label**, not a build.zig step: nothing invokes a step by
that name. It is passed through so the steps gated on `!= '__SKIP__'` (the
smoke test, the python/playwright cache) fire on every cell, Windows included.

## Caches

| What | Key | Why keyed that way |
|---|---|---|
| `.zig-cache` + `src/modules/databases/vendor` (backend) | `v4-zig-<image>-<zig target>-<hash(build.zig, build.zig.zon, fetch-vendor-sqlite3.sh)>` | **By image, not `runner.os`.** `runner.os` is the bare string `Linux`/`macOS`/`Windows` on *both* self-hosted and GitHub-hosted runners, so an `runner.os` key would have restored the old Arch box's `.zig-cache` into an Ubuntu runner and mixed two distros' object hashes — a failure that surfaces as random corrupt-cache errors with no diagnostic trail. Keying on the image label also invalidates on an image bump. No `restore-keys`: a changed `build.zig` must not resurrect object files from an older graph. |
| zig **global** cache (`zig env`'s `global_cache_dir`) | `v1-zig-global-<image>-<hash(build.zig.zon)>` | The package SOURCES `build.zig.zon` pulls from github.com (kabelweb, ruangsql). Cold, this is what produces the `NameServerFailure` / `invalid HTTP response` aborts at *config* time — the flake class the functional job still retries around defensively. Unlike the cache above it does have a `restore-keys` prefix: the global cache is content-addressed and hash-verified, so a stale restore cannot produce a corrupt build. The path is asked of `zig` rather than hardcoded (`~/.cache/zig` vs `~/Library/Caches/zig` vs `%LOCALAPPDATA%\zig`) because `actions/cache` does not expand shell variables in `path:`. |
| `.zig-cache` + vendor (functional) | `v1-func-zig-<image>-<zig target>-<same hash>` | **New.** The functional job cached nothing zig-related, so each of the three shards per platform paid a full cold compile of the same SHA. Shards 2 and 3 now start from shard 1's object files. Separate prefix from the backend's `v4-zig-` because the two jobs build different targets from the same graph. |
| zig global cache (functional) | `v1-func-zig-global-<image>-<hash(build.zig.zon)>` | Same reason, same shape. |
| pnpm store (backend) | `v1-pnpm-<image>-<hash(pnpm-lock.yaml)>` | Every backend cell runs a full `pnpm install`. Each GitHub-hosted job gets a fresh `$HOME`, so without this the largest download in the pipeline is cold every run. The path is forced via `npm_config_store_dir` because pnpm's default differs per platform and `actions/cache` paths do not expand shell variables. |
| pnpm store (functional) | `v3-pnpm-<image>-<hash(pnpm-lock.yaml)>` | Same image scoping: pnpm's store holds platform-tagged optional dependencies. Separate prefix because these jobs no longer share a machine with the backend cell. |
| pytest venv (`android-test`) | `v3-py-ubuntu-24.04-py312-android-<hash(functional + functional_android requirements)>`, restore-keys `v3-py-ubuntu-24.04-py312-` | Shares a prefix with the Linux shards' venv so the emulator job restores instead of building a cold one. Its restore-key used to be `v2-py-Linux-py312-` — a stale major version *and* `runner.os` instead of the image — which could never match, so every run paid a cold venv. |
| pnpm store (lint) | `v4-lint-pnpm-<hash(pnpm-lock.yaml)>` | Private to the lint job. It is deliberately NOT shared with the backend/functional prefixes: an actions/cache entry is written once and is immutable, so a shared key means whichever job finishes first wins and the rest report "already exists". |
| pytest venv + Playwright Chromium | `v3-py-<image>-py312-<hash(both requirements.txt)>` | **By image.** The venv is a directory of scripts + site-packages whose layout is platform-specific (Windows uses `Scripts/`, not `bin/`), so a Linux venv restored onto a Windows runner is a broken interpreter path, not a slow cache hit. |

`zig-out` and `webapp_assets.zig` are deliberately **not** cached: they are
build output, regenerable from `.zig-cache` in seconds, and caching them cost
~124 MB of archive I/O per run.

## Functional tests

Both suites run in **one** `zig build functional-test-all`, in one pytest
process, per shard:

| Step | Runs | Used by |
|---|---|---|
| `zig build functional-test` | `pytest tests/functional/` (API only) | local iteration on one suite |
| `zig build functional-test-ui` | `pytest tests/functional_ui/` (Playwright only) | local iteration on one suite |
| `zig build functional-test-all` | **both directories, one pytest process** | the `functional-*` shards |

### Sharding

Three shards per platform (nine jobs). The split is `index % total == shard`
over the flat list of collected items, implemented in `tests/func_shard.py`
and applied by `tests/conftest.py` — which lives at `tests/` rather than in
either suite's `conftest.py` because pytest loads a conftest from every
directory between the rootdir and the test file, and a hook in
`tests/functional/` would never see an item collected from
`tests/functional_ui/`.

Two properties are load-bearing:

1. **The shards partition the suite.** Verified locally:
   778 collected = 260 + 259 + 259, and the union is byte-identical to the
   unsharded run. Modulo over *items* rather than files, because the two
   suites have wildly different per-file durations — splitting by file would
   hand one shard the entire UI suite.
2. **A bad shard index fails loudly.** `resolve_shard()` raises on an
   out-of-range index, a non-integer, or half a pair (e.g. `TOTAL` set but
   `INDEX` missing), and `tests/conftest.py` re-raises it as
   `pytest.UsageError` (exit 4, one clean line) rather than letting it become
   an `INTERNALERROR` traceback. An empty shard exits **0** and would report
   green over a third of the suite it never ran.

The contract is two environment variables on the pytest step:
`NALAR_FUNC_SHARD_TOTAL` and `NALAR_FUNC_SHARD_INDEX` (zero-based). Nothing
reaches `build.zig`: `b.addSystemCommand` inherits the parent environment, so
`zig build functional-test-all` forwards them to the pytest process it spawns
and the invocation stays the one the local dev loop uses. A local run with
neither variable set runs the whole suite, unchanged.

**No `-n auto`.** pytest-xdist is the obvious way to make this faster and it
is wrong here: the port picker binds a probe socket, closes it, and hands the
number to the nalar child, which binds tens of ms later. That gap is the
documented reason the random range lives at 20k-32k, and widening it does not
help when N workers draw from it simultaneously. Under `-n` the suite trades
a deterministic ~15 min for intermittent `BindFailed` at boot.

**Logs.** Each shard copies `/tmp/functional-test.log` into the workspace and,
on failure only, uploads it as `functional-test-<image>-shard-<n>-log`
(`continue-on-error`: artifact storage is an account-level quota this repo
does not control, and hitting it turned an otherwise-green run red once
already). The gate is the pytest step; the artifact is a diagnostic.

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

`NALAR_FUNCTIONAL_DRY_RUN=1` skips the rmtree and prints what would have
been deleted — useful for paranoia-debugging.

If a CI run ever deletes the runner's real `$HOME`, that is a P0 incident in
the harness, not a bug to fix in the test. The 12 negative tests in
`harness_safety_test.py` guard the invariants.

## Android

Two `ubuntu-24.04` jobs, side by side with the backends rather than under
them:

- **`android-apk`** — `:app:assembleDebug`, staged as
  `Nalar-android-debug.apk` and published to `ci-latest`. Debug-signed
  because no release keystore is committed and none is configured; `-debug`
  in the asset name is the disclosure.
- **`android-test`** — the emulator suite (ten scenarios on the real
  `MainActivity`, assertions on the rendered Compose tree) via
  `reactivecircus/android-emulator-runner@v2`. It `needs:` `android-apk` only,
  and runs under `!cancelled()` rather than `success()`: the emulator suite is
  the more valuable of the two signals, so a red Gradle build upstream must
  not turn ten scenarios into "skipped".

### Why they no longer wait for the backend matrix

`android-apk` used to be sequenced strictly after **all three** backend cells,
for one genuine reason: a GitHub Release row is last-writer-wins and
`softprops/action-gh-release@v2` takes no lock over the tag, so a publisher
that wrote a *different* body had to go last. The fix is
`scripts/ci-release-body.md` — one body file, rendered by a `sed` step in each
of the four publisher jobs and passed as `body_path`, so every publisher sends
byte-identical text and the order stops mattering. (Note the input is
`body_path`, not `body_file`, and its contents are read verbatim — which is
why the sha and run id are `@@SHA@@`/`@@RUN@@` placeholders substituted by
the step rather than `${{ }}` expressions.)

## `ci-ok`

```yaml
if: ${{ always() }}
```

Mandatory, not defensive: `ci-ok` *is* the required check, so if it is skipped
the PR is stuck on a check that will never report. It prints one
`job=result` line per upstream job and fails on any `failure`.

- `skipped` is **not** a failure — that is what a docs-only change produces,
  and it is a pass by decision, not by absence.
- `cancelled` is not a failure either (a superseded run is cancelled
  wholesale and GitHub does not gate on it) but it logs a `::warning::`,
  because "everything skipped" and "everything cancelled" look identical in
  the checks list otherwise.

## Downloading binaries

Binaries are **not** uploaded as Actions artifacts — artifact storage is
quota-metered and the repo hit the cap ("Artifact storage quota has been
hit", 2026-08-23). Releases do not count against that quota, so every green
`main` build publishes to the rolling release instead:

  https://github.com/ginwa123/ginwaaitoolbox/releases/tag/ci-latest

Assets (names carry the zig target triple):

  nalar-x86_64-linux-gnu          + nalar-desktop-x86_64-linux-gnu
  nalar-aarch64-macos             + nalar-desktop-aarch64-macos
  nalar-desktop-x86_64-windows-gnu.zip   (self-contained: both exes, every
                                          runtime DLL, WebView2Loader.dll,
                                          html/ and Install-Nalar.ps1)

macOS also ships `Nalar-aarch64-macos.zip` holding `Nalar.app`, and Android
ships `Nalar-android-debug.apk`.

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
cd src/apps/desktop && pnpm lint:check          # the `lint` CI job
bash scripts/ci-change-filter.sh --selftest     # the path classifier
```

Run ONE shard of the functional suite exactly as CI does:

```bash
NALAR_FUNC_SHARD_TOTAL=3 NALAR_FUNC_SHARD_INDEX=1 zig build functional-test-all
```

Local webapp deps: `cd src/apps/desktop && pnpm install --frozen-lockfile`
(or let `zig build` run it when `node_modules` is missing).

## Editing the workflows

Run `actionlint` on all three workflow files before pushing:

```bash
actionlint .github/workflows/ci.yml \
           .github/workflows/reusable/backend.yml \
           .github/workflows/reusable/functional.yml
```

GitHub rejects invalid workflow syntax at **parse** time: the run appears for
0 seconds, has zero jobs, and produces no logs to debug from, so a mistake
costs a full push cycle. "The YAML parses" is not a check — `actionlint` is
stricter and knows the expression contexts each key accepts (e.g. `runner` is
available in step `env:` but *not* in job-level `env:`; `shell:` accepts no
`${{ }}` at all). It also knows each action's real input list, which is how
the `body_file` → `body_path` bug in this very restructure was caught.

Three things to keep in sync when you edit:

- `ci-ok`'s `needs:` list and its `RESULTS` block — a new heavy job that is
  not in both does not hold up a merge.
- `ci-cancel-on-merge.yml`'s `concurrency.group` literal — it mirrors
  `ci.yml`'s on purpose.
- `.husky/pre-commit`, which mirrors the `lint` job's exact command so
  commits cannot slip past locally with lint errors CI would catch.
