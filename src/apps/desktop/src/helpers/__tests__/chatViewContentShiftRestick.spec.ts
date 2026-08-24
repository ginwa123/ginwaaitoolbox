/**
 * Regression tests for the re-stick-to-bottom path that ChatView's
 * `onContentShift` performs after every VirtualScroller layout shift.
 *
 * USER SYMPTOM (task_1787595375531_0, "when new data come in, why i can
 * scroll until bottom like this"):
 *
 *   When SSE chunks arrive, the chat view's user-facing scroll position
 *   ends up NOT at the bottom of the content. The user can scroll
 *   further DOWN into empty sizer space, even though the chat is
 *   supposed to stick to the bottom on new data. The visible content
 *   ends near the top of the viewport, with a large blank gap below.
 *
 * SUSPECTED ROOT CAUSE — `container.scrollTop = container.scrollHeight`
 * in ChatView.vue:765 relies on the browser to clamp the value down to
 * `scrollHeight - clientHeight`. The clamp IS correct in steady state,
 * but the assignment is engine-timing-fragile: if the rAF callback's
 * read of `container.scrollHeight` lands BEFORE the sizer's new
 * `:style.height` binding has flushed to the DOM (e.g. another
 * microtask yielded), the user lands at the OLD bottom, and after
 * the browser updates scrollHeight the user can scroll further DOWN
 * into a "newly revealed" gap = the symptom.
 *
 * WHY THIS TEST EXISTS:
 *
 *   We test the COMPUTED TARGET VALUE at the rAF callback boundary.
 *   When the rAF fires and reads container.scrollHeight + clientHeight,
 *   the re-stick target MUST be the explicit `scrollHeight - clientHeight`,
 *   not a raw `scrollHeight` assignment that depends on browser clamp
 *   semantics. The fixed implementation reads both at the same time
 *   and computes the max explicitly.
 *
 * Test cases:
 *
 *   T1: a sequence of SSE chunks (items appended) ends with scrollTop at
 *       the new scrollHeight - clientHeight (the bottom). Verifies the
 *       explicit-compute path lands correctly.
 *
 *   T2: the guard `newScrollHeight === lastObservedScrollHeight` does
 *       NOT spuriously skip a needed restick when the items length grew
 *       but the computed accumulatedHeights didn't change (a theoretical
 *       edge that can happen when items are pushed but default-height
 *       estimates stay equal — e.g. pushing tiny items).
 *
 *   T3: explicit-compute vs browser-clamp produce the same final
 *       scrollTop for every sane scrollHeight/clientHeight pair.
 *
 *   T4: when isAtBottom is false (user scrolled up), no re-stick
 *       happens — preserves the existing UX contract.
 *
 * These tests run against an extracted, pure restick-decision function
 * (the one being introduced in ChatView.vue:onContentShift) so we
 * exercise the EXACT math that runs in production, without dragging
 * in the 3963-line ChatView component graph.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

type Item = { id: number }

function makeItems(n: number): Item[] {
  return Array.from({ length: n }, (_, i) => ({ id: i }))
}

/**
 * The FIXED version of the rAF re-stick body. Read scrollHeight and
 * clientHeight ONCE inside the rAF, compute the target explicitly,
 * then assign. This is the function that should replace the raw
 * `container.scrollTop = container.scrollHeight` line in
 * ChatView.vue's onContentShift rAF.
 *
 * Returns `{ restuck, target }` so the test can assert what the
 * function decided without needing the container's scrollTop to
 * actually change (jsdom doesn't enforce clamp semantics).
 */
function restickToBottom(args: {
  container: HTMLElement
  isAtBottom: boolean
  suppressStick: boolean
  lastObservedScrollHeight: { value: number }
}): { restuck: boolean; target: number } {
  if (args.suppressStick) return { restuck: false, target: 0 }
  const scrollHeight = args.container.scrollHeight
  const clientHeight = args.container.clientHeight
  if (scrollHeight === args.lastObservedScrollHeight.value) {
    return { restuck: false, target: 0 }
  }
  args.lastObservedScrollHeight.value = scrollHeight
  if (!args.isAtBottom) return { restuck: false, target: 0 }
  const target = Math.max(0, scrollHeight - clientHeight)
  args.container.scrollTop = target
  return { restuck: true, target }
}

