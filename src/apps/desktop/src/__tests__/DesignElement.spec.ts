/**
 * Static source-grep tests for DesignElement.vue.
 *
 * The component renders one design element on the canvas with
 * drag-to-move + resize handles + selection. Static contract:
 *  - The 8 resize handles (4 corners + 4 edges) are rendered when
 *    the element is selected.
 *  - The drag uses pointerdown/pointermove/pointerup + setPointerCapture.
 *  - The element has data-testid selectors for E2E tests.
 *  - Delete/Backspace keys emit delete (when selected and not readonly).
 */
import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const SOURCE_PATH = path.resolve(__dirname, '../components/design/DesignElement.vue')
const source = fs.readFileSync(SOURCE_PATH, 'utf-8')

describe('DesignElement.vue static contract', () => {
  it('emits select, update, groupDrag, dragEnd, htmlChanged, delete', () => {
    expect(source).toContain("select:")
    expect(source).toContain("update:")
    expect(source).toContain("groupDrag:")
    expect(source).toContain("dragEnd:")
    expect(source).toContain("htmlChanged:")
    expect(source).toContain("delete:")
  })

  it('declares element, selected, and readonly props', () => {
    expect(source).toContain("element:")
    expect(source).toContain("selected:")
    expect(source).toContain("readonly:")
  })

  // Chunk 2: multi-select (Figma-style). The parent DesignView owns
  // the selection Set and passes it down as `selectedIds` so the
  // wrapper renders the violet outline + resize handles for every
  // element in the set, not just the single `selected` one.
  it('declares selectedIds prop for multi-select (Chunk 2)', () => {
    expect(source).toContain("selectedIds:")
    expect(source).toContain("selectedIds: () => []")
  })

  it('uses pointerdown + setPointerCapture for drag', () => {
    // setPointerCapture is the trick that makes the drag survive a
    // fast mouse that outruns the handle.
    expect(source).toContain("setPointerCapture")
    expect(source).toContain("pointerdown")
    expect(source).toContain("pointermove")
    expect(source).toContain("pointerup")
  })

  it('renders the 4 corner resize handles with diagonal cursors', () => {
    // The corner handles use the diagonal resize cursors; the test
    // checks the standard CSS class names.
    expect(source).toContain("nw")
    expect(source).toContain("ne")
    expect(source).toContain("sw")
    expect(source).toContain("se")
    expect(source).toContain("cursor-nwse-resize")
    expect(source).toContain("cursor-nesw-resize")
  })

  it('renders the 4 edge resize handles', () => {
    expect(source).toContain("cursor-ns-resize")
    expect(source).toContain("cursor-ew-resize")
  })

  it('has per-element and per-handle data-testid selectors', () => {
    expect(source).toContain("design-element-${element.id}")
    expect(source).toContain("design-element-handle-${element.id}-${handle}")
  })

  it('Delete/Backspace on selected element emits delete', () => {
    // Keyboard shortcut for deletion (when the canvas has focus and
    // the user isn't typing in a form input).
    expect(source).toContain("Delete")
    expect(source).toContain("Backspace")
    expect(source).toContain("keydown")
  })

  // Regression test for the 2026-07-18 "design mode elements don't
  // show" bug: DesignElementPreview was imported but never rendered
  // in the template, so the canvas only showed faint placeholder
  // rectangles. The fix: render DesignElementPreview inside the
  // file_path placeholder div so the canvas shows the actual HTML
  // body (landing-bg, landing-nav, hero-left, etc.). Without this
  // contract, a future refactor could silently drop the iframe
  // rendering and the user would see only placeholders again.
  it('renders the DesignElementPreview iframe for elements with file_path', () => {
    expect(source).toContain('<DesignElementPreview')
    expect(source).toContain('v-if="element.file_path"')
    expect(source).toContain(':html="htmlBody"')
    // pointer-events is bound dynamically: 'none' in Edit mode (clicks
    // pass through to the wrapper for drag/resize/select) and 'auto' in
    // Preview mode (so the user can type into the iframe's inputs).
    // The `:pointer-events=` Vue binding handles both branches.
    expect(source).toContain(':pointer-events="previewMode ? \'auto\' : \'none\'"')
  })

  // Regression test for the 2026-07-18 bug: the element must fetch
  // its HTML body so the iframe has content to render. The fetch is
  // wired to onMounted + a watch on (id, file_path, updated_at) so
  // Monaco edits in the PropertiesPanel trigger a re-render.
  it('lazy-loads the element HTML body via getDesignElementHtml', () => {
    expect(source).toContain('getDesignElementHtml')
    expect(source).toContain('htmlBody')
    expect(source).toContain('onMounted')
    // The watch covers id (switching elements/pages), file_path (HTML
    // path changed) and updated_at (Monaco re-save without path change).
    expect(source).toContain('updated_at')
  })

  // The canvas-mode iframe must NOT capture pointer events — clicks
  // must fall through to the parent DesignElement so drag/resize/
  // select still work when the user clicks on top of the rendered
  // HTML content (e.g. the "Install →" button).
  it('declares workspaceId, itemId, pageId props for the HTML fetch', () => {
    expect(source).toContain('workspaceId:')
    expect(source).toContain('itemId:')
    expect(source).toContain('pageId:')
  })

  // The Preview/Edit mode toggle (canvas header bar) is plumbed
  // down as `previewMode`. When true:
  //   - startDrag short-circuits (no drag/resize/select)
  //   - the resize-handles and selection-outline are hidden
  //   - the iframe gets pointer-events: auto so the user can interact
  //     with the rendered HTML.
  it('declares previewMode prop and gates edit chrome on it', () => {
    expect(source).toContain('previewMode?: boolean')
    expect(source).toContain('previewMode: false')
    expect(source).toContain('if (props.previewMode) return') // startDrag guard
    // Selection chrome (outline + resize handles) hidden in Preview:
    expect(source).toContain('selected && !previewMode')
    // data-preview-mode attribute exposes the mode for E2E tests:
    expect(source).toContain(':data-preview-mode="previewMode"')
  })

  // Regression test for the 2026-07-26 "design mode is white" bug:
  // the plain-rectangle fallback div (which provides bg color +
  // dashed outline for legacy / failed loads) was rendered
  // UNCONDITIONALLY after the iframe wrapper in DOM order. With
  // both divs using `position: absolute; inset: 0` and no z-index,
  // the plain rectangle stacked ON TOP of the iframe and its
  // solid `backgroundColor: element.fill` (typically `#ffffff`)
  // completely covered the rendered chat / top-bar / input-area
  // HTML. The author had added `pointer-events-none` so clicks
  // passed through, but `pointer-events` only affects pointer
  // events — NOT visual rendering — so the bug was silent and
  // looked like "design mode is white".
  //
  // The fix: gate the plain rectangle on `!htmlBody && !isLoadingHtml`
  // so it only renders when there's NO iframe to cover (legacy
  // elements with no file_path, or HTML fetch failures). The
  // `!isLoadingHtml` half is required too — otherwise the
  // rectangle would cover the "loading…" text rendered inside
  // the iframe wrapper below it.
  it('hides the plain-rectangle fallback when iframe is rendering', () => {
    expect(source).toContain('v-if="!htmlBody && !isLoadingHtml"')
    // Sanity: the wrapper's bg-color style is still applied
    // unconditionally (it provides the bg color for the iframe
    // wrapper itself).
    expect(source).toContain("backgroundColor: element.fill || 'transparent'")
  })
})