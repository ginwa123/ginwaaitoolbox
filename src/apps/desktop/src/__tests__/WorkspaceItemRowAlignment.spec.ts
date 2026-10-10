/**
 * The workspace-item row's edge alignment.
 *
 * The row used to be TWO boxes: a padded <button> plus two unpadded action
 * buttons as siblings in the wrapper. The button's padding only padded the
 * button, so `+`/`×` reached the panel edge 12px past every other row in the
 * sidebar (measured: 279 vs 267 in a 280px panel). The chevron also sat in a
 * 24px hit box, which centred its glyph at x=20 while every section-header
 * chevron rendered at x=12.
 *
 * These tests assert the STRUCTURE that makes both edges resolve against one
 * gutter, rather than a pixel count — jsdom returns all-zero rects, so a
 * geometry assertion here would be vacuous. The pixel values were measured in
 * a real browser and are recorded in the comments so a reviewer can see what
 * the structure buys.
 *
 * What is asserted:
 *   1. the row's actions are DESCENDANTS of the padded button, not siblings
 *   2. the chevron carries no hit box, so it renders like a section header
 *   3. the row uses the same inter-element gap as every other row
 *   4. the right-click menu offers the same two actions the row does
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick, ref, type Ref } from 'vue'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import type { WorkspaceItem as WorkspaceItemType, Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

const makeTask = (overrides: Partial<Task> = {}): Task => ({
  id: 'task_1',
  name: 'My Task',
  ...overrides,
})

const makeItem = (overrides: Partial<WorkspaceItemType> = {}): WorkspaceItemType => ({
  id: ITEM_ID,
  name: 'My Project',
  item_type: 'folder',
  path: '/abs/path',
  tasks: [makeTask()],
  ...overrides,
})

function mountItem(item: WorkspaceItemType, isActive = false) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(WorkspaceItem, {
    props: { item, isActive, workspaceId: WS_ID },
    global: { provide: { processingState } },
  })
}

/**
 * The menu is `v-if="menuPos"`, so it only mounts after a real right-click
 * on the row. Trigger it the way a user does rather than poking the
 * composable's ref — the point of these tests is the wired path.
 */
async function openRowMenu(w: VueWrapper) {
  await w.find('button.flex-1').trigger('contextmenu', { clientX: 40, clientY: 40 })
  await nextTick()
}

/**
 * OpenInNewTabMenu is `<Teleport to="body">`, so its rows are NOT inside the
 * wrapper's element tree and `wrapper.find` cannot see them. Read the
 * document instead.
 */
function menuRowExists(testid: string): boolean {
  return document.querySelector(`[data-testid="${testid}"]`) !== null
}

