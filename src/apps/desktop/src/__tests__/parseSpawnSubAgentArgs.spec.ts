import { describe, it, expect } from 'vitest'
import { parseSpawnSubAgentArgs } from '../helpers/parseSpawnSubAgentArgs'

describe('parseSpawnSubAgentArgs', () => {
  it('returns null when toolCallsJson is null', () => {
    expect(parseSpawnSubAgentArgs(null, 'call_xxx')).toBeNull()
  })

  it('returns null when toolCallsJson is undefined', () => {
    expect(parseSpawnSubAgentArgs(undefined, 'call_xxx')).toBeNull()
  })

  it('returns null when toolCallsJson is empty string', () => {
    expect(parseSpawnSubAgentArgs('', 'call_xxx')).toBeNull()
  })

  it('returns null when toolCallId is null', () => {
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: '{}' }
    }])
    expect(parseSpawnSubAgentArgs(json, null)).toBeNull()
  })

  it('returns null when toolCallsJson is malformed JSON', () => {
    expect(parseSpawnSubAgentArgs('{not valid json', 'call_xxx')).toBeNull()
  })

  it('returns null when no tool call matches the given toolCallId', () => {
    const json = JSON.stringify([{
      id: 'call_yyy', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: '{}' }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toBeNull()
  })

  it('returns null when the matching tool call is not spawn_sub_agent', () => {
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'get_skill', arguments: '{}' }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toBeNull()
  })

  it('parses arguments as a JSON string (OpenAI format)', () => {
    const args = JSON.stringify({
      sub_agents: [{ name: 'a', instruction: 'do x', inherited_context: 'last:3' }]
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toEqual([{ name: 'a', instruction: 'do x', inherited_context: 'last:3' }])
  })

  it('parses arguments as an already-parsed object (defensive)', () => {
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: { sub_agents: [{ name: 'a', instruction: 'x' }] } }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toEqual([{ name: 'a', instruction: 'x' }])
  })

  it('preserves all sub-agent fields when fully populated', () => {
    const args = JSON.stringify({
      sub_agents: [{
        name: 'researcher',
        instruction: 'find docs',
        tools: ['bash', 'web_browse'],
        timeout_seconds: 300,
        inherited_context: 'last:5'
      }]
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toEqual([{
      name: 'researcher',
      instruction: 'find docs',
      tools: ['bash', 'web_browse'],
      timeout_seconds: 300,
      inherited_context: 'last:5'
    }])
  })

  it('returns null when sub_agents is not an array', () => {
    const args = JSON.stringify({ sub_agents: 'not an array' })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toBeNull()
  })

  it('returns null when the matching call arguments is malformed JSON', () => {
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: '{not valid' }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toBeNull()
  })

  it('handles sub-agents with missing optional fields (no throw)', () => {
    const args = JSON.stringify({
      sub_agents: [{ name: 'a', instruction: 'x' }]  // no tools/timeout/inherited_context
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toEqual([{ name: 'a', instruction: 'x' }])
  })

  it('returns multiple sub-agents in order', () => {
    const args = JSON.stringify({
      sub_agents: [
        { name: 'a', instruction: 'x', inherited_context: 'last:3' },
        { name: 'b', instruction: 'y', inherited_context: 'none' },
        { name: 'c', instruction: 'z' }
      ]
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toHaveLength(3)
    expect(result?.[0]?.name).toBe('a')
    expect(result?.[1]?.inherited_context).toBe('none')
    expect(result?.[2]?.inherited_context).toBeUndefined()
  })
})
