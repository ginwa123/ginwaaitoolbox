## [active] 20260610_110000 — nalar-desktop webview wrapper

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
- [ ] Chunk 5: Linux platform — WebKitGTK (all in Zig via `@cImport`)
  - [ ] Task 5.1: Implementation
  - [ ] Task 5.2: Linux test (smoke only)
- [ ] Chunk 6: macOS platform — WKWebView via Objective-C++ shim
  - [ ] Task 6.1: Copy the header
  - [ ] Task 6.2: The Objective-C++ shim
- [ ] Chunk 7: Windows platform — WebView2 via C++ shim
  - [ ] Task 7.1: Copy the header
  - [ ] Task 7.2: The C++ shim
- [ ] Chunk 8: Main lifecycle — wire everything together
  - [ ] Task 8.1: Replace the hello-world with the real lifecycle
- [ ] Chunk 9: Final verification, Nalar.md update, install step
  - [ ] Task 9.1: Verify the install step
  - [ ] Task 9.2: Update NALAR.md
  - [ ] Task 9.3: Optional install script
