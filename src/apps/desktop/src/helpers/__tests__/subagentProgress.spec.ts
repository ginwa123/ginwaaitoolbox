/**
 * Tests for subagentProgress.ts — pure reducer for the chatview's
 * spawn_sub_agent live-progress map.
 *
 * 2026-08-23 spawn-subagent-live-progress: ChatView.vue maintains a
 * per-tool_call_id progress map and feeds it from the SSE bus's
 * `role="subagent_progress"` events. This file guards the reducer's
 * wiring semantics:
 *   - launched creates a running row, completed flips it to done,
 *     failed flips it to failed
 *   - events for unrelated tool_call_ids don't cross-contaminate
 *   - out-of-order delivery (launched after completed) doesn't
 *     downgrade a done row back to running
 *   - clearProgressFor drops the entry once the final <results>
 *     envelope lands (so the parsed-envelope view wins)
 *   - defensive: events missing required fields are ignored
 */
import { describe, expect, it } from 'vitest'

import {
  applyProgressEvent,
  clearProgressFor,
  type SubAgentProgressEvent,
  type SubAgentProgressMap,
} from '../subagentProgress'

const launchedEvent = (
  over: Partial<SubAgentProgressEvent> = {},
): SubAgentProgressEvent => ({
  role: 'subagent_progress',
  tool_call_id: 'tc_1',
  agent_name: 'agent-a',
  status: 'launched',
  agent_index: 0,
  total_agents: 2,
  elapsed_ms: 0,
  session_id: 'sess_parent',
  ...over,
})

const completedEvent = (
  over: Partial<SubAgentProgressEvent> = {},
): SubAgentProgressEvent => ({
  role: 'subagent_progress',
  tool_call_id: 'tc_1',
  agent_name: 'agent-a',
  status: 'completed',
  agent_index: 0,
  total_agents: 2,
  elapsed_ms: 5000,
  session_id: 'sess_parent',
  subagent_session_id: 'subagent_123_agent-a',
  ...over,
})

const failedEvent = (
  over: Partial<SubAgentProgressEvent> = {},
): SubAgentProgressEvent => ({
  role: 'subagent_progress',
  tool_call_id: 'tc_1',
  agent_name: 'agent-a',
  status: 'failed',
  agent_index: 0,
  total_agents: 2,
  elapsed_ms: 100,
  session_id: 'sess_parent',
  ...over,
})

describe('applyProgressEvent', () => {
  it('creates a running row on launched', () => {
    const next = applyProgressEvent({}, launchedEvent())
    expect(next.tc_1).toHaveLength(1)
    expect(next.tc_1?.[0]).toMatchObject({
      name: 'agent-a',
      status: 'running',
      index: 0,
      total: 2,
      elapsedMs: 0,
    })
  })

  it('flips running → done on completed', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(map, launchedEvent())
    map = applyProgressEvent(
      map,
      completedEvent({ subagent_session_id: 'subagent_1_a' }),
    )
    expect(map.tc_1?.[0]).toMatchObject({
      status: 'done',
      sessionId: 'subagent_1_a',
      elapsedMs: 5000,
    })
  })

  it('flips running → failed on failed', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(map, launchedEvent())
    map = applyProgressEvent(map, failedEvent())
    expect(map.tc_1?.[0]).toMatchObject({ status: 'failed' })
  })

  it('events for different tool_call_ids do not cross-contaminate', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(
      map,
      launchedEvent({ tool_call_id: 'tc_a', agent_index: 0, agent_name: 'a' }),
    )
    map = applyProgressEvent(
      map,
      launchedEvent({ tool_call_id: 'tc_b', agent_index: 0, agent_name: 'b' }),
    )
    expect(Object.keys(map).sort()).toEqual(['tc_a', 'tc_b'])
    expect(map.tc_a?.[0]?.name).toBe('a')
    expect(map.tc_b?.[0]?.name).toBe('b')
  })

  it('keys two concurrent spawn batches separately by agent_index', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(map, launchedEvent({ agent_index: 0 }))
    map = applyProgressEvent(
      map,
      launchedEvent({
        agent_index: 1,
        agent_name: 'agent-b',
        subagent_session_id: 'subagent_2_b',
      }),
    )
    expect(map.tc_1?.[0]?.name).toBe('agent-a')
    expect(map.tc_1?.[1]?.name).toBe('agent-b')
    expect(map.tc_1?.[1]?.sessionId).toBe('subagent_2_b')
  })

  it('out-of-order launched does NOT downgrade a done row', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(map, launchedEvent())
    map = applyProgressEvent(map, completedEvent())
    // A late `launched` (replay) must not undo completion.
    map = applyProgressEvent(map, launchedEvent())
    expect(map.tc_1?.[0]?.status).toBe('done')
  })

  it('preserves sessionId across launches (only set once known)', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(map, launchedEvent()) // no session_id yet
    map = applyProgressEvent(
      map,
      completedEvent({ subagent_session_id: 'subagent_x_a' }),
    )
    // A late launched-with-empty-subagent_session_id must not clear it.
    map = applyProgressEvent(map, launchedEvent())
    expect(map.tc_1?.[0]?.sessionId).toBe('subagent_x_a')
  })

  it('ignores events with wrong role (defense-in-depth)', () => {
    const original: SubAgentProgressMap = { tc_1: [] }
    const next = applyProgressEvent(original, {
      role: 'assistant' as unknown as 'subagent_progress',
      status: 'launched',
      tool_call_id: 'tc_1',
      agent_index: 0,
    })
    expect(next).toBe(original) // same reference → no allocation, no mutation
  })

  it('ignores events missing tool_call_id', () => {
    const next = applyProgressEvent({}, launchedEvent({ tool_call_id: undefined }))
    expect(next).toEqual({})
  })

  it('ignores events missing status', () => {
    const next = applyProgressEvent({}, { ...launchedEvent(), status: undefined })
    expect(next).toEqual({})
  })

  it('ignores events with negative agent_index', () => {
    const next = applyProgressEvent({}, launchedEvent({ agent_index: -1 }))
    expect(next).toEqual({})
  })
})

describe('clearProgressFor', () => {
  it('drops the entry for a known tool_call_id', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(map, launchedEvent())
    map = applyProgressEvent(
      map,
      launchedEvent({
        tool_call_id: 'tc_2',
        agent_index: 0,
        agent_name: 'other',
      }),
    )
    const cleared = clearProgressFor(map, 'tc_1')
    expect(cleared.tc_1).toBeUndefined()
    expect(cleared.tc_2).toBeDefined()
  })

  it('returns the same reference when the id is unknown (no-op)', () => {
    const original: SubAgentProgressMap = { tc_1: [] }
    const next = clearProgressFor(original, 'tc_unknown')
    expect(next).toBe(original)
  })
})
