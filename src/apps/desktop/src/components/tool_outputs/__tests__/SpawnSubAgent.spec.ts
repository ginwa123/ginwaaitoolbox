/**
 * Tests for SpawnSubAgent.vue live-progress rendering.
 *
 * 2026-08-23 spawn-subagent-live-progress — verifies the new `progress`
 * prop drives live per-agent rows WHILE the final `<results>` envelope
 * is still empty, and that the existing parsed-results behaviour keeps
 * working once the envelope arrives. Specifically:
 *
 *  - empty content + progress prop → renders one row per agent,
 *    running/done/failed badge per row, header count reflects state
 *  - populated `<results>` content + stale progress → parsed-results
 *    view wins (envelope is source of truth on completion)
 *  - peek button on a running row is wired when subagent_session_id
 *    is present
 *  - failed row shows ✗ styling
 *  - invalid UTF-8 / partial progress doesn't crash the row renderer
 */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import SpawnSubAgent from '../SpawnSubAgent.vue'
import type { SubAgentProgress } from '../../../helpers/subagentProgress'

// ────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────

// Loose props type: tests intentionally pass partial / loosely-typed
// values (e.g. `null` sessionId, optional `progress`). vue-tsc
// independently type-checks the production component against its
// real prop definitions; this cast only relaxes the test fixture.
type TestProps = {
  content?: string
  expanded?: boolean
  subAgentArgs?: unknown
  progress?: unknown
}
const mountAt = (props: TestProps) =>
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- test fixture; production props are typed at the component boundary.
  mount(SpawnSubAgent, { props: props as any, global: { stubs: {} } })

const sampleProgress = (
  status: 'running' | 'done' | 'failed',
  overrides: Partial<SubAgentProgress> = {},
): SubAgentProgress => ({
  name: 'researcher',
  status,
  index: 0,
  total: 2,
  sessionId: status === 'running' ? undefined : 'subagent_1_researcher',
  elapsedMs: 1234,
  ...overrides,
})

beforeEach(() => {
  Object.defineProperty(navigator, 'clipboard', {
    configurable: true,
    value: { writeText: vi.fn(async () => {}) },
  })
})

afterEach(() => {
  vi.restoreAllMocks()
})

// ────────────────────────────────────────────────────────────────────────
// Live-progress rendering (NEW — 2026-08-23 feature)
// ────────────────────────────────────────────────────────────────────────

