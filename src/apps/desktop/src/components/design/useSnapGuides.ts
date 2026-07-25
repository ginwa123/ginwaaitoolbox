/**
 * Snap-to-edges math for design-mode drag.
 *
 * Algorithm:
 *   1. The dragged element's bbox at the cursor's current position.
 *   2. For every OTHER element on the page, compute the distance from
 *      each of the 3 edges/centers (left, center, right) of the dragged
 *      bbox to the matching edge/center of the target.
 *   3. The closest pair within 6 design-px wins. The dx/dy needed to
 *      align them is the snap delta.
 *   4. If the dragged element is the ONLY element on the page (no
 *      other targets nearby) AND no element snap fired, fall back to
 *      canvas-center snapping. The dragged element's center H is
 *      pulled toward the canvas center H. Canvas-center snap has a
 *      wider (effectively infinite) threshold than element-to-element
 *      — it's a soft preference, not a strict 6px window. Only fires
 *      when the dragged element is alone; otherwise element snap wins.
 *
 * Returns:
 *   - dx: design-px delta to ADD to the user's input dx
 *   - dy: same for y
 *   - guides: array of { axis, position } pairs to render as 1px lines
 *
 * Why a separate file: the math is pure (no DOM, no Vue) so it's
 * trivially testable in isolation. DesignView imports the function
 * and calls it on every pointermove.
 */

export interface Bbox { id: string; x: number; y: number; width: number; height: number }
export interface SnapGuide { axis: 'x' | 'y'; position: number }
export interface SnapResult {
  dx: number
  dy: number
  guides: SnapGuide[]
}

const SNAP_THRESHOLD = 6  // design-px for element-to-element snapping

