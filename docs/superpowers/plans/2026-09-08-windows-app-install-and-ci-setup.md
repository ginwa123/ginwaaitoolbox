# Windows User-Local App Install + CI Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows parity with Linux: one-command user-local install of nalar-desktop (Start Menu search finds it, no admin) + CI release zip becomes a setup package.

**Architecture:** New PowerShell setup script `packaging/windows/Install-Nalar.ps1` (copies exes+DLLs to `%LOCALAPPDATA%\nalar\bin`, creates `Nalar.lnk` in the per-user Start Menu via WScript.Shell — all user-local, no admin, idempotent); new `install:windows:app` build.zig step that builds both binaries then runs the script with `-SourceDir zig-out/bin`; CI Windows bundle step drops the same script into the release zip and the release body documents the one-line setup.

**Tech Stack:** PowerShell 5.1 inbox (WScript.Shell COM for .lnk), Zig 0.16 build graph (`b.step`, `b.addSystemCommand`), existing `installVcpkgDlls` + WebView2Loader.dll bundling, softprops/action-gh-release rolling `ci-latest`.

## Global Constraints

- User-local ONLY: `%LOCALAPPDATA%\nalar\bin` (fallbacks APPDATA → USERPROFILE, same order as `tools/install_tui.zig`); Start Menu shortcut in `%APPDATA%\Microsoft\Windows\Start Menu\Programs\`. Never Program Files, never HKLM, no admin prompt.
- No new CI tooling (no Inno/WiX dependency on the self-hosted runner): the setup is a PS1 inside the existing zip. Inno setup.exe is an explicit non-goal / follow-up.
- Both exes ship together (desktop next-to-self auto-spawns `nalar.exe` — same lesson as Linux `install:linux:app` service-binary fix).
- build.zig step must configure cleanly on Linux hosts (addSystemCommand only executes on invocation); description marks it Windows-only.
- PowerShell 5.1 compatible (Windows PowerShell inbox, not just pwsh 7): no `??`, no ternary, no pwsh-only cmdlets.

## Files

- NEW `packaging/windows/Install-Nalar.ps1` — the setup script (install + Start Menu shortcut + `-DesktopShortcut` switch + `-Uninstall` switch).
- EDIT `build.zig` — new `install:windows:app` step after the `install:linux:app` block.
- EDIT `.github/workflows/ci.yml` — bundle `Install-Nalar.ps1` into the Windows zip; release body documents Windows setup.
- NEW this plan file.

## Tasks

- [ ] Create `packaging/windows/Install-Nalar.ps1` (user-local copy + Start Menu .lnk + switches, PS 5.1-safe)
- [ ] Wire `install:windows:app` in build.zig (depends on desktop_install + default install, runs PS1 with `-SourceDir zig-out/bin`)
- [ ] CI: add PS1 to Windows bundle zip + update `ci-latest` release body with setup instructions
- [ ] Verify: `zig build --list-steps` shows step; `zig build --help`-level config passes; actionlint on ci.yml; review PS1 by hand (no Windows box here)
