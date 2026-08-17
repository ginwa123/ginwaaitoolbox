/**
 * Tests for SpawnSubAgent.vue, focusing on the new peek button +
 * event that triggers SubAgentPeekPanel.
 */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import SpawnSubAgent from '../components/tool_outputs/SpawnSubAgent.vue'

describe('SpawnSubAgent peek button', () => {
  const sampleResult =
    '<results>\n' +
    '<agent name="backend-dev" success="true" random_fallback="false">\n' +
    '<session_id>subagent_1_backend-dev</session_id>\n' +
    '<response>Did the task</response>\n' +
    '</agent>\n' +
    '<summary succeeded="1" failed="0" />\n' +
    '</results>'

  it('emits peek with sessionId + agentName + instruction when peek button is clicked', async () => {
    const wrapper = mount(SpawnSubAgent, {
      props: {
        content: sampleResult,
        expanded: true,
        subAgentArgs: [
          { agent_name: 'backend-dev', instruction: 'do X' },
        ],
      },
    })

    const peekBtn = wrapper.find('[data-testid="peek-button"]')
    expect(peekBtn.exists()).toBe(true)

    await peekBtn.trigger('click')
    const emitted = wrapper.emitted('peek')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      expect.objectContaining({
        sessionId: 'subagent_1_backend-dev',
        agentName: 'backend-dev',
        instruction: 'do X',
      }),
    ])
  })

  it('renders one peek button per agent row (one per sub-agent)', () => {
    const twoAgentResult =
      '<results>\n' +
      '<agent name="a" success="true" random_fallback="false">' +
      '<session_id>subagent_1_a</session_id><response>ok</response></agent>\n' +
      '<agent name="b" success="true" random_fallback="false">' +
      '<session_id>subagent_1_b</session_id><response>ok</response></agent>\n' +
      '<summary succeeded="2" failed="0" />\n' +
      '</results>'
    const wrapper = mount(SpawnSubAgent, {
      props: {
        content: twoAgentResult,
        expanded: true,
        subAgentArgs: [
          { agent_name: 'a', instruction: 'do A' },
          { agent_name: 'b', instruction: 'do B' },
        ],
      },
    })
    expect(wrapper.findAll('[data-testid="peek-button"]')).toHaveLength(2)
  })

  it('does NOT render a peek button for agents without a session_id', () => {
    const noSessionResult =
      '<results>\n' +
      '<agent name="a" success="false" random_fallback="false">' +
      '<error>Workflow error: X</error></agent>\n' +
      '<summary succeeded="0" failed="1" />\n' +
      '</results>'
    const wrapper = mount(SpawnSubAgent, {
      props: {
        content: noSessionResult,
        expanded: true,
        subAgentArgs: [{ agent_name: 'a', instruction: 'do A' }],
      },
    })
    expect(wrapper.findAll('[data-testid="peek-button"]')).toHaveLength(0)
  })

  it('passes an empty string for instruction when subAgentArgs is missing', async () => {
    const wrapper = mount(SpawnSubAgent, {
      props: {
        content: sampleResult,
        expanded: true,
        // No subAgentArgs — the component must not crash.
      },
    })

    const peekBtn = wrapper.find('[data-testid="peek-button"]')
    expect(peekBtn.exists()).toBe(true)

    await peekBtn.trigger('click')
    const emitted = wrapper.emitted('peek')
    expect(emitted![0]![0]).toEqual(
      expect.objectContaining({
        sessionId: 'subagent_1_backend-dev',
        agentName: 'backend-dev',
        instruction: '',
      }),
    )
  })
})