/**
 * Tests for UpdatePlan.vue.
 *
 * Verifies:
 *  - parses the success envelope (session_id + updated_at)
 *  - parses the error envelope (<error> tag → red border, no rows)
 *  - header label shows the session_id on success, "error" on failure
 *  - expanded body renders the session_id + updated_at rows
 *  - empty envelope (no session_id, no updated_at) renders an empty-state hint
 *  - click on header toggles expanded state
 *  - inner envelope extraction works both with and without the <tool> wrapper
 */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import UpdatePlan from '../UpdatePlan.vue'

// ────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────

const makeSuccessContent = (opts: {
  sessionId?: string
  updatedAt?: string
} = {}) => {
  const sessionId = opts.sessionId ?? 's_1787073929852_8'
  const updatedAt = opts.updatedAt ?? '2026-08-19 21:00:00'
  return [
    `<update_plan>`,
    `<session_id>${sessionId}</session_id>`,
    `<updated_at>${updatedAt}</updated_at>`,
    `</update_plan>`,
  ].join('')
}

const makeErrorContent = (msg = 'session_id mismatch') =>
  `<update_plan><error>${msg}</error></update_plan>`

const makeEmptyContent = () => `<update_plan></update_plan>`

/**
 * Wrap the inner envelope in the full `<tool>...</tool>` wire shape the
 * dispatcher actually passes through. Mirrors the backend's `wrapToolOutput`
 * (which is one of the two shapes the component's `findInnerEnvelope`
 * regex must defensively handle).
 */
const wrapInToolEnvelope = (inner: string): string =>
  '<tool>' +
  '<name>tool</name>' +
  '<parameters>{}</parameters>' +
  '<success>true</success>' +
  `<data>${inner}</data>` +
  '</tool>'

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────

describe('UpdatePlan.vue — happy path', () => {
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

  it('renders the tool name pill + session_id in the header on success', () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeSuccessContent() } },
    })
    expect(wrapper.find('[data-testid="update-plan"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('update_plan')
    expect(wrapper.text()).toContain('s_1787073929852_8')
  })

  it('shows the green ✓ status on success', () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeSuccessContent() } },
    })
    expect(wrapper.text()).toContain('✓')
    expect(wrapper.text()).not.toContain('✗')
  })

  it('does not show the red border on success', () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeSuccessContent() } },
    })
    const root = wrapper.find('[data-testid="update-plan"]')
    expect(root.classes()).not.toContain('border-red-500/50')
  })

  it('shows the updated_at timestamp in the right meta', () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeSuccessContent() } },
    })
    expect(wrapper.text()).toContain('2026-08-19 21:00:00')
  })

  it('does NOT auto-expand (collapsed by default)', () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeSuccessContent() } },
    })
    expect(wrapper.find('[data-testid="update-plan-session-row"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="update-plan-updated-row"]').exists()).toBe(false)
  })

  it('renders session_id + updated_at rows when expanded', async () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeSuccessContent() } },
      attachTo: document.body,
    })

    // Click the header to expand.
    await wrapper.find('[role="button"]').trigger('click')

    expect(wrapper.find('[data-testid="update-plan-session-row"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="update-plan-updated-row"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('s_1787073929852_8')
    expect(wrapper.text()).toContain('2026-08-19 21:00:00')
  })

  it('renders the Session and Updated labels in the expanded body', async () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeSuccessContent() } },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).toContain('Session:')
    expect(wrapper.text()).toContain('Updated:')
  })

  it('clicking the header a second time collapses the body', async () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeSuccessContent() } },
      attachTo: document.body,
    })

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="update-plan-session-row"]').exists()).toBe(true)

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="update-plan-session-row"]').exists()).toBe(false)
  })
})

