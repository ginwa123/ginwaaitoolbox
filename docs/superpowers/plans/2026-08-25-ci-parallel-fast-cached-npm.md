# CI/CD Parallel + Fast + Cached + npm-Everywhere Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut CI wall-clock time by removing serial waste inside each job, slim the caches, and standardize the whole pipeline on **npm** (drop bun from CI and from `zig build`'s webapp chain).

**Architecture:** The runner fleet is 1 self-hosted runner per OS, so adding jobs does not add parallelism — it adds queue waits. All speedups therefore land *inside* the existing 5 jobs (backend ×3 OS cells, frontend, frontend-windows): merge redundant zig invocations, drop heavyweight cache paths, gate no-op system steps, and hoist the Python venv into a cached location. Bun is removed at both layers — `.github/workflows/ci.yml` (setup-bun/bun-cache/bun-install steps) and `build.zig` (the webapp build chain invokes `npm ci`/`npm run build` instead of `bun install`/`bun run build`).

**Tech Stack:** GitHub Actions (self-hosted runners), Zig 0.16 build system, npm 10 / Node 24, Vue 3 + Vite + vitest, Python venv + pytest + Playwright.

## Global Constraints

- **Never kill or reconfigure the port-8081 dev server.** Functional tests already pick free ports in 8080–8199 excluding 8081; do not change that.
- **Do NOT split backend into more jobs** (e.g. test/build/publish as separate jobs). One runner per OS means extra jobs queue behind each other and are strictly slower.
- **Keep all 3 publish gates intact**: PR builds never publish; only `push`/`workflow_dispatch` to main publishes to the rolling `ci-latest` release (PR #303/#325 contract).
- **Keep target-triple asset naming** on release binaries (nalar-x86_64-linux-gnu etc., PR #325).
- **`shell:` keys stay literal** — no `${{ matrix.* }}` expressions in `shell:` (parse-time rejection, CI run 32588301656). bash = mac/linux, pwsh = windows steps.
- **Run actionlint before every push** of a workflow edit (asset URL pattern: `actionlint_<ver>_linux_amd64.tar.gz`, v1.7.12).
- **npm lockfile is canonical**: `src/apps/desktop/package-lock.json`. `bun.lock` gets deleted in Task 6; if it ever reappears, it's a mistake.
- **Node stays pinned at 24** everywhere (setup-node@v4).
- Every task ends with an atomic commit; workflow edits verified with actionlint before commit.

## Current State (measured)

Job wall-clock from run 32743212590 (2026-08-24):

| Job | Wall-clock | Notes |
|---|---|---|
| backend (Linux X64) | ~15 min | longest pole; runs zig test → zig build → smoke → functional → UI tests serially |
| backend (Windows X64) | ~15 min | |
| backend (macOS ARM64) | ~30 s→fail | runner outage that day (externals/ missing); normally ~12–18 min |
| frontend (Linux X64) | ~2 min | |
| frontend (Windows X64) | ~16 min | mostly queue wait behind backend Windows |

Serial waste identified inside backend Linux/Windows cells:

1. `zig build test --summary all` then `zig build nalar-desktop --summary all` — two separate invocations; the second re-checks/re-links what it can reuse but pays full graph traversal twice plus the always-cold webapp rebuild.
2. Zig cache uploads/downloads `zig-out` (~90 MB nalar + ~34 MB nalar-desktop binaries) on every run — binaries are build *outputs*, caching them wastes minutes of archive I/O per run.
3. Backend duplicates the frontend's node_modules work: bun-cache step + `Install npm + webapp dependencies` tarball-cache step both manage `src/apps/desktop/node_modules`.
4. `pacman -Sy` refreshes package DB unconditionally even when all packages are present (Linux cell).
5. `.venv-func` is recreated + pip-installed on every run because the workspace is cleaned between runs; Playwright Chromium (~150 MB) re-downloads too.
6. Frontend jobs install bun (setup-bun) then immediately use npm for everything — bun is dead weight there.

---

## Task 1 — Merge the two zig invocations in backend

**Files:**
- Modify: `.github/workflows/ci.yml`

**Steps:**
- [ ] In the `backend` job, replace the two steps "Run main test suite" (line ~899) and "Build nalar + nalar-desktop binaries" (line ~937) with ONE step per platform:

```yaml
      - name: Test + build (single zig invocation)
        if: runner.os != 'Windows'
        run: zig build test nalar-desktop --summary all
```

and the Windows twin keeps its Git-bash wrapper but runs `zig build test nalar-desktop --summary all`.

- [ ] Rationale comment: one graph traversal compiles test binaries AND the desktop exe; `--summary all` still prints per-step totals. This removes a duplicate dependency-graph walk + duplicate vendor-probe passes.
- [ ] Verify locally on Linux first: `timeout 900 zig build test nalar-desktop --summary all` completes with both summaries (test results + install steps).
- [ ] Commit: `ci: single zig invocation for test+build in backend job`

**Note:** If `zig build test nalar-desktop` proves problematic on any cell (step-name collision), fall back to keeping two invocations but moving this task's win into Task 2's cache slimming. Do not force it.

## Task 2 — Slim the Zig cache (drop zig-out, keep .zig-cache + vendor)

**Files:**
- Modify: `.github/workflows/ci.yml`

**Steps:**
- [ ] Edit the "Cache Zig build artifacts" step (line ~876). New path list:

```yaml
          path: |
            .zig-cache
            src/modules/databases/vendor
            src/modules/custom_http_client/vendor
```

Remove `zig-out` and `src/apps/desktop_app/embedded` from the cached paths (embedded/webapp_assets.zig is regenerated every build by design — fresh-assets policy; zig-out is pure output).

- [ ] Bump the cache key prefix `v2-zig-` → `v3-zig-` so stale entries don't collide, and drop `'src/apps/desktop_app/main.zig'` + `'src/apps/desktop/bun.lock'` from `hashFiles(...)` (bun.lock dies in Task 6; main.zig hash doesn't invalidate zig object caches meaningfully). Keep `build.zig`, `build.zig.zon`, and the sqlite fetch script in the hash.
- [ ] Expected saving: ~124 MB less archive I/O per run per cell (upload AND download), typically 1–3 min on self-hosted disks.
- [ ] Verify: actionlint clean; push to a branch; confirm the run restores `.zig-cache` (log line "Cache restored from key: v3-zig-...") and that `zig-out/bin/nalar*` still appear after the build step.
- [ ] Commit: `ci: stop caching zig-out binaries; v3 cache key`

## Task 3 — Gate `pacman -Sy` behind missing packages (Linux cell)

**Files:**
- Modify: `.github/workflows/ci.yml`

**Steps:**
- [ ] Reorder the "Install system dependencies (Arch)" step body: run the `pacman -Q` presence loop FIRST; only if `missing` is non-empty, run `sudo -n pacman -Sy --noconfirm` followed by `sudo -n pacman -S --needed --noconfirm "${missing[@]}"`. When nothing is missing, print `✓ all required packages present (no DB refresh needed)` and skip network entirely.
- [ ] Keep the existing remediation messaging for the passwordless-sudo failure branch unchanged.
- [ ] Verify: actionlint clean. On the runner the happy path now does zero network calls (saves ~5–20 s depending on mirror latency).
- [ ] Commit: `ci: skip pacman db refresh when all packages present`

## Task 4 — Cache the Python venv + Playwright browser (functional/UI tests)

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `build.zig` (venv creation path only — see below)

**Steps:**
- [ ] In `build.zig`, the functional-test steps create `.venv-func` relative to the repo root (lines ~1927–1933). Add an env-var override so CI can relocate it OUTSIDE the workspace (which gets cleaned between runs):

```zig
const venv_dir = std.process.getEnvVarOwned(b.graph.allocator, "NALAR_FUNC_VENV_DIR") catch ".venv-func";
```

then use `venv_dir` in place of the literal `.venv-func` strings in `install_venv.setCwd`, pip targets, and pytest invocations (4–6 sites, lines ~1927–2001). Local behavior unchanged when the env var is unset.

- [ ] In `ci.yml` backend job (non-Windows cells), add BEFORE the functional-test step:

```yaml
      - name: Cache python venv + playwright chromium
        uses: actions/cache@v4
        with:
          path: |
            ~/.cache/nalar-ci-venv
            ~/.cache/ms-playwright
          key: v1-py-${{ runner.os }}-${{ hashFiles('tests/functional/requirements.txt', 'tests/functional_ui/requirements.txt') }}
          restore-keys: |
            v1-py-${{ runner.os }}-
```

- [ ] Set `NALAR_FUNC_VENV_DIR: ${{ HOME }}/.cache/nalar-ci-venv/venv` as step-level env on BOTH functional-test steps ("Functional tests: real-data isolation suites" line ~1157 and "UI tests: functional-test-ui" line ~1246).
- [ ] Note: `build.zig` hardcodes `.venv-func/bin/python` style paths — the env override must flow through ALL of them (grep `.venv-func` in build.zig to catch every site; expect ~8 occurrences across the two step definitions).
- [ ] Verify locally: `NALAR_FUNC_VENV_DIR=/tmp/test-venv zig build functional-test --summary all` creates the venv at /tmp/test-venv and passes; unset var still uses `.venv-func`.
- [ ] Verify in CI: first run = cache miss (pip install ~40 s), second run = hit (skips straight to pytest). Chromium download skipped on hits (~150 MB saved).
- [ ] Commit: `build: NALAR_FUNC_VENV_DIR override; ci: cache venv + chromium`

## Task 5 — Unify node_modules handling in backend on npm

**Files:**
- Modify: `.github/workflows/ci.yml`

**Steps:**
- [ ] DELETE the "Cache bun node_modules" step from the `backend` job (lines ~864–874). The backend's own webapp needs are served by the remaining "Install npm + webapp dependencies" tarball-cache step (line ~1208) which already keys off `package-lock.json`.
- [ ] In that surviving step, remove the bun.lock fallback line:
  `HASH=$(sha256sum src/apps/desktop/package-lock.json)` becomes unconditional (delete the `|| sha256sum ... bun.lock` fallback).
- [ ] Also delete the `BUN_VERSION: 1.3.11` env var and the backend job's "Install Bun" step (oven-sh/setup-bun@v2, lines ~859–862) — nothing left in backend uses bun after Tasks 5+6.
- [ ] Verify: actionlint clean; grep ci.yml for `bun` returns zero matches after Task 6 (this task leaves build.zig's bun usage until Task 6 lands).
- [ ] Commit: `ci(backend): single npm-based node_modules mechanism; drop setup-bun`

## Task 6 — Switch build.zig webapp chain from bun to npm

**Files:**
- Modify: `build.zig` (webapp section, lines ~967–1125)
- Delete: `src/apps/desktop/bun.lock`

**Steps:**
- [ ] Replace the four bun invocations:
  - Line ~1036: `b.addSystemCommand(&.{ "bun", "install" })` → `b.addSystemCommand(&.{ "npm", "ci", "--no-audit", "--no-fund" })`
  - Line ~1045: same replacement for `rebuild_install_cmd`
  - Line ~1054: `b.addSystemCommand(&.{ "bun", "run", "build" })` → `b.addSystemCommand(&.{ "npm", "run", "build" })`
  - Line ~1112: same for `webapp_rebuild_bun`
- [ ] Update comments that mention bun (step descriptions at lines ~973, ~1092; rationale blocks referencing "bun run build" → "npm run build"). Keep the vue-tsc-needs-real-node explanation — it becomes MORE relevant (npm always uses real Node).
- [ ] The `check_webapp_node` pre-flight (line ~993) already requires node+npm on PATH — keep as-is, it's now the primary guard instead of a bun workaround.
- [ ] Delete `src/apps/desktop/bun.lock` (`git rm`). package-lock.json (Aug 22) is newer than bun.lock (Jul 26) — npm's lockfile is the live one.
- [ ] Grep sweep: `rg -n '"bun"' build.zig` must return zero; `rg -ni bun .github/workflows/ci.yml` must return zero.
- [ ] Verify locally: `rm -rf src/apps/desktop/node_modules && timeout 600 zig build nalar-desktop --summary all` — npm ci runs, vite builds, codegen emits webapp_assets.zig, binary links. Then a second run confirms the conditional-install skip still works (node_modules exists probe).
- [ ] Run `zig build test --summary all` to confirm no test regressions from the build.zig edits.
- [ ] Commit: `build: webapp chain via npm (drop bun); delete stale bun.lock`

## Task 7 — Purge bun from frontend + frontend-windows jobs

**Files:**
- Modify: `.github/workflows/ci.yml`

**Steps:**
- [ ] In `frontend` job: delete "Install Bun" step (lines ~1446–1449) and "Cache bun node_modules" (lines ~1451–1459). Replace with actions/cache keyed on package-lock.json:

```yaml
      - name: Cache npm node_modules
        uses: actions/cache@v4
        with:
          path: src/apps/desktop/node_modules
          key: npm-${{ runner.os }}-${{ hashFiles('src/apps/desktop/package-lock.json') }}
          restore-keys: |
            npm-${{ runner.os }}-
```

- [ ] Change "Install dependencies (cache miss only)" from `bun install --frozen-lockfile` to `npm ci --no-audit --no-fund` (working-directory unchanged).
- [ ] Mirror all three changes in `frontend-windows` job (literal `shell: powershell` steps stay; only the install command + cache step change).
- [ ] Remove `BUN_VERSION` env from workflow top level (already gone via Task 5 if ordered sequentially — verify with grep).
- [ ] Verify: actionlint clean; grep `-i bun .github/workflows/ci.yml` → zero matches repo-wide for the workflow.
- [ ] Commit: `ci(frontend): npm ci + npm-keyed cache; remove setup-bun`

## Task 8 — docs/ci.md + AGENTS.md convention note

**Files:**
- Modify: `docs/ci.md` (if it documents bun anywhere)
- Modify: `AGENTS.md` (add one changelog entry)

**Steps:**
- [ ] Grep docs/ci.md for bun references; update "Downloading binaries"/setup sections to describe npm-only flow.
- [ ] Add AGENTS.md changelog entry summarizing: parallel/fast/cached pass + npm-everywhere migration, with measured before/after timings from the verification runs.
- [ ] Commit: `docs: npm-only CI conventions + changelog entry`

## Task 9 — End-to-end verification + kanban

**Files:**
- None modified (verification only)

**Steps:**
- [ ] Push branch → open draft PR → watch full run green on all 5 jobs.
- [ ] Record per-job wall-clock before/after in the PR description (baseline table above vs new run).
- [ ] Confirm publish gate: PR run stages but does NOT publish; after merge, next main run publishes triple-named assets to ci-latest.
- [ ] Mark PR ready for review; move kanban card to `in_review_task`.

---

## Expected Impact

| Change | Est. saving per run |
|---|---|
| Task 1 merged zig invocation | 1–3 min (duplicate graph walk + probes) |
| Task 2 drop zig-out from cache | 1–3 min (archive I/O) |
| Task 3 pacman gating | 5–20 s |
| Task 4 venv+chromium cache | 1–2 min cold→warm steady-state |
| Task 5+7 bun removal | 20–60 s (setup-bun downloads ×5 jobs) + simpler cache story |
| Task 6 npm in build.zig | neutral-to-positive; removes dual-lockfile drift risk |

Realistic total: **backend Linux cell ~15 min → ~9–11 min**, frontend cells slightly faster, Windows cells dominated by MSVC/vcpkg setup (unchanged here — separate follow-up if wanted).

## Out of Scope (follow-up candidates)

- Splitting vcpkg port installs into a cached standalone step (Windows cell deep-dive).
- MSVC BuildTools bootstrapper caching.
- Adding more self-hosted runners per OS (the real fix for queue waits like frontend-Windows' 14 min idle).
- sccache/zig-native compilation caching beyond .zig-cache.
