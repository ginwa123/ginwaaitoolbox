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
  it('emits select, update, htmlChanged, delete', () => {
    expect(source).toContain("select:")
    expect(source).toContain("update:")
    expect(source).toContain("htmlChanged:")
    expect(source).toContain("delete:")
  })

  it('declares element, selected, and readonly props', () => {
    expect(source).toContain("element:")
    expect(source).toContain("selected:")
    expect(source).toContain("readonly:")
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
})