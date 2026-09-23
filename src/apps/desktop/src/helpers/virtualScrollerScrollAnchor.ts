/**
 * virtualScrollerScrollAnchor.ts
 *
 * Pure math for VirtualScroller's measurement-shift compensation.
 *
 * Why this exists: `measureItems()` rewrites REAL heights over ESTIMATES
 * for every rendered child — including up to `buffer` items ABOVE the
 * viewport. Each write mutates `accumulatedHeights`, and since CSS scroll
 * anchoring is disabled (`overflow-anchor: none`, needed for the older
 * ratcheting fix), nothing adjusts scrollTop unless WE do. Content under
 * the viewport teleports by the total model delta above the anchor —
 * the "long chats jump while scrolling" bug
 * (task_1787496087806_6).
 *
 * ── v2: anchor prefix-sum delta (2026-09-23, scroll-jump fix) ──────────────
 *
 * v1 summed PER-MEUREMENT deltas with `baseline = oldHeight ??
 * defaultItemHeight`. That baseline was wrong twice over, and both
 * failure modes showed up as jumps on "many messages with many
 * different heights":
 *
 *   1. Wrong baseline for first measurements. The model does NOT
 *      estimate unmeasured items with the static `defaultItemHeight`
 *      prop (64px in ChatView) — it uses the adaptive running MEDIAN
 *      (`estimateHeight`, typically 200-600px in a real chat). Every
 *      first measurement above the viewport therefore over-compensated
 *      by (median − 64) px. With buffer=30, scrolling up through
 *      unmeasured history stacked tens of those errors into one
 *      scrollTop write — the scroll gesture visibly "fought back".
 *
 *   2. Estimate drift carried NO measurement entry. `observe()` feeds
 *      the estimator INSIDE a measure pass, so the median can move
 *      between rebuilds; every UNMEASURED item's contribution to the
 *      prefix changes with it — including items above the viewport.
 *      v1 only compensated entries in its `measurements` list, so a
 *      median shift (e.g. the first SSE-driven remeasure after mount)
 *      moved topSpacer with zero scrollTop correction: a pure
 *      teleport of the whole rendered window.
 *
 * v2 compares the ANCHOR's prefix sum before/after the model rebuild.
 * `prefix(anchor)` IS the summed height-model contribution of every
 * item strictly above the anchor — measured or not, any estimate
 * source. Its delta is exactly the signed shift of the content under
 * the viewport top edge:
 *
 *   screenPos(item) = prefix(anchor) + realOffset - scrollTop
 *
 * Keeping `scrollTop + prefix(anchor)` constant keeps every rendered
 * pixel stationary, and items AT/AFTER the anchor are excluded by
 * construction (their heights never appear in `prefix(anchor)`) —
 * visible-window growth still flows through uncompensated, as
 * intended.
 *
 * Pure function (no DOM, no Vue) so every branch is unit-testable,
 * mirroring `virtualScrollerThreshold.ts`.
 */

// Keep the wire shape honest without importing DOM types into a pure
// module: heights are plain numbers in px.
type geometry_px = number

/**
 * One pending height write from a measure pass. Carried on the debug
 * log only — compensation itself no longer consumes per-item entries
 * (see the v2 note above).
 */
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
   * height model changed (the anchor). Negative = empty list → no-op.
   */
  anchorIndex: number
  /** scrollTop captured before the height model changed. */
  prevScrollTop: geometry_px
  /**
   * `accumulatedHeights[anchorIndex]` captured BEFORE the pass
   * mutates the model — the model-space top edge of the anchor item.
   */
  oldAnchorTop: geometry_px
  /**
   * `accumulatedHeights[anchorIndex]` after the pass rebuilt the
   * model (measured heights written, estimator re-seeded, estimates
   * refreshed).
   */
  newAnchorTop: geometry_px
}

export interface AnchorCompensationResult {
  /**
   * Signed delta of the anchor's prefix sum. Positive = content above
   * grew in the model → scrollTop must increase to stay stationary.
   */
  shiftPx: geometry_px
  /** scrollTop after compensation, clamped at ≥ 0. */
  newScrollTop: geometry_px
  /** True when the clamp at 0 bit (residual jump is unavoidable). */
  clamped: boolean
}

/**
 * Compute the scrollTop adjustment that keeps rendered content
 * stationary when the height model's prefix sum at the anchor changes.
 *
 * Rules:
 *   - `prefix(anchor)` covers items STRICTLY ABOVE the anchor only.
 *     A height change AT/AFTER the anchor moves that item's bottom
 *     edge (and everything below), never its top edge — content under
 *     the viewport top is unchanged, so those writes must not
 *     contribute. The prefix definition gives this for free.
 *   - The delta covers BOTH kinds of model churn in one subtraction:
 *     real-height writes for measured items AND estimate refreshes
 *     (estimator median movement) for unmeasured ones.
 *   - Result clamps at ≥ 0 (scrollTop can't go negative); `clamped`
 *     flags the residual-jump case.
 *   - Negative / non-finite anchorIndex (empty or unmounted list) is
 *     a no-op.
 */
export function computeAnchorCompensation(
  input: AnchorCompensationInput,
): AnchorCompensationResult {
  const { anchorIndex, prevScrollTop, oldAnchorTop, newAnchorTop } = input

  if (
    !Number.isFinite(anchorIndex) ||
    anchorIndex < 0 ||
    !Number.isFinite(oldAnchorTop) ||
    !Number.isFinite(newAnchorTop)
  ) {
    return { shiftPx: 0, newScrollTop: prevScrollTop, clamped: false }
  }

  const shiftPx = newAnchorTop - oldAnchorTop
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
