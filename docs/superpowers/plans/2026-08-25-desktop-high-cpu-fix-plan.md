# Desktop App High CPU / Slowness — Investigation & Fix Plan

**Date:** 2026-08-25
**Task:** task_1787668675883_1 ("desktop app very slow and has cpu usage high")
**Status:** investigation complete, plan awaiting approval

## Executive Summary

Four parallel investigations (frontend timers/watchers, SSE streaming, backend
schedulers, webview/render layer) converged on one dominant root cause plus a
tail of secondary contributors:

> **The streaming hot path is O(n²) per response.** Every SSE token chunk
> triggers: (a) an un-gated `console.log` of the FULL accumulated content,
> (b) a full `marked.parse()` re-parse of the entire message (no memo),
> (c) four transcript-wide computeds re-running regex passes over ALL messages,
> and (d) a container-wide `querySelectorAll` + DOM button injection.
> At ~20 chunks/sec on a long chat this pins the renderer thread.

Secondary: backend hot loops when an LLM endpoint misbehaves (unthrottled
retry/empty-content spin), constant idle cost from 1–5 s scheduler polls,
sidebar drag doing sync `localStorage.setItem` per mousemove, expensive CSS
(`backdrop-filter`, infinite animations), and Windows WebView2 still linear-
scanning assets per request.

Prior art NOT duplicated here: PR #321 (VirtualScroller P1 — merged work is
intact), PR #329 (scroll-perf cross-platform — Linux gfx env pins + asset
index already on main; FPS overlay verified dev-only).

---

## Root-Cause Findings (ranked)

### P0 — Streaming O(n²) amplification (the main CPU burner)

| # | Location | Problem |
|---|----------|---------|
| 1 | `ChatView.vue:2563` | `console.log('[updateStreamingMessage] streamingContent:', ...)` logs the **entire accumulated content** on EVERY chunk. Un-gated → runs in prod. Console serialization makes it O(n) per chunk ⇒ O(n²) per response. |
| 2 | `ChatView.vue:3359–3372` + `195–217` | `renderResponse()` calls `marked.parse(stripThinkingTags(content))` inline in the template (`v-html`). No memo. Every chunk mutates `messages` → whole list re-renders → **entire transcript re-parsed** per token. |
| 3 | `ChatView.vue:1278–1297, 1306–1337, 1343–1353, 1389` | `filteredMessages`, `messageGroups`, `unwrappedByMessageId`, `groupToolNames` all read every message's `content`; one chunk mutation dirties all four ⇒ O(chat length) regex/grouping work per token. |
| 4 | `ChatView.vue:2601` + `166–192` | `setupCodeBlockCopyButtons()` runs `querySelectorAll('.markdown-content pre')` + button injection after EVERY chunk. |
| 5 | `ChatView.vue:2301, 2500, 2519` | Un-gated per-event `console.log` of full SSE event objects. |
| 6 | `helpers/sseClient.ts:407, 437–443, 993–1013` | Diagnostic logging **enabled by default in prod** (`debugOn = globalThis.__sseDebug !== false`) — JSON.stringify per event incl. every token. |
| 7 | Backend `workflow.zig:1594–1644` | One SSE event per provider delta, zero batching/throttling. Providers can emit hundreds of chunks/sec; each does JSON serialize + UTF-8 sanitize + heap allocs + info log. |

### P1 — Backend hot loops (active-path CPU spikes)

| # | Location | Problem |
|---|----------|---------|
| 8 | `workflow.zig:1124–1129` | Empty-content `stop` → unconditional `continue`. No counter, no backoff, no cap. A poisoned endpoint = infinite hot loop of full LLM HTTP call + ~8 DB queries + SSE emits per iteration. |
| 9 | `workflow.zig:847–895` + `config.retry_delay_ms` default 0 | Unattended soft-bail resets `retry_count=0` and continues forever at full speed when delay is 0 (the default). |
| 10 | `retry_delay_ms.zig:89–117` | Cancellation polled via SQLite SELECT every 50 ms during backoff — 20 queries/sec contending on the DB mutex. |

### P2 — Render layer / interaction jank

| # | Location | Problem |
|---|----------|---------|
| 11 | `Sidebar.vue:251–257` → `AppLayout.vue:132–134` → `navigation.ts:83–86` | Sidebar resize drag: `localStorage.setItem` (sync disk I/O) + store write + full shell relayout **per mousemove** (60–120 Hz). Same layout churn in `RightSidebar.vue:43–53`. |
| 12 | `PreviewContentRenderer.vue:158–162` | MutationObserver on `document.body {subtree:true}` inside preview iframes → forced reflow (`scrollHeight` read) + postMessage per DOM mutation, zero coalescing. |
| 13 | `windows/nalar_webview.cpp:236–242` | WebView2 asset serving still linear-scans (`strcmp` loop) per request on the UI thread. Linux got StringHashMap, macOS got NSDictionary — Windows skipped. |
| 14 | `DesignChatDialog.vue:137`, `KanbanChatDialog.vue:134` | `backdrop-filter: blur(8px)` over live-streaming chat content — costliest WebKitGPU op; under software rendering can pin a core while dialog is open. |

### P3 — Constant idle baseline

