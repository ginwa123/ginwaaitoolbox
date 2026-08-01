/**
 * Behavioural tests for DesignPageTabs.vue.
 *
 * The component is a pure presentation layer — given a list of pages,
 * it renders one button per page + an "+ Page" button, and emits
 * `selectPage` / `addPage` / `deletePage` upward. DesignView wires
 * these to the API.
 *
 * Plan: docs/superpowers/plans/2026-08-06-design-pages-left-sidebar.md
 * (chunk 2 — "convert static-contract tests to behavioural tests").
 *
 * The previous static-contract tests (which only asserted on
 * `source.toContain(...)` patterns) were removed as part of the
 * user-rule (2026-07-29) cleanup — they don't catch *runtime* bugs
 * like a missing `selectPage` emit on click.
 */
import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import DesignPageTabs from '../components/design/DesignPageTabs.vue'
import type { DesignPage } from '../api'

function makePage(overrides: Partial<DesignPage> = {}): DesignPage {
  return {
    id: 'page_1',
    workspace_item_id: 'item_1',
    name: 'Page 1',
    workspace_item_task_id: 'task_1',
    width: 1440,
    height: 1024,
    position: 0,
    created_at: '2026-08-06 00:00:00',
    updated_at: '2026-08-06 00:00:00',
    ...overrides,
  }
}

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

function mountTabs(props: {
  pages: DesignPage[]
  activePageId: string
}) {
  return mount(DesignPageTabs, {
    props: {
      pages: props.pages,
      activePageId: props.activePageId,
      workspaceId: WS_ID,
      itemId: ITEM_ID,
    },
  })
}

describe('DesignPageTabs.vue — vertical orientation (left sidebar)', () => {
  it('renders one button per page with the design-page-tab-${id} testid', () => {
    const pages = [
      makePage({ id: 'p_a', name: 'Alpha' }),
      makePage({ id: 'p_b', name: 'Beta' }),
      makePage({ id: 'p_c', name: 'Gamma' }),
    ]
    const wrapper = mountTabs({ pages, activePageId: 'p_a' })
    for (const p of pages) {
      const tab = wrapper.find(`[data-testid="design-page-tab-${p.id}"]`)
      expect(tab.exists(), `expected tab for ${p.id} to exist`).toBe(true)
    }
    expect(wrapper.findAll('[data-testid^="design-page-tab-"]')).toHaveLength(3)
  })

  it('clicking a page tab emits selectPage with the clicked id', async () => {
    const pages = [
      makePage({ id: 'p_a', name: 'Alpha' }),
      makePage({ id: 'p_b', name: 'Beta' }),
    ]
    const wrapper = mountTabs({ pages, activePageId: 'p_a' })
    await wrapper.find('[data-testid="design-page-tab-p_b"]').trigger('click')
    const emitted = wrapper.emitted('selectPage')
    expect(emitted).toBeTruthy()
    expect(emitted).toHaveLength(1)
    expect(emitted![0]).toEqual(['p_b'])
  })

  it('clicking the active page does NOT re-emit selectPage (no-op guard)', async () => {
    // Figma / Sketch / VS Code tab behaviour: clicking the already-
    // active tab shouldn't fire a redundant selectPage — the page
    // hasn't changed and the parent's watch would re-render for no
    // reason.
    const pages = [
      makePage({ id: 'p_a', name: 'Alpha' }),
      makePage({ id: 'p_b', name: 'Beta' }),
    ]
    const wrapper = mountTabs({ pages, activePageId: 'p_a' })
    await wrapper.find('[data-testid="design-page-tab-p_a"]').trigger('click')
    expect(wrapper.emitted('selectPage')).toBeFalsy()
  })

  it('clicking + Page emits addPage', async () => {
    const pages = [makePage({ id: 'p_a' })]
    const wrapper = mountTabs({ pages, activePageId: 'p_a' })
    await wrapper.find('[data-testid="design-add-page"]').trigger('click')
    expect(wrapper.emitted('addPage')).toBeTruthy()
    expect(wrapper.emitted('addPage')).toHaveLength(1)
  })

  it('clicking the × button emits deletePage with the page id', async () => {
    const pages = [
      makePage({ id: 'p_a', name: 'Alpha' }),
      makePage({ id: 'p_b', name: 'Beta' }),
    ]
    const wrapper = mountTabs({ pages, activePageId: 'p_a' })
    await wrapper.find('[data-testid="design-delete-page-p_b"]').trigger('click')
    const emitted = wrapper.emitted('deletePage')
    expect(emitted).toBeTruthy()
    expect(emitted).toHaveLength(1)
    expect(emitted![0]).toEqual(['p_b'])
  })

  it('does NOT render the × button when only one page exists (orphan guard)', () => {
    // Once you delete the last page, you can't delete anything — the
    // UX is "you must have at least one page". Locks the contract
    // so a future refactor that always shows × can't accidentally
    // expose a delete-on-last-page affordance.
    const pages = [makePage({ id: 'p_a' })]
    const wrapper = mountTabs({ pages, activePageId: 'p_a' })
    expect(wrapper.find('[data-testid="design-delete-page-p_a"]').exists()).toBe(
      false,
    )
  })

  it('the active page has a left-border accent (border-left), not a bottom-border', () => {
    // The horizontal tab strip used `border-bottom: 2px solid
    // var(--color-violet)` for the active state. After moving to a
    // vertical left sidebar, the active indicator is a left-edge
    // accent (`border-left`). The bottom-border styling must be
    // removed (else the row gets a redundant 2px bottom highlight
    // that reads as a "selected" tab from a horizontal layout).
    const pages = [
      makePage({ id: 'p_a', name: 'Alpha' }),
      makePage({ id: 'p_b', name: 'Beta' }),
    ]
    const wrapper = mountTabs({ pages, activePageId: 'p_a' })
    const activeTab = wrapper.find('[data-testid="design-page-tab-p_a"]')
    const style = activeTab.attributes('style') ?? ''
    expect(style).toContain('border-left')
    expect(style).not.toContain('border-bottom')
  })

  it('uses a vertical flex direction (flex-col, not items-center)', () => {
    // Lock the orientation contract — the root container must declare
    // `flex-col` (vertical) so the tabs stack top-to-bottom rather
    // than flow left-to-right. A regression to the horizontal layout
    // would quickly be caught by this single assertion.
    const pages = [makePage({ id: 'p_a' })]
    const wrapper = mountTabs({ pages, activePageId: 'p_a' })
    const root = wrapper.find('[data-testid="design-page-tabs"]')
    expect(root.classes()).toContain('flex-col')
    expect(root.classes()).not.toContain('items-center')
  })
})
