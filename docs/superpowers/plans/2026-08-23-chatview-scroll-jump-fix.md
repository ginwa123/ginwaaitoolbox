# ChatView scroll jumping — measurement-shift compensation in VirtualScroller

**Task:** task_1787496087806_6 ("i feels like when chatview have long chat messages, the view its kind of jummping")
**Date:** 2026-08-23
**Status:** planned → ready for implementation

## 1. Symptom

User report: with long chats (255 messages), scrolling through history makes the
view "jump" — content visibly shifts under a stationary finger/wheel.

Scroll-log evidence (`scrollLogger`, chat `task_1786540903899`):

```
#1863 content-resized top=7979   bottom=22445px  sh=31443
#1864 content-resized top=10527  bottom=24870px  sh=36416   ← +4973px height, +2548px top
#1865 content-resized top=11941  bottom=24249px  sh=37209
...
#1872 content-resized top=28123  bottom=12818px  sh=41960
#1873 direction-change  top=28094 bottom=7807px  sh=36920   ← −5040px height in one step
```

Two adjacent samples differ by **+4973 px of scrollHeight while scrollTop
advanced only +2548 px** — i.e. ~2400 px of content teleported under the
viewport in one frame. The `↑` marker is the logger's `isAtBottom=false`
glyph (scrollLogger.ts:505-506), not direction; direction was consistently
downward. This is not loadMore/preserve (no `load-more-preserve-*` lines) and
not auto-stick (user is mid-list; no `spacer-resize-stick` lines).

## 2. Root cause

VirtualScroller.vue keeps a per-item height model:

- `itemHeights: Map<index, px>` — seeded lazily; unmeasured items use
  `defaultItemHeight = 64` (ChatView passes `:default-item-height="64"`).
- `accumulatedHeights[]` — prefix sums over that map.
- `visibleRange` computed → `topSpacer` / `bottomSpacer` div heights.

`measureItems()` (VirtualScroller.vue:413-438) runs debounced after every
scroll/resize and writes **real** `offsetHeight`s over the estimates for every
rendered child. Rendered children include up to `buffer=30` items *above* the
viewport. When real heights exceed the 64px estimate (markdown paragraphs,
tool cards are commonly 100–400px), each write mutates `accumulatedHeights`
and therefore both spacers.

The browser keeps `scrollTop` fixed when spacers change (CSS scroll anchoring
is disabled — `overflow-anchor: none`, VirtualScroller.vue:678). So when item
*k* above the viewport grows from 64→300px:

- items below k shift down by +236px in document space;
- the viewport stays at the same scrollTop;
- the message the user was reading **teleports down 236px**.

Summed across a batch of ~30 measured buffer items this is exactly the
±2500–5000px swings in the log. Two aggravators:

1. **Estimate bias is signed.** 64px vs real 40–400px means measurements
   almost always grow the model, so errors accumulate instead of cancelling.
2. **Measurement happens during scroll.** The 50ms debounce fires mid-gesture
   as new buffer items enter the DOM, so the jump lands while the user is
   actively moving — maximally visible.

Existing guards don't cover this case:
- `HYSTERESIS_PX=4` dead-band only suppresses sub-pixel noise.
- `beginPreserve/endPreserve` only brackets explicit prepend/loadMore.
- ChatView's spacer MutationObserver re-sticks to bottom only when
  `isAtBottom` — mid-list it does nothing (correctly).

## 3. Fix strategy

**Anchor-compensated measurement**: whenever `measureItems()` changes stored
heights for items whose index is **above the current viewport start**, adjust
`scrollTop` by the negative of the accumulated height delta so the content
under the viewport stays visually stationary.

