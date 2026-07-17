/**
 * Static source-grep tests for LayersPanel.vue.
 *
 * The component renders the vertical list of elements on the active
 * page (ordered top-to-bottom by z-index) with per-row select /
 * up / down / delete buttons.
 *
 * Static contract:
 *  - Emits `select`, `reorder`, `delete`.
 *  - The reorder logic swaps adjacent elements in the sorted array
 *    and emits the new top-to-bottom order.
 *  - Each row has 4 data-testid selectors (row + 3 buttons).
 *  - Layers are sorted by z_index DESC, position ASC.
 */
import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const SOURCE_PATH = path.resolve(__dirname, '../components/design/LayersPanel.vue')
const source = fs.readFileSync(SOURCE_PATH, 'utf-8')

describe('LayersPanel.vue static contract', () => {
  it('emits select, reorder, delete', () => {
    expect(source).toContain("select:")
    expect(source).toContain("reorder:")
    expect(source).toContain("delete:")
  })

  it('declares elements, selectedElementId, and readonly props', () => {
    expect(source).toContain("elements:")
    expect(source).toContain("selectedElementId:")
    expect(source).toContain("readonly:")
  })

  it('sorts layers by z_index DESC then position ASC', () => {
    // The computed layers value drives the panel's top-to-bottom order.
    expect(source).toContain("z_index")
    expect(source).toContain("position")
    // b.z_index - a.z_index is descending sort
    expect(source).toMatch(/b\.z_index\s*-\s*a\.z_index/)
    // a.position - b.position is ascending sort
    expect(source).toMatch(/a\.position\s*-\s*b\.position/)
  })

  it('renders per-row and per-button data-testid selectors', () => {
    expect(source).toContain("design-layer-${element.id}")
    expect(source).toContain("design-layer-reorder-up-${element.id}")
    expect(source).toContain("design-layer-reorder-down-${element.id}")
    expect(source).toContain("design-layer-delete-${element.id}")
  })

  it('reorder emits the new ordered id list', () => {
    // handleMoveUp/Down emit the new top-to-bottom order so the parent
    // can re-order the elements array.
    expect(source).toContain("next.map((e) => e.id)")
  })

  it('has the design-panel data-testid', () => {
    expect(source).toContain("layers-panel")
  })

  it('renders an empty state when there are no elements', () => {
    expect(source).toContain("layers-panel-empty")
  })
})