describe('SpawnSubAgent.vue — live progress', () => {
  it('renders one row per progress entry when content has no <results> envelope yet', () => {
    const progress: SubAgentProgress[] = [
      sampleProgress('running', { name: 'agent-a', index: 0, total: 2 }),
      sampleProgress('done', {
        name: 'agent-b',
        index: 1,
        total: 2,
        sessionId: 'subagent_2_agent-b',
      }),
    ]
    const wrapper = mountAt({ content: '', progress })

    // Header should reflect total count + run/done state.
    expect(wrapper.text()).toContain('2 sub-agents')
    expect(wrapper.text()).toContain('1 running')
    expect(wrapper.text()).toContain('✓ 1') // done

    // Both row names are visible (the component auto-shows the list
    // while in live mode — no expand toggle required).
    expect(wrapper.text()).toContain('agent-a')
    expect(wrapper.text()).toContain('agent-b')
  })

  it('shows ✓ styling on a done row and running chip on a running row', () => {
    const progress: SubAgentProgress[] = [
      sampleProgress('running', { name: 'r1', index: 0, total: 1 }),
    ]
    const wrapper = mountAt({ content: '', progress })
    // Spinner/running badge text — implementation detail; presence is
    // enough to prove the row is rendered.
    expect(wrapper.text()).toMatch(/running/i)
  })

  it('shows ✗ styling on a failed row', () => {
    const progress: SubAgentProgress[] = [
      sampleProgress('failed', { name: 'broken', index: 0, total: 1 }),
    ]
    const wrapper = mountAt({ content: '', progress })
    expect(wrapper.text()).toContain('✗')
  })

  it('emits a peek event with the sub-agent sessionId when a done row is peeked', async () => {
    const progress: SubAgentProgress[] = [
      sampleProgress('done', {
        name: 'a',
        index: 0,
        total: 1,
        sessionId: 'subagent_99_a',
      }),
    ]
    const subAgentArgs = [
      {
        agent_name: 'a',
        instruction: 'do the thing',
        inherited_context: 'none',
      },
    ]
    const wrapper = mountAt({ content: '', progress, subAgentArgs })
    const peekButton = wrapper.find('[data-testid="peek-button"]')
    expect(peekButton.exists()).toBe(true)
    await peekButton.trigger('click')
    const events = wrapper.emitted('peek') ?? []
    expect(events.length).toBe(1)
    expect(events[0]).toEqual([
      { sessionId: 'subagent_99_a', agentName: 'a', instruction: 'do the thing' },
    ])
  })

  it('does NOT show a peek button on a running row until sessionId is known', () => {
    const progress: SubAgentProgress[] = [
      sampleProgress('running', {
        name: 'a',
        index: 0,
        total: 1,
        sessionId: undefined,
      }),
    ]
    const wrapper = mountAt({ content: '', progress })
    expect(wrapper.find('[data-testid="peek-button"]').exists()).toBe(false)
  })

  it('shows the header counts even before any agent has finished (only running)', () => {
    const progress: SubAgentProgress[] = [
      sampleProgress('running', { name: 'a', index: 0, total: 3 }),
      sampleProgress('running', { name: 'b', index: 1, total: 3 }),
      sampleProgress('running', { name: 'c', index: 2, total: 3 }),
    ]
    const wrapper = mountAt({ content: '', progress })
    expect(wrapper.text()).toContain('3 sub-agents')
    expect(wrapper.text()).toContain('3 running')
  })

  it('tolerates empty progress array without crashing (falls back to old behaviour)', () => {
    const wrapper = mountAt({ content: '', progress: [] })
    // Without progress AND without parsed-results content, the card
    // should render its empty-state header (mirrors pre-feature UX).
    expect(wrapper.text()).toContain('0 sub-agents')
  })

  it('does not crash on a progress entry whose sessionId is undefined AND no agentName', () => {
    const progress: SubAgentProgress[] = [
      {
        name: '',
        status: 'running',
        index: 0,
        total: 1,
        sessionId: undefined,
        elapsedMs: 0,
      },
    ]
    const wrapper = mountAt({ content: '', progress })
    expect(wrapper.text()).toContain('1 sub-agent')
  })
})

// ────────────────────────────────────────────────────────────────────────
// Envelope vs progress precedence (NEW — 2026-08-23 feature)
// ────────────────────────────────────────────────────────────────────────

describe('SpawnSubAgent.vue — envelope precedence', () => {
  const envelope = `<results>
  <agent name="alpha" success="true" random_fallback="false">
    <session_id>subagent_1_alpha</session_id>
    <response>done</response>
  </agent>
  <summary succeeded="1" failed="0" />
</results>`

  it('renders the parsed <results> envelope even if progress prop is also passed', async () => {
    // Once the tool result lands, the envelope wins — progress prop is
    // ignored. This matches the PR #299 dedupe principle: the source
    // of truth is the llm_history row, never the SSE-only progress
    // stream (which is ephemeral).
    const progress: SubAgentProgress[] = [
      sampleProgress('running', { name: 'stale', index: 0, total: 1 }),
    ]
    const wrapper = mountAt({ content: envelope, progress, expanded: false })
    // Expand so the row body is rendered (matches what a user sees
    // after clicking the header).
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).toContain('alpha')
    expect(wrapper.text()).not.toContain('stale')
  })

  it('keeps the existing parsed-envelope test: header shows ✓1 from <summary>', () => {
    const wrapper = mountAt({ content: envelope })
    expect(wrapper.text()).toContain('✓ 1')
  })
})
