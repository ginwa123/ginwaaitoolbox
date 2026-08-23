/**
 * virtualScrollerScrollAnchor.ts
 *
 * Pure math for VirtualScroller's measurement-shift compensation.
 *
 * Why this exists: `measureItems()` writes REAL heights over the
 * `defaultItemHeight` ESTIMATES for every rendered child — including up
 * to `buffer` items ABOVE the viewport. Each write mutates
 * `accumulatedHeights` and therefore the top/bottom spacers, and since
 * CSS scroll anchoring is disabled (`overflow-anchor: none`, needed for
 * the older ratcheting fix), nothing adjusted scrollTop. Content below
 * the measured items shifted by Σ(real − estimate) while the viewport
 * stayed put — the "long chats jump while scrolling" bug
 * (task_1787496087806_6, log evidence: adjacent samples sh=31443 →
 * sh=36416 with top advancing only half as much).
 *
 * The scroller compensates by adjusting scrollTop by the same signed
 * total whenever measured heights change for indices strictly ABOVE the
 * current viewport start (the anchor). Growth in the visible window is
 * real content (streaming text, image load) and must NOT be compensated.
 *
 * Pure function (no DOM, no Vue) so the branchy parts are unit-testable,
 * mirroring `virtualScrollerThreshold.ts`.
 */

/** One pending height write from a measure pass. */
export interface AnchorMeasurement {
  /** Item index in the full items array. */
  index: number
  /** Newly measured height in px (>0). */
  newHeight: number
  /**
   * Previously stored height in px, or undefined when this item has
   * never been measured before.
   */
  oldHeight: number | undefined
}

export interface AnchorCompensationInput {
  /**
   * Index of the first item at/under the viewport top edge BEFORE the
   * height model changed (the anchor). Measurements strictly above this
   * index shift content under the viewport; measurements at/after it do
   * not. Negative = empty list → no-op.
   */
  anchorIndex: number
  /** scrollTop captured before the height model changed. */
  prevScrollTop: geometry_px
  /** The estimate that backed unmeasured items' old layout. */
  defaultItemHeight: number
  /** Pending writes from the measure pass. */
  measurements: AnchorMeasurement[]
}

// Keep the wire shape honest without importing DOM types into a pure
// module: heights are plain numbers in px.
type geometry_px = number

export interface AnchorCompensationResult {
  /**
   * Signed total shift of all above-anchor content in px. Positive =
   * content above grew → scrollTop must increase to stay stationary.
   */
  shiftPx: number
  /**
   * scrollTop after compensation, clamped at ≥ 0. Equals prevScrollTop
   * when there was nothing to compensate.
   */
  newScrollTop: number
  /** True when the clamp at 0 bit (residual jump is unavoidable). */
  clamped: boolean
}

/**
 * Compute the scrollTop adjustment that keeps the viewport stationary
 * when stored heights change for items above the viewport start.
 *
 * Rules:
 *   - Only indices STRICTLY BELOW `anchorIndex` contribute. A write AT
 *     the anchor index changes where the anchor's own top edge sits...
 *     but the browser keeps scrollTop fixed and the spacer above the
 *     anchor grows by exactly (new − estimate), so the anchor's content
 *     moves down by that amount — it DOES shift content under the
 *     viewport. Hmm — wait, let me restate precisely:
 *
 *     Actually the anchor item itself IS part of what's visible. If the
 *     anchor item's own height changes, its bottom edge moves but its
 *     TOP edge stays put (it starts right at the topSpacer boundary).
 *     Content under the viewport top edge = the anchor's top region —
 *     unchanged. So writes AT the anchor index must NOT contribute;
 *     only writes strictly above it.
 *
 *   - Never-measured items previously contributed `defaultItemHeight`
 *     to the layout, so their baseline is the estimate, not 0.
 *   - Result clamps at ≥ 0 (scrollTop can't go negative); `clamped`
 *     flags the residual-jump case.
 */
export function computeAnchorCompensation(
  input: AnchorCompensationInput,
): AnchorCompensationResult {
  const { anchorIndex, prevScrollTop, defaultItemHeight, measurements } = input

  if (!Number.isFinite(anchorIndex) || anchorIndex < 0) {
    return { shiftPx: 0, newScrollTop: prevScrollTop, clamped: false }
  }

  let shiftPx = 0
  for (const m of measurements) {
    if (m.index >= anchorIndex) continue // visible-window growth: real content
    const baseline = m.oldHeight ?? defaultItemHeight
    shiftPx += m.newHeight - baseline
  }

  if (shiftPx === 0) {
    return { shiftPx: 0, newScrollTop: prevScrollTop, clamped: false }
  }

  const raw = prevScrollTop + shiftPx
  const clamped = raw < 0
  return {
    shiftPx,
    newScrollTop: Math.max(0, raw),
    clamped,
  }
}
