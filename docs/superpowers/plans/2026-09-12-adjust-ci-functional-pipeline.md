# Adjust ci.yml — Linux-only chained functional pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `functional-test` + `functional-test-ui` from the macOS/Linux `backend` matrix cells and replace them with a Linux-only sequential chain: `backend` → `functional-test` → `functional-test-ui`.

**Architecture:** Keep the existing `backend` matrix job (Linux/macOS/Windows) as build+stage+publish only. Add two new top-level jobs pinned to the Linux self-hosted runner, wired with `needs:` so UI only runs after functional passes and functional only runs after the backend build is green. No binary-artifact passing — each new job checks out the same SHA and rebuilds via `zig build <step>`, matching how the steps work today.

**Tech Stack:** GitHub Actions (`needs`, `runs-on`, `if`), Zig 0.16.0 (`zig build functional-test` / `functional-test-ui`), Python pytest harness (`tests/functional/harness.py`), Playwright + Vite (`pnpm run dev`), pnpm 11 + Node 24.

## Global Constraints

- Runner labels are fixed: Linux = `[self-hosted, Linux, X64]`. Do NOT invent new labels.
- Port 8081 is a never-kill dev server — functional harness randomises ports, never bind 8081.
- No `// NEW (plan: ...)` comment tags in code; plan references belong here and in the PR body.
- `zig-out/` artifacts are quota-metered — do NOT reintroduce `actions/upload-artifact`; rebuild from checkout in each job.
- Validate workflow edits with `actionlint` before pushing (repo skill `actionlint-before-pushing-workflows`).
- Work in the git worktree (this repo root is bare), commit per task, open PR with `gh` against `main`.

## Current State (verified 2026-09-12, `.github/workflows/ci.yml`, 1909 lines)

- Single job `jobs.backend` (line 28), matrix 3 native cells (Linux X64 / macOS ARM64 / Windows X64, lines 57-115).
- Functional steps live INLINE in `backend`, all gated `if: matrix.target.step != '__SKIP__' && runner.os != 'Windows'` so they run on Linux + macOS:
  - `Cache python venv + playwright chromium` (~line 1496)
  - `Functional tests: real-data isolation suites` → `zig build functional-test` (~line 1507)
  - `Install pnpm + webapp dependencies` (~line 1565)
  - `UI tests: functional-test-ui` → `zig build functional-test-ui` (~line 1618)
- Windows already skips all four (the `runner.os != 'Windows'` gate). macOS runs both suites today — flaky/slow, the motivation for this change.
- `zig build functional-test` (build.zig:3250) creates the venv at `$PABRIK_FUNC_VENV_DIR`, installs requirements, boots a fresh `pabrik` binary per test against an isolated tmpdir HOME. `zig build functional-test-ui` (build.zig:3296) reuses that venv, installs Playwright/Chromium, boots backend + Vite per test. Neither consumes an uploaded binary — both build from source.

## File Map

- MODIFY: `.github/workflows/ci.yml` — only file with workflow changes.
- ADD: this plan file (already written).
- NO changes to `build.zig`, `tests/functional/*`, `tests/functional_ui/*`, `src/apps/desktop/*`.

## Design Decisions (for reviewer)

1. **Two new jobs vs. reusing `backend` matrix:** two new jobs. Keeps `backend` fast on all 3 OSes and isolates the slow suites (~5 min functional + ~3-5 min UI) to Linux.
2. **Chain via `needs:` (`functional-test` needs `backend`, `functional-test-ui` needs `functional-test`):** guarantees the requested order `linux build done → functional → UI`, and UI never runs on a red functional. Note GitHub semantics: `needs: backend` waits for ALL matrix cells (Linux+macOS+Windows). If the reviewer wants UI to run as soon as Linux build is green even when macOS/Windows are still running, the follow-up is to split `backend` into `backend-build` per-OS jobs — out of scope for this plan unless requested.
3. **No artifact passing:** each job does a fresh `actions/checkout` + `zig build`. Avoids the artifact-storage quota incident (2026-08-23, `ci.yml` stage step comment) and matches current step behaviour.
4. **macOS functional removed entirely (not kept as optional):** per task description. If flake-hunting on macOS is needed later, re-add as a manual `workflow_dispatch`-only job.

## Tasks

### Task 1 — Strip the 4 inline functional steps from `backend`