This is the standard virtual-list technique (react-window's
`useAdjustScrollWhileNavigating`, TanStack Virtual's `_didScroll...`
reconciliation, vue-virtual-scroller's ResizeObserver anchor).

### Design decisions

1. **Compensation lives inside VirtualScroller.vue**, not ChatView — the
   scroller owns the height model; ChatView can't know the per-index deltas.
2. **Anchor = first visible index** (`findStartIndex()` result captured
   before re-measure), not offsetTop of a DOM node — jsdom-testable without
   layout, and stable even if the anchor item unmounts between frames.
3. **Only compensate for indices strictly above the viewport start.** Deltas
   for the visible window itself are real content growth (streaming text);
   compensating those would fight stick-to-bottom and SSE growth.
4. **Guard against feedback loops:** compensation assigns scrollTop directly
   (bypasses smooth behavior); set an internal flag so the resulting scroll
   event doesn't re-trigger measureItems' compensation pass on unchanged
   data (it would be a no-op anyway since heights already written, but the
   guard also prevents double-counting with the debounce).
5. **Keep `overflow-anchor: none`.** Browser anchoring fights our own
   programmatic adjustments; we do compensation explicitly where we know the
   exact deltas.

### Implementation sketch (VirtualScroller.vue)

```ts
// In measureItems(), replace `if (changed) updateAccumulatedHeights()`:
const measureItems = () => {
  if (!containerRef.value) return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content) return
  let changed = false
  // NEW: capture pre-measure geometry for anchor compensation.
  const anchorIndex = findStartIndex()          // first visible index
  const anchorOffsetBefore = accumulatedHeights.value[anchorIndex] ?? 0
  const prevScrollTop = containerRef.value.scrollTop

  // ... existing measurement loop, but record per-index old/new:
  const deltasAboveAnchor: number[] = []        // (new - old) per index < anchorIndex

  for (...) {
    ...
    if (prev === undefined || Math.abs(h - prev) > HYSTERESIS_PX) {
      if (realIndex < anchorIndex && prev !== undefined) {
        deltasAboveAnchor.push(h - prev)
      } else if (realIndex < anchorIndex && prev === undefined) {
        // First-ever measurement of an above-viewport item: compare
        // against the ESTIMATE that was actually backing the layout.
        deltasAboveAnchor.push(h - props.defaultItemHeight)
      }
      itemHeights.set(realIndex, h)
      changed = true
    }
  }
  if (!changed) return
  updateAccumulatedHeights()

  // NEW: compensate so content at anchorOffsetBefore stays put.
  const totalShift = deltasAboveAnchor.reduce((a, b) => a + b, 0)
  if (totalShift !== 0 && !isPreservingScroll.value) {
    const newST = Math.max(0, prevScrollTop + totalShift)
    if (newST !== prevScrollTop) {
      containerRef.value.scrollTop = newST
      scrollTop.value = newST
      lastScrollTop.value = newST
    }
  }
}
```

Notes:
- `totalShift > 0` (content above grew) → scrollTop increases by the same
  amount → same pixels remain under the viewport top edge.
- Clamped at 0; if clamping bites (rare — user near absolute top), residual
  jump is unavoidable but bounded by the clamp distance.
- `endPreserve` path untouched (it has its own anchor logic).
- Also apply the identical compensation inside `updateAccumulatedHeights`'
  other caller? No — the watch on `items.length` handles appends/prepends via
  preserve; measurement is the only unguarded mutation source.

Edge cases handled:
- Items entering the buffer for the FIRST time above the anchor: their
  estimate (64px) was part of the previous layout, so comparing against
  `defaultItemHeight` is correct.
- Item heights shrinking (code fold collapse): totalShift negative → scrolls
  up equally — still stationary content.
- `forceRenderUpTo` active (preserve window): skipped via
  `isPreservingScroll` guard.

## 4. Files changed

| File | Change |
|---|---|
| `src/apps/desktop/src/helpers/VirtualScroller.vue` | Anchor-compensated `measureItems()` (~30 lines incl. comments) |
| `src/apps/desktop/src/helpers/__tests__/virtualScrollerScrollAnchor.spec.ts` | NEW spec, 6 tests |
| `docs/superpowers/plans/2026-08-23-chatview-scroll-jump-fix.md` | This plan |

No backend changes. No migration. No wire/SSE changes.

## 5. Test plan

New spec `virtualScrollerScrollAnchor.spec.ts` (jsdom, following
virtualScrollerBuffer.spec.ts patterns — Object.defineProperty for geometry):

1. **grows-above-anchor keeps content stationary** — 200 items × 64px est;
   mount, scroll to middle; simulate measureItems writing 300px for 10 items
   above the anchor; assert scrollTop increased by exactly Σ(300−64).
2. **shrink-above-anchor scrolls up equally** — reverse sign case.
3. **first-measurement-of-buffer-item uses estimate baseline** — item never
   measured before, above anchor: compensation = h − defaultItemHeight.
4. **visible-window growth does NOT compensate** — item AT/after anchor
   grows: scrollTop unchanged (streaming growth must not be fought).
5. **no compensation while preserving scroll** — beginPreserve active →
   measureItems changes heights → scrollTop untouched.
6. **clamps at zero** — compensation would go negative → scrollTop = 0.

Plus regression: full vitest suite green (existing
virtualScrollerBuffer/ScrollEmit/Threshold/scrollToPosition specs must stay
green), `vue-tsc` typecheck, `vite build`.

## 6. Risks / mitigations

- **Double-compensation with ChatView's spacer observer:** ChatView only
  acts when `isAtBottom`; at-bottom the user isn't reading mid-list, and
  stick-to-bottom wins (desired). Mid-list ChatView does nothing. No overlap.
- **Interaction with scrollToBottom('auto') during SSE streaming:** at
  bottom, anchor ≈ last items; above-anchor deltas rare (buffer above bottom
  is fully measured after initial settle). Streaming appends don't change
  above-anchor heights. Safe.
- **Rapid fling + many pending measurements:** compensation applies once per
  debounced measureItems run using cumulative deltas — single assignment per
  batch, no per-item thrash.
- **jsdom has no layout:** tests drive `measureItems` indirectly by mocking
  child `offsetHeight` via `Object.defineProperty` on rendered wrappers, or
  by calling exposed internals through component vm if needed. If direct
  invocation proves cleaner, extract the compensation math into a pure
  exported helper `computeAnchorCompensation(...)` unit-tested separately
  (preferred — matches repo pattern of pure helpers +
  thin integration test).

## 7. Execution order

1. Worktree `worktree/chatview-scroll-jump-fix` (+ node_modules symlink into
   src/apps/desktop — known worktree gotcha from PR #299/#302).
2. Extract pure helper + write failing tests (TDD).
3. Implement in VirtualScroller.vue.
4. Green: targeted spec → full vitest → vue-tsc + vite build.
5. Commit, push, open PR, kanban → in_review_task.