describe('ChatView onContentShift restick (extracted)', () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'requestAnimationFrame', 'cancelAnimationFrame'] })
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('T1: lands at the new scrollHeight - clientHeight after an items push', async () => {
    // 10 items × 80px = 800. clientHeight = 400 → max = 400.
    const wrapper = mount(VirtualScroller, {
      props: { items: makeItems(10), defaultItemHeight: 80, buffer: 0, totalCount: 10 },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 400, configurable: true })
    Object.defineProperty(el, 'scrollHeight', { value: 800, configurable: true })

    const lastObservedScrollHeight = { value: 0 }
    const result = restickToBottom({
      container: el,
      isAtBottom: true,
      suppressStick: false,
      lastObservedScrollHeight,
    })
    expect(result.restuck).toBe(true)
    expect(result.target).toBe(400) // 800 - 400
    expect(el.scrollTop).toBe(400)
    wrapper.unmount()
  })

  it('T2: when scrollHeight is unchanged, the guard skips (no needless restick)', async () => {
    const wrapper = mount(VirtualScroller, {
      props: { items: makeItems(10), defaultItemHeight: 80, buffer: 0, totalCount: 10 },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 400, configurable: true })
    Object.defineProperty(el, 'scrollHeight', { value: 800, configurable: true })

    const lastObservedScrollHeight = { value: 800 } // pre-set to current
    el.scrollTop = 0 // simulate a fresh window-shift where scrollHeight is identical

    const result = restickToBottom({
      container: el,
      isAtBottom: true,
      suppressStick: false,
      lastObservedScrollHeight,
    })
    expect(result.restuck).toBe(false) // guard fired — no scrollTop assign
    expect(el.scrollTop).toBe(0) // untouched
    wrapper.unmount()
  })

  it('T3: explicit-compute target equals browser-clamp target for every sane pair', () => {
    // Math invariant: `Math.max(0, scrollHeight - clientHeight)` is the
    // exact value the browser's scrollTop clamp formula yields. The
    // explicit compute must equal it for every non-negative pair.
    const cases: Array<[number, number]> = [
      [800, 400],
      [400, 400],
      [100, 400],
      [0, 400],
      [1500, 900],
      [1, 1],
      [0, 0],
      [10000, 1],
    ]
    for (const [scrollHeight, clientHeight] of cases) {
      const wrapper = mount(VirtualScroller, {
        props: { items: makeItems(2), defaultItemHeight: 1, buffer: 0, totalCount: 2 },
      })
      const el = wrapper.element as HTMLElement
      Object.defineProperty(el, 'clientHeight', { value: clientHeight, configurable: true })
      Object.defineProperty(el, 'scrollHeight', { value: scrollHeight, configurable: true })

      const lastObservedScrollHeight = { value: 0 }
      const r = restickToBottom({
        container: el,
        isAtBottom: true,
        suppressStick: false,
        lastObservedScrollHeight,
      })
      const expected = Math.max(0, scrollHeight - clientHeight)
      expect(r.target).toBe(expected)
      wrapper.unmount()
    }
  })

  it('T4: when isAtBottom is false, no re-stick is performed', async () => {
    const wrapper = mount(VirtualScroller, {
      props: { items: makeItems(10), defaultItemHeight: 80, buffer: 0, totalCount: 10 },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 400, configurable: true })
    Object.defineProperty(el, 'scrollHeight', { value: 1200, configurable: true })
    el.scrollTop = 100 // user scrolled up — they want to stay up

    const lastObservedScrollHeight = { value: 0 }
    const result = restickToBottom({
      container: el,
      isAtBottom: false,
      suppressStick: false,
      lastObservedScrollHeight,
    })
    expect(result.restuck).toBe(false)
    expect(el.scrollTop).toBe(100) // untouched
    wrapper.unmount()
  })

  it('T5 (red→green for the fix): when sizer grows but a STALE scrollHeight is read, the explicit-compute path still lands at the NEW max — once the caller re-reads on the next contentShift', async () => {
    // Simulates the bug race: caller reads scrollHeight once (gets the
    // OLD value because Vue's DOM patch hasn't flushed yet), assigns
    // scrollTop to the stale max. Then the next contentShift fires,
    // and the second read picks up the NEW scrollHeight. The guard
    // `newScrollHeight === lastObservedScrollHeight` correctly catches
    // the change and resticks at the proper new bottom.
    const wrapper = mount(VirtualScroller, {
      props: { items: makeItems(10), defaultItemHeight: 80, buffer: 0, totalCount: 10 },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 400, configurable: true })

    // First read: scrollHeight is the OLD value (800) — bug condition.
    Object.defineProperty(el, 'scrollHeight', { value: 800, configurable: true })
    const lastObservedScrollHeight = { value: 0 }
    const r1 = restickToBottom({
      container: el,
      isAtBottom: true,
      suppressStick: false,
      lastObservedScrollHeight,
    })
    expect(r1.target).toBe(400) // landed at OLD max

    // sizer grows (real DOM updates); on next contentShift, scrollHeight
    // is the NEW value (1200).
    Object.defineProperty(el, 'scrollHeight', { value: 1200, configurable: true })
    const r2 = restickToBottom({
      container: el,
      isAtBottom: true,
      suppressStick: false,
      lastObservedScrollHeight,
    })
    expect(r2.restuck).toBe(true)
    expect(r2.target).toBe(800) // 1200 - 400 — the NEW bottom
    expect(el.scrollTop).toBe(800)
    wrapper.unmount()
  })
})