describe('WorkspaceItem row — one padded box owns both edges', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('keeps the row actions INSIDE the padded button, not as siblings', () => {
    // The regression this guards: the actions were siblings of the padded
    // button in the `group/item` wrapper, which has no padding of its own,
    // so they ran to the panel edge (279) while every other row stopped at
    // the gutter (267).
    wrapper = mountItem(makeItem())

    const button = wrapper.find('button.flex-1')
    expect(button.exists()).toBe(true)

    const addTask = wrapper.find('[data-testid="add-task-button"]')
    const deleteItem = wrapper.find('[data-testid="delete-item-button"]')
    expect(addTask.exists()).toBe(true)
    expect(deleteItem.exists()).toBe(true)

    // `contains` walks up the real DOM tree, so this is the structural
    // claim — not a class-string guess.
    expect(button.element.contains(addTask.element)).toBe(true)
    expect(button.element.contains(deleteItem.element)).toBe(true)
  })

  it('hides the row actions until hover or keyboard focus', () => {
    // An idle row is clean text. `focus-visible` is what keeps the actions
    // reachable without a pointer — hover alone is undiscoverable and does
    // nothing on touch, which is why the same two actions are also in the
    // right-click menu.
    wrapper = mountItem(makeItem())

    for (const testid of ['add-task-button', 'delete-item-button']) {
      const cls = wrapper.find(`[data-testid="${testid}"]`).classes().join(' ')
      expect(cls).toContain('opacity-0')
      expect(cls).toContain('group-hover/item:opacity-60')
      expect(cls).toContain('focus-visible:opacity-100')
    }
  })

  it('renders the chevron as bare text, with no hit box', () => {
    // The chevron used to sit in a 24px `--sb-hit` box, centring its glyph at
    // x=20 while every section-header chevron rendered at x=12. Bare text
    // puts this one at 12 too, and the project name at 28 — matching the
    // section titles.
    wrapper = mountItem(makeItem())

    const chevron = wrapper.find('[data-testid="item-row-chevron"]')
    expect(chevron.exists()).toBe(true)

    const cls = chevron.classes().join(' ')
    expect(cls).not.toContain('w-[var(--sb-hit)]')
    expect(cls).not.toContain('h-[var(--sb-hit)]')
    expect(chevron.text()).toContain('▶')
  })

  it('uses the same inter-element gap as every other row in the panel', () => {
    // `gap-0.5` (2px) against every other row's `gap-2` (8px) is what left
    // the project name 6px left of where it belonged.
    wrapper = mountItem(makeItem())

    const cls = wrapper.find('button.flex-1').classes().join(' ')
    expect(cls).toContain('gap-2')
    expect(cls).not.toContain('gap-0.5')
  })

  it('offers Add task and Delete project in the right-click menu', async () => {
    // The hover-reveal actions need a second door: hover is undiscoverable
    // and does nothing on touch. The menu already existed on this row, so
    // this is two rows on it, not a new component.
    wrapper = mountItem(makeItem())
    await openRowMenu(wrapper)

    const menu = wrapper.findComponent({ name: 'OpenInNewTabMenu' })
    expect(menu.exists()).toBe(true)
    expect(menu.props('showAddTask')).toBe(true)
    expect(menu.props('showDeleteItem')).toBe(true)

    // The rows are actually rendered, not just flagged on. Teleported to
    // body, so read the document rather than the wrapper.
    expect(menuRowExists('add-task-menu-item')).toBe(true)
    expect(menuRowExists('delete-item-menu-item')).toBe(true)
  })

  it('menu Add task emits the same payload as the row button', async () => {
    wrapper = mountItem(makeItem())
    const item = makeItem()
    await openRowMenu(wrapper)

    wrapper.findComponent({ name: 'OpenInNewTabMenu' }).vm.$emit('addTask')
    wrapper.findComponent({ name: 'OpenInNewTabMenu' }).vm.$emit('deleteItem')

    expect(wrapper.emitted('addTask')).toEqual([[item]])
    expect(wrapper.emitted('delete')).toEqual([[item]])
  })

  it('hides Add task for kanban + routine on BOTH doors', async () => {
    // The board/scheduler own creation for these types. The menu row follows
    // the same rule as the row button so the two doors never disagree.
    for (const item_type of ['kanban', 'routine'] as const) {
      wrapper = mountItem(makeItem({ item_type }))
      expect(wrapper.find('[data-testid="add-task-button"]').exists()).toBe(false)

      await openRowMenu(wrapper)
      expect(menuRowExists('add-task-menu-item')).toBe(false)
      // Delete is still offered — deleting a board is a legitimate action.
      expect(menuRowExists('delete-item-menu-item')).toBe(true)
      wrapper.unmount()
    }
    wrapper = null
  })

  it('keeps the chevron ahead of the row spinner in DOM order', async () => {
    // Pre-existing contract (workspaceItemProcessingSpinner.spec.ts): the
    // spinner sits after the chevron + content, not before. Moving the
    // actions inside the button must not disturb it.
    const processingState: Ref<Record<string, boolean>> = ref({})
    wrapper = mount(WorkspaceItem, {
      props: { item: makeItem(), isActive: false, workspaceId: WS_ID },
      global: { provide: { processingState } },
    })
    processingState.value = { task_1: true }
    await nextTick()

    const html = wrapper.find('button.flex-1').html()
    expect(html.indexOf('item-row-chevron')).toBeGreaterThan(-1)
    expect(html.indexOf('item-processing-spinner')).toBeGreaterThan(html.indexOf('item-row-chevron'))
  })
})