describe('UpdatePlan.vue — error path', () => {
  it('renders the error message in red when expanded', async () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeErrorContent() } },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="update-plan-error"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('session_id mismatch')
  })

  it('shows the red ✗ status on error', () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeErrorContent() } },
    })
    expect(wrapper.text()).toContain('✗')
  })

  it('applies the red border on error', () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeErrorContent() } },
    })
    const root = wrapper.find('[data-testid="update-plan"]')
    expect(root.classes()).toContain('border-red-500/50')
  })

  it('shows "error" as the primary label on failure', () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeErrorContent() } },
    })
    expect(wrapper.text()).toContain('error')
    expect(wrapper.text()).not.toContain('s_1787073929852_8')
  })

  it('does not render session_id or updated_at rows when in error state', async () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeErrorContent() } },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="update-plan-session-row"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="update-plan-updated-row"]').exists()).toBe(false)
  })

  it('shows the error message text in the right meta when collapsed', () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeErrorContent('database is locked') } },
    })
    expect(wrapper.text()).toContain('database is locked')
  })
})

describe('UpdatePlan.vue — empty envelope edge case', () => {
  it('renders an empty-state hint when envelope has no fields', async () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeEmptyContent() } },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="update-plan-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('no fields in envelope')
  })

  it('still shows ✓ status on an empty envelope (no error tag)', () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeEmptyContent() } },
    })
    expect(wrapper.text()).toContain('✓')
  })

  it('does not show the red border on an empty envelope', () => {
    const wrapper = mount(UpdatePlan, {
      props: { message: { content: makeEmptyContent() } },
    })
    const root = wrapper.find('[data-testid="update-plan"]')
    expect(root.classes()).not.toContain('border-red-500/50')
  })

  it('falls back to "unknown session" when session_id is missing on success', () => {
    const wrapper = mount(UpdatePlan, {
      props: {
        message: {
          content: `<update_plan><updated_at>2026-08-19 21:00:00</updated_at></update_plan>`,
        },
      },
    })
    expect(wrapper.text()).toContain('unknown session')
  })
})

