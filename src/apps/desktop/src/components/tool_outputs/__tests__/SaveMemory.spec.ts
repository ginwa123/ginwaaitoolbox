/**
 * Tests for SaveMemory.vue.
 *
 * Verifies:
 *  - parses the success envelope (id + created_at + updated_at)
 *  - parses the error envelope (<error> tag → red border, no rows)
 *  - header label shows the truncated id on success, "error" on failure
 *  - expanded body renders the id / created / updated rows
 *  - copy-id button is wired to clipboard (jsdom stub) and only present on success
 *  - empty envelope (no id, no timestamps) renders an empty-state hint
 *  - click on header toggles expanded state
 */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import SaveMemory from '../SaveMemory.vue'

// ────────────────────────────────────────────────────────────────────────
// jsdom clipboard stub (matches ReadWorkspaceSession.spec.ts pattern)
// ────────────────────────────────────────────────────────────────────────

let clipboardWrites: string[] = []

beforeEach(() => {
  clipboardWrites = []
  Object.defineProperty(navigator, 'clipboard', {
    configurable: true,
    value: {
      writeText: vi.fn(async (s: string) => {
        clipboardWrites.push(s)
      }),
    },
  })
})

afterEach(() => {
  vi.restoreAllMocks()
})

// ────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────

const makeSuccessContent = (
  opts: {
    id?: string
    created_at?: string
    updated_at?: string
  } = {},
) => {
  const id = opts.id ?? 'mem_aabbccdd11223344'
  const created = opts.created_at ?? '2026-08-06 10:00:00'
  const updated = opts.updated_at ?? '2026-08-06 10:05:00'
  return [
    `<save_memory>`,
    `<id>${id}</id>`,
    `<created_at>${created}</created_at>`,
    `<updated_at>${updated}</updated_at>`,
    `</save_memory>`,
  ].join('')
}

const makeErrorContent = (msg = 'content exceeds the 1 MiB per-memory cap') =>
  `<save_memory><error>${msg}</error></save_memory>`

const makeEmptyContent = () => `<save_memory></save_memory>`

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────

describe('SaveMemory.vue — happy path', () => {
  it('renders the tool name pill + truncated id in the header on success', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="save-memory"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('save_memory')
    // Header shows the id (full id is 24 chars; within the flex-1 truncate
    // element, vue's class applies ellipsis at render time but the text
    // content itself is the full id).
    expect(wrapper.text()).toContain('mem_aabbccdd11223344')
    expect(wrapper.text()).toContain('✓')
  })

  it('shows the green ✓ status on success', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    // Status indicator is the second-to-last span in the header (last is
    // the +/− toggle). Both should be present.
    expect(wrapper.text()).toContain('✓')
    expect(wrapper.text()).not.toContain('✗')
  })

  it('does not show the red border on success', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    const root = wrapper.find('[data-testid="save-memory"]')
    expect(root.classes()).not.toContain('border-red-500/50')
  })

  it('renders the copy-id button on success', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="save-memory-copy-id"]').exists()).toBe(true)
  })

  it('hides copy-id button on error (no id to copy)', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent() },
    })
    expect(wrapper.find('[data-testid="save-memory-copy-id"]').exists()).toBe(false)
  })

  it('does NOT auto-expand (parent controls via :expanded prop)', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="save-memory-id-row"]').exists()).toBe(false)
  })

  it('renders id/created_at/updated_at rows when expanded=true', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-id-row"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="save-memory-created-at-row"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="save-memory-updated-at-row"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('mem_aabbccdd11223344')
    expect(wrapper.text()).toContain('2026-08-06 10:00:00')
    expect(wrapper.text()).toContain('2026-08-06 10:05:00')
  })
})

describe('SaveMemory.vue — error path', () => {
  it('renders the error message in red when expanded', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-error"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('content exceeds the 1 MiB per-memory cap')
  })

  it('shows the red � status on error', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent() },
    })
    expect(wrapper.text()).toContain('✗')
  })

  it('applies the red border on error', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent() },
    })
    const root = wrapper.find('[data-testid="save-memory"]')
    expect(root.classes()).toContain('border-red-500/50')
  })

  it('shows "error" in the header label on failure', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent() },
    })
    // Header text is the flex-1 truncate span — verify it includes
    // "error" verbatim.
    expect(wrapper.text()).toContain('error')
    expect(wrapper.text()).not.toContain('mem_')
  })

  it('does not render id/created/updated rows when in error state', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-id-row"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="save-memory-created-at-row"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="save-memory-updated-at-row"]').exists()).toBe(false)
  })
})

describe('SaveMemory.vue — expand/collapse interaction', () => {
  it('clicking the header toggles expanded state', async () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="save-memory-id-row"]').exists()).toBe(false)

    // Click header (the role=button div).
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="save-memory-id-row"]').exists()).toBe(true)

    // Click again — collapses.
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="save-memory-id-row"]').exists()).toBe(false)
  })

  it('clicking the copy-id button does NOT toggle expanded state', async () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
      attachTo: document.body,
    })

    await wrapper.find('[data-testid="save-memory-copy-id"]').trigger('click')
    expect(clipboardWrites).toEqual(['mem_aabbccdd11223344'])
    // Body still collapsed (the click was stopPropagation'd inside the
    // copy handler, so it didn't bubble to the header).
    expect(wrapper.find('[data-testid="save-memory-id-row"]').exists()).toBe(false)

    wrapper.unmount()
  })
})

describe('SaveMemory.vue — empty envelope edge case', () => {
  it('renders an empty-state hint when envelope has no fields', async () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeEmptyContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('no fields in envelope')
  })

  it('still shows ✓ status on an empty envelope (no error tag)', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeEmptyContent() },
    })
    expect(wrapper.text()).toContain('✓')
  })
})
