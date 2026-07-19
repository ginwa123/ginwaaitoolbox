/**
 * Static source-grep tests for LayersPanel.vue.
 *
 * The component renders a tree of elements on the active page (depth-
 * first walk of the parent_id adjacency map). Each row exposes select /
 * up / down / delete buttons, plus a chevron toggle for parents with
 * children.
 *
 * Static contract (verified by reading the source):
 *  - Emits `select`, `reorder`, `delete`.
 *  - Builds the tree from `parent_id` adjacency; renders children
 *    indented under their parent (`depth * 16px`).
 *  - Each row has `design-layer-${id}`, `design-layer-toggle-${id}`,
 *    `design-layer-reorder-up-${id}`, `design-layer-reorder-down-${id}`,
 *    and `design-layer-delete-${id}` `data-testid`s.
 *  - Children within a level are sorted by z_index DESC, position ASC.
 *  - Reorder emits the new top-to-bottom order (the parent applies it
 *    to the elements array). Children of a parent are contiguous in
 *    the flattened tree, so up/down swap siblings within a parent —
 *    they cannot cross parent boundaries via the buttons.
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

  it('reads parent_id to build a tree (not a flat list)', () => {
    // The `tree` computed should walk the parent_id adjacency; the
    // chevron column should only appear for rows that have children.
    expect(source).toContain('parent_id')
    expect(source).toContain('childMap')
    expect(source).toContain('hasChildren')
  })

  it('renders depth-based indentation (rows indent by parent depth)', () => {
    // `paddingLeft` is computed from `row.depth * INDENT_PX_PER_DEPTH`,
    // which the test grep below asserts via two substrings.
    expect(source).toContain('row.depth')
    expect(source).toContain('INDENT_PX_PER_DEPTH')
    // The numeric multiplier — 16 in the implementation; the symbol
    // matters more than the value (any positive indentation works).
    expect(source).toContain('* INDENT_PX_PER_DEPTH')
  })

  it('renders an expand/collapse chevron for parents with children', () => {
    expect(source).toContain('toggleParent')
    expect(source).toContain('design-layer-toggle-')
    expect(source).toContain('aria-expanded')
    // The collapsed glyph is right-pointing triangle ▶, expanded is ▼.
    expect(source).toContain('▶')
    expect(source).toContain('▼')
  })

  it('collapses/expands only when the chevron is clicked (stopPropagation on toggle)', () => {
    // The chevron button must call stopPropagation so clicking it
    // doesn't ALSO emit `select` for the underlying row. Vue
    // expresses this as `@click.stop="toggleParent(row.element.id)"`
    // — the modifier and the handler are on the same @click binding.
    expect(source).toMatch(/@click\.stop="toggleParent\(/)
  })

  it('sorts children within a level by z_index DESC, position ASC', () => {
    // Same sort as before (the previous flat panel) — applied per
    // bucket inside the tree computed.
    expect(source).toContain("z_index")
    expect(source).toContain("position")
    expect(source).toMatch(/b\.z_index\s*-\s*a\.z_index/)
    expect(source).toMatch(/a\.position\s*-\s*b\.position/)
  })

  it('renders per-row and per-button data-testid selectors', () => {
    expect(source).toContain("design-layer-${row.element.id}")
    expect(source).toContain("design-layer-reorder-up-${row.element.id}")
    expect(source).toContain("design-layer-reorder-down-${row.element.id}")
    expect(source).toContain("design-layer-delete-${row.element.id}")
  })

  it('reorder emits the new top-to-bottom id list (in tree order)', () => {
    // handleMoveUp/Down swap adjacent rows and emit the flat id list
    // so the parent can re-order the elements array.
    expect(source).toContain(".map((row) => row.element.id)")
  })

  it('has the design-panel data-testid', () => {
    expect(source).toContain("layers-panel")
  })

  it('renders an empty state when there are no elements', () => {
    expect(source).toContain("layers-panel-empty")
  })
})