describe('UpdatePlan.vue — inner envelope extraction', () => {
  it('finds the inner <update_plan> envelope inside a <tool> wrapper', async () => {
    const wrapper = mount(UpdatePlan, {
      props: {
        message: {
          content: wrapInToolEnvelope(makeSuccessContent()),
        },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="update-plan-session-row"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('s_1787073929852_8')
  })

  it('handles a raw <update_plan> envelope (no <tool> wrapper)', async () => {
    const wrapper = mount(UpdatePlan, {
      props: {
        message: { content: makeSuccessContent() },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="update-plan-session-row"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('s_1787073929852_8')
  })

  it('treats an unrecognised envelope as empty (no error tag, no fields)', async () => {
    const wrapper = mount(UpdatePlan, {
      props: {
        message: { content: '<foo>bar</foo>' },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="update-plan-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('✓')
  })
})

// ────────────────────────────────────────────────────────────────────────
// Description rendering (content from `parameters` JSON).
//
// The agent's input to `update_plan` is `{"content": "## Goal\n..."}`.
// That JSON lives in `msg.parameters` (the dispatcher's
// `getParametersForMessage(msg)` helper). We extract `content` from
// there and render it as a checklist — same UX as expanding a
// GetPlan card — so users see what the agent just wrote without
// having to call get_plan separately.
// ────────────────────────────────────────────────────────────────────────

/** Helper: build the JSON-stringified parameters payload an
 *  update_plan tool call would carry. */
const makeParameters = (content: string): string =>
  JSON.stringify({ content })

describe('UpdatePlan.vue — description from parameters', () => {
  it('renders the description as a checklist inside the expanded body', async () => {
    const content = '- [x] step 1 done\n- [ ] step 2 todo\n- [ ] step 3 todo'
    const wrapper = mount(UpdatePlan, {
      props: {
        message: {
          content: makeSuccessContent(),
          parameters: makeParameters(content),
        },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')

    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('step 1 done')
    expect(wrapper.text()).toContain('step 2 todo')
    expect(wrapper.text()).toContain('step 3 todo')
  })

  it('renders ☐ for unchecked items and ☑ for checked items', async () => {
    const content = '- [x] step 1\n- [ ] step 2'
    const wrapper = mount(UpdatePlan, {
      props: {
        message: {
          content: makeSuccessContent(),
          parameters: makeParameters(content),
        },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')

    // Content from `parameters` is raw markdown without a leading \n,
    // so line 0 is "- [x] step 1" (checked) → ☑, line 1 is "- [ ] step 2"
    // (unchecked) → ☐.
    const checkedLine = wrapper.find('[data-testid="update-plan-line-0"]')
    const uncheckedLine = wrapper.find('[data-testid="update-plan-line-1"]')
    expect(checkedLine.exists()).toBe(true)
    expect(uncheckedLine.exists()).toBe(true)
    expect(checkedLine.attributes('data-kind')).toBe('checked')
    expect(uncheckedLine.attributes('data-kind')).toBe('unchecked')

    const checkedGlyph = checkedLine.find('span').text()
    const uncheckedGlyph = uncheckedLine.find('span').text()
    expect(checkedGlyph).toBe('☑')
    expect(uncheckedGlyph).toBe('☐')
  })

  it('applies line-through to checked items', async () => {
    const content = '- [x] step 1\n- [ ] step 2'
    const wrapper = mount(UpdatePlan, {
      props: {
        message: {
          content: makeSuccessContent(),
          parameters: makeParameters(content),
        },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')

    const checkedText = wrapper.find('[data-testid="update-plan-line-0"]').find('span.line-through')
    expect(checkedText.exists()).toBe(true)
    expect(checkedText.text()).toContain('step 1')

    const uncheckedText = wrapper.find('[data-testid="update-plan-line-1"]').find('span.line-through')
    expect(uncheckedText.exists()).toBe(false)
  })

  it('renders plain (non-checklist) lines as text rows', async () => {
    const content = '## Goal\nBuild the whole thing\n\n## Steps\n- [x] step 1'
    const wrapper = mount(UpdatePlan, {
      props: {
        message: {
          content: makeSuccessContent(),
          parameters: makeParameters(content),
        },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')

    expect(wrapper.text()).toContain('Build the whole thing')
    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(true)
  })

  it('does NOT render the description when collapsed', () => {
    const content = '- [x] step 1 done'
    const wrapper = mount(UpdatePlan, {
      props: {
        message: {
          content: makeSuccessContent(),
          parameters: makeParameters(content),
        },
      },
    })
    // Default collapsed — no checklist body visible.
    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(false)
  })

  it('falls back gracefully when parameters is missing', async () => {
    const wrapper = mount(UpdatePlan, {
      props: {
        message: { content: makeSuccessContent() },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(false)
    // Existing session/updated rows still render.
    expect(wrapper.find('[data-testid="update-plan-session-row"]').exists()).toBe(true)
  })

  it('falls back gracefully when parameters is malformed JSON', async () => {
    const wrapper = mount(UpdatePlan, {
      props: {
        message: {
          content: makeSuccessContent(),
          parameters: 'not valid json {{',
        },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="update-plan-session-row"]').exists()).toBe(true)
  })

  it('falls back gracefully when parameters has no content field', async () => {
    const wrapper = mount(UpdatePlan, {
      props: {
        message: {
          content: makeSuccessContent(),
          parameters: JSON.stringify({ other: 'field' }),
        },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="update-plan-session-row"]').exists()).toBe(true)
  })

  it('falls back gracefully when parameters.content is empty string', async () => {
    const wrapper = mount(UpdatePlan, {
      props: {
        message: {
          content: makeSuccessContent(),
          parameters: JSON.stringify({ content: '' }),
        },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(false)
  })

  it('does NOT render the description on error', async () => {
    const content = '- [x] step 1'
    const wrapper = mount(UpdatePlan, {
      props: {
        message: {
          content: makeErrorContent(),
          parameters: makeParameters(content),
        },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    // Error path shows the error block, not the description.
    expect(wrapper.find('[data-testid="update-plan-error"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(false)
  })
})
