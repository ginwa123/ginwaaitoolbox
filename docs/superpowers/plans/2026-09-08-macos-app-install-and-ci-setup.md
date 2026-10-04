# macOS User-Local App Install + CI Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS parity with Linux/Windows: one-command user-local `Pabrik.app` in `~/Applications` (Spotlight/Launchpad find it, no admin) + CI release ships a macOS app zip.

**Architecture:** Static `packaging/macos/Info.plist` (CFBundleExecutable=pabrik-desktop) + `packaging/macos/install-pabrik-app.sh` that assembles `Pabrik.app/Contents/{Info.plist,MacOS/{pabrik-desktop,pabrik}}` from a source dir into a destination app dir (default `~/Applications/Pabrik.app`), clears quarantine (`xattr -dr`, best-effort) and ad-hoc signs (`codesign -s -`, best-effort); new `install:macos:app` build.zig step runs the script with `zig-out/bin`; CI macOS cell calls the same script with a staging dest then `ditto`-zips it as `Pabrik-<target>.zip` next to the bare binaries.

**Tech Stack:** macOS bundle layout + `ditto` (inbox zip for bundles), `codesign` ad-hoc, `xattr`, Zig 0.16 build graph, existing `install:macos-arm` native build.

## Global Constraints

- User-local ONLY: `~/Applications/Pabrik.app`. Never `/Applications`, no sudo.
- Both binaries in `Contents/MacOS/` (desktop next-to-self auto-spawns `pabrik` — same lesson as Linux/Windows).
- No custom icon in v1 (only `favicon.ico` exists; `.icns` needs macOS `iconutil` — follow-up on a Mac box). Bundle still indexes by name.
- build.zig step configures cleanly on Linux (addSystemCommand runs only on invocation); description marks macOS-only.
- CI change is additive: bare `pabrik-*`/`pabrik-desktop-*` assets stay; the `.app` zip is an extra asset. No new runner tooling (`ditto`/`codesign`/`xattr` are macOS inbox).
- Shell script must be `sh`-clean (`bash -n` + `shellcheck` if present); keep POSIX-bash (no zsh-isms).

## Files

- NEW `packaging/macos/Info.plist` — bundle metadata.
- NEW `packaging/macos/install-pabrik-app.sh` — assemble + quarantine/sign (source dir + optional dest app dir args).
- EDIT `build.zig` — new `install:macos:app` step after `install:windows:app`.
- EDIT `.github/workflows/ci.yml` — macOS-only bundle step (assemble + ditto zip) + release body macOS setup lines.
- NEW this plan file.

## Tasks

- [ ] Create `packaging/macos/Info.plist` + `install-pabrik-app.sh` (user-local, quarantine/ad-hoc sign best-effort)
- [ ] Wire `install:macos:app` in build.zig
- [ ] CI: macOS bundle step (Pabrik-<target>.zip via same script + ditto) + release body
- [ ] Verify: `zig build --list-steps`, `bash -n` script, actionlint; hand-review (no Mac box here)
