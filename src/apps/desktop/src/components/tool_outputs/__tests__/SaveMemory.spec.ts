/**
 * Tests for SaveMemory.vue.
 *
 * Verifies:
 *  - parses the success envelope (id + created_at + updated_at)
 *  - parses the error envelope (<error> tag → red border, no rows)
 *  - header label shows the truncated id + a body preview on success,
 *    "error" on failure
 *  - expanded body is exactly three things: id, tags, content (the
 *    timestamps live in the header hover title, not in rows)
 *  - renders the SAVED BODY + tags from the tool-call args (`parameters`),
 *    because `executeSaveMemory` never echoes the note back
 *  - hides `content` from the Arguments block; copy button yields the full
 *    (unclipped) body
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
  return { id, created_at: created, updated_at: updated }
}

const makeErrorContent = (msg = 'content exceeds the 1 MiB per-memory cap') => ({ error: msg })

const makeEmptyContent = () => ({})

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

  it('renders only the id row when expanded=true (no timestamp rows)', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-id-row"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('mem_aabbccdd11223344')
    // Timestamps are not rows — they moved to the header hover title.
    expect(wrapper.find('[data-testid="save-memory-created-at-row"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="save-memory-updated-at-row"]').exists()).toBe(false)
    expect(wrapper.text()).not.toContain('2026-08-06 10:00:00')
    expect(wrapper.text()).not.toContain('2026-08-06 10:05:00')
  })

  it('keeps the saved timestamp reachable in the header hover title', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    const title = wrapper.find('[data-testid="save-memory-header-label"]').attributes('title')
    expect(title).toContain('saved 2026-08-06 10:00:00')
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

  it('does not render the id row when in error state', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeErrorContent(), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-id-row"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="save-memory-content-row"]').exists()).toBe(false)
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

// ────────────────────────────────────────────────────────────────────────
// The saved body. `executeSaveMemory` deliberately does NOT echo the
// stored note back (1 KiB–1 MiB would blow the LLM's context), so the card
// reads `content` / `tags` from the tool-call args in `parameters`.
// ────────────────────────────────────────────────────────────────────────

const BODY = 'The user prefers dark mode for the editor and pnpm over npm.'
const TAGS = 'preferences||user'

const makeParams = (content: string, tags: string | null = TAGS) =>
  JSON.stringify(tags === null ? { content } : { content, tags })

describe('SaveMemory.vue — saved body', () => {
  it('renders the note body from the tool-call args when expanded', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-content-row"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="save-memory-content"]').text()).toBe(BODY)
  })

  it('hides the body until the card is expanded', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY) },
    })
    expect(wrapper.find('[data-testid="save-memory-content"]').exists()).toBe(false)
  })

  it('reads the body from XML-shaped parameters too', () => {
    const wrapper = mount(SaveMemory, {
      props: {
        content: makeSuccessContent(),
        parameters: `<content>${BODY}</content><tags>preferences||user</tags>`,
        expanded: true,
      },
    })
    expect(wrapper.find('[data-testid="save-memory-content"]').text()).toBe(BODY)
  })

  it('prefers data.content over the call args when the backend echoes it', () => {
    const wrapper = mount(SaveMemory, {
      props: {
        content: { ...makeSuccessContent(), content: 'body from result envelope' },
        parameters: makeParams(BODY),
        expanded: true,
      },
    })
    expect(wrapper.find('[data-testid="save-memory-content"]').text()).toBe(
      'body from result envelope',
    )
  })

  it('renders tags as individual chips (|| separated)', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-tags-row"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="save-memory-tag-0"]').text()).toBe('preferences')
    expect(wrapper.find('[data-testid="save-memory-tag-1"]').text()).toBe('user')
  })

  it('splits tags sent with the | separator the LLM often uses', () => {
    const wrapper = mount(SaveMemory, {
      props: {
        content: makeSuccessContent(),
        parameters: makeParams(BODY, 'demo|tool-test|nalar'),
        expanded: true,
      },
    })
    expect(wrapper.findAll('[data-testid^="save-memory-tag-"]')).toHaveLength(3)
  })

  it('omits the tags row when no tags were sent', () => {
    const wrapper = mount(SaveMemory, {
      props: {
        content: makeSuccessContent(),
        parameters: makeParams(BODY, null),
        expanded: true,
      },
    })
    expect(wrapper.find('[data-testid="save-memory-tags-row"]').exists()).toBe(false)
  })

  it('shows a size + line-count badge for the body', () => {
    const wrapper = mount(SaveMemory, {
      props: {
        content: makeSuccessContent(),
        parameters: makeParams('line one\nline two'),
        expanded: true,
      },
    })
    const badge = wrapper.find('[data-testid="save-memory-content-size"]').text()
    expect(badge).toContain('B · 2 lines')
  })

  it('previews the body in the header, after the id, on one line', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams('line one\nline two') },
    })
    const label = wrapper.find('[data-testid="save-memory-header-label"]').text()
    // Newlines are collapsed so a multi-line note still fits the header row.
    expect(label).toBe('mem_aabbccdd11223344 · line one line two')
  })

  it('puts the full body in the header hover title', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY) },
    })
    const title = wrapper.find('[data-testid="save-memory-header-label"]').attributes('title')
    expect(title).toContain(BODY)
  })

  it('leaves the header as the bare id when there is no body', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent() },
    })
    expect(wrapper.find('[data-testid="save-memory-header-label"]').text()).toBe(
      'mem_aabbccdd11223344',
    )
  })

  it('hides content from the Arguments block so it is not repeated', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY), expanded: true },
    })
    // The Arguments <details> keeps `tags` but must not re-print the body.
    const argsBlock = wrapper.find('details')
    expect(argsBlock.exists()).toBe(true)
    expect(argsBlock.text()).not.toContain(BODY)
    expect(argsBlock.text()).toContain('preferences')
  })

  it('copies the full body without collapsing the card', async () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(BODY) },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    await wrapper.find('[data-testid="save-memory-copy-content"]').trigger('click')
    expect(clipboardWrites).toEqual([BODY])
    // The click was stopPropagation'd — the card is still expanded.
    expect(wrapper.find('[data-testid="save-memory-content"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('clips an over-long body for display but still copies all of it', async () => {
    const long = 'x'.repeat(25000)
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: makeParams(long), expanded: true },
      attachTo: document.body,
    })
    const rendered = wrapper.find('[data-testid="save-memory-content"]').text()
    expect(rendered).toHaveLength(20000)
    const note = wrapper.find('[data-testid="save-memory-content-clipped"]')
    expect(note.exists()).toBe(true)
    expect(note.text()).toContain('5,000 more characters not shown')

    await wrapper.find('[data-testid="save-memory-copy-content"]').trigger('click')
    expect(clipboardWrites).toEqual([long])
    wrapper.unmount()
  })

  it('renders no content row when the args carry no body', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: makeSuccessContent(), parameters: '{}', expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-content-row"]').exists()).toBe(false)
  })

  it('shows the body of a still-running call (result envelope empty)', () => {
    const wrapper = mount(SaveMemory, {
      props: { content: '', parameters: makeParams(BODY), expanded: true },
    })
    expect(wrapper.find('[data-testid="save-memory-running"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="save-memory-content"]').text()).toBe(BODY)
  })
})
