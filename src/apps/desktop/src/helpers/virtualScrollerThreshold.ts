/**
 * Compute the effective `loadMore` threshold in pixels.
 *
 * The VirtualScroller fires `loadMore` when the user is within this many
 * pixels of the load edge. The threshold is the **larger** of:
 *
 *   - `absoluteFloor`  — the existing `loadMoreThreshold` prop, in px.
 *                        A safety net for small viewports and the 0×0
 *                        initial-mount flicker case.
 *   - `containerHeight * viewportRatio` — a proportion of the visible
 *                        area. Adapts to monitor size: half a screen on
 *                        a 600 px laptop viewport, half a screen on a
 *                        1200 px monitor.
 *
 * Taking `max(floor, proportional)` lets the component say "load at
 * least 200 px from the edge, but also load when the user is half a
 * screen away" — both at once, with one prop controlling the
 * proportional bit and the other keeping a sane minimum.
 *
 * Pure function (no DOM, no Vue) so the threshold math is unit-testable
 * and reusable by other scrollers.
 *
 * @param absoluteFloor    Minimum threshold in px. Default sentinel: 200.
 * @param viewportRatio    Proportion of `containerHeight`. Use 0 to opt
 *                         out of the proportional mode (floor only).
 * @param containerHeight  Current container height in px. The caller
 *                         passes the live value (e.g.
 * `containerRef.value.clientHeight` or the scroller's cached
 * `containerHeight` ref) so this stays reactive without re-mounting.
 * @returns Effective threshold in px, always a finite, positive number.
 */
export function computeLoadMoreThreshold(
  absoluteFloor: number,
  viewportRatio: number,
  containerHeight: number,
): number {
  const safeFloor = Number.isFinite(absoluteFloor) ? absoluteFloor : 200
  if (!Number.isFinite(viewportRatio) || viewportRatio <= 0) {
    return safeFloor
  }
  if (!Number.isFinite(containerHeight) || containerHeight <= 0) {
    return safeFloor
  }
  const proportional = containerHeight * viewportRatio
  return Math.max(safeFloor, proportional)
}
