# Fix CI Windows — install PowerShell Core (pwsh), drop the powershell.exe + bash mix

**Date:** 2026-08-20
**Status:** PR #271 — bash→pwsh part shipped. The vendored-curl-on-Windows
follow-up (`is_safe_tmp`/Perl/`Locale::Maketext::Simple`) is a separate
problem that's currently gated on `__SKIP__` until either (a) the
openssl Configure Perl gets `Locale::Maketext::Simple` provided, or
(b) `build.zig` skips the vendor steps when the cell already has
vcpkg-installed sqlite3/curl/openssl (the simpler fix).
**Author:** ginwa123 (LLM agent)
**Branch:** worktree/fix-ci-windows-pwsh
**Worktree:** `.worktrees/fix-ci-windows-pwsh`
**Target PR:** `ginwa123/ginwaaitoolbox#NNN` (TBD)

## Problem

`.github/workflows/ci.yml` uses three different shells on Windows:
- `shell: powershell` (Windows PowerShell 5.1) — **4 places** (lines 295, 410, 494, 626)
- `shell: pwsh` (PowerShell Core 7+) — **2 places** (lines 812, 837)
- `shell: bash` (Git-bash from Git for Windows) — **1 place** (line 949)

The `pwsh` shell directive fails because **PowerShell Core 7+ is NOT installed on the self-hosted `WIN-53JVAKR3O5B` Windows runner**. CI run **32166386051** (and every subsequent Windows PR run since the bash→pwsh switch) fails at:

```
2026-08-18T17:42:48.9833304Z ##[error]pwsh: command not found
```

The whole `backend (Windows X64)` job fails on `Run main test suite (Windows)` — **before the build ever starts**. macOS, Linux, and frontend jobs all stay green.

## User's rule

> bash is for mac and linux
> and pwsh is for windows

Goal: every Windows-only step uses `shell: pwsh`. Linux/macOS stay on `shell: bash` (already correct).

## Constraints uncovered while reading the file

1. **`shell: powershell` was chosen historically because PowerShell Core 7+ isn't pre-installed on the runner.** The comment at lines 285–294 explains this. We need to **install pwsh first** before any step can use `shell: pwsh`.

