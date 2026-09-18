/**
 * Regression tests for VirtualScroller scroll-anchor compensation.
 *
 * Why this file exists:
 *   The user reported "when chatview have long chat messages, the view
 *   its kind of jumping". Scroll-log evidence (task_1786540903899):
 *   adjacent samples showed scrollHeight swinging ±5000px while scrollTop
 *   advanced independently — e.g. sample #1863 sh=31443 → #1864 sh=36416
 *   (+4973px) with top advancing only +2548px. The content under the
 *   viewport teleported by the difference.
 *
 *   Root cause: `measureItems()` writes REAL heights over the 64px
 *   ESTIMATES for every rendered child — including up to `buffer=30`
 *   items ABOVE the viewport. Each write mutates `accumulatedHeights`
 *   and therefore the top/bottom spacers. CSS scroll anchoring is off
 *   (`overflow-anchor: none`, needed to fix the older ratcheting bug),
 *   so nothing adjusted scrollTop — content below the measured items
 *   shifted by Σ(real − estimate) while the viewport stayed put.
 *
 *   Fix: anchor-compensated measurement. When stored heights change for
 *   indices strictly ABOVE the current viewport start, adjust scrollTop
 *   by the same signed total so the pixels under the viewport stay put.
 *   Growth in the VISIBLE window is real content (streaming text) and
 *   must NOT be compensated.
 *
 *   The math lives in a pure helper (`virtualScrollerScrollAnchor.ts`)
 *   so every branch is unit-testable without DOM; two integration tests
 *   drive the mounted component end-to-end (mocked offsetHeight, real
 *   debounce timing) to pin the wiring.
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
    prevScrollTop: 3200, // 50 items × 64px estimate
    defaultItemHeight: 64,
  }

  it('sums positive deltas for items above the anchor (content grew)', () => {
    // Three items above the viewport grew 64 → 300.
    const result = computeAnchorCompensation({
      ...base,
      measurements: [
        { index: 40, newHeight: 300, oldHeight: 64 },
        { index: 41, newHeight: 300, oldHeight: 64 },
        { index: 42, newHeight: 300, oldHeight: 64 },
      ],
    })
    expect(result.shiftPx).toBe(3 * 236)
    expect(result.newScrollTop).toBe(3200 + 3 * 236)
    expect(result.clamped).toBe(false)
  })

  it('sums negative deltas for items above the anchor (content shrank)', () => {
    const result = computeAnchorCompensation({
      ...base,
      measurements: [
        { index: 10, newHeight: 40, oldHeight: 200 },
        { index: 11, newHeight: 40, oldHeight: 200 },
      ],
    })
    expect(result.shiftPx).toBe(-320)
    expect(result.newScrollTop).toBe(3200 - 320)
    expect(result.clamped).toBe(false)
  })

  it('compares never-measured items against defaultItemHeight (their estimate backed the old layout)', () => {
    const result = computeAnchorCompensation({
      ...base,
      measurements: [{ index: 30, newHeight: 264, oldHeight: undefined }],
    })
    expect(result.shiftPx).toBe(264 - 64)
    expect(result.newScrollTop).toBe(3200 + 200)
  })

  it('ignores measurements at or after the anchor (visible-window growth is real content)', () => {
    const result = computeAnchorCompensation({
      ...base,
      measurements: [
        { index: 50, newHeight: 900, oldHeight: 64 }, // exactly at anchor
        { index: 51, newHeight: 900, oldHeight: 64 }, // below anchor
        { index: 99, newHeight: 1200, oldHeight: undefined },
      ],
    })
    expect(result.shiftPx).toBe(0)
    expect(result.newScrollTop).toBe(3200)
  })

  it('clamps at zero when the correction would go negative', () => {
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 100,
      measurements: [{ index: 5, newHeight: 10, oldHeight: 500 }],
    })
    expect(result.shiftPx).toBe(-490)
    expect(result.clamped).toBe(true)
    expect(result.newScrollTop).toBe(0)
  })

  it('returns a no-op for empty measurements', () => {
    const result = computeAnchorCompensation({ ...base, measurements: [] })
    expect(result.shiftPx).toBe(0)
    expect(result.newScrollTop).toBe(base.prevScrollTop)
    expect(result.clamped).toBe(false)
  })

  it('handles negative anchorIndex (empty/unmounted list) as no-op', () => {
    const result = computeAnchorCompensation({
      ...base,
      anchorIndex: -1,
      measurements: [{ index: 0, newHeight: 300, oldHeight: 64 }],
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

    // scrollTop must have been advanced by exactly Σ(300−64) so the same
    // content remains under the viewport top edge.
    expect(el.scrollTop).toBe(before + expectedShift)
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
    // through uncompensated (see 'ignores measurements at or after the
    // anchor' above).
    mockChildHeights(el, 100, 3000, 64, 97)
    el.scrollTop = 6400 - 128
    el.dispatchEvent(new Event('scroll'))
    await nextTick() // Vue commits the new window incl. item 97

    // NO vi.advanceTimersByTime here — the correction must already be
    // applied synchronously within the pre-paint tick. Final position =
    // user's own −128px scroll (preserved) + item 97's growth (+2936)
    // (compensated) = 6272 + 2936.
    expect(el.scrollTop).toBe(6400 - 128 + (3000 - 64))
    wrapper.unmount()
  })
})
