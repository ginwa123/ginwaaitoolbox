# VirtualScroller Bounce / Tall-Gap / Blank / Shrink Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the bounce, tall phantom gap, full-blank viewport, and list-shrink in ChatView's `<VirtualScroller>` when message count is large.

**Architecture:** Break the sizer⇄scrollTop feedback loop by making `sizerHeight` a pure function of the height model only; fix the height model so unmeasured tails don't collapse/overshoot (adaptive estimate + streaming-key stability); make `scrollToBottom` always land on the real DOM bottom instead of the model bottom.

**Tech Stack:** Vue 3 (`src/apps/desktop/src/helpers/VirtualScroller.vue`), ChatView (`src/apps/desktop/src/components/views/ChatView.vue`), vitest specs in `helpers/__tests__/`.

## Global Constraints

- No new npm dependencies. No backend / migration / Zig changes — frontend-only.
- `pnpm test:unit` must stay green; add regression specs per fix (follow existing `helpers/__tests__/virtualScroller*.spec.ts` patterns).
- `vue-tsc --noEmit -p tsconfig.app.json` clean.
- Chat behavior contracts preserved: stick-to-bottom while `isAtBottom`, never yank a scrolled-up reader, `loadMore` at top still fires, `contentShift` event shape `{ topSpacer, bottomSpacer, total }` unchanged.

## Audit findings (why each symptom happens)

1. **Bounce (UI jumping up/down):** `sizerHeight` (VirtualScroller.vue:507-570) reads `visibleRange` (`range.end`, `range.topSpacer`), which is derived from `scrollTop`. Writing the sizer changes `scrollHeight` → fires `contentShift` → ChatView calls `scrollToBottom` → `scrollTop` changes → `visibleRange` changes → `sizerHeight` recomputes. The `clampFlipped/contentHeightChanged/totalChanged` guards + 50px hysteresis dampen but don't break the loop — at the at-bottom boundary (`range.end == length` flipping) the sizer still oscillates. Anchor compensation (`measureItems` → `container.scrollTop = …`) adds a second writer of `scrollTop` in the same frame.
2. **Tall gap → fully blank:** `estimateHeight` (line 368) returns static `64` for every unmeasured item; the `AdaptiveItemHeightEstimator` is fed (`observe`) but never read — dead code. With 100+ msgs the model total is off by thousands of px. The "too tall" branch (line 536-538) deliberately keeps `modelTotal` and relies on `scrollToBottom` real-bottom handling — but `scrollToBottom` only uses the real bottom when the rendered window already includes the last item (line 1112 `range.end >= length`); during fast scroll / fresh append it targets the phantom model bottom → viewport lands in empty sizer space → blank.
3. **List becomes small (shrink):** when scrolled up (`range.end < length`, line 512) sizer = `modelTotal` = Σ 64px estimates for the unmeasured tail → far shorter than real content → `scrollHeight` collapses → browser clamps `scrollTop` → visible window jumps → user perceives the list shrinking. Same collapse happens on streaming-id swap: `itemKey = group.messages[0].id` changes from `streaming-*` to the DB id, the new key has no stored height → falls back to 64 → sizer suddenly shrinks mid-stream.
4. **Contributors:** `realContentHeight` measures only the currently rendered window (not the full list), so `realTotal = topSpacer + realContentHeight` is only valid at-bottom; `onContentRef` + `renderTick` re-trigger `sizerHeight` on every window-height change (>50px), re-entering the loop from (1).

## File map

- EDIT `src/apps/desktop/src/helpers/VirtualScroller.vue` — sizer, estimate, scrollToBottom, measure loop.
- EDIT `src/apps/desktop/src/components/views/ChatView.vue` — `groupKey` stability, remeasure gating (small, only if needed).
- NEW/EDIT specs in `src/apps/desktop/src/helpers/__tests__/` — one spec file per fix below.
- EDIT `docs/superpowers/plans/2026-09-06-virtual-scroller-bounce-gap-blank.md` — this file.

---

## Phase 0 — Reproduce with failing tests (do first, no prod code)

- [ ] Write failing spec `helpers/__tests__/virtualScrollerSizerPure.spec.ts`: mount scroller with 120 items, set scrollTop so `range.end < length`, assert `sizerHeight` style equals `modelTotal` AND that changing `scrollTop` alone (no item/height change) does not change sizer height.
  - Run it to make sure it fails (documents the scrollTop→sizer coupling).
- [ ] Write failing spec `helpers/__tests__/virtualScrollerEstimateTail.spec.ts`: 100 unmeasured items with real heights ~400px mocked, assert sizer is within ±20% of real total (documents the 64px-estimate collapse).
  - Run it to make sure it fails.
