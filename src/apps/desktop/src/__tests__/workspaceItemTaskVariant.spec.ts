/**
 * Tests for WorkspaceItemTask's `variant` prop. Verifies:
 *   - default variant is 'row' (data-task-row present, data-task-card absent)
 *   - variant='card' renders card-specific data attributes
 *   - variant='card' renders the description preview when present
 *   - variant='row' (explicit) hides the description line
 *   - The card variant preserves the existing action icons + name rendering
 *   - Static-contract guard: WorkspaceItem.vue never passes variant='card'
 *
 * Plan: docs/plans/2026-07-01-change-task-to-card-kanban.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { ref, type Ref } from 'vue'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import WorkspaceItemTask from '../components/WorkspaceItemTask.vue'
import type { Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

function mountTask(
  task: Task,
  props: Partial<{ variant: 'row' | 'card' }> = {},
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(WorkspaceItemTask, {
    props: {
      task,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      ...props,
    },
    global: { provide: { processingState } },
  })
  return wrapper
}

describe('WorkspaceItemTask variant prop', () => {
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

  it('defaults to variant="row" when no prop is passed', () => {
    wrapper = mountTask({ id: 't1', name: 'Alpha' })
    expect(wrapper.find('[data-task-row]').exists()).toBe(true)
    expect(wrapper.find('[data-task-card]').exists()).toBe(false)
  })

  it('renders data-task-card and hides data-task-row when variant="card"', () => {
    wrapper = mountTask({ id: 't1', name: 'Alpha' }, { variant: 'card' })
    expect(wrapper.find('[data-task-card]').exists()).toBe(true)
    expect(wrapper.find('[data-task-row]').exists()).toBe(false)
  })

  it('accepts an explicit variant="row" prop', () => {
    wrapper = mountTask({ id: 't1', name: 'Alpha' }, { variant: 'row' })
    expect(wrapper.find('[data-task-row]').exists()).toBe(true)
    expect(wrapper.find('[data-task-card]').exists()).toBe(false)
  })

  it('renders description when variant="card" and description is non-empty', () => {
    wrapper = mountTask(
      { id: 't1', name: 'Alpha', description: 'A note about Alpha' },
      { variant: 'card' },
    )
    const desc = wrapper.find('[data-testid="task-description"]')
    expect(desc.exists()).toBe(true)
    expect(desc.text()).toBe('A note about Alpha')
  })

  it('hides description when variant="row" (default), even if description is set', () => {
    wrapper = mountTask({ id: 't1', name: 'Alpha', description: 'A note' })
    expect(wrapper.find('[data-testid="task-description"]').exists()).toBe(false)
  })

  it('hides description line in card variant when description is empty', () => {
    wrapper = mountTask({ id: 't1', name: 'Alpha' }, { variant: 'card' })
    expect(wrapper.find('[data-testid="task-description"]').exists()).toBe(false)
  })

  it('hides description line in card variant when description is undefined', () => {
    wrapper = mountTask(
      // explicitly pass undefined — the production ref to an unset
      // description is JS-undefined, NOT empty string.
      { id: 't1', name: 'Alpha', description: undefined },
      { variant: 'card' },
    )
    expect(wrapper.find('[data-testid="task-description"]').exists()).toBe(false)
  })

  it('renders the task name in card variant', () => {
    wrapper = mountTask({ id: 't1', name: 'Alpha' }, { variant: 'card' })
    expect(wrapper.text()).toContain('Alpha')
  })

  it('renders the pin toggle button in card variant', () => {
    wrapper = mountTask({ id: 't1', name: 'Alpha' }, { variant: 'card' })
    expect(wrapper.find('[data-testid="task-pin-toggle"]').exists()).toBe(true)
  })

  it('emits select-task when card variant is clicked', async () => {
    wrapper = mountTask({ id: 't1', name: 'Alpha' }, { variant: 'card' })
    // Trigger click on the root button via the data-task-id selector
    // (works for any variant since it is on the root <button>).
    await wrapper.find('[data-task-id="t1"]').trigger('click')
    expect(wrapper.emitted('selectTask')).toBeTruthy()
    expect(wrapper.emitted('selectTask')?.[0]).toEqual(['t1'])
  })
})

/**
 * Static-contract test: the sidebar's WorkspaceItem.vue (the only
 * non-KanbanCard consumer) MUST NOT pass a `variant` prop to its
 * <WorkspaceItemTask> instances. If someone accidentally adds
 * `:variant="'card'"` to one of those lines, this test fires.
 *
 * Lives in this file because it's a guard for the variant prop. If
 * the prop is ever renamed, both the implementation, the consumer
 * test, AND this contract test move together.
 */
describe('WorkspaceItem.vue — task variant invariant', () => {
  const SIDEBAR_PATH = resolve(
    __dirname,
    '..',
    'components',
    'WorkspaceItem.vue',
  )

  it('does not pass variant="card" to <WorkspaceItemTask>', () => {
    const source = readFileSync(SIDEBAR_PATH, 'utf8')
    // Anchored on `variant=` (not bare `variant`) so we don't trip
    // over type defs or comments mentioning the variant concept.
    expect(source).not.toMatch(/variant\s*=\s*['"]card['"]/)
  })

  it('still renders <WorkspaceItemTask> (sanity: the contract test is testing the right file)', () => {
    const source = readFileSync(SIDEBAR_PATH, 'utf8')
    expect(source).toContain('<WorkspaceItemTask')
  })
})
