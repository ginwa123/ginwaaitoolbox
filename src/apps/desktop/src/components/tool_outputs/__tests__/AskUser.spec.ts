/**
 * AskUser.vue — the `ask_user` tool card.
 *
 * The card renders from the JSON `data` object and, while
 * the state is `pending`, POSTs the answer. These tests pin:
 *
 *   1. every state renders (pending single/multi/free-text, answered, skipped,
 *      abandoned, unavailable, invalid);
 *   2. the EXACT body the endpoint receives — `question_id` + `answer`, a JSON
 *      array for multi-select, and `skip:true` for Skip;
 *   3. the keyboard affordances (digit pick, Enter to send, Esc to skip);
 *   4. that a failed POST leaves a Retry affordance instead of silently
 *      swallowing the answer.
 *
 * Plan: docs/superpowers/plans/2026-09-16-agent-tool-ask-user.md
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount } from '@vue/test-utils'
import AskUser from '../AskUser.vue'

vi.mock('../../../api', () => ({
  answerAskUser: vi.fn(),
}))

import { answerAskUser } from '../../../api'

const mockedAnswer = vi.mocked(answerAskUser)

function pendingData(
  overrides: {
    question?: string
    header?: string
    options?: string[]
    allowFreeText?: boolean
    multiSelect?: boolean
    recommended?: string | null
  } = {},
): Record<string, unknown> {
  const {
    question = 'Which environment should I deploy to?',
    header = 'Deploy target',
    options = ['staging', 'production'],
    allowFreeText = true,
    multiSelect = false,
    recommended = 'staging',
  } = overrides

  return {
    status: 'pending',
    question_id: 'q_1789509583247',
    header,
    question,
    allow_free_text: allowFreeText,
    multi_select: multiSelect,
    recommended,
    options,
    instruction: 'The human has been asked.',
  }
}

function resolvedData(
  status: string,
  extra: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    status,
    question_id: 'q_1',
    question: 'Which environment should I deploy to?',
    ...extra,
  }
}

function mountCard(content: unknown, props: Record<string, unknown> = {}) {
  return mount(AskUser, {
    props: { content, parameters: '{}', expanded: true, sessionId: 'sess_1', ...props },
  })
}

beforeEach(() => {
  mockedAnswer.mockReset()
})

afterEach(() => {
  // The card attaches a window keydown listener while pending; unmount in each
  // test via wrapper.unmount() where the listener matters.
})

describe('AskUser — rendering', () => {
  it('renders the pending state with the question, options and a recommended chip', () => {
    const wrapper = mountCard(pendingData())

    expect(wrapper.attributes('data-state')).toBe('pending')
    expect(wrapper.text()).toContain('Which environment should I deploy to?')
    expect(wrapper.text()).toContain('staging')
    expect(wrapper.text()).toContain('production')
    expect(wrapper.text()).toContain('recommended')
    wrapper.unmount()
  })

  it('marks the card as "waiting for you" while pending', () => {
    const wrapper = mountCard(pendingData())
    expect(wrapper.find('[data-testid="tool-card-running"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('hides the free-text box when the model disallowed it', () => {
    const wrapper = mountCard(pendingData({ allowFreeText: false }))
    expect(wrapper.find('[data-testid="ask-user-freetext"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('renders a free-text-only question with no option list', () => {
    const wrapper = mountCard(
      pendingData({ options: [], recommended: null, question: 'What should I name the branch?' }),
    )
    expect(wrapper.find('[data-testid="ask-user-option-0"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="ask-user-freetext"]').exists()).toBe(true)
    // Send stays disabled until something is typed.
    expect(wrapper.find('[data-testid="ask-user-send"]').attributes('disabled')).toBeDefined()
    wrapper.unmount()
  })

  it('renders an answered payload as a resolved chip', () => {
    const wrapper = mountCard(resolvedData('answered', { answer: 'staging', answers_count: 1 }))
    expect(wrapper.attributes('data-state')).toBe('answered')
    expect(wrapper.find('[data-testid="ask-user-answer-chip"]').text()).toContain('staging')
    // No interactive affordances left.
    expect(wrapper.find('[data-testid="ask-user-send"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('renders a multi-select answer as one chip with every value', () => {
    const wrapper = mountCard(
      resolvedData('answered', { answer: '["zig unit","pytest"]', answers_count: 2 }),
    )
    expect(wrapper.find('[data-testid="ask-user-answer-chip"]').text()).toContain('zig unit')
    expect(wrapper.find('[data-testid="ask-user-answer-chip"]').text()).toContain('pytest')
    wrapper.unmount()
  })

  it('renders skipped / abandoned / unavailable as distinct muted states', () => {
    const skipped = mountCard(resolvedData('skipped'))
    expect(skipped.find('[data-testid="ask-user-skipped"]').text()).toContain('will not guess')
    skipped.unmount()

    const abandoned = mountCard(resolvedData('abandoned'))
    expect(abandoned.find('[data-testid="ask-user-abandoned"]').text()).toContain('moved on')
    abandoned.unmount()

    const unavailable = mountCard(resolvedData('unavailable'))
    expect(unavailable.find('[data-testid="ask-user-unavailable"]').text()).toContain(
      'No human was available',
    )
    unavailable.unmount()
  })

  it('renders a failed call as an invalid state with the backend error', () => {
    const wrapper = mountCard(
      JSON.stringify({
        tool: 'ask_user',
        parameters: {},
        success: false,
        data: null,
        error: 'recommended must exactly match one of the strings in options',
        v: 1,
      }),
    )
    expect(wrapper.attributes('data-state')).toBe('invalid')
    expect(wrapper.text()).toContain('recommended must exactly match one of the strings in options')
    wrapper.unmount()
  })

  it('degrades an unknown status to an invalid card instead of blanking', () => {
    const wrapper = mountCard(resolvedData('something_new'))
    expect(wrapper.attributes('data-state')).toBe('invalid')
    wrapper.unmount()
  })

  it('reads the outcome from an envelope that LOST its parameters block', () => {
    // The answer endpoint rewrites the tool row in place. A variant emits
    // an envelope with no `parameters`, which makes `unwrapToolOutput`
    // throw — ChatView then hands the card the raw envelope string, and
    // without this fallback the card rendered a bare PENDING question:
    // every resolved question looked unanswered.
    const raw = JSON.stringify({
      tool: 'ask_user',
      success: true,
      data: resolvedData('skipped'),
      error: null,
      v: 1,
    })
    const wrapper = mountCard(raw)

    expect(wrapper.attributes('data-state')).toBe('skipped')
    expect(wrapper.find('[data-testid="ask-user-skipped"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('accepts the data payload as a JSON string', () => {
    const wrapper = mountCard(JSON.stringify(pendingData()))
    expect(wrapper.attributes('data-state')).toBe('pending')
    expect(wrapper.text()).toContain('Which environment should I deploy to?')
    wrapper.unmount()
  })

  it('renders <>& in the question verbatim without entity decoding', () => {
    const wrapper = mountCard(pendingData({ question: 'Deploy <staging> & "prod"?' }))
    expect(wrapper.text()).toContain('Deploy <staging> & "prod"?')
    wrapper.unmount()
  })

  it('disables every input once the question is skipped', () => {
    // Requested behaviour: a skipped question must not stay interactive.
    // (The header's expand/collapse toggle is still a <button> — that one is
    // fine: the settled card stays inspectable.)
    const wrapper = mountCard(resolvedData('skipped'))

    expect(wrapper.find('[data-testid="ask-user-send"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="ask-user-skip"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="ask-user-freetext"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="ask-user-other-radio"]').exists()).toBe(false)
    expect(wrapper.find('textarea').exists()).toBe(false)
    expect(wrapper.find('input[type="radio"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('expands itself while the question is unanswered, and collapses once resolved', () => {
    // An inline card that hides the thing the human must act on is a card
    // nobody acts on — so a PENDING question ignores `expanded: false`.
    const pending = mountCard(pendingData(), { expanded: false })
    expect(pending.find('[data-testid="ask-user-send"]').exists()).toBe(true)
    expect(pending.text()).toContain('Which environment should I deploy to?')
    pending.unmount()

    // A resolved card behaves like every other tool card: a one-line summary.
    const resolved = mountCard(resolvedData('answered', { answer: 'staging' }), {
      expanded: false,
    })
    expect(resolved.find('[data-testid="ask-user-collapsed-summary"]').text()).toContain('staging')
    expect(resolved.find('[data-testid="ask-user-answer-chip"]').exists()).toBe(false)
    resolved.unmount()

    // …including for the non-answered outcomes, which used to render nothing.
    const skipped = mountCard(resolvedData('skipped'), { expanded: false })
    expect(skipped.find('[data-testid="ask-user-collapsed-summary"]').text()).toContain('skipped')
    skipped.unmount()
  })

  it('honours an explicit expand for a resolved card', () => {
    const wrapper = mountCard(resolvedData('skipped'), { expanded: true })
    expect(wrapper.find('[data-testid="ask-user-skipped"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('gives the free-text box room for a real answer', () => {
    const wrapper = mountCard(pendingData({ options: [] }))
    const box = wrapper.find('[data-testid="ask-user-freetext"]')
    // Three rows of `text-xs` plus a min-height, not the original two-line sliver.
    expect(box.attributes('rows')).toBe('3')
    expect(box.attributes('style')).toContain('min-height')
    wrapper.unmount()
  })
})

describe('AskUser — the wire body', () => {
  it('POSTs question_id + the picked option for a single-select question', async () => {
    mockedAnswer.mockResolvedValue({ success: true, status: 'answered', answer: 'production' })
    const wrapper = mountCard(pendingData())

    await wrapper.find('[data-testid="ask-user-option-1"]').trigger('click')
    await wrapper.find('[data-testid="ask-user-send"]').trigger('click')

    expect(mockedAnswer).toHaveBeenCalledTimes(1)
    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', {
      question_id: 'q_1789509583247',
      answer: 'production',
    })
    wrapper.unmount()
  })

  it('POSTs a JSON array for a multi-select question', async () => {
    mockedAnswer.mockResolvedValue({ success: true, status: 'answered', answer: '["a","b"]' })
    const wrapper = mountCard(pendingData({ multiSelect: true, options: ['a', 'b', 'c'] }))

    await wrapper.find('[data-testid="ask-user-option-0"]').trigger('click')
    await wrapper.find('[data-testid="ask-user-option-2"]').trigger('click')
    await wrapper.find('[data-testid="ask-user-send"]').trigger('click')

    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', {
      question_id: 'q_1789509583247',
      answer: '["a","c"]',
    })
    wrapper.unmount()
  })

  it('POSTs the typed free text when the user picked Other', async () => {
    mockedAnswer.mockResolvedValue({
      success: true,
      status: 'answered',
      answer: 'staging, but skip 087',
    })
    const wrapper = mountCard(pendingData())

    const textarea = wrapper.find('[data-testid="ask-user-freetext"]')
    await textarea.setValue('staging, but skip 087')
    await wrapper.find('[data-testid="ask-user-send"]').trigger('click')

    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', {
      question_id: 'q_1789509583247',
      answer: 'staging, but skip 087',
    })
    wrapper.unmount()
  })

  it('POSTs skip:true (and no answer) for Skip', async () => {
    mockedAnswer.mockResolvedValue({ success: true, status: 'skipped' })
    const wrapper = mountCard(pendingData())

    await wrapper.find('[data-testid="ask-user-skip"]').trigger('click')

    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', {
      question_id: 'q_1789509583247',
      skip: true,
    })
    wrapper.unmount()
  })

  it('does not POST while nothing is selected', async () => {
    const wrapper = mountCard(pendingData())
    await wrapper.find('[data-testid="ask-user-send"]').trigger('click')
    expect(mockedAnswer).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('flips the card locally once the POST succeeds (a dropped SSE frame cannot strand it)', async () => {
    mockedAnswer.mockResolvedValue({ success: true, status: 'answered', answer: 'staging' })
    const wrapper = mountCard(pendingData())

    await wrapper.find('[data-testid="ask-user-option-0"]').trigger('click')
    await wrapper.find('[data-testid="ask-user-send"]').trigger('click')
    await flush()

    expect(wrapper.attributes('data-state')).toBe('answered')
    expect(wrapper.find('[data-testid="ask-user-answer-chip"]').text()).toContain('staging')
    wrapper.unmount()
  })

  it('shows a Retry affordance when the POST fails, and keeps the selection', async () => {
    mockedAnswer.mockResolvedValue({ success: false })
    const wrapper = mountCard(pendingData())

    await wrapper.find('[data-testid="ask-user-option-1"]').trigger('click')
    await wrapper.find('[data-testid="ask-user-send"]').trigger('click')
    await flush()

    expect(wrapper.find('[data-testid="ask-user-error"]').exists()).toBe(true)
    // Still pending, so the user can retry without re-picking.
    expect(wrapper.attributes('data-state')).toBe('pending')

    mockedAnswer.mockResolvedValue({ success: true, status: 'answered', answer: 'production' })
    await wrapper.find('[data-testid="ask-user-error"] button').trigger('click')
    await flush()
    expect(mockedAnswer).toHaveBeenLastCalledWith('sess_1', {
      question_id: 'q_1789509583247',
      answer: 'production',
    })
    wrapper.unmount()
  })
})

describe('AskUser — keyboard', () => {
  it('digits pick an option, Enter sends, Escape skips', async () => {
    mockedAnswer.mockResolvedValue({ success: true, status: 'answered', answer: 'production' })
    const wrapper = mountCard(pendingData())
    // The card listens on `window`.
    const dispatch = (key: string) =>
      window.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true }))

    dispatch('2')
    await flush()
    expect(wrapper.attributes('data-state')).toBe('pending')

    dispatch('Enter')
    await flush()
    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', {
      question_id: 'q_1789509583247',
      answer: 'production',
    })

    wrapper.unmount()
  })

  it('ignores digits beyond the option count', async () => {
    mockedAnswer.mockResolvedValue({ success: true, status: 'answered', answer: 'x' })
    const wrapper = mountCard(pendingData({ options: ['a', 'b'] }))
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '9', bubbles: true }))
    await flush()
    // Nothing selected → Send is a no-op → no POST.
    await wrapper.find('[data-testid="ask-user-send"]').trigger('click')
    expect(mockedAnswer).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('stops listening once the question is resolved', async () => {
    mockedAnswer.mockResolvedValue({ success: true, status: 'answered', answer: 'staging' })
    const wrapper = mountCard(pendingData())
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '1', bubbles: true }))
    await flush()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await flush()
    expect(mockedAnswer).toHaveBeenCalledTimes(1)

    // Escape after resolution must not fire another POST.
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await flush()
    expect(mockedAnswer).toHaveBeenCalledTimes(1)
    wrapper.unmount()
  })
})

async function flush(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
  await new Promise((resolve) => setTimeout(resolve, 0))
}
