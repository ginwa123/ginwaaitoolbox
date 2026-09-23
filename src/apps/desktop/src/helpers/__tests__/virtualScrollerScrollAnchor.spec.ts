/**
 * Regression tests for VirtualScroller scroll-anchor compensation.
 *
 * Why this file exists:
 *   The user reported "when chatview have long chat messages, the view
 *   its kind of jumping" — and again, years of commits later, as
 *   "virtual scroller not smooth, feels like jumping … when data is
 *   many with many different height".
 *
 *   The scroller positions its rendered window at MODEL coordinates
 *   (`topSpacer = accumulatedHeights[start]`, estimates + measurements)
 *   while the content inside lays out with REAL heights. CSS scroll
 *   anchoring is disabled (`overflow-anchor: none`, needed for the
 *   older ratcheting bug), so whenever the model changes above the
 *   viewport the scroller must adjust scrollTop itself or the content
 *   under the viewport teleports.
 *
 *   v1 of the compensation summed per-measurement deltas with
 *   `baseline = oldHeight ?? defaultItemHeight`. Two failure modes
 *   survived review until 2026-09-23:
 *
 *     A. WRONG BASELINE — the model does not estimate unmeasured items
 *        with the static prop (64px) but with the adaptive running
 *        MEDIAN (200-600px in real chats). Every first measurement
 *        above the viewport over-compensated by (median − 64) px;
 *        with buffer=30 those errors stacked into thousands of px of
 *        wrong scrollTop while scrolling up through history.
 *
 *     B. UNCOMPENSATED ESTIMATE DRIFT — `observe()` feeds the
 *        estimator INSIDE a pass, so the median can move between
 *        rebuilds; every UNMEASURED item's contribution above the
 *        viewport shifts with it and v1 had no measurement entry for
 *        it (a pure teleport — e.g. the first SSE-driven remeasure).
 *
 *   v2 compensates the ANCHOR's prefix-sum delta
 *   (`newAnchorTop − oldAnchorTop`), which by construction covers
 *   exactly the items strictly above the viewport top — measured or
 *   not — and never the anchor itself. The pure helper
 *   (`virtualScrollerScrollAnchor.ts`) carries the math; integration
 *   tests drive the mounted component end-to-end (mocked offsetHeight,
 *   fake timers) to pin the wiring and the measure cadence.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'
import { computeAnchorCompensation } from '../virtualScrollerScrollAnchor'

// ─── Pure helper tests ────────────────────────────────────────────────────────

describe('computeAnchorCompensation', () => {
  const base = {
    anchorIndex: 50,
    prevScrollTop: 3200, // model prefix at the anchor before the pass
  }

  it('shifts scrollTop by the anchor prefix delta (content above grew)', () => {
    // Everything strictly above index 50 grew 640px in the model —
    // real-height writes and estimate refreshes alike.
    const result = computeAnchorCompensation({
      ...base,
      oldAnchorTop: 3200,
      newAnchorTop: 3200 + 640,
    })
    expect(result.shiftPx).toBe(640)
    expect(result.newScrollTop).toBe(3840)
    expect(result.clamped).toBe(false)
  })

  it('shifts scrollTop down when content above shrank', () => {
    const result = computeAnchorCompensation({
      ...base,
      oldAnchorTop: 3200,
      newAnchorTop: 2880,
    })
    expect(result.shiftPx).toBe(-320)
    expect(result.newScrollTop).toBe(2880)
    expect(result.clamped).toBe(false)
  })

  it('is a no-op when the prefix is unchanged (writes at/below the anchor)', () => {
    // Height changes AT or AFTER the anchor never appear in
    // prefix(anchor) — visible-window growth must flow through
    // uncompensated. Exercised by passing identical tops.
    const result = computeAnchorCompensation({
      ...base,
      oldAnchorTop: 3200,
      newAnchorTop: 3200,
    })
    expect(result.shiftPx).toBe(0)
    expect(result.newScrollTop).toBe(3200)
    expect(result.clamped).toBe(false)
  })

  it('clamps at zero when the correction would go negative', () => {
    const result = computeAnchorCompensation({
      ...base,
      anchorIndex: 5,
      prevScrollTop: 100,
      oldAnchorTop: 6400,
      newAnchorTop: 5910, // −490
    })
    expect(result.shiftPx).toBe(-490)
    expect(result.clamped).toBe(true)
    expect(result.newScrollTop).toBe(0)
  })

  it('handles negative anchorIndex (empty/unmounted list) as no-op', () => {
    const result = computeAnchorCompensation({
      ...base,
      anchorIndex: -1,
      oldAnchorTop: 0,
      newAnchorTop: 900,
    })
    expect(result.shiftPx).toBe(0)
    expect(result.newScrollTop).toBe(base.prevScrollTop)
    expect(result.clamped).toBe(false)
  })

  it('treats non-finite tops as a no-op (defensive)', () => {
    const result = computeAnchorCompensation({
      ...base,
      oldAnchorTop: Number.NaN,
      newAnchorTop: 4000,
    })
    expect(result.shiftPx).toBe(0)
    expect(result.newScrollTop).toBe(base.prevScrollTop)
  })
})

// ─── Integration tests (mounted component) ───────────────────────────────────

/**
 * Mount a scroller with N items at the ChatView-like settings
 * (defaultItemHeight 64, buffer 30) and a fixed 800px viewport.
 */