| # | Location | Problem |
|---|----------|---------|
| 15 | `routines/Scheduler.zig:195–199` | Routines poll every 5 s forever (SQL JOIN query even with zero routines). |
| 16 | `cronjob_manager.zig:209–216` | Cron thread wakes every 1 s + ArrayList copy per tick. |
| 17 | `main.zig:553–575` cleanup crons | Per-minute full-table scans + info log lines even when idle. |
| 18 | `websocket_manager.zig:102…202`, `security.zig:114–116` | Busy-spin locks (`while(!tryLock()) spinLoopHint()`) — 100% core while contended. |
| 19 | Various (`SseStatusBadge.vue:129`, `SubAgentPeekPanel.vue:475,598`, `Chats.vue:90,108`, `FilePickerDialog.vue:1511`) | Infinite CSS animations keep compositor awake app-wide; only SseStatusBadge has reduced-motion guard. |
| 20 | `ChatsList.vue:320–322` | Full `loadChats()` refetch (30 sessions) on EVERY session SSE event, un-debounced. |
| 21 | `ChatView.vue:1245–1249` | Git status poll every 30 s, ungated by visibility/repo presence. |
| 22 | llm_history / frontend_log | No retention/prune anywhere — unbounded growth slows queries over weeks. |

Verified-clean: Pinia fan-out during streaming (chunks don't touch stores),
SSE manager loops (proper poll/sleep), HTTP accept loop (blocking accept +
per-request arena), fonts (none loaded), window-resize listeners (debounced/
trivial), VirtualScroller translate3d positioning (PR #321 intact).

---

## Fix Plan

### Phase 1 — Kill the streaming O(n²) (biggest win, frontend-only)

1. **Delete/gate all hot-path console.logs**
   - `ChatView.vue:2563` (full-content log), `:2301`, `:2500`, `:2519`.
   - `helpers/sseClient.ts`: flip default — `__sseDebug`/`__sseStallDetector`
     ON only when `import.meta.env.DEV`.
   - Test: vitest asserting prod build emits no console output on chunk path.

2. **Memoize markdown rendering**
   - Wrap `renderResponse` result in a per-message child component with
     `computed` keyed on `msg.content` (or a small LRU Map `(content→html)`).
   - While streaming, render only the streaming row's tail; finalized rows
     never re-parse.
   - Test: spy on `marked.parse` — assert parse count does not grow with
     chunk count for unchanged history.

3. **Throttle streaming commit to ~100 ms**
   - Buffer deltas in a non-reactive string; commit to `messages` on a timer.
   - This collapses computeds (#3) and re-render fan-out to ≤10 Hz regardless
     of provider chunk rate.
   - ⚠️ Constraint from PR #321 lessons: do NOT add rAF layers into the
     VirtualScroller scroll pipeline; throttle only the ChatView commit point.

4. **Copy buttons once per finalize** — move `setupCodeBlockCopyButtons()`
   from per-chunk to `chunk_final`/message-complete only.

5. **Backend batch emits** (`workflow.zig` stream_callback): coalesce deltas
   on a ~30–50 ms flush timer or N-byte threshold before emitting `llm_chunk`.
   Keep final flush on stream end (no added latency to completion).

**Expected effect:** streaming CPU drops from O(n²) to O(n); likely eliminates
the majority of reported burn.

### Phase 2 — Backend hot-loop guards

6. **Empty-content circuit breaker** (`workflow.zig:1124`): consecutive-empty
   counter (cap ~3) → bail with error event instead of infinite continue.
7. **Retry floor**: enforce min 1000 ms soft-bail delay regardless of config;
   document `retry_delay_ms` default change.
8. **Cancellation poll interval**: 50 ms → 500 ms–1 s in
   `retry_delay_ms.zig` (or atomic flag instead of DB).

### Phase 3 — Interaction & render fixes

9. **Sidebar drag**: rAF-throttle `handleResize`; persist width on mouseup
   only (RightSidebar pattern).
10. **Preview MutationObserver**: debounce `report()` (~100 ms trailing);
    observe content root not `document.body`.
11. **Windows asset index**: port Linux's prebuilt path→index map to
    `nalar_webview.cpp` WebResourceRequested handler.
12. **Drop backdrop-filter** on the two chat dialogs → opaque rgba overlay.

### Phase 4 — Idle baseline & hygiene

13. Routines scheduler: sleep until next-due (min 60 s cap) instead of fixed 5 s.
14. Cron manager: wake on earliest job time instead of 1 s tick.
15. Cleanup crons: skip scan when COUNT=0; downgrade per-tick logs to debug.
16. Replace busy-spin mutexes with `std.Io.Mutex` (SseManager precedent).
17. Global `prefers-reduced-motion` kill-switch for infinite animations;
    pause when panel hidden.
18. Debounce ChatsList refetch (500 ms trailing); gate git-status poll on
    `document.visibilityState` + repo presence.
19. Nightly prune cron for `llm_history`/`frontend_log` (retention window,
    e.g. 30 days).

---

## Verification

- **Perf harness:** measure CPU% before/after each phase with a scripted
  long-chat streaming replay (FPS overlay exists for dev; add a simple
  `performance.memory`/CPU sampler spec or manual top measurement protocol
  documented in the plan).
- **Regression guards:** vitest tests from Phase 1 items 1–2 (log silence,
  parse-count bound); Zig static tests for Phase 2 caps/floors.
- Full suites: `zig build test --summary all`, `npm run test:unit`,
  functional pytest suite untouched areas stay green.

## Suggested sequencing

Phase 1 alone is a shippable PR (frontend-only, low risk, biggest win).
Phases 2–4 can be separate small PRs. Recommend starting with Phase 1.
