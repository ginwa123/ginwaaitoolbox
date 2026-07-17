/**
 * Static source-grep tests for AddDesignElementDialog.vue.
 *
 * The component is the modal for creating a new design element.
 * Renders type select + name input + initial HTML textarea, with
 * a Teleport to body and a Transition for the modal entry/exit.
 *
 * Static contract:
 *  - Teleport target is body.
 *  - Resets all state on every `show` flip (defensive — matches
 *    AddKanbanDialog's UX).
 *  - Has all 6 element types (rectangle/ellipse/text/image/frame/group).
 *  - Emits `create` with {name, type, html} and `close`.
 *  - Submit disabled when name is empty.
 */
import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const SOURCE_PATH = path.resolve(__dirname, '../components/design/AddDesignElementDialog.vue')
const source = fs.readFileSync(SOURCE_PATH, 'utf-8')

describe('AddDesignElementDialog.vue static contract', () => {
  it('emits create and close', () => {
    expect(source).toContain("create:")
    expect(source).toContain("close:")
  })

  it('declares show, pageId, readonly props', () => {
    expect(source).toContain("show:")
    expect(source).toContain("pageId:")
    expect(source).toContain("readonly:")
  })

  it('Teleports the dialog to body', () => {
    // The modal must escape any ancestor stacking contexts; the
    // Teleport target is the standard 'body' target.
    expect(source).toContain("<Teleport to=\"body\">")
  })

  it('resets all form state on every show flip', () => {
    // The watch on props.show is the canonical pattern for "fresh
    // dialog every time it's opened". Without this, the dialog
    // would carry stale data from the last open.
    expect(source).toMatch(/watch\(\(\)\s*=>\s*props\.show/)
  })

  it('renders all 6 element types in the type select', () => {
    expect(source).toContain("rectangle")
    expect(source).toContain("ellipse")
    expect(source).toContain("text")
    expect(source).toContain("image")
    expect(source).toContain("frame")
    expect(source).toContain("group")
  })

  it('has the type/name/html/submit/cancel data-testid selectors', () => {
    expect(source).toContain("add-design-element-type")
    expect(source).toContain("add-design-element-name")
    expect(source).toContain("add-design-element-html")
    expect(source).toContain("add-design-element-submit")
    expect(source).toContain("add-design-element-cancel")
  })

  it('the add-design-element-dialog testid is on the modal wrapper', () => {
    expect(source).toContain("add-design-element-dialog")
  })
})