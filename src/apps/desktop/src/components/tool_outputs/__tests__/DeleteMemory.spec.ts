/**
 * Tests for DeleteMemory.vue.
 *
 * Verifies:
 *  - parses the success envelope (id + <deleted>true|false</deleted>)
 *  - parses the error envelope (<error> tag → red border, no rows)
 *  - header shows truncated id on success with a status chip
 *    (removed / not-found) reflecting the <deleted> value
 *  - expanded body shows the id row + the permanence-warning note
 *  - copy-id button works on success
 *  - empty envelope renders an empty-state hint
 *  - click on header toggles expanded state
 *
 * Plan: docs/superpowers/plans/2026-08-24-delete-memory-agent-tool.md (Task 5)
 * Task: task_1787546484030_8
 */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import DeleteMemory from '../DeleteMemory.vue'

// ────────────────────────────────────────────────────────────────────────
// jsdom clipboard stub (matches SaveMemory.spec.ts pattern)
// ────────────────────────────────────────────────────────────────────────

let clipboardWrites: string[] = []

beforeEach(() => {
  clipboardWrites = []
  Object.defineProperty(navigator, 'clipboard', {
    configurable: true,
    value: { writeText: vi.fn(async (s: string) => { clipboardWrites.push(s) }) },
  })
})

afterEach(() => {
  vi.restoreAllMocks()
})

// ────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────

const makeSuccessContent = (opts: {
  id?: string
  deleted?: 'true' | 'false'
} = {}) => {
  const id = opts.id ?? 'mem_aabbccdd11223344'
  const deleted = opts.deleted ?? 'true'
  return [
    `<delete_memory>`,
    `<id>${id}</id>`,
    `<deleted>${deleted}</deleted>`,
    `</delete_memory>`,
  ].join('')
}

const makeErrorContent = (msg = 'id is required') =>
  `<delete_memory><error>${msg}</error></delete_memory>`

const makeEmptyContent = () => `<delete_memory></delete_memory>`

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────

describe('DeleteMemory.vue — happy path (row existed)', () => {
  it('renders the tool name pill + truncated id in the header on success', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="delete-memory"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('delete_memory')
    expect(wrapper.text()).toContain('mem_aabbccdd11223344')
    expect(wrapper.text()).toContain('✓')
  })

  it('shows the "removed" status chip when deleted=true', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeSuccessContent({ deleted: 'true' }) },
    })
    expect(wrapper.find('[data-testid="delete-memory-status-removed"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('removed')
  })

  it('shows the "not found" status chip when deleted=false', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeSuccessContent({ deleted: 'false' }) },
    })
    expect(wrapper.find('[data-testid="delete-memory-status-notfound"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('not found')
  })

  it('does not show the red border on success', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeSuccessContent() },
    })
    const root = wrapper.find('[data-testid="delete-memory"]')
    expect(root.classes()).not.toContain('border-red-500/50')
  })

  it('renders the copy-id button on success', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="delete-memory-copy-id"]').exists()).toBe(true)
  })

  it('does NOT auto-expand (parent controls via :expanded prop)', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="delete-memory-id-row"]').exists()).toBe(false)
  })

  it('renders id row + permanence warning when expanded=true', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeSuccessContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="delete-memory-id-row"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="delete-memory-warning"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('mem_aabbccdd11223344')
    expect(wrapper.text()).toContain('permanent')
  })
})

describe('DeleteMemory.vue — error path', () => {
  it('renders the error message in red when expanded', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeErrorContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="delete-memory-error"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('id is required')
  })

  it('shows the red ✗ status on error', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeErrorContent() },
    })
    expect(wrapper.text()).toContain('✗')
  })

  it('applies the red border on error', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeErrorContent() },
    })
    const root = wrapper.find('[data-testid="delete-memory"]')
    expect(root.classes()).toContain('border-red-500/50')
  })

  it('shows "error" in the header label on failure', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeErrorContent() },
    })
    expect(wrapper.text()).toContain('error')
    expect(wrapper.text()).not.toContain('mem_')
  })

  it('does not render id row when in error state', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeErrorContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="delete-memory-id-row"]').exists()).toBe(false)
  })
})

describe('DeleteMemory.vue — expand/collapse interaction', () => {
  it('clicking the header toggles expanded state', async () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeSuccessContent() },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="delete-memory-id-row"]').exists()).toBe(false)

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="delete-memory-id-row"]').exists()).toBe(true)

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="delete-memory-id-row"]').exists()).toBe(false)
  })

  it('clicking the copy-id button does NOT toggle expanded state', async () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeSuccessContent() },
      attachTo: document.body,
    })

    await wrapper.find('[data-testid="delete-memory-copy-id"]').trigger('click')
    expect(clipboardWrites).toEqual(['mem_aabbccdd11223344'])
    expect(wrapper.find('[data-testid="delete-memory-id-row"]').exists()).toBe(false)

    wrapper.unmount()
  })
})

describe('DeleteMemory.vue — empty envelope edge case', () => {
  it('renders an empty-state hint when envelope has no fields', async () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeEmptyContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="delete-memory-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('no fields in envelope')
  })

  it('still shows ✓ status on an empty envelope (no error tag)', () => {
    const wrapper = mount(DeleteMemory, {
      props: { content: makeEmptyContent() },
    })
    expect(wrapper.text()).toContain('✓')
  })
})