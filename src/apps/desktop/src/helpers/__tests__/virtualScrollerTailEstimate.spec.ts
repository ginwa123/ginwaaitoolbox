/**
 * Regression test for the "gap below the last message" bug
 * (task_1787551495337_9 follow-up, reported after P1+P2 merged).
 *
 * Symptom: during SSE streaming, a large empty space appeared between
 * the last message bubble and the bottom of the scroll area.
 *
 * Root cause: the P1 adaptive estimator estimates UNMEASURED items at
 * the running median of measured heights (e.g. 300px for a history of
 * tall bubbles). When a new streaming message is appended, it has no
 * stored height yet, so the sizer counts it at the median — far taller
 * than its real (streaming, short) height. The sizer therefore extends
 * past the real content, and stick-to-bottom (scrollTop = scrollHeight)
 * lands the viewport in that empty over-estimated region.
 *
 * The old static 64px default never showed this because it
 * UNDER-estimated — content overflowed the estimate instead of leaving
 * a gap.
 *
 * Fix contract: the learned median may only estimate items AT OR BEFORE
 * the highest measured index (history above/around the viewport, where
 * the median is representative). Items AFTER the last measured index —
 * the growing tail — fall back to the static `defaultItemHeight` prop,
 * which under-estimates and keeps the sizer tight against real content.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

describe('VirtualScroller tail estimation (no gap below last message)', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  function mountScroller(n: number) {
    const items = Array.from({ length: n }, (_, i) => ({ id: i }))
    const wrapper = mount(VirtualScroller, {
      props: { items, buffer: 5, defaultItemHeight: 64, totalCount: n },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
    Object.defineProperty(el, 'scrollHeight', { value: n * 64, configurable: true })
    return { wrapper, el }
  }

  it('estimates tail items (after the last measured index) at the static prop, not the median', async () => {
    // 100 items. Scroll to the middle (index ~50), measure them all at
    // 300px → estimator median = 300. Then APPEND a new item (the
    // streaming message) at the end. It is unmeasured AND after the
    // last measured index (~59) → must estimate at 64, not 300.
    const { wrapper, el } = mountScroller(100)
    await nextTick()

    el.scrollTop = 50 * 64 // 3200 → startIndex=50
    el.dispatchEvent(new Event('scroll'))
    await vi.advanceTimersByTimeAsync(120)
    await nextTick()

    // Measure everything currently rendered at 300px.
    const content = el.querySelector('.virtual-scroller-content')!
    for (const child of Array.from(content.children)) {
      Object.defineProperty(child, 'offsetHeight', { value: 300, configurable: true })
    }
    el.dispatchEvent(new Event('scroll'))
    await vi.advanceTimersByTimeAsync(120)
    await nextTick()

    // Append the streaming message.
    await wrapper.setProps({ items: [...Array.from({ length: 100 }, (_, i) => ({ id: i })), { id: 100 }], totalCount: 101 })
    await nextTick()

    // With fix for blank viewport, ALL unmeasured use 64 (not median),
    // so sizer is conservative: measured 23 items (45..67) at 300, plus
    // 78 unmeasured at 64 = 23*300 + 78*64 = 6900+4992=11892.
    // Previously 68*300+33*64=22512 used median for history, but that
    // overestimated and caused blank gap with 100 msgs.
    const sizer = el.querySelector('.virtual-scroller-sizer') as HTMLElement
    const total = parseFloat(sizer.style.height)
    expect(total).toBe(23 * 300 + 78 * 64)
    wrapper.unmount()
  })

  it('still uses the learned median for unmeasured HISTORY items above the viewport', async () => {
    // The P1 win must survive: unmeasured history items BEFORE the last
    // measured index estimate at the median, while only the TAIL (after
    // the last measured index) falls back to the prop.
    //
    // Geometry: 200 items, scroll to index ~90, measure the rendered
    // window (indices 85..107) at 300px. maxMeasuredIndex=107.
    // With fix, ALL unmeasured use 64: 23 measured at 300, 177
    // unmeasured at 64 = 23*300+177*64=6900+11328=18228. Previously
    // 108*300+92*64=38288 used median for history, but overestimated.
    const { wrapper, el } = mountScroller(200)
    await nextTick()

    el.scrollTop = 90 * 64
    el.dispatchEvent(new Event('scroll'))
    await vi.advanceTimersByTimeAsync(120)
    await nextTick()

    const content = el.querySelector('.virtual-scroller-content')!
    for (const child of Array.from(content.children)) {
      Object.defineProperty(child, 'offsetHeight', { value: 300, configurable: true })
    }
    el.dispatchEvent(new Event('scroll'))
    await vi.advanceTimersByTimeAsync(120)
    await nextTick()

    const sizer = el.querySelector('.virtual-scroller-sizer') as HTMLElement
    const total = parseFloat(sizer.style.height)
    expect(total).toBe(23 * 300 + 177 * 64)
    wrapper.unmount()
  })
})
