# VirtualScroller Tail-Gap Cap — `maxTailGap` (500px)

**Goal (user report):** "virtual scroll weird issue gap is to long, ma — can we limit that the gap only maybe 500px?"
DevTools evidence: `virtual-scroller-sizer { height: 26796px }`, `virtual-scroller-content { transform: translate3d(0px, 23406px, 0px); min-height: 708px }`
→ **~2682px of scrollable blank below the content box.**

**Architecture:** clamp the RENDERED sizer height (a style binding only — the height model is never written) to the measured real content bottom + `maxTailGap`, while the rendered window covers the tail. The measured bottom is recorded inside `measureItems()` so it can never go stale.

**Tech stack:** Vue 3 (`src/apps/desktop/src/helpers/VirtualScroller.vue`), vitest specs (`src/apps/desktop/src/helpers/__tests__/`), Playwright UI probe (`tests/functional_ui/`).

## Audit — why the void exists

`sizerHeight` was made a pure function of the model (Σ measured/estimated row heights) by the 2026-09-06 bounce/gap fix. That removed the bounce, but the model itself can still overshoot reality:

- Unmeasured rows are estimated from the running **median** of the measured ones (`AdaptiveItemHeightEstimator`, clamped to 32–1600px), so a tail of short one-line rows inherits a tall median (e.g. 109px vs a real 23px).
- `scrollToBottom` compensates (it targets the real DOM bottom), but nothing stops the user from scrolling further DOWN into the reserved-but-empty sizer: a blank viewport below the last message.
- Rows the scroller cannot measure (`offsetHeight === 0`) keep their median estimate forever, and a bulk `itemKey` change (messageGroups regroup / streaming→DB id swap) invalidates every stored height **without re-rendering the range** — so no measure pass is scheduled and the inflated model can persist until the user happens to scroll.

An earlier attempt (PR #355) clamped the sizer to `topSpacer + realContentHeight` but read `realContentHeight` from a template `:ref` callback, which only fires when the content DIV is mounted/replaced — after a window shift it described the PREVIOUS window (a tall one) and inflated the sizer ~3x, so it was reverted.

## Implementation

`src/apps/desktop/src/helpers/VirtualScroller.vue`

- New prop `maxTailGap` (default **500**, `0` disables).
- `measureItems()` (the one place that reads live child geometry) now also sums the rendered rows' real heights and tracks the first/last `data-vs-index` they are stamped with, then `recordTailContentBottom()` stores
  `tailContentBottom = accumulatedHeights[firstRenderedIndex] + Σ rendered row heights`.
  Fresh by construction: it runs on every window change (pre-paint), scroll, and content resize — no ref-callback staleness.
- `sizerHeight = min(modelTotal, tailContentBottom + maxTailGap)` while the latching `tailCapLatched` flag is on:
  ON as soon as the window reaches the last item (`visibleRange.end >= items.length`, the only state where the real bottom is measurable), OFF only once the window is a full `buffer` away — so a clamp-driven scrollTop write at the capped bottom cannot dither the cap on/off, and a reader scrolled up can always scroll back down to appended rows.
- Because it is a `min()` on the style binding, the cap can only ever SHRINK the reserved void — the "sizer blew up 3x / bounce" failure mode is impossible, and `contentShift` (topSpacer/bottomSpacer/model total) is untouched, so ChatView's stick logic does not react to it.
- Fail-open guards: skipped when the last item is not in the DOM, when nothing in the window has laid out (`Σ heights === 0`), and reset on list swap (`items.length → 0`).

## Verification

- [x] `npx vitest --run src/helpers/__tests__/virtualScroller* + VirtualScroller* + chatView*` → 17 files / 109 tests green.
- [x] New spec `virtualScrollerTailGap.spec.ts` (7 tests): cap value, custom/smaller gap, `0` disables, latch release away from the tail, fresh re-record on window shift, fail-open on an un-laid-out window, never inflates above the model. Verified to FAIL when the cap default is set to 0.
- [x] Full frontend unit suite: 3816 passed / 35 failed — the same 35 pre-existing failures (ChatView.*, workspacesStore*, FilePicker*, …) reproduce on a clean checkout with this file stashed, i.e. no new failures.
- [x] `vue-tsc --noEmit -p tsconfig.app.json` clean; `oxlint`/`eslint` clean on the touched files.
- [x] Playwright probe `tests/functional_ui/chatview_tail_gap_probe_test.py` on a real 700-message chat (Vite + nalar + Chromium): reachable blank ≤ maxTailGap at the bottom, tail rows still rendered, and 12 × 60px steps inside the tail region track scrollTop 1:1 (no jump/hole).
- [x] Existing `tests/functional_ui/chatview_scroll_popin_probe_test.py` (3 tests, incl. SSE streaming + up-scroll into unmeasured head) still green.

## Out of scope

- Re-measuring on `itemKey` churn (a root-cause fix for one way the model gets inflated) and reducing the estimate clamp range — the cap bounds the symptom for every cause and is what the user asked for.
- Changing `scrollToBottom`, the `contentShift` payload, `min-height: containerHeight` on the content box, or the `items`/`buffer` props.
