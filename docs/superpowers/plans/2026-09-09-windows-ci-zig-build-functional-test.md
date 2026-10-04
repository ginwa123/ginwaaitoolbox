# Windows CI + zig build functional test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable `zig build functional-test` on the Windows CI cell and add a minimal canary functional test proving the Windows-built `pabrik.exe` boots and serves.

**Architecture:** Keep the existing `build.zig:functional-test` chain untouched (it is already Windows-aware: `Scripts/` venv, `python.exe`, `cmd.exe` probe). Add a Windows-only CI step running a smoke subset via `pwsh`, plus a new `tests/functional/zig_build_test.py` canary. Gate everything so Linux/macOS behavior is bit-identical.

**Tech Stack:** GitHub Actions (`ci.yml`, `pwsh` shell), Zig 0.16 `build.zig`, Python pytest + `tests/functional/harness.py` / `conftest.py`.

## Global Constraints

- `pwsh` is for Windows, `bash` is for mac/linux — never mix (repo rule, see ci.yml pwsh-bootstrap comment).
- Self-hosted runners persist workspaces: venv MUST stay at `${{ runner.temp }}/pabrik-ci-venv` via `PABRIK_FUNC_VENV_DIR`; never use workspace-relative `.venv-func` in CI.
- `PABRIK_BIN` on Windows MUST point at `zig-out/bin/pabrik.exe` (native `zig build` output, `b.graph.host.result`).
- Harness safety invariants (`is_safe_tmp`, `REQUIRED_TMP_SUBSTR=pabrik-func-`, no `rmtree` without gate) are P0 — do not weaken.
- Linux/macOS CI steps stay `shell: bash` + `runner.os != 'Windows'` gates untouched; Windows step is ADDITIVE.
- Line endings: LF everywhere (`.gitattributes`); new `.py` must be LF.

## Files touched

- `.github/workflows/ci.yml` — add one Windows-only functional-test step (after `zig build test`, before staging).
- `tests/functional/zig_build_test.py` — NEW canary test (boot + health + workspace CRUD).
- `tests/functional/conftest.py` — (only if needed) ensure `pabrik.exe` resolves when `PABRIK_BIN` unset; currently already lists `pabrik.exe` so likely no change.
- `docs/superpowers/plans/2026-09-09-windows-ci-zig-build-functional-test.md` — this plan.

## Why this shape (findings)

- `ci.yml:1477,1512,1557,1613` — four steps still gate `runner.os != 'Windows'`: venv cache, `functional-test`, pnpm install, `functional-test-ui`. The matrix comment at `ci.yml:80-88` says Windows should have parity, but the gates were never lifted.
- `build.zig:3064-3171` — `functional-test` is already Windows-capable (venv `Scripts/`, `python.exe`, `cmd.exe /c where` probe, `\\`→`/` normalize, PATH scan skipping 0-byte Store stubs). No build.zig change needed for v1.
- `harness.py:ALLOWED_TMP_PREFIXES` + XDG/APPDATA isolation + `_SIGKILL` fallback — already Windows-aware. `conftest.py` already probes `pabrik.exe`.
- Risk on Windows: full 55-test suite is ~5 min + flaky (port scan, venv cold). So v1 runs a smoke SUBSET (`zig_build_test.py + smoke_boot_test.py`), not the whole `tests/functional/` dir. Full-suite enablement is a follow-up.

---

### Task 1 — Add `tests/functional/zig_build_test.py` canary

- [ ] Write failing test: new file `tests/functional/zig_build_test.py` with 3 tests using the existing `harness` fixture:
  ```python
  def test_zig_build_binary_boots_and_healthy(harness): assert harness.health() is True
  def test_zig_build_workspace_crud(harness): POST /api/workspaces → 200, GET list contains it
  def test_zig_build_tempdir_isolated(harness): is_safe_tmp(harness.temp_dir, harness.orig_home) is True
  ```
  Keep it dependency-free (no mcp binaries, no Vite, no playwright) so it runs on a bare Windows `zig build` output.
- [ ] Run it to see it fail (no binary / bad import): `PABRIK_BIN=$(pwd)/zig-out/bin/pabrik python3 -m pytest tests/functional/zig_build_test.py -v`
- [ ] Implement: fix imports/fixture usage until green on Linux (dev box is Linux; Windows parity comes from harness, not test logic).
- [ ] Run full local verify: `zig build test --summary all` still passes; `PABRIK_BIN=... python3 -m pytest tests/functional/zig_build_test.py tests/functional/smoke_boot_test.py -v` green.
- [ ] Commit: `feat(tests): add zig_build_test.py canary for Windows zig build`

### Task 2 — Add Windows-only CI step running the canary via `zig build`

- [ ] Write failing check: `grep -n "zig_build_test" .github/workflows/ci.yml` returns nothing (proves step missing).
- [ ] Implement in `ci.yml` right after the `Functional tests` step (`~line 1543`), before `Install pnpm`:
  ```yaml
  - name: "Functional tests (Windows): zig build canary"
    if: matrix.target.step == 'install:windows-nat' && runner.os == 'Windows'
    shell: pwsh
    env:
      PABRIK_FUNC_VENV_DIR: ${{ runner.temp }}/pabrik-ci-venv
      PABRIK_BIN: zig-out/bin/pabrik.exe
    run: |
      $ErrorActionPreference = 'Stop'
      # reuse the venv build.zig creates; run only the canary subset (fast, no Vite)
      zig build functional-test --summary all -Dno-webapp-rebuild  # OR direct pytest below
      # precise subset (preferred v1 — avoids 5-min full suite on Windows):
      # & "$env:PABRIK_FUNC_VENV_DIR/Scripts/python.exe" -m pytest tests/functional/zig_build_test.py tests/functional/smoke_boot_test.py -v --tb=short
  ```
  Decision at implement time: if `zig build functional-test` runs the WHOLE dir, prefer the direct-pytest two-file invocation (venv python must exist — depend on a venv-ensure preamble: `zig build functional-test` creates venv but runs everything; so preamble = `python -m venv` + `pip install -r tests/functional/requirements.txt` if venv missing). Document the choice in the PR.
  `shell: pwsh` (not bash) per repo rule; `PABRIK_BIN` uses forward slashes (pwsh accepts both; forward avoids escaping).
- [ ] Verify YAML: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"` (or `actionlint` if available); `git diff --check` clean (LF).
- [ ] Commit: `feat(ci/windows): run zig build functional-test canary (zig_build_test.py)`

### Task 3 — Docs + PR

- [ ] Update `tests/functional/README.md` "Running on Windows" snippet (pwsh, `pabrik.exe`, venv `Scripts/`).
- [ ] Open PR with: what changed, why subset-not-full, CI run link showing Windows cell green, Linux/macOS cells unaffected.
- [ ] Do NOT lift the `runner.os != 'Windows'` gates on the full `functional-test` / `functional-test-ui` steps in this PR — that is the follow-up after the canary is green for a week.

## Out of scope (follow-ups)

- Full 55-test Windows enablement (remove `runner.os != 'Windows'` from `functional-test` step).
- `functional-test-ui` (Playwright/Chromium) on Windows.
- `actions/cache` for the Windows venv (`~/.cache/ms-playwright` + `runner.temp` paths differ on Windows; needs separate key).
- Any `build.zig` change (probe already handles Windows).

## Verification

- [ ] Plan saved to `docs/superpowers/plans/2026-09-09-windows-ci-zig-build-functional-test.md`
- [ ] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task has bite-sized steps (test → implement → verify → commit)
- [ ] User has reviewed the plan before execution begins