- [ ] Write failing spec for streaming-key stability: mount with `itemKey` returning `streaming-1`, measure, then swap item identity to `db-1` (same content, ChatView's streaming→DB swap), assert stored height is retained (documents the shrink-on-swap).
  - Run it to make sure it fails.
- [ ] Commit (tests only, all failing for the right reason).

## Phase 1 — Break the feedback loop (sizer pure of scrollTop)

- [ ] Write the failing test from Phase 0 step 1 (if not already green-path).
- [ ] Implement: rewrite `sizerHeight` to depend ONLY on `modelTotal` (+ hysteresis cache). Delete the `visibleRange`/`range.end`/`range.topSpacer`/`realContentHeight` reads from the computed. Keep `realContentHeight`/`renderTick` for `scrollToBottom` use only, not for sizer size.
  - At-bottom "too short" case: do NOT expand the sizer — instead fix `scrollToBottom` (Phase 3) to reach the real bottom. Sizer stays `modelTotal` always.
  - Keep the `cachedSizerHeight` + `HYSTERESIS_PX` damping so sub-50px measurement noise doesn't relayout.
- [ ] Run the Phase 0 sizer-purity spec + full `virtualScroller*` specs to make sure they pass.
- [ ] Commit.

## Phase 2 — Fix the height model (kill tall gap + shrink)

- [ ] Write failing test: tail-estimate accuracy (Phase 0 step 2).
- [ ] Implement: wire `AdaptiveItemHeightEstimator` into `estimateHeight` — unmeasured items return `heightEstimator.estimate()` (running median, already fed by `observe`) instead of static 64. Keep 64 as the seed. Cap the estimate (e.g. clamp to [40, 1200]) so one giant code-block doesn't blow out the tail.
  - `observe()` call sites stay as-is; `reset()` on list-swap stays.
- [ ] Write failing test: streaming-key stability (Phase 0 step 3).
- [ ] Implement: stabilize ChatView `groupKey` across the streaming→DB swap — key on stable content identity (e.g. prefer a persistent client-generated key per group, or fall back to index-anchored key while `id` starts with `streaming-`), so the measured height survives the swap instead of falling back to the estimate. Scroller side needs no change (keyed map already correct once keys are stable).
- [ ] Run tail + key specs + all `virtualScroller*` + `chatViewContentShiftRestick` specs.
- [ ] Commit.

## Phase 3 — scrollToBottom always lands on real content (kill blank viewport)

- [ ] Write failing test: with model overshoot (sizer style 29389, real window bottom far lower — mirror existing `virtualScrollerStableKeys.spec.ts:159` setup), call `scrollToBottom` when the window does NOT include the last item and assert `scrollTop` targets the real DOM bottom (`content.offsetTop + content.offsetHeight - clientHeight`), not `scrollHeight - clientHeight`.
- [ ] Implement: in `scrollToBottom`, compute the real-bottom target from the content element geometry first; use it whenever `contentH > 0`, regardless of whether `range.end >= length`. Keep the model-bottom as fallback only when content isn't measurable. Do not write sizer here.
- [ ] Run the new spec + existing blank-viewport spec (`virtualScrollerStableKeys.spec.ts:159`) + restick spec.
- [ ] Commit.

## Phase 4 — Stop same-frame scrollTop fights (kill residual bounce)

- [ ] Write failing test: `measureItems` compensation write is coalesced — spy on `container.scrollTop` setter, run a measure pass with above-anchor growth + a pending `contentShift`, assert at most one `scrollTop` write per frame and that `contentShift` emit carries the post-compensation geometry.
- [ ] Implement (minimal): in `measureItems`, compute anchor compensation but apply it via `requestAnimationFrame` coalescing with the `contentShift` emit (single write per frame); keep the `markProgrammaticScroll`/`isProgrammatic` contract unchanged so ChatView's `userScrolledUp` guard keeps working.
- [ ] Run full frontend unit suite `pnpm test:unit` (or at least all `helpers/__tests__/virtualScroller*` + `chatView*` specs).
- [ ] Commit.

## Phase 5 — Verify + clean up

- [ ] `pnpm test:unit` fully green; `vue-tsc --noEmit -p tsconfig.app.json` clean.
- [ ] Manual verify with debug build: open a 100+ message chat, fling-scroll top↔bottom, stream a long reply at bottom — confirm via `debugChatId` logs that `sizer-recomputed` no longer alternates with `spacer-resize-stick` at 60Hz, no blank frames, no shrink.
- [ ] Remove any now-dead code paths (e.g. unused `lastRealContentHeightForSizer` / `lastSizerClamped` if Phase 1 deletes them; confirm `heightEstimator` is actually read now).
- [ ] Final commit. Report back with spec results + log evidence.

## Out of scope (do NOT do in this plan)

- Rewriting the scroller to fixed-height rows, swapping in a library (vue-virtual-scroller etc.), or changing the `contentShift` wire shape.
- Backend/SSE pacing changes; `loadMore` threshold tuning.
- The `hasBubbleContent` unrendered-group 200px-estimate note — only touch if a Phase 2 test proves it matters.
