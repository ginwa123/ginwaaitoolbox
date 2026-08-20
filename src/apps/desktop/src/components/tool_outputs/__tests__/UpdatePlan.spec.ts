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
import { tryUnwrapToolOutput } from '@/helpers/unwrapToolOutput'

// ────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────

const makeSuccessContent = (opts: {
  sessionId?: string
  updatedAt?: string
  /** The markdown body — wrapped in <plan><![CDATA[...]]></plan>. Default:
   *  `''` (no plan block), so tests that don't care about the body just
   *  see session_id + updated_at metadata. Pass a value to render the
   *  checklist section. */
  body?: string
} = {}) => {
  const sessionId = opts.sessionId ?? 's_1787073929852_8'
  const updatedAt = opts.updatedAt ?? '2026-08-19 21:00:00'
  const planBlock =
    opts.body === undefined
      ? ''
      : `<plan><![CDATA[\n${opts.body}\n]]></plan>`
  return [
    `<update_plan>`,
    `<session_id>${sessionId}</session_id>`,
    `<updated_at>${updatedAt}</updated_at>`,
    planBlock,
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
// Description rendering (content from the <plan><![CDATA[...]]></plan>
// block in the response envelope — mirrors get_plan's wire shape).
//
// The backend's `executeUpdatePlan` embeds the just-written body in
// `<plan><![CDATA[...]]></plan>` so the frontend renders the checklist
// directly from the response, NOT from the tool's input arguments.
// Same UX as expanding a GetPlan card — users see what the agent
// just wrote without having to call get_plan separately.
// ────────────────────────────────────────────────────────────────────────

describe('UpdatePlan.vue — plan body from <plan> CDATA', () => {
  it('renders the plan body as a checklist inside the expanded body', async () => {
    const body = '- [x] step 1 done\n- [ ] step 2 todo\n- [ ] step 3 todo'
    const wrapper = mount(UpdatePlan, {
      props: {
        message: { content: makeSuccessContent({ body }) },
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
    const body = '- [x] step 1\n- [ ] step 2'
    const wrapper = mount(UpdatePlan, {
      props: {
        message: { content: makeSuccessContent({ body }) },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')

    // Body from <plan><![CDATA[...]]></plan> starts with a leading
    // \n (the CDATA wrapper inserts one — matches get_plan's wire
    // shape, see `executeGetPlan.zig`), so line 0 is the empty
    // text-row before the checklist proper. Line 1 is "- [x] step 1"
    // (checked -> ☑) and line 2 is "- [ ] step 2" (unchecked -> ☐).
    // Same convention as GetPlan.spec.ts -> "renders ☑/☐".
    const checkedLine = wrapper.find('[data-testid="update-plan-line-1"]')
    const uncheckedLine = wrapper.find('[data-testid="update-plan-line-2"]')
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
    const body = '- [x] step 1\n- [ ] step 2'
    const wrapper = mount(UpdatePlan, {
      props: {
        message: { content: makeSuccessContent({ body }) },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')

    // Line 1 is `- [x] step 1` (after the leading CDATA newline).
    const checkedText = wrapper.find('[data-testid="update-plan-line-1"]').find('span.line-through')
    expect(checkedText.exists()).toBe(true)
    expect(checkedText.text()).toContain('step 1')

    const uncheckedText = wrapper.find('[data-testid="update-plan-line-2"]').find('span.line-through')
    expect(uncheckedText.exists()).toBe(false)
  })

  it('renders plain (non-checklist) lines as text rows', async () => {
    const body = '## Goal\nBuild the whole thing\n\n## Steps\n- [x] step 1'
    const wrapper = mount(UpdatePlan, {
      props: {
        message: { content: makeSuccessContent({ body }) },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')

    expect(wrapper.text()).toContain('Build the whole thing')
    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(true)
  })

  it('does NOT render the plan body when collapsed', () => {
    const body = '- [x] step 1 done'
    const wrapper = mount(UpdatePlan, {
      props: {
        message: { content: makeSuccessContent({ body }) },
      },
    })
    // Default collapsed — no checklist body visible.
    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(false)
  })

  it('falls back gracefully when the envelope has no <plan> block', async () => {
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
    expect(wrapper.find('[data-testid="update-plan-updated-row"]').exists()).toBe(true)
  })

  it('preserves raw <, >, & bytes verbatim inside the CDATA body', async () => {
    const body = '## Notes\nIf arr[i] > 0 && x < 10, then done.'
    const wrapper = mount(UpdatePlan, {
      props: {
        message: { content: makeSuccessContent({ body }) },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')

    // Raw bytes appear verbatim — no XML escape substitution.
    expect(wrapper.text()).toContain('arr[i] > 0')
    expect(wrapper.text()).toContain('x < 10')
    expect(wrapper.text()).toContain('&& x')
    // None of the escape substitutions should appear.
    expect(wrapper.text()).not.toContain('&lt;')
    expect(wrapper.text()).not.toContain('&gt;')
    expect(wrapper.text()).not.toContain('&amp;')
  })

  it('does NOT render the plan body on error', async () => {
    const wrapper = mount(UpdatePlan, {
      props: {
        message: { content: makeErrorContent() },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    // Error path shows the error block, not the plan body.
    expect(wrapper.find('[data-testid="update-plan-error"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(false)
  })
})

// ────────────────────────────────────────────────────────────────────────
// Regression: real ChatView dispatcher path
// ────────────────────────────────────────────────────────────────────────
//
// Pins the wire contract that the BACKEND `executeUpdatePlan` enforces:
// the response envelope embeds `<plan><![CDATA[...]]></plan>` so the
// component can render the checklist directly from `message.content`,
// without depending on the dispatcher threading `parameters` through
// (the agent's input args, which the dispatcher might forget).
//
// The full wire shape the test simulates:
//   <tool>
//     <name>update_plan</name>
//     <parameters>{ "content": "..." }</parameters>  ← ignored by UpdatePlan.vue
//     <success>true</success>
//     <data>
//       <update_plan>
//         <session_id>...</session_id>
//         <updated_at>...</updated_at>
//         <plan><![CDATA[ ... ]]></plan>             ← source of truth
//       </update_plan>
//     </data>
//   </tool>

/** Build a `<tool>...</tool>` envelope with the agent's input args in
 *  `<parameters>` and the just-written plan body in `<plan><![CDATA[...]]></plan>`.
 *  Mirrors the backend's `wrapToolOutput` shape (success path). */
const wrapAsFullToolEnvelope = (
  inner: string,
  parametersJson: string,
): string =>
  '<tool>' +
  '<name>update_plan</name>' +
  `<parameters>${parametersJson}</parameters>` +
  '<success>true</success>' +
  `<data>${inner}</data>` +
  '</tool>'

describe('UpdatePlan.vue — full <tool> envelope from the dispatcher', () => {
  it('renders the checklist when fed the production wire shape (no parameters prop needed)', async () => {
    const body = '- [x] step 1 done\n- [ ] step 2 todo'
    const fullEnvelope = wrapAsFullToolEnvelope(
      makeSuccessContent({ body }),
      JSON.stringify({ content: body }),
    )
    // Sanity-check the unwrap path (ChatView uses it for OTHER
    // components; here we only care that the envelope parses).
    const unwrapped = tryUnwrapToolOutput(fullEnvelope)
    expect(unwrapped).not.toBeNull()

    const wrapper = mount(UpdatePlan, {
      props: {
        // ChatView passes the raw <tool> envelope as message.content
        // — the component extracts the plan body from <plan><![CDATA[...]]></plan>
        // inside the inner <update_plan>, NOT from <parameters>.
        message: { content: fullEnvelope },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')

    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('step 1 done')
    expect(wrapper.text()).toContain('step 2 todo')
    // Metadata strip also renders.
    expect(wrapper.find('[data-testid="update-plan-session-row"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="update-plan-updated-row"]').exists()).toBe(true)
  })

  it('does NOT silently fall back to <parameters> if the <plan> block is missing', async () => {
    // Construct an envelope where <parameters> carries the agent's
    // input but the response envelope's <data> has NO <plan> block
    // (legacy backend, or a backend bug). The component must NOT
    // silently read from <parameters> — that field is the agent's
    // input, not the canonical plan body. The user sees session +
    // updated metadata only (no checklist), which is the safe
    // fallback behavior.
    const body = '- [x] step 1'
    const fullEnvelope = wrapAsFullToolEnvelope(
      makeSuccessContent(), // no body → no <plan> block
      JSON.stringify({ content: body }),
    )

    const wrapper = mount(UpdatePlan, {
      props: {
        message: { content: fullEnvelope },
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')

    // No checklist — because the backend envelope has no <plan> block.
    expect(wrapper.find('[data-testid="update-plan-checklist"]').exists()).toBe(false)
    // Metadata still renders.
    expect(wrapper.find('[data-testid="update-plan-session-row"]').exists()).toBe(true)
  })
})