function mountScroller(n: number) {
  const items = Array.from({ length: n }, (_, i) => ({ id: i }))
  const wrapper = mount(VirtualScroller, {
    props: {
      items,
      buffer: 30,
      defaultItemHeight: 64,
      totalCount: n,
      loadMoreAtTop: true,
    },
  })
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
  Object.defineProperty(el, 'scrollHeight', { value: n * 64, configurable: true })
  return { wrapper, el }
}

/** Dispatch a scroll event; onScroll reads el.scrollTop synchronously. */
function scroll(el: HTMLElement, top: number) {
  el.scrollTop = top
  el.dispatchEvent(new Event('scroll'))
}

/**
 * Dispatch a scroll event WITHOUT moving the viewport — for "the user
 * keeps scrolling and the position genuinely didn't change" (a real
 * repeated event reports the current, already-compensated position;
 * writing `el.scrollTop` here would manually undo the compensation the
 * test is trying to observe).
 */
function dispatchScroll(el: HTMLElement) {
  el.dispatchEvent(new Event('scroll'))
}

/**
 * Give the rendered children fake offsetHeights: `tallPx` for items
 * above `anchorIndex`, `estimatePx` for the rest. Returns the expected
 * compensation total for the above-anchor set. Pass `onlyIndex` to
 * make exactly ONE above-anchor item tall (the "single long message"
 * case); the rest keep the estimate.
 */
function mockChildHeights(
  el: HTMLElement,
  anchorIndex: number,
  tallPx: number,
  estimatePx: number,
  onlyIndex?: number,
): number {
  const content = el.querySelector('.virtual-scroller-content')
  if (!content) throw new Error('.virtual-scroller-content not found')
  let expectedShift = 0
  for (const child of Array.from(content.children)) {
    const idx = Number((child as HTMLElement).getAttribute('data-vs-index'))
    const isAbove = idx < anchorIndex
    const h = isAbove && (onlyIndex === undefined || idx === onlyIndex) ? tallPx : estimatePx
    Object.defineProperty(child, 'offsetHeight', { value: h, configurable: true })
    if (isAbove && h !== estimatePx) expectedShift += h - estimatePx
  }
  return expectedShift
}

/** Mock EVERY rendered child to one height. */
function mockAllChildren(el: HTMLElement, h: number) {
  const content = el.querySelector('.virtual-scroller-content')
  if (!content) throw new Error('.virtual-scroller-content not found')
  for (const child of Array.from(content.children)) {
    Object.defineProperty(child, 'offsetHeight', { value: h, configurable: true })
  }
}

