/**
 * P1 performance helpers for VirtualScroller.vue
 * (task_1787551495337_9, "make virtual scroller more smooth").
 *
 * Pure functions/classes only — no DOM, no Vue imports — so every branch
 * is unit-testable without mounting (same convention as
 * virtualScrollerScrollAnchor.ts / virtualScrollerThreshold.ts).
 */

/**
 * Round a measured height to an integer pixel value ≥ 1.
 *
 * WHY: `offsetHeight` in Chromium can be fractional under sub-pixel
 * layout. Fractional stored heights re-quantize differently between our
 * prefix sums and the browser's own layout, producing ±1px spacer drift
 * that shows up as micro-jitter while scrolling. Integers make the
 * hysteresis dead-band (`HYSTERESIS_PX`) exact and the accumulated
 * heights stable across frames.
 *
 * Non-finite / non-positive inputs collapse to 1 (defense-in-depth —
 * the scroller already filters `h > 0` before measuring, but jsdom and
 * detached nodes can still hand back 0/NaN).
 */
export function quantizePx(value: number): number {
  if (!Number.isFinite(value) || value <= 0) return 1
  return Math.round(value)
}

/**
 * Running-median estimator for unmeasured item heights.
 *
 * WHY: ChatView passes a fixed `defaultItemHeight=64`, but real chat
 * bubbles are almost always taller (200–3000px). Every unmeasured item
 * is estimated at 64px, so spacers are systematically short until
 * measured and every measurement pass triggers anchor compensation.
 * Learning the running MEDIAN of measured heights gives far better
 * estimates for never-measured items → fewer wrong spacers → fewer
 * compensation shifts → smoother scroll.
 *
 * Median (not mean) so one giant code-block message can't skew the
 * estimate for everyone.
 *
 * Complexity: `observe()` is O(log n) search + O(n) splice where
 * n ≤ maxSamples (a small constant, default 64) — effectively O(1) per
 * call. `estimate()` is O(1).
 */
export class AdaptiveItemHeightEstimator {
  /** Sorted sample store (ascending px). */
  private samples: number[] = []
  /** Observation-order FIFO — tracks which sample is oldest for eviction. */
  private order: number[] = []
  private readonly seed: number
  private readonly maxSamples: number

  constructor(options?: { seed?: number; maxSamples?: number }) {
    const s = options?.seed
    this.seed = Number.isFinite(s) && (s as number) > 0 ? Math.round(s as number) : 100
    const m = options?.maxSamples
    this.maxSamples = Number.isFinite(m) && (m as number) > 0 ? Math.floor(m as number) : 64
  }

  /**
   * Record one real measured height. Invalid values (non-finite,
   * non-positive) are ignored silently — callers already filter most of
   * these; double-filtering keeps the sample set clean regardless.
   */
  observe(heightPx: number): void {
    if (!Number.isFinite(heightPx) || heightPx <= 0) return
    const h = quantizePx(heightPx)

    // Binary search for insertion point (leftmost position where h fits).
    let lo = 0
    let hi = this.samples.length
    while (lo < hi) {
      const mid = (lo + hi) >> 1
      if ((this.samples[mid] ?? 0) < h) lo = mid + 1
      else hi = mid
    }
    this.samples.splice(lo, 0, h)
    this.order.push(h)

    // Rolling window: evict the OLDEST observation when over capacity.
    if (this.order.length > this.maxSamples) {
      const oldest = this.order.shift()
      if (oldest !== undefined) {
        const idx = this.samples.indexOf(oldest)
        if (idx !== -1) this.samples.splice(idx, 1)
      }
    }
  }

  /** Current best guess for an unmeasured item's height (integer px). */
  estimate(): number {
    const n = this.samples.length
    if (n === 0) return this.seed
    const mid = n >> 1
    if (n % 2 === 1) return this.samples[mid] ?? this.seed
    const a = this.samples[mid - 1] ?? this.seed
    const b = this.samples[mid] ?? a
    return Math.round((a + b) / 2)
  }

  /** Forget everything — back to the seed (e.g. on items list swap). */
  reset(): void {
    this.samples = []
    this.order = []
  }
}
