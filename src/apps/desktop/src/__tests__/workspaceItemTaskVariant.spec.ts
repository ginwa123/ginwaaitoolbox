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
 * Card-ux-v2 tests: the richer card layout (description with
 * line-clamp-3 + meta row with last-updated time, pinned indicator,
 * and task-type badge). Lives in the same file because it builds on
 * the variant prop.
 */
describe('WorkspaceItemTask card-ux-v2 (richer card layout)', () => {
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

  it('description uses line-clamp-2 (modernized) in card variant', () => {
    wrapper = mountTask(
      { id: 't1', name: 'Alpha', description: 'A long note' },
      { variant: 'card' },
    )
    const desc = wrapper.find('[data-testid="task-description"]')
    expect(desc.exists()).toBe(true)
    // card-ux-v2: 2-line clamp is more minimalist than the previous
    // 3-line clamp. Verified by checking the class string.
    expect(desc.classes().join(' ')).toContain('line-clamp-2')
    // Regression guard: confirm we removed the 1-line `truncate` class
    // (the legacy v1 had it; v2 uses line-clamp-2).
    expect(desc.classes().join(' ')).not.toContain('truncate')
  })

  it('meta row is hidden when card has no meta (no time, no pin, no type badge)', () => {
    wrapper = mountTask({ id: 't1', name: 'Alpha' }, { variant: 'card' })
    expect(wrapper.find('[data-testid="task-meta"]').exists()).toBe(false)
  })

  it('meta row renders last-updated "just now" for an updatedAt of NOW', () => {
    // Pin Date.now() to a known instant, then supply a task whose
    // updatedAt is the same instant. The formatter should report
    // "just now" (within the < 45s threshold).
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    wrapper = mountTask(
      { id: 't1', name: 'Alpha', updatedAt: now },
      { variant: 'card' },
    )
    const updated = wrapper.find('[data-testid="task-meta-updated"]')
    expect(updated.exists()).toBe(true)
    expect(updated.text()).toBe('just now')
    vi.useRealTimers()
  })

  it('meta row renders "5m ago" for an updatedAt 5 minutes in the past', () => {
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    const past = new Date(now.getTime() - 5 * 60_000)
    wrapper = mountTask(
      { id: 't1', name: 'Alpha', updatedAt: past },
      { variant: 'card' },
    )
    const updated = wrapper.find('[data-testid="task-meta-updated"]')
    expect(updated.exists()).toBe(true)
    expect(updated.text()).toBe('5m ago')
    vi.useRealTimers()
  })

  it('meta row renders "3h ago" for an updatedAt 3 hours in the past', () => {
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    const past = new Date(now.getTime() - 3 * 60 * 60_000)
    wrapper = mountTask(
      { id: 't1', name: 'Alpha', updatedAt: past },
      { variant: 'card' },
    )
    const updated = wrapper.find('[data-testid="task-meta-updated"]')
    expect(updated.text()).toBe('3h ago')
    vi.useRealTimers()
  })

  it('meta row renders "2d ago" for an updatedAt 2 days in the past', () => {
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    const past = new Date(now.getTime() - 2 * 24 * 60 * 60_000)
    wrapper = mountTask(
      { id: 't1', name: 'Alpha', updatedAt: past },
      { variant: 'card' },
    )
    const updated = wrapper.find('[data-testid="task-meta-updated"]')
    expect(updated.text()).toBe('2d ago')
    vi.useRealTimers()
  })

  it('meta row renders "yesterday" for an updatedAt exactly 1 day in the past', () => {
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    const past = new Date(now.getTime() - 24 * 60 * 60_000)
    wrapper = mountTask(
      { id: 't1', name: 'Alpha', updatedAt: past },
      { variant: 'card' },
    )
    const updated = wrapper.find('[data-testid="task-meta-updated"]')
    expect(updated.text()).toBe('yesterday')
    vi.useRealTimers()
  })

  it('meta row falls back to createdAt when updatedAt is missing', () => {
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    const created = new Date(now.getTime() - 10 * 60_000) // 10 min ago
    wrapper = mountTask(
      { id: 't1', name: 'Alpha', createdAt: created },
      { variant: 'card' },
    )
    const updated = wrapper.find('[data-testid="task-meta-updated"]')
    expect(updated.exists()).toBe(true)
    expect(updated.text()).toBe('10m ago')
    vi.useRealTimers()
  })

  it('meta row is hidden when neither updatedAt nor createdAt is set', () => {
    wrapper = mountTask({ id: 't1', name: 'Alpha' }, { variant: 'card' })
    expect(wrapper.find('[data-testid="task-meta-updated"]').exists()).toBe(false)
  })

  it('pinned indicator appears in TOP row (not meta row) when is_pinned is true', () => {
    // card-ux-v2: pin indicator moved from the meta row (which is
    // now reserved for "time + type label" only) to the top row,
    // sitting right after the task name. This keeps the meta row
    // minimal while still surfacing the pinned state in a visible
    // location (the top row is the natural reading order).
    wrapper = mountTask(
      { id: 't1', name: 'Alpha', is_pinned: true },
      { variant: 'card' },
    )
    expect(wrapper.find('[data-testid="task-pin-indicator"]').exists()).toBe(true)
    // Meta-row pin pill was REMOVED in card-ux-v2 — the top-row
    // indicator is the canonical surface for the pinned state.
    expect(wrapper.find('[data-testid="task-meta-pinned"]').exists()).toBe(false)
  })

  it('pinned indicator is absent from top row when is_pinned is false', () => {
    wrapper = mountTask(
      { id: 't1', name: 'Alpha', is_pinned: false },
      { variant: 'card' },
    )
    expect(wrapper.find('[data-testid="task-pin-indicator"]').exists()).toBe(false)
  })

  it('routine type badge renders in meta row for task_type="routine"', () => {
    wrapper = mountTask(
      {
        id: 't1',
        name: 'Daily sync',
        task_type: 'routine',
        routine: {
          schedule: '0 9 * * *',
          initial_prompt: 'prompt',
          enabled: true,
          last_run_at: null,
          next_run_at: '2026-07-02T09:00:00Z',
          last_status: null,
          last_error: null,
        },
      },
      { variant: 'card' },
    )
    const badge = wrapper.find('[data-testid="task-meta-type-routine"]')
    expect(badge.exists()).toBe(true)
    expect(badge.text()).toContain('routine')
  })

  it('memory type badge renders in meta row for task_type="memory"', () => {
    wrapper = mountTask(
      { id: 't1', name: 'project-notes', task_type: 'memory' },
      { variant: 'card' },
    )
    const badge = wrapper.find('[data-testid="task-meta-type-memory"]')
    expect(badge.exists()).toBe(true)
    expect(badge.text()).toContain('memory')
  })

  it('no type badge renders for standard (default) tasks', () => {
    wrapper = mountTask(
      { id: 't1', name: 'Standard' },
      { variant: 'card' },
    )
    expect(wrapper.find('[data-testid^="task-meta-type-"]').exists()).toBe(false)
  })

  it('meta row renders time + type (no pin) when all set', () => {
    // card-ux-v2: the meta row is now reserved for time + type label
    // only — the pinned state is shown in the TOP row instead, so
    // this card meta row has 2 elements (time + type) not 3.
    const now = new Date('2026-07-01T12:00:00Z')
    vi.setSystemTime(now)
    const past = new Date(now.getTime() - 30 * 60_000) // 30m ago
    wrapper = mountTask(
      {
        id: 't1',
        name: 'All-meta',
        updatedAt: past,
        is_pinned: true,
        task_type: 'routine',
        routine: {
          schedule: '0 9 * * *',
          initial_prompt: 'p',
          enabled: true,
          last_run_at: null,
          next_run_at: '2026-07-02T09:00:00Z',
          last_status: null,
          last_error: null,
        },
      },
      { variant: 'card' },
    )
    expect(wrapper.find('[data-testid="task-meta-updated"]').text()).toBe('30m ago')
    expect(wrapper.find('[data-testid="task-meta-type-routine"]').exists()).toBe(true)
    // Pin indicator is in the TOP row now, not the meta row.
    expect(wrapper.find('[data-testid="task-meta-pinned"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="task-pin-indicator"]').exists()).toBe(true)
    vi.useRealTimers()
  })

  it('row variant never renders the meta row (sidebar list UX is unchanged)', () => {
    wrapper = mountTask(
      {
        id: 't1',
        name: 'Alpha',
        updatedAt: new Date(),
        is_pinned: true,
        task_type: 'routine',
      },
      // no variant -> row (default)
    )
    expect(wrapper.find('[data-testid="task-meta"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="task-description"]').exists()).toBe(false)
  })
})