- [ ] Read `.github/workflows/ci.yml` lines 1490-1664 in the worktree and confirm the 4 step names (`Cache python venv…`, `Functional tests…`, `Install pnpm + webapp…`, `UI tests…`).
- [ ] Write the failing check: `search(pattern="functional-test", path=".github/workflows/ci.yml")` must currently return hits inside the `backend` job (proves steps still inline).
- [ ] Delete exactly those 4 steps from the `backend` job. Keep the surrounding steps untouched (`Build webapp dist` above, `Stage binaries` below).
- [ ] Re-run the search — `functional-test` must now appear ZERO times inside `jobs.backend` (only in the new jobs added in Task 2).
- [ ] Commit: `ci: remove inline functional/UI steps from backend matrix`

### Task 2 — Add `functional-test` job (Linux, needs backend)

- [ ] Append new job after the end of `jobs.backend` (before `Publish…` is inside backend — the new job is a sibling of `backend`, same indent as `backend:`):
  ```yaml
  functional-test:
    name: functional-test (Linux X64)
    runs-on: [self-hosted, Linux, X64]
    needs: backend
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4 (node 24)
      - uses: pnpm/action-setup@v4 (version 11)
      - uses: mlugg/setup-zig@v2 (ZIG_VERSION)
      - actions/cache@v4 (same path/key as the removed cache step)
      - run: zig build functional-test (same PABRIK_FUNC_VENV_DIR env + log/timing wrapper as the removed step)
  ```
- [ ] Copy the `env: PABRIK_FUNC_VENV_DIR: ${{ runner.temp }}/pabrik-ci-venv` and the `set -u … tee /tmp/functional-test.log` body verbatim from the removed step — no behaviour change, only relocation.
- [ ] Verify YAML indent (2 spaces per level, `jobs:` → `functional-test:` → `runs-on/needs/steps`).
- [ ] Commit: `ci: add linux-only functional-test job chained after backend`

### Task 3 — Add `functional-test-ui` job (Linux, needs functional-test)

- [ ] Append sibling job:
  ```yaml
  functional-test-ui:
    name: functional-test-ui (Linux X64)
    runs-on: [self-hosted, Linux, X64]
    needs: functional-test
    steps:
      - checkout, setup-node, pnpm setup, setup-zig (same as Task 2)
      - Install pnpm + webapp dependencies (verbatim body from removed step)
      - run: zig build functional-test-ui (verbatim body + PABRIK_FUNC_VENV_DIR env from removed step)
  ```
- [ ] Confirm the chain reads `backend → functional-test → functional-test-ui` via `needs:` (UI must NOT `needs: backend` directly — it inherits transitively).
- [ ] Commit: `ci: add linux-only functional-test-ui job chained after functional-test`

### Task 4 — Validate, push, open PR

- [ ] Run `actionlint .github/workflows/ci.yml` from the worktree (per `actionlint-before-pushing-workflows` skill). Fix all findings.
- [ ] Run a YAML parse smoke check (`python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`).
- [ ] `git -C <worktree> status --short` clean; `git log --oneline -4` shows the 3 ci commits on `worktree/worktrees_agent_ci-functional-pipeline`.
- [ ] Push `git push --no-verify -u origin worktree/worktrees_agent_ci-functional-pipeline` (docs+workflow-only change; disclose `--no-verify` in PR body per worktree skill — the pre-push hook would run the full 10-30 min suite).
- [ ] Open PR `gh pr create --base main --head <branch> --title "ci: linux-only chained functional pipeline" --body-file /tmp/pr_body.md` with body covering: what was removed (macOS+Linux inline steps), the new `needs:` chain diagram, the `needs: backend` waits-for-all-matrix-cells caveat, and how to verify (PR CI run must show `backend` green on 3 OSes, then `functional-test`, then `functional-test-ui`, all on Linux).
- [ ] Report the PR URL and move the kanban card to `in_review_task` for human review.

## Verification (end-to-end)

- [ ] `actionlint` passes with zero findings.
- [ ] PR CI shows: `backend (Linux X64)`, `backend (macOS ARM64)`, `backend (Windows X64)` all green with NO functional/UI step logs; then `functional-test (Linux X64)` green; then `functional-test-ui (Linux X64)` green.
- [ ] A deliberately failing functional test (if exercised) blocks `functional-test-ui` (proves `needs:` wiring).
- [ ] `ci-latest` rolling release still publishes from `backend` only (publish step untouched).