export function computeSnapDelta(
  elements: Bbox[],
  draggedId: string,
  rawDx: number,
  rawDy: number,
  canvasSize: { width: number; height: number } | null = null,
): SnapResult {
  const dragged = elements.find((e) => e.id === draggedId)
  if (!dragged) return { dx: rawDx, dy: rawDy, guides: [] }

  // The dragged bbox at the cursor's current position.
  const movedX = dragged.x + rawDx
  const movedY = dragged.y + rawDy
  const movedRight = movedX + dragged.width
  const movedBottom = movedY + dragged.height
  const movedCx = movedX + dragged.width / 2
  const movedCy = movedY + dragged.height / 2

  // Targets: every OTHER element's matching edge/center.
  const otherElementEdgesX: number[] = []
  const otherElementEdgesY: number[] = []
  for (const e of elements) {
    if (e.id === draggedId) continue
    otherElementEdgesX.push(e.x, e.x + e.width, e.x + e.width / 2)
    otherElementEdgesY.push(e.y, e.y + e.height, e.y + e.height / 2)
  }
  // isAlone = true iff the dragged element is the ONLY element on
  // the page (no other targets nearby).
  const isAlone = otherElementEdgesX.length === 0
  // Snap-to-start targets: the original left, center, and right
  // edges of the dragged element. Within 6px of start, the cursor
  // gets pulled back to the original position (Figma UX). These are
  // a SECONDARY target — they only fire when no other-element snap
  // fires (priority: element-snap > snap-to-start > canvas-center).
  const snapToStartX: number[] = [
    dragged.x, dragged.x + dragged.width, dragged.x + dragged.width / 2,
  ]
  const snapToStartY: number[] = [
    dragged.y, dragged.y + dragged.height, dragged.y + dragged.height / 2,
  ]

  // Canvas-center fallback targets. The canvas center is a special
  // "magnetic" target — a single element with no other targets nearby
  // is pulled toward the canvas center. We only expose the canvas
  // CENTER (not the canvas edges) here because we want the soft
  // pull to be toward the center, not toward a random edge.
  const canvasCenterX = canvasSize ? canvasSize.width / 2 : null
  const canvasCenterY = canvasSize ? canvasSize.height / 2 : null

  const movedEdgesX = [movedX, movedRight, movedCx]
  const movedEdgesY = [movedY, movedBottom, movedCy]

  let bestSnapX: { dist: number; correction: number; position: number; isStart: boolean } | null = null
  let bestSnapY: { dist: number; correction: number; position: number; isStart: boolean } | null = null
  let elementSnapXFired = false
  let elementSnapYFired = false

  // Stage 1: element-to-element snap (6px threshold, strict).
  // Note the `dist > 0` guard: a snap fires only when the cursor is
  // APPROACHING the target (distance > 0). When the cursor is exactly
  // on the target (dist == 0), no correction is needed (the user
  // already landed there) and emitting a guide would be noise.
  for (const movedEdgeX of movedEdgesX) {
    for (const t of otherElementEdgesX) {
      const dist = Math.abs(movedEdgeX - t)
      if (dist > 0 && dist < SNAP_THRESHOLD) {
        if (!bestSnapX || dist < bestSnapX.dist) {
          bestSnapX = { dist, correction: t - movedEdgeX, position: t, isStart: false }
          elementSnapXFired = true
        }
      }
    }
  }
  for (const movedEdgeY of movedEdgesY) {
    for (const t of otherElementEdgesY) {
      const dist = Math.abs(movedEdgeY - t)
      if (dist > 0 && dist < SNAP_THRESHOLD) {
        if (!bestSnapY || dist < bestSnapY.dist) {
          bestSnapY = { dist, correction: t - movedEdgeY, position: t, isStart: false }
          elementSnapYFired = true
        }
      }
    }
  }

  // Stage 1.5: snap-to-start fallback. Only fires when no other-
  // element snap fired on that axis. The dragged element's original
  // edges are added as targets so a tiny drag (within 6px of start)
  // pulls the cursor back to the original position. Lower priority
  // than element-to-element snap so a real alignment opportunity
  // always wins. The `isStart` flag suppresses guide emission
  // (snapping back to start is silent — no alignment line drawn).
  if (!elementSnapXFired) {
    for (const movedEdgeX of movedEdgesX) {
      for (const t of snapToStartX) {
        const dist = Math.abs(movedEdgeX - t)
        if (dist > 0 && dist < SNAP_THRESHOLD) {
          if (!bestSnapX || dist < bestSnapX.dist) {
            bestSnapX = { dist, correction: t - movedEdgeX, position: t, isStart: true }
          }
        }
      }
    }
  }
  if (!elementSnapYFired) {
    for (const movedEdgeY of movedEdgesY) {
      for (const t of snapToStartY) {
        const dist = Math.abs(movedEdgeY - t)
        if (dist > 0 && dist < SNAP_THRESHOLD) {
          if (!bestSnapY || dist < bestSnapY.dist) {
            bestSnapY = { dist, correction: t - movedEdgeY, position: t, isStart: true }
          }
        }
      }
    }
  }

  // Stage 2: canvas-center fallback. Only fires when the dragged
  // element is the ONLY element on the page AND no element snap
  // fired. A lone element being dragged with no alignment partners
  // is pulled toward the canvas center (a Figma-like soft preference).
  // The correction is computed from the dragged element's center,
  // so the element's center H aligns with the canvas center H.
  if (isAlone && !elementSnapXFired && canvasCenterX !== null) {
    const correction = canvasCenterX - movedCx
    bestSnapX = { dist: 0, correction, position: canvasCenterX, isStart: false }
  }
  if (isAlone && !elementSnapYFired && canvasCenterY !== null) {
    const correction = canvasCenterY - movedCy
    bestSnapY = { dist: 0, correction, position: canvasCenterY, isStart: false }
  }

  const finalDx = rawDx + (bestSnapX?.correction ?? 0)
  const finalDy = rawDy + (bestSnapY?.correction ?? 0)
  const guides: SnapGuide[] = []
  // Emit guides for alignment snaps (element or canvas). Skip the
  // snap-to-start case — snapping back to the original position is
  // silent (no alignment line, just the cursor returning).
  if (bestSnapX && !bestSnapX.isStart) {
    guides.push({ axis: 'x', position: bestSnapX.position })
  }
  if (bestSnapY && !bestSnapY.isStart) {
    guides.push({ axis: 'y', position: bestSnapY.position })
  }

  return { dx: finalDx, dy: finalDy, guides }
}
