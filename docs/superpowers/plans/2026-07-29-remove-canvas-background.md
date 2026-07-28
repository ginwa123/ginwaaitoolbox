# Remove the Canvas Background Feature

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the canvas background — both the **visible page rectangle** in the design canvas and the **implicit boundary concept** that supposedly constrains elements. Today the canvas shows a `1440 × 1024` rectangle and the drag / arrow-key handlers clamp elements to a 10-px sliver inside it — but the user can also type `y = 1098` into PropertiesPanel or call the LLM tool with arbitrary x/y, so the constraint is **leaky and inconsistent**. Pages become purely logical containers (like Figma's pages); elements can be placed anywhere. No more "the canvas told me this is the page area".

**Architecture:** Pure removal — undo the canvas-as-boundary feature end-to-end. The `<div data-testid="design-canvas">` rectangle goes transparent + auto-grow. The W × H header inputs go away. The drag-clamp + nudge-clamp + canvas-snap-target all vanish. `design_pages.width` / `height` columns stay in the DB for legacy data + the `set_design_page` LLM tool (which still lets the LLM set a "preferred design size" if it wants), but they're no longer consumed as a constraint or rendered as a rectangle. The LLM system prompt no longer tells the agent "elements must stay within W × H".

**Tech Stack:** Zig 0.16 (backend, NO changes — only frontend + tests), Vue 3 + TypeScript + Pinia (frontend), SQLite (NO schema changes). Cross-platform support: Linux + macOS + Windows.

---

## Global Constraints

- Existing cross-platform + Zig 0.16 + Vue 3 constraints from `AGENTS.md` apply unchanged.
- **Every feature must work on Linux, macOS, AND Windows.** This is a hard requirement.
- **Do NOT kill the process on port 8081** (the always-running nalar). Use 8080 for any local smoke tests.
- Use `git worktree` for parallel development. This plan targets `worktree/remove-canvas-background`.
- NO Zig changes — this is a frontend-only plan. The previous plan (`2026-07-29-constrain-design-elements-to-canvas.md`) was never landed; nothing to revert.
- The pre-commit checklist from `AGENTS.md` must pass before declaring done: `zig build test --summary all` (regression safety), `zig build install:linux:system`, `rm -rf zig-out/bin && zig build`, cross-compile to Windows/macOS, `bun run build` (vue-tsc), `bunx vitest run`.

---

## Design Background (read first)

### Why the canvas background should go

The "canvas background" feature has TWO parts that have both become confusing:

1. **Visual rectangle.** A `<div data-testid="design-canvas">` with fixed `width: ${canvasWidth}px; height: ${canvasHeight}px` styled as a card with `box-shadow` and a faint checker pattern. It's the "page area" the user sees when designing.

2. **Implicit constraint.** The drag handler clamps the moving element to a 10-px sliver of the rectangle (`DesignView.vue` lines 1027-1041). The arrow-key nudge does the same (lines 559-568). `computeSnapDelta` uses the canvas dims as snap targets (Figma-style snap-to-canvas-edges fallback).

The problem: only the FRONTEND respects the constraint. The PropertiesPanel X/Y input emits whatever the user types (no clamp). The REST endpoints (`PATCH /geometry`, `PUT /elements/:id`, `POST /elements`, `POST /elements/group`) write whatever x/y is in the body — no clamp. The LLM tools call the same REST endpoints — no clamp. So users **see** a 1440×1024 page boundary but can put elements wherever they want, and the visual + constraint lie about what's possible.

The user looked at this and reasonably concluded: "the canvas background is more confusing than useful — I don't want to see a rectangle that elements can stick out of."

### What goes away

| Surface | Today | After this plan |
|---|---|---|
| Visible page rectangle (`<div data-testid="design-canvas">`) | Fixed `width × height` matching page dims, styled as a card with box-shadow | Auto-grow container; no fixed dims; transparent background |
| Canvas header W × H inputs (`design-page-width-input`, `design-page-height-input`) | Two `<input type="number">` fields | **Removed entirely** |
| Drag clamp in `applyGroupDragDelta` (lines 1027-1041) | 10-px sliver rule prevents drag-past-canvas | **Removed** — elements can be dragged anywhere |
| Nudge clamp in `handleKeydown` (lines 559-568) | 10-px sliver rule for arrow keys | **Removed** — arrow keys move freely |
| `computeSnapDelta({width, height})` canvas-edge snap targets | Falls back to canvas center / canvas edges when no nearby elements | **Removed** — snap-to-canvas-edges gone; only snap-to-other-elements |
| Zoom-Fit (`zoomFit`) | Computes scale from `canvasWidth × canvasHeight` | **Fit-to-elements**: computes scale from union bbox of all elements + padding |
| LLM system prompt (in `BuildDesignCanvasPrompt`) | Mentions page bounds as a constraint | **Removed** — no fixed page bounds |

### What stays

| Surface | Why |
|---|---|
| `design_pages.width` + `design_pages.height` columns | Legacy data. Existing rows have values; existing `setDesignPage` + `updateDesignPage` still accept them with range validation. The columns just become unused-by-frontend. |
| `setDesignPage` + `updateDesignPage` REST endpoints + LLM tools | Keep the API surface for backward compat. Users who want to set a "preferred export size" can still call them. |
| `DesignPage.width` + `DesignPage.height` in wire format | Backward compat. Frontend ignores them. |
| `PropertiesPanel` element `width` / `height` fields | These are ELEMENT dimensions, not page dimensions. The user complained about page constraint, not element size. Element size is a per-element property that has nothing to do with the canvas. |
| Page model itself (`design_pages` table, `PageWithElements`, etc.) | Pages are still useful as logical groupings / tabs. |
| Snap-to-other-elements | Still works (no canvas edges needed). |

### Why this isn't a "make the constraint work" plan

I (the planner) initially wrote `2026-07-29-constrain-design-elements-to-canvas.md` to FIX the leak by adding backend clamps + PropertiesPanel clamps + store clamps. The user reviewed it and clarified: "I think we DON'T need the canvas background". They want the **concept removed**, not enforced. This plan supersedes the previous one (delete it).

Removing the feature is also the **smaller, simpler, less-risky** path:
- No schema changes
- No backend changes (Zig untouched)
- No new helpers to test
- No "what about legacy off-canvas elements?" decision (irrelevant)
- The user already wants this direction; the previous plan would have shipped work they'd immediately ask to undo

---

## File Structure

| File | Action | Notes |
|---|---|---|
| `src/apps/desktop/src/components/design/DesignView.vue` | EDIT | Remove drag clamp (lines 1027-1041), nudge clamp (lines 559-568), visible canvas rectangle (lines 1556-1571), W × H header inputs (lines 1448-1479), `handlePageSizeChange` + related state. Update zoom-fit to use union bbox. Drop `canvasWidth`/`canvasHeight` computed properties. |
| `src/apps/desktop/src/components/design/useSnapGuides.ts` | EDIT | `computeSnapDelta` no longer takes `{width, height}` — drop the canvas-edge snap targets. Call site in `DesignView.vue` updated. |
| `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` | EDIT | `BuildDesignCanvasPrompt` no longer tells the LLM "elements must stay within page bounds" (or similar). |
| `src/apps/desktop/src/__tests__/DesignView.canvasBounds.spec.ts` | NEW | Static-contract tests confirming the clamps + W × H inputs are gone. |
| `src/apps/desktop/src/__tests__/DesignView.zoomFit.spec.ts` | NEW | Behavioral test for the new zoom-fit (fits to union bbox, not page dims). |
| `src/apps/desktop/src/components/design/__tests__/DesignView.snap.spec.ts` | EDIT | Remove the canvas-edge snap test cases; keep the element-to-element snap cases. |
| `src/apps/desktop/src/__tests__/workspacesStore.design.spec.ts` | EDIT | If any tests referenced `canvasWidth`/`canvasHeight` via the store, drop those assertions. |
| `docs/SPEC.md` | EDIT | Update §3.8 row for this plan; mark the drag-and-drop plan as "✅" only for the drag-wire + multi-select + snap + nudge parts (drop "constrain" from the description). |
| `docs/superpowers/plans/2026-07-29-constrain-design-elements-to-canvas.md` | REMOVE | Superseded by this plan. |
| `src/apps/desktop/src/components/design/__tests__/DesignView.nudgeAndDrag.spec.ts` | NEW | Behavioral test confirming drag + arrow-key nudge now move freely (no clamp). |

---

## Implementation Tasks

### Task 0 — Delete the superseded plan

```bash
rm /home/ginwa/ginwaaitoolbox/docs/superpowers/plans/2026-07-29-constrain-design-elements-to-canvas.md
```

- [ ] Delete the previous plan file.

### Task 1 — Remove drag clamp in `applyGroupDragDelta`

In `src/apps/desktop/src/components/design/DesignView.vue` (around lines 990-1056), the `clampX` / `clampY` helpers clamp each selected element to the canvas with the 10-px sliver rule. Remove them and pass `delta.dx` / `delta.dy` straight through:

```ts
// BEFORE (lines 1030-1041):
const clampX = (el: typeof selected[number], dx: number): number => {
  const newX = el.x + dx
  if (newX < -el.width + 10) return -el.width + 10 - el.x
  if (newX > canvasWidth.value - 10) return canvasWidth.value - 10 - el.x
  return dx
}
const clampY = (el: typeof selected[number], dy: number): number => {
  const newY = el.y + dy
  if (newY < -el.height + 10) return -el.height + 10 - el.y
  if (newY > canvasHeight.value - 10) return canvasHeight.value - 10 - el.y
  return dy
}
for (const el of selected) {
  const clampedDx = clampX(el, finalDx)
  const clampedDy = clampY(el, finalDy)
  void workspacesStore.updateDesignElementGeometry(...)
}

// AFTER:
for (const el of selected) {
  void workspacesStore.updateDesignElementGeometry(
    workspaceId, itemId, pageId, el.id,
    { x: Math.round(el.x + finalDx), y: Math.round(el.y + finalDy) },
  )
}
```

- [ ] Remove `clampX` + `clampY`.
- [ ] Update the loop body to pass `finalDx` / `finalDy` directly (no clamping).

### Task 2 — Remove nudge clamp in `handleKeydown`

In `DesignView.vue::handleKeydown` (around lines 540-580), the arrow-key branch has 4 clamp lines:

```ts
// BEFORE (lines 563-568):
let ndx = dx
let ndy = dy
if (baseX + ndx < -el.width + 10) ndx = -el.width + 10 - baseX
if (baseX + ndx > canvasWidth.value - 10) ndx = canvasWidth.value - 10 - baseX
if (baseY + ndy < -el.height + 10) ndy = -el.height + 10 - baseY
if (baseY + ndy > canvasHeight.value - 10) ndy = canvasHeight.value - 10 - baseY
const newX = baseX + ndx
const newY = baseY + ndy

// AFTER:
const newX = baseX + dx
const newY = baseY + dy
```

- [ ] Remove the 4 clamp lines.
- [ ] Use `dx` / `dy` directly (no clamp).

### Task 3 — Remove the visible canvas rectangle

In `DesignView.vue` template (around lines 1556-1571), the `<div data-testid="design-canvas">` has fixed `width` + `height` + `backgroundColor` + `boxShadow` + `backgroundImage`. Replace with an auto-grow container that has no fixed dimensions and a transparent background:

```vue
<!-- BEFORE (lines 1556-1571): -->
<div
  class="relative mx-auto my-6 origin-top-left"
  :style="{
    width: `${canvasWidth}px`,
    height: `${canvasHeight}px`,
    transform: `scale(${zoom})`,
    backgroundColor: 'var(--semantic-card-bg)',
    boxShadow: '0 4px 20px rgba(0, 0, 0, 0.3)',
    backgroundImage: '...checkerboard...',
    backgroundSize: '20px 20px',
    backgroundPosition: '0 0, 10px 10px',
  }"
  data-testid="design-canvas"
  @click.stop
>

<!-- AFTER: -->
<div
  class="relative mx-auto my-6 origin-top-left"
  :style="{ transform: `scale(${zoom})` }"
  data-testid="design-canvas"
  @click.stop
>
```

The container's actual size is now determined by its children (auto-grow). If there are no elements, the container is empty (or has a min-height for the empty-state hint). The scroll container around it (`.overflow-auto` parent) handles scrolling.

- [ ] Remove `width` / `height` / `backgroundColor` / `boxShadow` / `backgroundImage` / `backgroundSize` / `backgroundPosition` from the canvas div's inline style.
- [ ] Keep `transform: scale(${zoom})` — zoom math still uses `zoom` (now fits-to-elements instead of fits-to-canvas; see Task 6).

### Task 4 — Remove W × H header inputs

In `DesignView.vue` template (around lines 1448-1479), the entire `<div data-testid="design-page-size">` block with the two number inputs is gone:

```vue
<!-- DELETE the entire block: -->
<div
  v-if="activePage && !isPreviewMode"
  class="flex items-center gap-1 text-xs shrink-0"
  style="color: var(--semantic-text-dim);"
  data-testid="design-page-size"
>
  <input type="number" ... data-testid="design-page-width-input" ... />
  <span aria-hidden="true">×</span>
  <input type="number" ... data-testid="design-page-height-input" ... />
</div>
```

The `<span aria-hidden="true">×</span>` separator also goes.

- [ ] Delete the `data-testid="design-page-size"` div block from the canvas header.

### Task 5 — Remove `handlePageSizeChange` + related state

In `DesignView.vue` script:

1. Delete `handlePageSizeChange` function (around line 1228-1300 in the file — it's the function bound to `@change="handlePageSizeChange"` on the inputs).
2. Delete the `widthInput` + `heightInput` querySelectors (around line 1258-1262).
3. Delete `pageWidthInput` + `pageHeightInput` computed properties (around lines 1235-1240).

These are now unreferenced.

- [ ] Delete `handlePageSizeChange` function.
- [ ] Delete `widthInput` + `heightInput` refs.
- [ ] Delete `pageWidthInput` + `pageHeightInput` computed properties.

### Task 6 — Update `zoomFit` to use union bbox of elements

In `DesignView.vue::zoomFit` (around lines 1158-1200), it currently reads `canvasWidth` + `canvasHeight` to compute the scale that fits the canvas into the scroll container. Replace with a function that fits the union bbox of all elements + padding.

```ts
// BEFORE (lines 1158-1200, paraphrased):
const zoomFit = () => {
  const el = document.querySelector('[data-testid="design-canvas-scroll-container"]') as HTMLElement | null
  if (!el) return
  const cw = el.clientWidth - ZOOM_FIT_MARGIN * 2
  const ch = el.clientHeight - ZOOM_FIT_MARGIN * 2
  const zoomX = cw / canvasWidth.value
  const zoomY = ch / canvasHeight.value
  zoom.value = Math.min(zoomX, zoomY, 1)
  // ... rest of centering logic
}

// AFTER:
const zoomFit = () => {
  const el = document.querySelector('[data-testid="design-canvas-scroll-container"]') as HTMLElement | null
  if (!el) return
  const cw = el.clientWidth - ZOOM_FIT_MARGIN * 2
  const ch = el.clientHeight - ZOOM_FIT_MARGIN * 2

  // Union bbox of all elements. If no elements, fit a 1440×1024
  // default (matches the legacy canvas default size; user sees the
  // same starting view they had before).
  let minX = 0, minY = 0, maxX = 1440, maxY = 1024
  if (elements.value.length > 0) {
    minX = Math.min(...elements.value.map((e) => e.x))
    minY = Math.min(...elements.value.map((e) => e.y))
    maxX = Math.max(...elements.value.map((e) => e.x + e.width))
    maxY = Math.max(...elements.value.map((e) => e.y + e.height))
  }
  const contentW = maxX - minX
  const contentH = maxY - minY
  const zoomX = cw / contentW
  const zoomY = ch / contentH
  zoom.value = Math.min(zoomX, zoomY, 1)
  // ... rest of centering math, updated to use minX/minY/contentW/contentH
}
```

The centering logic (`scrollLeft`/`scrollTop` math) also needs to use `minX`/`minY` instead of 0/0 (so the scroll position lands on the elements, not the page origin). Review the rest of `zoomFit` carefully.

- [ ] Rewrite `zoomFit` to compute scale from union bbox of `elements.value`.
- [ ] Update scrollLeft / scrollTop math to center on `(minX, minY)` + content center.

### Task 7 — Drop `canvasWidth` + `canvasHeight` computed properties

In `DesignView.vue` script (around lines 1104-1105):

```ts
// DELETE these two lines:
const canvasWidth = computed(() => activePage.value?.width ?? 1440)
const canvasHeight = computed(() => activePage.value?.height ?? 1024)
```

After all the removals above, these refs are unreferenced.

- [ ] Delete `canvasWidth` + `canvasHeight` computed properties.

### Task 8 — Update `computeSnapDelta` to drop canvas-edge snap targets

In `src/apps/desktop/src/components/design/useSnapGuides.ts`:

```ts
// BEFORE (signature line 39):
export function computeSnapDelta(
  elements: DesignElementApi[],
  movingId: string,
  dx: number,
  dy: number,
  canvasBounds?: { width: number; height: number },  // ← used for canvas-edge fallback
): { dx: number; dy: number; guides: SnapGuide[] }

// AFTER:
export function computeSnapDelta(
  elements: DesignElementApi[],
  movingId: string,
  dx: number,
  dy: number,
): { dx: number; dy: number; guides: SnapGuide[] }
```

Drop the canvas-edge fallback logic inside the function body (the `if (others.length === 0)` branch that snaps to canvas center / canvas edges). Now if no other elements are nearby, the function returns `{ dx: 0, dy: 0, guides: [] }` — no snap, no guides.

Update the call site in `DesignView.vue::applyGroupDragDelta` (around line 1017-1023):

```ts
// BEFORE:
const snapResult = computeSnapDelta(
  [unionBbox, ...others],
  '__union__',
  0,
  0,
  { width: canvasWidth.value, height: canvasHeight.value },
)

// AFTER:
const snapResult = computeSnapDelta(
  [unionBbox, ...others],
  '__union__',
  0,
  0,
)
```

- [ ] Update `computeSnapDelta` signature (drop `canvasBounds`).
- [ ] Drop canvas-edge snap logic from the function body.
- [ ] Update the call site in `DesignView.vue`.

### Task 9 — Update LLM system prompt

In `src/ai_workflow/tui/build_messages_for_agent_prompt.zig::BuildDesignCanvasPrompt`:

1. Remove any sentence that says "elements must stay within page bounds" or "the page is `width × height` and elements are clipped to it".
2. Replace with: "Each design page is a logical container; elements can be placed at any coordinates (positive, negative, or large values). No fixed page bounds — the canvas is the design viewport, not a constraint."

- [ ] Update `BuildDesignCanvasPrompt` to remove the page-bound constraint language.

### Task 10 — Tests

#### Task 10a — `DesignView.canvasBounds.spec.ts` (NEW — static-contract regression tests)

Create `src/apps/desktop/src/__tests__/DesignView.canvasBounds.spec.ts`:

```ts
import { readFileSync } from 'fs'
import { join } from 'path'

const DESIGN_VIEW_PATH = join(
  __dirname, '..', 'src', 'components', 'design', 'DesignView.vue',
)

describe('DesignView removes the canvas-background feature', () => {
  const source = readFileSync(DESIGN_VIEW_PATH, 'utf8')

  test('does NOT declare canvasWidth / canvasHeight computed properties', () => {
    expect(source).not.toMatch(/const canvasWidth\s*=/)
    expect(source).not.toMatch(/const canvasHeight\s*=/)
  })

  test('does NOT clamp the drag in applyGroupDragDelta', () => {
    // The clamp helpers are GONE — drag passes delta straight through.
    expect(source).not.toMatch(/clampX\s*\(/)
    expect(source).not.toMatch(/clampY\s*\(/)
  })

  test('does NOT clamp the arrow-key nudge', () => {
    // The 4 clamp lines (canvasWidth - 10 / canvasHeight - 10)
    // are GONE.
    expect(source).not.toMatch(/canvasWidth\.value\s*-\s*10/)
    expect(source).not.toMatch(/canvasHeight\.value\s*-\s*10/)
  })

  test('does NOT render the W × H header inputs', () => {
    expect(source).not.toContain('data-testid="design-page-size"')
    expect(source).not.toContain('design-page-width-input')
    expect(source).not.toContain('design-page-height-input')
  })

  test('does NOT pass canvasBounds to computeSnapDelta', () => {
    expect(source).not.toMatch(/canvasBounds:.*canvasWidth/)
    expect(source).not.toMatch(/width:\s*canvasWidth\.value/)
  })

  test('canvas div has NO fixed width / height / boxShadow / backgroundColor', () => {
    // The old inline style block on <div data-testid="design-canvas">
    // had width: ${canvasWidth}px, height: ${canvasHeight}px,
    // backgroundColor: 'var(--semantic-card-bg)', boxShadow: '0 4px ...'.
    // None of those should remain.
    expect(source).not.toMatch(/width:\s*`\$\{canvasWidth\}/)
    expect(source).not.toMatch(/height:\s*`\$\{canvasHeight\}/)
    expect(source).not.toMatch(/backgroundColor:\s*'var\(--semantic-card-bg\)'/)
    expect(source).not.toMatch(/boxShadow:\s*'0 4px/)
  })
})
```

- [ ] Create the static-contract regression test file.

#### Task 10b — `DesignView.nudgeAndDrag.spec.ts` (NEW — behavioral)

Create `src/apps/desktop/src/__tests__/DesignView.nudgeAndDrag.spec.ts`:

This test mounts `DesignView`, simulates a drag of an element past the (now-gone) canvas bounds, and asserts the element's x/y in the store equals the unbounded value. (Uses `mount` + a Pinia store stub + fakeApi — pattern from existing tests in `src/__tests__/`.)

Sketch:
```ts
test('drag moves element freely past any prior canvas bounds', async () => {
  // Mount DesignView with an element at (100, 100) on a "page" that
  // used to be 200×200. Drag the element to (5000, 5000). Assert the
  // store receives x=5000, y=5000 — no clamp.
})

test('arrow-key nudge moves element freely', async () => {
  // Press ArrowRight 100 times. Element at (0, 0) becomes (100, 0).
  // No clamp.
})
```

(Full implementation follows the existing test patterns; the key assertion is "the move is unbounded".)

- [ ] Create the behavioral test file.

#### Task 10c — `DesignView.zoomFit.spec.ts` (NEW — behavioral)

```ts
test('zoomFit uses union bbox of elements, not page dimensions', async () => {
  // Mount DesignView with two elements: at (0,0,100,100) and (2000,2000,50,50).
  // Trigger zoomFit. Assert the resulting zoom + scroll position is
  // consistent with fitting the union bbox (minX=0, minY=0, maxX=2050,
  // maxY=2050), NOT with fitting a fixed 1440×1024 canvas.
})
```

- [ ] Create the zoom-fit behavioral test.

#### Task 10d — Update `DesignView.snap.spec.ts`

The existing test file has cases that pass `{ width: 1440, height: 1024 }` as `canvasBounds`. Remove those cases (the function no longer takes that arg). Keep cases that test snap-to-element-edges.

- [ ] Remove the `canvasBounds` test cases from `DesignView.snap.spec.ts`.

#### Task 10e — Update `workspacesStore.design.spec.ts`

If any test references `canvasWidth` / `canvasHeight` (they shouldn't — they're component-local), remove those assertions. Search:

```bash
grep -n "canvasWidth\|canvasHeight" src/__tests__/workspacesStore.design.spec.ts
```

- [ ] Remove any canvasWidth / canvasHeight references in `workspacesStore.design.spec.ts`.

### Task 11 — End-to-end smoke verification

Smoke against port 8080 (NOT 8081):

```bash
# Start isolated server.
rm -rf /tmp/nalar-rmbg-smoke && mkdir -p /tmp/nalar-rmbg-smoke
env -i HOME=/tmp/nalar-rmbg-smoke PATH=$PATH \
  nohup /home/ginwa/.../zig-out/bin/nalarcore-linux-x86_64 --port 8080 \
  >/tmp/nalar-rmbg-smoke.log 2>&1 &
disown
sleep 4

# Create workspace + design item + page.
WS=$(curl ... POST /api/workspaces -d '{"name":"rmbg"}' | jq -r .id)
ITEM=$(curl ... POST /api/workspaces/$WS/items/design -d '{"name":"no canvas","path":"/tmp"}' | jq -r .id)
PAGE=$(curl ... POST /api/workspaces/$WS/items/$ITEM/design/pages -d '{"name":"home"}' | jq -r .id)

# 1. Create an element at (10000, 10000). Backend doesn't clamp —
#    should persist as-is. (This is now EXPECTED, not a bug.)
ELEM=$(curl ... POST /api/workspaces/$WS/items/$ITEM/design/pages/$PAGE/elements \
  -d '{"name":"far","type":"rectangle","html":"<div></div>","x":10000,"y":10000,"width":50,"height":50}' \
  | jq -r .id)
# 2. Re-fetch the element. Assert x=10000, y=10000.
curl ... GET /api/workspaces/$WS/items/$ITEM/design/pages/$PAGE | jq '.elements[0].x,.elements[0].y'
# Expect: 10000, 10000 (NOT clamped).

# 3. Verify the W × H fields are still in the API response (legacy
#    fields, informational only — frontend ignores them).
curl ... GET ... | jq '.width,.height'
# Expect: 1440, 1024 (the page's default size; still present).

# 4. Frontend: open the design canvas in the desktop app. Verify:
#    - NO visible rectangle around the page.
#    - NO W × H inputs in the canvas header.
#    - Drag the element to (-1000, -1000) — it moves freely.
#    - Zoom-Fit fits to the element's position, not a 1440×1024 box.

# Cleanup
SMOKE_PID=$(ps aux | grep nalarcore-linux-x86_64 | grep -v grep | awk '{print $2}')
[ -n "$SMOKE_PID" ] && kill $SMOKE_PID
```

- [ ] Run the smoke recipe.
- [ ] All 4 scenarios pass.

### Task 12 — Update SPEC.md

Append a row to `docs/SPEC.md` §3.8 (Frontend — Design Canvas):

```markdown
| `2026-07-29-remove-canvas-background.md` | ✅ | Canvas background removed (no visible page rectangle, no enforced boundary, no W × H header inputs). Pages are purely logical containers; elements can be placed anywhere. Drag + arrow-key nudge + zoom-fit updated accordingly. |
```

Also update the prior row's description:

```markdown
// BEFORE:
| `2026-07-25-design-element-drag-and-drop.md` | ✅ | Drag-wire + multi-select + snap + nudge + constrain (#125) |

// AFTER:
| `2026-07-25-design-element-drag-and-drop.md` | ✅ | Drag-wire + multi-select + snap + nudge (#125) |
```

(Drop "constrain" — that part was the 10-px sliver rule, now removed.)

- [ ] Update SPEC.md §3.8 (new row + edit existing row).

---

## Pitfalls

- **Don't keep `width` / `height` as PropertiesPanel ELEMENT fields.** Those are per-element dimensions (the element's own size), not page dimensions. The user complained about page constraint, not element size. PropertiesPanel keeps the element's `width` + `height` inputs unchanged.
- **Don't remove the snap-to-other-elements feature.** Snap-to-other-elements stays (the user finds it useful). Only snap-to-canvas-edges goes.
- **Don't remove the empty-state hint ("drop elements here").** It's inside the canvas div but uses `absolute inset-0 flex items-center justify-center` — doesn't depend on fixed canvas dims. Keeps working.
- **`DesignElement.vue` is independent.** It doesn't know about canvas dims. Its drag handler emits `update` with raw dx/dy. The PARENT (DesignView) used to clamp on receive. Now the parent doesn't clamp — but DesignElement.vue doesn't need to change.
- **The LLM tools `add_element` / `update_element` / `group_elements` still work.** They call the same backend handlers, which don't clamp (and never did). The LLM was getting mixed signals before ("you can put elements anywhere, but the page is 1440×1024"). Now the LLM gets clear messaging: "no fixed page bounds; elements can be placed anywhere".
- **Page dimensions stay in the DB.** Don't remove the columns or the migration. `setDesignPage` + `updateDesignPage` still accept W × H. They're just informational / not used by the frontend.
- **Snap guides inside `<svg>` (lines 1603-1631).** The SVG was sized to `canvasWidth × canvasHeight`. Now it's just an overlay inside the auto-grow canvas div. Update the SVG to size to the actual content (use `viewBox` or measure via ref). Simplest fix: make the SVG `width="100%"` + `height="100%"` of its container, with `overflow="visible"`.
- **Snap guides + zoom.** The SVG also draws `:x2="canvasHeight"` etc. for vertical guide lines. After removing canvas dims, those refs are gone — update to use `100%` of the SVG's intrinsic size (which now matches the canvas div's intrinsic size).
- **Snap guide test that uses `'canvasBounds'` in `useSnapGuides.ts`.** After dropping the arg, the test that passes canvas bounds needs the arg removed. The function's behavior on "no canvas bounds" should be: snap-to-element-edges only, no canvas fallback. The 1 canvas-center + 4 canvas-edge guides are GONE.

