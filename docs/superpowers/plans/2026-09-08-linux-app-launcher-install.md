# Linux App Launcher Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `zig build install:linux:app` so Pabrik appears in GNOME/KDE launcher search.

**Architecture:** New static `packaging/linux/pabrik.desktop` entry (Exec=/usr/local/bin/pabrik-desktop, Icon=/usr/share/pixmaps/pabrik.ico) plus a build.zig step that reuses the existing `desktop_install` artifact, copies the binary to `/usr/local/bin`, installs the .desktop + icon system-wide, and refreshes the desktop database best-effort.

**Tech Stack:** Zig 0.16 build graph (`b.step`, `b.addSystemCommand`), freedesktop `.desktop` spec, `update-desktop-database`, existing `src/apps/desktop/public/favicon.ico` as icon source.

## Global Constraints

- Linux-only paths (`/usr/local/bin`, `/usr/share/applications`, `/usr/share/pixmaps`); no Windows/macOS behavior change.
- Follow existing `install:linux:system` pattern (`cp zig-out/bin/... /usr/local/bin/...` via `addSystemCommand`, requires sudo — same as today).
- Do not touch `pabrik-desktop`, `install:linux`, `install:linux:system` behavior.
- `update-desktop-database` / icon cache refresh must be best-effort (`|| true`) so missing tools don't fail the build.
- Icon source stays single-source: `src/apps/desktop/public/favicon.ico`, no binary duplication.

## Files

- NEW `packaging/linux/pabrik.desktop` — freedesktop entry, one responsibility: launcher metadata.
- EDIT `build.zig` — new `install:linux:app` step after `linux_system_step` block (~line 2835), one responsibility: wire binary + desktop + icon + database refresh.
- NEW this plan file.

## Tasks

- [ ] Write failing check: `zig build --list-steps` shows no `install:linux:app`
  - Run `timeout 30 zig build --list-steps 2>&1 | head -n 60` and confirm missing.
- [ ] Create `packaging/linux/pabrik.desktop` with Exec=/usr/local/bin/pabrik-desktop, Icon=/usr/share/pixmaps/pabrik.ico, Terminal=false, Type=Application, Categories=Utility;Development
- [ ] Wire `install:linux:app` in build.zig depending on `desktop_install` + cp binary + install desktop + icon + best-effort database refresh
  - Run `timeout 60 zig build --list-steps 2>&1 | head -n 60` to confirm step appears.
- [ ] Verify: `timeout 120 sudo zig build install:linux:app 2>&1 | tail -n 30`, then check `/usr/local/bin/pabrik-desktop`, `/usr/share/applications/pabrik.desktop`, `/usr/share/pixmaps/pabrik.ico` exist and Super-key search finds Pabrik
- [ ] Commit