describe('VirtualScroller measurement anchor compensation', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('keeps content stationary when items above the viewport are measured taller', async () => {
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    // Scroll to the middle: 100 items × 64px = 6400. With all-equal
    // estimates, findStartIndex() → 100.
    scroll(el, 6400)
    await nextTick()
    const before = el.scrollTop

    // Simulate the layout settling: every above-anchor buffer item is
    // really 300px tall (markdown paragraph), visible items stay 64px.
    // NOTE: the scroll we just dispatched scheduled measureItems with
    // offsetHeight still 0 everywhere (h>0 filter skips) — flush it first.
    vi.advanceTimersByTime(60)
    const expectedShift = mockChildHeights(el, 100, 300, 64)

    // Next scroll event schedules the measure pass that sees the mocks.
    scroll(el, 6400)
    vi.advanceTimersByTime(60)
    await nextTick()

    // scrollTop must have advanced by exactly Σ(300−64) so the same
    // content remains under the viewport top edge. (The estimator
    // median stays 64 here — the mock heights straddle it — so the
    // prefix delta equals the per-item sum.)
    expect(el.scrollTop).toBe(before + expectedShift)
    wrapper.unmount()
  })

  it('baselines first measurements on the MODEL estimate (median), not defaultItemHeight', async () => {
    // Regression for failure mode A: the model estimates unmeasured
    // items with the adaptive median — once the median has learned
    // 400px, the static 64px prop no longer describes anything. First
    // measurements above the anchor must be compensated against the
    // 400px model contribution (plus the in-pass estimator drift),
    // NOT against 64px.
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    // Phase 1 — teach the estimator a 400px profile. Measure the first
    // window (indices 0..31) at 400px: anchor is 0 so no compensation
    // runs (prefix(0) = 0), stored heights land, median becomes 400,
    // and every unmeasured item now contributes 400px to the model.
    scroll(el, 0)
    await nextTick()
    vi.advanceTimersByTime(60) // flush pre-debounce measure (offsetHeight 0 → no-op)
    mockAllChildren(el, 400)
    scroll(el, 0)
    vi.advanceTimersByTime(60) // phase-1 measure pass
    await nextTick()
    expect(el.scrollTop).toBe(0)

    // Phase 2 — jump into virgin history: scrollTop 40000 → anchor 100
    // (uniform 400px model), buffer window 70..131. Render first, then
    // mock the fresh children to 700px, then arm the measure pass.
    scroll(el, 40000)
    await nextTick() // render + pre-paint measure (fresh children: h=0 → no-op)
    vi.advanceTimersByTime(60) // trailing debounce (still h=0 → no-op)
    mockAllChildren(el, 700)
    scroll(el, 40000)
    vi.advanceTimersByTime(60)
    await nextTick()

    // Ground truth for prefix(100) AFTER the pass:
    //   0..42   stored 400 (phase 1 measured the full pre-measure
    //           window — at that point estimates were still the 64px
    //           seed, so the 800px viewport rendered 43 items)  = 17200
    //   43..69  unmeasured, median is now 700                = 18900
    //   70..99  first-measured at 700                         = 21000
    //   total   = 57100, old prefix = 400 × 100 = 40000 → shift 17100.
    // v1 would have computed Σ(700−64) over 70..99 = 19080 — wrong
    // baseline AND blind to the unmeasured drift (43..69).
    expect(el.scrollTop).toBe(57100)
    wrapper.unmount()
  })

  it('does NOT compensate while a preserve window is active', async () => {
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 6400)
    await nextTick()
    vi.advanceTimersByTime(60)

    // Open a preserve window (as handleLoadMore does around a prepend).
    const vm = wrapper.vm as unknown as {
      beginPreserve: (n: number) => void
      isPreservingScroll: boolean
    }
    vm.beginPreserve(1)
    expect(vm.isPreservingScroll).toBe(true)

    const before = el.scrollTop
    mockChildHeights(el, 100, 300, 64)
    scroll(el, 6400)
    vi.advanceTimersByTime(60)
    await nextTick()

    // Heights were recorded (model updated) but scrollTop untouched —
    // endPreserve owns scroll restoration during prepends.
    expect(el.scrollTop).toBe(before)
    wrapper.unmount()
  })

  it('corrects a tall item rendering above the viewport PRE-PAINT (no timer advance)', async () => {
    // The residual jump (task_1787496087806_6 follow-up): when ONE long
    // message scrolls into the top buffer, Vue renders it in one commit
    // — topSpacer shrinks by the 64px estimate while ~3000px of real
    // content takes its place → content under the viewport shifts
    // immediately at RENDER time. The debounced measureItems only
    // compensates ≤50ms LATER, so the user sees a down-up bounce.
    //
    // Fix contract: a watcher on rendered-range change must run
    // measureItems inside nextTick (pre-paint), so render + compensation
    // land in the SAME frame. This test asserts the correction WITHOUT
    // advancing timers — if compensation needed the 50ms debounce, this
    // fails.
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 6400) // anchor = item 100
    await nextTick()
    vi.advanceTimersByTime(60) // flush initial measure pass

    // Simulate scrolling UP so a new tall item enters the TOP buffer:
    // move the viewport up by exactly two estimate-slots (128px). The
    // visibleRange recomputes; item 97 renders above the viewport with
    // mocked offsetHeight=3000 (the "one long message"). All other
    // buffer items keep the 64px estimate.
    //
    // The tall item MUST sit strictly above the anchor (97 < 98): the
    // anchor rule compensates only indices strictly above the viewport
    // start — growth at/below the anchor is real content and flows
    // through uncompensated (see 'is a no-op when the prefix is
    // unchanged' above).
    mockChildHeights(el, 100, 3000, 64, 97)
    el.scrollTop = 6400 - 128
    el.dispatchEvent(new Event('scroll'))
    await nextTick() // Vue commits the new window incl. item 97

    // NO vi.advanceTimersByTime here — the correction must already be
    // applied synchronously within the pre-paint tick. Final position =
    // user's own −128px scroll (preserved) + item 97's growth (+2936)
    // (compensated) = 6272 + 2936. The estimator median stays 64
    // (one 3000px sample among ~70×64), so prefix delta = 3000 − 64.
    expect(el.scrollTop).toBe(6400 - 128 + (3000 - 64))
    wrapper.unmount()
  })

  it('keeps measuring during sustained scrolling (trailing timer must not starve)', async () => {
    // Failure mode D: the 50ms measure debounce used to CLEAR+REARM on
    // every scroll event, so while scroll events kept arriving faster
    // than 50ms apart it never fired — all pending corrections then
    // landed in one lump when the gesture stopped (the "scroll, then
    // it jumps" feel). The scheduler must be max-wait: armed once,
    // fired at the deadline regardless of later events.
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 6400)
    await nextTick()
    vi.advanceTimersByTime(60) // flush pre-paint + debounce passes (h=0 → no-op)
    vi.advanceTimersByTime(50) // consume the mount-time measure timer (unmocked → no-op)

    const expectedShift = mockChildHeights(el, 100, 300, 64) // 30 × 236

    // Sustained scrolling: events every 40ms — always inside the 50ms
    // window, so a reset-per-event scheduler would never fire. Dispatch
    // WITHOUT rewriting scrollTop (see dispatchScroll): the position
    // genuinely did not change, and writing it would manually undo the
    // compensation this test observes.
    dispatchScroll(el)
    vi.advanceTimersByTime(40)
    dispatchScroll(el)
    vi.advanceTimersByTime(40) // past firstEvent+50: the measure must have run

    expect(el.scrollTop).toBe(6400 + expectedShift)
    wrapper.unmount()
  })
})