---

## Verification

After all tasks complete, the pre-commit checklist from `AGENTS.md`:

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all
# Expect: same pass count as before this plan (no Zig changes; any
# delta = a regression somewhere).

timeout 200 zig build install:linux:system
# Binary builds.

rm -rf zig-out/bin
timeout 240 zig build

# Cross-compile smoke (catches Windows/macOS-only compile errors):
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# Both must exit 0.

# Frontend (this plan's actual work):
cd src/apps/desktop
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build
# Expect: 0 errors. CRITICAL — vue-tsc catches the prop / ref
# type errors that bunx vitest misses.

timeout 180 bunx vitest run
# Expect: all tests pass (existing + 13 new from this plan).

timeout 180 bun run build
# Expect: vue-tsc + vite clean.
```

End-to-end smoke (Task 11) on port 8080 must pass all 4 scenarios.

---

## Reference

- Bug source: user's intent — "remove canvas background feature, I think we DON'T need the canvas background" (clarification in second message).
- Supersedes: `docs/superpowers/plans/2026-07-29-constrain-design-elements-to-canvas.md` (the plan I wrote first, which would have FIXED the constraint — wrong direction; delete it).
- Existing drag clamp: `src/apps/desktop/src/components/design/DesignView.vue` lines 559-568 (nudge) and 1027-1041 (drag).
- Existing canvas div: `src/apps/desktop/src/components/design/DesignView.vue` lines 1556-1571.
- Existing W × H header inputs: `src/apps/desktop/src/components/design/DesignView.vue` lines 1448-1479.
- Existing snap-to-canvas-edges: `src/apps/desktop/src/components/design/useSnapGuides.ts::computeSnapDelta` + call site at `DesignView.vue:1017-1023`.
- LLM system prompt: `src/ai_workflow/tui/build_messages_for_agent_prompt.zig::BuildDesignCanvasPrompt`.
- Page model: `src/ai_workflow/tui/design_model.zig` — `design_pages.width` + `height` columns + `setDesignPage` + `updateDesignPage` STAY (legacy fields, unchanged).
- Plan format precedent: `docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md` (style template).