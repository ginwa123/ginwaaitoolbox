/**
 * Static source-grep tests + behavioral mount tests for LayersPanel.vue.
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
 *
 * Tree contract (Chunk 7 of grouped-layers plan):
 *  - A flat list of DesignElement[] becomes a tree by grouping
 *    children under their `parent_id`. LayersPanel exposes the
 *    recursive `<LayerRow>` component to render it.
 *  - Selection across the tree is still flat (highlight rows whose
 *    id is in `selectedIds` regardless of nesting).
 *  - Children indented by `depth * 16px`.
 *  - Chevron toggle hides children when collapsed.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import * as fs from 'node:fs'
import * as path from 'node:path'

import LayersPanel from '../components/design/LayersPanel.vue'
import type { DesignElement } from '../api'

// ─── Static contract — existing source-grep tests ──────────────────────────

const SOURCE_PATH = path.resolve(__dirname, '../components/design/LayersPanel.vue')
const source = fs.readFileSync(SOURCE_PATH, 'utf-8')
const LAYER_ROW_PATH = path.resolve(__dirname, '../components/design/LayerRow.vue')
const layerRowSource = fs.readFileSync(LAYER_ROW_PATH, 'utf-8')

describe('LayersPanel.vue static contract', () => {
  it('emits select, reorder, delete', () => {
    expect(source).toContain('select:')
    expect(source).toContain('reorder:')
    expect(source).toContain('delete:')
  })

  it('declares elements, selectedIds, and readonly props (multi-aware: array, not nullable single id)', () => {
    expect(source).toContain('elements:')
    expect(source).toContain('selectedIds:')
    expect(source).toContain('readonly:')
  })

  it('sorts layers by z_index DESC then position ASC (in the layerTree builder)', () => {
    // Chunk 7 moved the sort out of the `layers` computed and into the
    // `layerTree` builder. Each bucket (top-level + per-parent) is
    // sorted by z_index DESC, position ASC. Verify in the new location.
    expect(source).toContain('z_index')
    expect(source).toContain('position')
    expect(source).toMatch(/b\.element\.z_index\s*-\s*a\.element\.z_index/)
    expect(source).toMatch(/a\.element\.position\s*-\s*b\.element\.position/)
  })

  it('renders per-row and per-button data-testid selectors (delegated to LayerRow)', () => {
    // The data-testid selectors now live on the recursive LayerRow
    // component. The contract is preserved across the layer split.
    expect(layerRowSource).toContain('design-layer-${node.element.id}')
    expect(layerRowSource).toContain('design-layer-reorder-up-${node.element.id}')
    expect(layerRowSource).toContain('design-layer-reorder-down-${node.element.id}')
    expect(layerRowSource).toContain('design-layer-delete-${node.element.id}')
  })

  it('reorder emits the new ordered id list (depth-first walk)', () => {
    // Chunk 7 changed the reorder wire from a flat list swap
    // (`next.map(e => e.id)`) to a depth-first walk of the cloned
    // tree (`flattenTopDown`). The wire shape (string[]) is preserved.
    expect(source).toContain('emit(\'reorder\'')
    expect(source).toContain('flattenTopDown')
  })

  it('has the design-panel data-testid', () => {
    expect(source).toContain('layers-panel')
  })

  it('renders an empty state when there are no elements', () => {
    expect(source).toContain('layers-panel-empty')
  })
})

// ─── Tree contract — static grep tests (Chunk 7) ───────────────────────────

describe('LayersPanel.vue tree contract (Chunk 7)', () => {
  it('imports the recursive LayerRow component', () => {
    // The import may include a named import for LayerTreeNode
    // alongside the default. Match the import path (the import target
    // is what matters for the recursive render — the named imports
    // are an implementation detail).
    expect(source).toContain("from './LayerRow.vue'")
  })

  it('renders LayerRow in a v-for (replacing the flat row template)', () => {
    expect(source).toMatch(/<LayerRow[\s\S]*v-for/)
  })

  it('declares the layerTree computed for building the tree', () => {
    expect(source).toContain('layerTree')
    expect(source).toContain('LayerTreeNode')
  })

  it('declares the collapsedIds ref for collapse state', () => {
    expect(source).toContain('collapsedIds')
  })

  it('groups children by parent_id in the tree builder', () => {
    expect(source).toContain('parent_id')
  })

  it('preserves the data-testid selector design-layer-${...} on the LayerRow', () => {
    // The selector lives on LayerRow's outer div (the row component
    // owns its own data-testid contract). Verify in LayerRow.vue.
    expect(layerRowSource).toContain('design-layer-${node.element.id}')
  })

  it('LayerRow component declares its name so recursive rendering type-checks', () => {
    // Vue 3's vue-tsc compiler requires either `defineOptions({ name })`
    // OR an explicit `name` field in a non-setup component declaration
    // to recognize recursive usage. Without this, the strict type-check
    // (`bun run build`) reports "Component LayerRow is not registered in
    // any module" — a silent failure under `bunx vitest run` only.
    const hasDefineOptions = /defineOptions\s*\(\s*\{\s*name:\s*['"]LayerRow['"]/.test(layerRowSource)
    expect(hasDefineOptions).toBe(true)
  })
})

// ─── Behavioral mount tests (Chunk 7 — tree render) ────────────────────────

function makeElement(overrides: Partial<DesignElement> = {}): DesignElement {
  return {
    id: 'elem_1',
    page_id: 'page_1',
    name: 'Element 1',
    type: 'rectangle',
    x: 0,
    y: 0,
    width: 100,
    height: 50,
    rotation: 0,
    fill: '#ffffff',
    stroke: '',
    stroke_width: 1,
    corner_radius: 0,
    opacity: 1,
    text_content: '',
    text_style: '',
    image_url: '',
    file_path: '',
    parent_id: null,
    z_index: 0,
    position: 0,
    created_at: '2026-07-28 12:00:00',
    updated_at: '2026-07-28 12:00:00',
    ...overrides,
  }
}

function mountPanel(props: { elements: DesignElement[]; selectedIds?: string[]; readonly?: boolean }): VueWrapper {
  return mount(LayersPanel, {
    props: {
      elements: props.elements,
      selectedIds: props.selectedIds ?? [],
      readonly: props.readonly ?? false,
    },
  })
}

describe('LayersPanel.vue — flat list (no parent_id set)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders one row per element when no element has parent_id', () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 2, position: 0 }),
      makeElement({ id: 'elem_b', z_index: 1, position: 0 }),
      makeElement({ id: 'elem_c', z_index: 0, position: 0 }),
    ]
    wrapper = mountPanel({ elements })
    const rows = wrapper.findAll('[data-testid^="design-layer-elem_"]')
    // Three rows, all top-level.
    expect(rows).toHaveLength(3)
  })
})

describe('LayersPanel.vue — tree render (parent_id set)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders parent and its children in the tree (parent before children)', async () => {
    // Tree: group (elem_g) contains two children (elem_a, elem_b).
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 3, position: 0 }),
      makeElement({ id: 'elem_a', z_index: 2, position: 0, parent_id: 'elem_g' }),
      makeElement({ id: 'elem_b', z_index: 1, position: 0, parent_id: 'elem_g' }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    const rows = wrapper.findAll('[data-testid^="design-layer-elem_"]')
    expect(rows).toHaveLength(3)

    // The group appears first (highest z_index). Its children appear
    // below it (nested under the group).
    const testIds = rows.map((r) => r.attributes('data-testid'))
    // Group testid is at index 0 (top of the panel).
    expect(testIds[0]).toBe('design-layer-elem_g')
    // The two children are below the group in the walk.
    expect(testIds).toContain('design-layer-elem_a')
    expect(testIds).toContain('design-layer-elem_b')
  })

  it('indents children by depth * 16px', async () => {
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 3 }),
      makeElement({ id: 'elem_a', z_index: 2, parent_id: 'elem_g' }),
      makeElement({ id: 'elem_b', z_index: 1, parent_id: 'elem_g' }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    const groupRow = wrapper.find('[data-testid="design-layer-elem_g"]')
    const childRowA = wrapper.find('[data-testid="design-layer-elem_a"]')

    const groupStyle = groupRow.attributes('style') ?? ''
    const childStyle = childRowA.attributes('style') ?? ''

    // Top-level row: paddingLeft = 0px
    expect(groupStyle).toMatch(/padding-left:\s*0(?:px)?/)
    // Nested row: paddingLeft = 16px (depth=1 × 16)
    expect(childStyle).toMatch(/padding-left:\s*16(?:px)?/)
  })

  it('indents grandchildren by 32px (depth=2)', async () => {
    // 3-level tree: group → subgroup → leaf
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 3 }),
      makeElement({ id: 'elem_sg', type: 'group', z_index: 2, parent_id: 'elem_g' }),
      makeElement({ id: 'elem_leaf', z_index: 1, parent_id: 'elem_sg' }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    const leaf = wrapper.find('[data-testid="design-layer-elem_leaf"]')
    const style = leaf.attributes('style') ?? ''
    expect(style).toMatch(/padding-left:\s*32(?:px)?/)
  })

  it('clicking the chevron on a parent toggles children visibility', async () => {
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 2 }),
      makeElement({ id: 'elem_a', z_index: 1, parent_id: 'elem_g' }),
      makeElement({ id: 'elem_b', z_index: 0, parent_id: 'elem_g' }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    // Initially: all 3 rows visible (parent + 2 children).
    expect(wrapper.findAll('[data-testid^="design-layer-elem_"]')).toHaveLength(3)

    // Find the chevron button. The button is identified by the
    // design-layer-toggle-${element.id} data-testid selector.
    const toggleBtn = wrapper.find('[data-testid="design-layer-toggle-elem_g"]')
    expect(toggleBtn.exists()).toBe(true)

    await toggleBtn.trigger('click')
    await nextTick()

    // After toggle: only the parent row visible (children hidden).
    const rowsAfter = wrapper.findAll('[data-testid^="design-layer-elem_"]')
    expect(rowsAfter).toHaveLength(1)
    expect(rowsAfter[0]?.attributes('data-testid')).toBe('design-layer-elem_g')

    // Click again: children re-appear.
    await toggleBtn.trigger('click')
    await nextTick()
    expect(wrapper.findAll('[data-testid^="design-layer-elem_"]')).toHaveLength(3)
  })

  it('selectedIds highlights rows across the tree regardless of nesting', async () => {
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 2 }),
      makeElement({ id: 'elem_a', z_index: 1, parent_id: 'elem_g' }),
    ]
    wrapper = mountPanel({ elements, selectedIds: ['elem_a'] })
    await nextTick()

    const groupRow = wrapper.find('[data-testid="design-layer-elem_g"]')
    const childRow = wrapper.find('[data-testid="design-layer-elem_a"]')

    // Child row (selected) has the active background color.
    const childStyle = childRow.attributes('style') ?? ''
    expect(childStyle).toContain('background-color')

    // Group row (not selected) does NOT have the active background.
    const groupStyle = groupRow.attributes('style') ?? ''
    // The dim color is applied; the violet "active" bg is not.
    expect(groupStyle).not.toContain('--semantic-active-bg')
  })

  it('delete emit bubbles up from a nested LayerRow', async () => {
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 2 }),
      makeElement({ id: 'elem_a', z_index: 1, parent_id: 'elem_g' }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    const deleteBtn = wrapper.find('[data-testid="design-layer-delete-elem_a"]')
    expect(deleteBtn.exists()).toBe(true)

    await deleteBtn.trigger('click')

    const emitted = wrapper.emitted('delete')
    expect(emitted).toBeTruthy()
    expect(emitted?.[0]).toEqual(['elem_a'])
  })

  it('does not render a chevron on leaf elements (no children)', async () => {
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 2 }),
      makeElement({ id: 'elem_a', z_index: 1, parent_id: 'elem_g' }),
      // elem_b is a leaf — no parent_id, no children.
      makeElement({ id: 'elem_b', z_index: 0 }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    // elem_g has children → chevron.
    expect(wrapper.find('[data-testid="design-layer-toggle-elem_g"]').exists()).toBe(true)
    // elem_a is a child of elem_g → no chevron of its own (unless
    // it had nested children, which it doesn't).
    expect(wrapper.find('[data-testid="design-layer-toggle-elem_a"]').exists()).toBe(false)
    // elem_b is top-level leaf → no chevron.
    expect(wrapper.find('[data-testid="design-layer-toggle-elem_b"]').exists()).toBe(false)
  })
})
