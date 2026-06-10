## [active] 20260610_170600 — fix scroll ratcheting (59% ↔ 57% oscillation) in ChatView

Plan: `docs/plans/2026-06-10-scroll-ratcheting-fix.md`
Branch: (not yet started — diagnostic + plan only this session)

### Diagnosis
- The user's log shows `scrollTop` and `scrollHeight` ratcheting in
  lockstep (Δ ±1265 px ≈ 6.3 items at defaultItemHeight=200) while
  `distanceFromBottom` stays constant at 17227 px.
- Smoking gun: this is **CSS scroll-anchoring** (overflow-anchor: auto,
  the browser default) reacting to topSpacer mutations from
  `VirtualScroller.measureItems()` re-measuring buffer items.
- The 2026-06-07 plan (`docs/plans/2026-06-07-virtual-scroller-fixed-height.md`)
  is the structural fix but clips long bubbles. This new plan is a
  surgical 2-line fix: hysteresis on `measureItems` (4 px dead-band) +
  `overflow-anchor: none` on `.virtual-scroller`.

### Tasks
- [x] Task 1: Add `HYSTERESIS_PX = 4` constant + 2-line check change
      in `VirtualScroller.vue` `measureItems()` ✅
- [x] Task 2: Add `overflow-anchor: none;` to `.virtual-scroller` CSS ✅
- [x] Task 3: `bun run build` clean (per project memory, NOT build-only) ✅
      180s build, exit 0, no TS errors
- [x] Task 3.5: `bunx vitest run` regression check ✅
      163/163 tests pass across 20 files
- [ ] Task 4: Manual test — open long chat, scroll to middle, observe
      scrollLogger for 5s — should see zero `direction-change` lines
      (deferred to user — runs in browser, not in this sandbox)
- [ ] Task 5: Resize-window test — no bounce after resize settles
      (deferred to user)
- [ ] Task 6: Stream test — no bounce during long assistant response
      (deferred to user)
- [ ] Task 7: Optional — extract `measureItems` to pure function and
      add `src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts`
      (skipped — change is small and surgical; existing tests cover
      the parent ChatView/VirtualScroller surface)

## [active] 20250606_175000 — workspace item task pagination (click-to-load)

Plan: `docs/superpowers/plans/2026-06-10-nalar-desktop-app.md`
Worktree: `/home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/desktop-webview-app`
Branch: `feature/desktop-webview-app`
Prerequisite: `docs/superpowers/plans/2026-06-10-nalar-static-dir.md` ✅ MERGED (4 commits on branch)

### Tasks
- [x] Chunk 1: Foundation — directory, port allocator, CLI, build skeleton ✅ DONE (commits 81e5bf7, e46e550, 0bf686e, 37a03aa)
  - [x] Task 1.1: Hello-world binary + build wiring (commit 81e5bf7)
  - [x] Task 1.2: Free-port allocator (TDD) (commit e46e550)
  - [x] Task 1.3: CLI parser (TDD) (commit 0bf686e)
  - [x] Task 1.4: Chunk 1 verification (CLI wired into main.zig in commit 37a03aa)
- [x] Chunk 2: Subprocess management — spawn nalar, healthcheck, kill ✅ DONE (commits 0756055, 134f8c4)
  - [x] Task 2.1: Path resolution — find nalar next to self (commit 0756055; resolve() doesn't check fileExists on explicit path; selfExePath is Linux-only)
  - [x] Task 2.2: Subprocess spawn + healthcheck + kill (commit 134f8c4; uses raw std.os.linux.* syscalls in waitForHealth — Io-based impl hung on EAGAIN; signature is `waitForHealth(port, timeout_ms, poll_ms)`, no allocator/io)
  - [x] Task 2.3: Chunk 2 verification (18/18 pass; manual smoke ok; user's nalar on 8081 untouched)
- [x] Chunk 3: Asset extraction + comptime codegen ✅ DONE (commits 839d2da, 384c794, 0842eaf)
  - [x] Task 3.1: Add `build:webapp` to `build.zig` (commit 839d2da)
  - [x] Task 3.2: Comptime codegen — walk dist/, emit webapp_assets.zig (commit 384c794; 93 assets, 4.7 MB generated)
  - [x] Task 3.3: Runtime extraction — write to temp dir (commit 0842eaf)
  - [x] Task 3.4: Chunk 3 verification (20/20 tests pass; main.zig doesn't yet @import the assets — that's Chunk 8)
- [x] Chunk 4: Webview interface — shared C ABI ✅ DONE (commits 7b024d6, d1cddfe)
  - [x] Task 4.1: The shared C header (commit 7b024d6)
  - [x] Task 4.2: Zig wrapper around the C ABI (commit d1cddfe)
  - [x] Task 4.3: Chunk 4 verification (build succeeds; deferred link errors verified by subagent)
- [x] Chunk 5: Linux platform — WebKitGTK ✅ DONE (commits 0e368d0, a090d64)
  - [x] Task 5.1: Implementation (commit 0e368d0; @cImport doesn't work for GTK due to GLib _Pragma — used manual extern "c" + webview_linux.c C shim)
  - [x] Task 5.2: Linux test (commit a090d64; 21/21 tests pass)
- [x] Chunk 6: macOS platform — WKWebView via Objective-C++ shim ✅ DONE (commits 4334532, e9fc8d0)
  - [x] Task 6.1: Copy the header (commit 4334532)
  - [x] Task 6.2: The Objective-C++ shim (commit e9fc8d0; defensive fixes for retain cycles, null safety, etc.)
- [x] Chunk 7: Windows platform — WebView2 via C++ shim ✅ DONE (commits 1e42995, e23bfb4)
  - [x] Task 7.1: Copy the header (commit 1e42995)
  - [x] Task 7.2: The C++ shim (commit e23bfb4; WebView2 NuGet not vendored — code is reviewable, needs NuGet extract to actually build on Windows)
- [x] Chunk 8: Main lifecycle — wire everything together ✅ DONE (commit b64612f)
  - [x] Task 8.1: Replace the hello-world with the real lifecycle (commit b64612f; fixed std.process.spawn io signature, child.kill/wait API change in 0.16, defer if-expression quirk; 29 MB binary with embedded assets)
- [x] Chunk 9: Final verification, Nalar.md update, install step ✅ DONE (commit 2b2f3aa)
  - [x] Task 9.1: Verify the install step (both `nalar` 53MB + `nalar-desktop` 29MB in zig-out/bin/)
  - [x] Task 9.2: Update NALAR.md (commit 2b2f3aa; documented desktop-app + 6 new Zig 0.16 quirks: std.process.spawn/kill/wait API, std.posix removed wrappers, std.Thread.sleep → nanosleep, std.fs.accessAbsolute → faccessat, @cImport + GLib _Pragma issue)
  - [x] Task 9.3: Optional install script (commit 2b2f3aa; scripts/install-nalar-desktop.sh)