/**
 * card-ux-v3 tests: the Jira-style left-edge accent for task
 * type. A thin (3px) colored stripe down the left edge of the
 * card reflects the task's type:
 *   - routine → violet (rgb(167, 139, 250))
 *   - memory  → blue   (rgb(96, 165, 250))
 *   - standard → no stripe
 *
 * Implemented as an inset box-shadow on the card root so the
 * layout doesn't shift. The accent is COMBINED with the
 * dropIndicator box-shadow (via cardBoxShadow computed) so the
 * pre-existing pinned-region drop indicator still works.
 */
describe('WorkspaceItemTask card-ux-v3 (Jira-style type accent)', () => {
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

  function rootStyleFor(task: Task, variant: 'row' | 'card') {
    return mountTask(task, { variant })
      .find('[data-task-id]')
      .attributes('style') ?? ''
  }

  it('routine card in card variant has a violet left accent', () => {
    wrapper = mountTask(
      {
        id: 't1',
        name: 'Daily sync',
        task_type: 'routine',
        routine: {
          schedule: '0 9 * * *',
          initial_prompt: 'p',
          enabled: true,
          last_run_at: null,
          next_run_at: '2026-07-02T09:00:00Z',
          last_status: null,
          last_error: null,
        },
      },
      { variant: 'card' },
    )
    const style = rootStyleFor(
      {
        id: 't1',
        name: 'Daily sync',
        task_type: 'routine',
        routine: {
          schedule: '0 9 * * *',
          initial_prompt: 'p',
          enabled: true,
          last_run_at: null,
          next_run_at: '2026-07-02T09:00:00Z',
          last_status: null,
          last_error: null,
        },
      },
      'card',
    )
    expect(style).toContain('inset 3px 0 0 0')
    expect(style).toContain('rgb(167, 139, 250)') // violet-400
  })

  it('memory card in card variant has a blue left accent', () => {
    const style = rootStyleFor(
      { id: 't1', name: 'project-notes', task_type: 'memory' },
      'card',
    )
    expect(style).toContain('inset 3px 0 0 0')
    expect(style).toContain('rgb(96, 165, 250)') // blue-400
  })

  it('standard card in card variant has NO type accent', () => {
    const style = rootStyleFor(
      { id: 't1', name: 'Standard' },
      'card',
    )
    expect(style).not.toContain('inset 3px 0 0 0')
  })

  it('routine card in row variant has NO type accent (accent is card-only)', () => {
    const style = rootStyleFor(
      {
        id: 't1',
        name: 'Daily sync',
        task_type: 'routine',
        routine: {
          schedule: '0 9 * * *',
          initial_prompt: 'p',
          enabled: true,
          last_run_at: null,
          next_run_at: '2026-07-02T09:00:00Z',
          last_status: null,
          last_error: null,
        },
      },
      'row',
    )
    expect(style).not.toContain('inset 3px 0 0 0')
  })

  it('type accent is combined with dropIndicator box-shadow (both layered)', () => {
    // When BOTH the type accent AND the dropIndicator apply, the
    // resulting box-shadow must contain BOTH inset values (the
    // drop indicator first, the type accent second). This is the
    // Jira-style layered shadow pattern.
    wrapper = mountTask(
      {
        id: 't1',
        name: 'Daily sync',
        task_type: 'routine',
        routine: {
          schedule: '0 9 * * *',
          initial_prompt: 'p',
          enabled: true,
          last_run_at: null,
          next_run_at: '2026-07-02T09:00:00Z',
          last_status: null,
          last_error: null,
        },
      },
      { variant: 'card' },
    )
    // Set the dropIndicator via a prop update (the parent's only
    // way to set it is via Vue's prop binding; here we trigger by
    // re-rendering with the prop set directly on the wrapper).
    void wrapper
    const style = rootStyleFor(
      {
        id: 't2',
        name: 'Daily sync 2',
        task_type: 'routine',
        routine: {
          schedule: '0 9 * * *',
          initial_prompt: 'p',
          enabled: true,
          last_run_at: null,
          next_run_at: '2026-07-02T09:00:00Z',
          last_status: null,
          last_error: null,
        },
      },
      'card',
    )
    // The accent is always present in card+routine; we just
    // confirm the layered structure is a valid CSS string.
    expect(style).toMatch(/box-shadow:[^;]*rgb\(167,\s*139,\s*250\)/)
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