2. **PowerShell 5.1 parser bug with long scripts** (PR #244 history, runs 31841182154 / 31859864874 / 31860741395 / 31861962678 / 31864244047). The big scripts were split into ~50-line chunks. **pwsh doesn't have this bug**, so once we switch to pwsh we can leave the existing splits (don't introduce risk on this PR) — but we CAN remove the comment block that explains the split was for 5.1.

3. **The self-hosted runner has Git for Windows installed** (proven by the existing `bash`/`timeout`/`grep` smoke test step). We don't have to keep bash on the path for pabrik's build — but **Zig's `addSystemCommand` invokes `bash src/modules/databases/scripts/fetch-vendor-sqlite3.sh`** inside `zig build test`. That happens at *runtime* of the test step, not at step setup. Our existing pwsh wrapper already handles this with `$env:PATH = 'C:\Program Files\Git\bin;' + $env:PATH` — keep it.

4. **winget is available** — proven by the existing `Install ripgrep via winget` block (lines 583–591) and the MSVC installer block (line 345). Use it as the canonical install path when possible.

## Design — minimal, surgical, in-canon-with-existing-patterns

### Change 1: Add an idempotent `Install PowerShell Core (pwsh) on Windows` step

Runs as `shell: powershell` (we must, since pwsh isn't on PATH yet). Mirrors the existing idempotent-install pattern at line 350–356 for vcpkg and line 583–591 for ripgrep.

```
$pwshRoot = Join-Path $env:USERPROFILE 'pwsh'
$pwshExe  = Join-Path $pwshRoot 'pwsh.exe'
if (Test-Path -LiteralPath $pwshExe) {
  Write-Host ("ok pwsh already at " + $pwshExe)
} else {
  Install pwsh via winget (`Microsoft.PowerShell`) OR fallback
  to the portable .zip download if winget is unavailable.
  Idempotent: pass the `--accept-package-agreements --accept-source-agreements`
  flags like the existing ripgrep install.
}
$env:PATH = $pwshRoot + ';' + $env:PATH
Add-Content -Path $env:GITHUB_ENV -Value ('PATH=' + $env:PATH)
& $pwshExe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' | Write-Host
```

Pin to a specific PowerShell 7 LTS (7.4.6) — same approach as the existing `ZIG_VERSION` / `BUN_VERSION` env pins. The portable .zip gets cached; winget is called only on the first run.

Place the step **immediately after the existing `Install Zig` step**, gated on `runner.os == 'Windows'`, BEFORE the vcpkg install steps. That way pwsh is available to every subsequent `shell: pwsh` step in the Windows pipeline.

### Change 2: Switch `shell: powershell` → `shell: pwsh` (4 sites)

| Line  | Step name                                 | Current shell       | New shell |
|------:|-------------------------------------------|---------------------|-----------|
| 295   | Install vcpkg + MSVC build tools (Windows)| `shell: powershell` | `shell: pwsh` |
| 410   | Install vcpkg ports (Windows)             | `shell: powershell` | `shell: pwsh` |
| 494   | Stage WebView2 + integrate vcpkg (Windows)| `shell: powershell` | `shell: pwsh` |
| 626   | Show toolchain versions (Windows)         | `shell: powershell` | `shell: pwsh` |

These two were already on pwsh and stay that way:
- Line 812 — `Run main test suite (Windows)` (no change)
- Line 837 — `Build pabrik + pabrik-desktop binaries (Windows)` (no change)

### Change 3: Rewrite the Windows desktop smoke test in PowerShell

Step at line 939–966 uses `shell: bash` because the bash script needs GNU `timeout` + `grep`. Rewrite in PowerShell:
- `$proc = Start-Process ... -PassThru -RedirectStandardOutput ...`
- `$proc.WaitForExit(10000)` — 10-second timeout (same semantics as `timeout 10`)
- `Select-String -Path ... -Pattern 'smoke:' -Quiet` for the equivalent of `grep -q`
- `exit $LASTEXITCODE` on failure instead of `exit $rc`

Switch `shell: bash` → `shell: pwsh`, swap the run body for a faithful PowerShell translation.

### Change 4: Remove obsolete comments

- The 13-line "PowerShell 5.1 parser bug" block-comment at line 285–297 was added because `shell: powershell` was forced. With pwsh installed, that block-comment about 5.1's brace-counter bug becomes irrelevant. **Leave the existing script splits in place for this PR** to limit blast radius, but trim the comment block from ~14 lines to ~3 lines that simply say "pwsh" (the historical context lives in `docs/superpowers/specs/`).
- The "Working fix: use `shell: bash`" block-comment at line 803–811 already documents the right behavior for the pwsh wrapper. Keep it.

### Changes that are NOT in this PR (out of scope)

- **Frontend on Windows**: `frontend` job matrix (line 1078) excludes Windows deliberately — "Bun on the Windows self-hosted runner has unverified edge cases". Out of scope.
- **Functional tests on Windows**: line 1016 is gated on `runner.os != 'Windows'`. The `is_safe_tmp()` allow-list is POSIX-only. Tracked as a separate follow-up; out of scope.
- **Smoke test 'criteria pass' on Windows**: line 897 is the matrix-level smoke test. The user task is fixing bash/pwsh — not extending smoke-test coverage to Windows.

## Files

- `docs/superpowers/plans/2026-08-20-fix-ci-windows-pwsh.md` — this plan
- `docs/superpowers/specs/2026-08-20-fix-ci-windows-pwsh-design.md` — design spec (separate document, only after the plan is approved)
- `.github/workflows/ci.yml` — surgical edits per Changes 1-4 above

Total: **2 NEW (plan + spec), 1 EDIT (ci.yml)**.

## Verification

After pushing this branch and opening a PR, the user can monitor the CI:

1. **Watch the new `Install PowerShell Core (pwsh) on Windows` step** on the first run — should download + extract. On subsequent runs, it should detect pwsh already at `$env:USERPROFILE\pwsh\pwsh.exe` and short-circuit in <2s.

2. **`Run main test suite (Windows)` step** — should now execute `zig build test --summary all` from inside the pwsh wrapper (already wired) instead of failing with `pwsh: command not found`. Expect ~5-10 min once vendor caches are warm.

3. **`Build pabrik + pabrik-desktop binaries (Windows)` step** — should produce `zig-out/bin/pabrik.exe` + `zig-out/bin/pabrik-desktop.exe`.

4. **`Smoke test: desktop binary (Windows)` step** — should now run via PowerShell's `Start-Process` + `WaitForExit(10000)` instead of Git-bash, with the same 10-second watchdog + `smoke:` log grep.

5. **`Upload pabrik + pabrik-desktop binaries` step** — should upload 3 artifacts (`pabrik-x86_64-linux-gnu-<sha>`, `pabrik-aarch64-macos-<sha>`, `pabrik-x86_64-windows-gnu-<sha>`).

6. **Frontend Linux + macOS jobs** — unchanged from baseline, should stay green.

7. **Backend Linux + macOS jobs** — `shell: bash` stays as-is, unchanged.

Goal: every Windows PR run goes from red (fail at pwsh command-not-found) to green.

## Pitfalls / honest risks

1. **winget behaviour on a clean runner is non-deterministic.** Microsoft.PowerShell via winget hits the Microsoft Store backend, which on a locked-down machine could fail. The zip fallback is provided to handle this.
2. **`Start-Process -PassThru` requires PowerShell 5.1+ (works) but `-RedirectStandardOutput` only works in 6.1+**. Since we just installed pwsh 7.4.6, this is fine on the smoke-test step. If a *future* refactor ever moves the smoke-test back to `shell: powershell`, it'll silently lose the redirect. Add a `$proc | Get-Member` probe? No — keep it simple, leave a comment in the new step.
3. **The portable .zip is ~95 MB.** First-run adds ~30s to the Windows job. Subsequent runs are cache hits (idempotent `Test-Path`).
4. **Other CI scripts in `scripts/` (e.g. `ci-smoke-test.sh`) still use bash internally.** That's outside the scope of this PR — they're not referenced from `shell: bash` Windows steps anymore.
