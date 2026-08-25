# Desktop Scroll/Perf Improvements — Cross-Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the nalar desktop app feel as smooth as Chrome by pinning hardware-accelerated rendering on every platform, fixing per-request asset-handler overhead, and eliminating first-paint / resize jank.

**Architecture:** Three layers of fix. (1) Platform shims get explicit GPU/compositing configuration — env vars on Linux WebKitGTK, `ICoreWebView2EnvironmentOptions` browser args on Windows, WKWebView config + a real `WKURLSchemeHandler` on macOS. (2) All three `app://` asset handlers switch from linear scan to O(1) lookup and serve cache headers. (3) Frontend gets a dev-only FPS overlay so regressions are measurable, plus two micro-fixes found in audit. Each task is independently verifiable and lands on its own commit.

**Tech Stack:** Zig 0.16 (linux.zig), Objective-C (nalar_webview.mm), C++/WRL (nalar_webview.cpp), Vue 3 + TypeScript + Vitest (frontend).

## Global Constraints

- **Never kill the port 8081 server.** Functional tests use ports 8080–8199 only.
- **macOS and Windows code cannot be compiled on this Linux box.** Verification for those platforms = static-contract tests (grep-based, following the repo's existing `<feature>_test.zig` pattern) + CI runners (`install:macos-arm` self-hosted runner compiles the .mm; Windows CI compiles the .cpp). Never claim "verified" without the static test passing locally AND CI green.
- ObjC string parsing gotcha (from PR #300): when writing delimiter-balance checks for `.mm` files, strip `@"..."` strings BEFORE comments or the parse breaks.
- The scroll pipeline is load-bearing synchronous — do NOT add rAF-coalescing to VirtualScroller (three variants already tried and reverted; see memory `mem_0a28e93fa5038d64`). This plan does not touch VirtualScroller internals.
- Every task ends with its own commit. Branch: `worktree/desktop-scroll-perf-cross-platform`.
- Baseline before starting: `zig build test --summary all` and `cd src/apps/desktop && bun run test:unit` must pass at current HEAD counts.

---

## Task 1 — Linux: pin WebKitGTK acceleration env vars

The Linux webview sets **zero** environment configuration today (`src/apps/desktop_app/platform/linux.zig` has no setenv anywhere). On many drivers WebKitGTK silently falls back to software rendering → slow scrolling. Fix: set the vars before `gtk_init()` (line 255).

- [ ] Write failing static-contract test `src/apps/desktop_app/platform/linux_gfx_test.zig`:
  - asserts `linux.zig` contains `WEBKIT_DISABLE_DMABUF_RENDERER`, `WEBKIT_FORCE_COMPOSITING_MODE`, and `GDK_BACKEND` setenv calls
  - asserts the setenv block appears BEFORE the `gtk_init(` call line number in the file
  - asserts a `gfx_debug` escape hatch exists (env override respected)
- [ ] Run it, confirm FAIL (`zig test src/apps/desktop_app/platform/linux_gfx_test.zig` or wire into test runner)
- [ ] Implement in `linux.zig` inside `nalar_webview_create` between lines 251–254 (before `gtk_init` at 255):
  - respect user override: skip any var already present in environ (use `std.posix.getenv` check)
  - default-set: `GDK_BACKEND=x11` only if unset AND Wayland detection fails is NOT needed — instead leave GDK_BACKEND alone unless `cfg.force_x11`; set `WEBKIT_DISABLE_DMABUF_RENDERER=1` and `WEBKIT_FORCE_COMPOSITING_MODE=1`
  - NOTE: which combination wins is driver-dependent — implement all three behind a small `applyLinuxGfxEnv()` helper with clear comments, gated by a new `Config.gfx_preset` enum (`auto` default | `compat` | `debug`)
- [ ] Add `gfx_preset` field to `webview.Config` in `src/apps/desktop_app/webview.zig` (next to `enable_developer_extras` ~line 42), default `.auto`
- [ ] Manual verification on this machine: launch binary with each preset, confirm window opens and page renders (no crash); record which preset feels smoother in commit message
- [ ] Commit: `linux: pin webkitgtk gfx env vars before gtk_init`

## Task 2 — Linux: hash-map asset lookup in app:// scheme handler

Current: linear `std.mem.eql` scan over assets at `linux.zig:508`. Fine at hundreds of entries but O(n) per request on main thread.

- [ ] Write failing test asserting a sorted-index or StringHashMap lookup replaces the linear loop (static contract: no `for (ctx.assets[0..ctx.count])` remains in `uriSchemeCallback`)
- [ ] Implement: build `std.StringHashMapUnmanaged(u32)` once in `nalar_webview_create` after SchemeContext alloc; store pointer in SchemeContext; callback does O(1) get
- [ ] Verify: existing scheme tests still pass; manual load of app://index.html works
- [ ] Commit: `linux: O(1) app:// asset lookup via StringHashMap`

## Task 3 — macOS: WKURLSchemeHandler + config fixes

macOS currently intercepts `app://` via navigation-delegate policy (`nalar_webview.mm:295-364`) which serializes sub-resource fetches, uses linear strcmp scan (`:329-349`), ignores `user_agent`, ignores `enable_developer_extras`, and leaves `drawsBackground` white-flash default.

- [ ] Write failing static-contract test `src/apps/desktop_app/platform/macos/nalar_webview_static_test.zig` (delimiter-balance aware, strip `@"..."` strings first):
  - asserts `setURLSchemeHandler:forURLScheme:` present
  - asserts `WKURLSchemeHandler` protocol class exists with `startURLSchemeTask:`/`stopURLSchemeTask:`
  - asserts nav-delegate linear-scan block removed (no `strcmp(asset->path` in decidePolicyForNavigationAction)
  - asserts `developerExtrasEnabled` KVC wired from `_config.enable_developer_extras`
  - asserts `applicationNameForUserAgent` set from `_config.user_agent`
- [ ] Implement in `nalar_webview.mm`:
  - New `NalarAppSchemeHandler : NSObject <WKURLSchemeHandler>` holding an `NSDictionary<NSString*, NSData*>` built once from the asset table (O(1) lookup)
  - Register via `[wkconfig setURLSchemeHandler:handler forURLScheme:@"app"]` at injection point :234–253
  - Delete nav-policy interception block :295–364 (keep delegate for other purposes if needed)
  - Wire `developerExtrasEnabled` + `WebKitDeveloperExtras` defaults when `enable_developer_extras`
  - Set `applicationNameForUserAgent` when `user_agent` non-null
  - Set `drawsBackground = NO` via KVC for dark-theme first paint
- [ ] Cannot compile locally — verification = static test passes + push branch, watch `install:macos-arm` CI job compile the .mm
- [ ] Commit: `macos: WKURLSchemeHandler with O(1) lookup, wire devtools+UA, kill white flash`

## Task 4 — Windows: WebView2 EnvironmentOptions + resize/background fixes

Windows shim passes NULL options (`nalar_webview.cpp:417-420`), re-sets bounds on every WM_SIZE during drag (:141-150), flashes white on cold start (COLOR_WINDOW brush :321, no put_DefaultBackgroundColor).

- [ ] Write failing static-contract test `src/apps/desktop_app/platform/windows/nalar_webview_static_test.zig`:
  - asserts `CreateCoreWebView2EnvironmentWithOptions` call passes non-NULL options (not `NULL,    // environmentOptions`)
  - asserts `put_AdditionalBrowserArguments` present
  - asserts WM_SIZE handler coalesces (SetTimer or SIZE_ source check present)
  - asserts `put_DefaultBackgroundColor` called in controller callback
- [ ] Implement in `nalar_webview.cpp`:
  - Build `ComPtr<ICoreWebView2EnvironmentOptions>` between lines 415–417; keep alive through completion lambda
  - Args: enable GPU compositing explicitly (`--disable-gpu-compositing` NOT set; instead ensure nothing disables it) + disable unused Edge features (`--disable-features=msSmartScreenProtection`) — conservative set only, document trade-offs in comment
  - WM_SIZE: coalesce via SetTimer(16ms) → apply bounds on WM_TIMER; kill timer on WM_EXITSIZEMOVE
  - Controller callback: `put_DefaultBackgroundColor` matching app dark background
  - Window brush: dark `hbrBackground` instead of COLOR_WINDOW+1
- [ ] Verification = static test passes + Windows CI job compiles
- [ ] Commit: `windows: WebView2 env options, coalesced resize, dark first paint`

## Task 5 — Frontend: dev-only FPS overlay

No FPS overlay exists anywhere (audit grep: zero matches). Needed to *measure* the platform fixes above.

- [ ] Write failing Vitest spec `src/apps/desktop/src/helpers/__tests__/fpsOverlay.spec.ts`: mounts overlay component/helper, fakes rAF ticks, asserts displayed FPS value updates and that it renders nothing when `import.meta.env.DEV === false`
- [ ] Implement `src/apps/desktop/src/helpers/fpsOverlay.ts` (+ tiny mount point in AppLayout.vue gated by `import.meta.env.DEV`): rAF loop counting frames per second, absolute-positioned corner chip, zero cost in prod builds (tree-shaken)
- [ ] Run `bun run test:unit` — new spec passes, full suite stays green
- [ ] Commit: `frontend: dev-only FPS overlay for perf measurement`

## Task 6 — Frontend: two micro-fixes from audit

- [ ] ChatView.vue:2922 avatar `<img>`: add explicit `width="80" height="80"` attributes (WebKit reserves box from attrs, avoids decode-shift)
- [ ] scrollLogger.ts:445: gate `info` level behind `import.meta.env.DEV` (currently prod-on at ~60Hz during SSE scroll)
- [ ] Existing specs still pass; adjust any spec asserting logger behavior
- [ ] Commit: `frontend: img dimensions + dev-gate scrollLogger.info`

## Task 7 — Buffer A/B experiment (measurement, not blind change)

ChatView passes `buffer: 30` (was bumped 20→30 on 2026-08-23 as insurance). With FPS overlay from Task 5 we can finally measure.

**STATUS: DEFERRED TO HUMAN MEASUREMENT** — the overlay now exists but reading it requires eyes on a real long-chat scroll. Procedure:

1. `zig build nalar-desktop && ./zig-out/bin/nalar-desktop` (dev build includes the overlay chip, top-right)
2. Open the longest chat you have; note steady-state FPS while scrolling fast up/down (chip updates 1×/sec)
3. Edit `src/apps/desktop/src/components/views/ChatView.vue` buffer prop (`buffer: 30` → try 15, then 45), rebuild, repeat
4. Record numbers below; keep whichever wins or revert to 30 if indistinguishable

| buffer | FPS fast-scroll | visual artifacts | verdict |
|--------|-----------------|------------------|---------|
| 30 (baseline) | _pending human run_ | — | current |
| 15 | | | |
| 45 | | | |

- [x] Measurement procedure documented; buffer left at 30 pending data

## Task 8 — Full verification + changelog

- [ ] `zig build test --summary all` — full suite green, no new leaks
- [ ] `cd src/apps/desktop && bun run test:unit` — full suite green
- [ ] `vue-tsc` type-check clean; `vite build` clean
- [ ] Push branch, open PR linking this plan; verify macOS + Windows CI jobs compile the shims
- [ ] Update CHANGELOG entry summarizing: Linux gfx pinning, macOS scheme handler rewrite, Windows resize/bg fixes, FPS overlay
- [ ] Move kanban card to in_review_task

---

## Risks & Notes

- **Env-var presets are driver-dependent.** `WEBKIT_DISABLE_DMABUF_RENDERER=1` helps some NVIDIA setups and hurts others. That's why Task 1 ships a `gfx_preset` enum rather than hardcoding one answer — and why we measure with the Task 5 overlay before declaring victory.
- **macOS WKURLSchemeHandler swap changes request semantics slightly** (handler runs on its own queue). The nav-delegate approach worked; if CI or smoke tests show asset-load regressions, fallback is keeping nav-delegate but adding the NSDictionary index.
- **Windows browser args**: keep minimal. Aggressive flag lists rot as Edge updates.
- Out of scope (deliberately): VirtualScroller internals (P3 ideas), SSE reconnect work, anything touching port 8081.
