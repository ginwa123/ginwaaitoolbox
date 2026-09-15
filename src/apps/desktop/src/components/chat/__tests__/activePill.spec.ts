import { describe, it, expect } from 'vitest'
import { pickActivePillIndex, isPillGroup } from '../activePill'

const pills = [{ groupIndex: 0 }, { groupIndex: 3 }, { groupIndex: 7 }]

describe('pickActivePillIndex', () => {
  it('returns null above the first user message', () => {
    // rangeStart is an assistant/tool group before any user pill
    expect(pickActivePillIndex(pills.slice(1), 1)).toBe(null)
  })

  it('activates the pill at the top of the viewport', () => {
    expect(pickActivePillIndex(pills, 0)).toBe(0)
    expect(pickActivePillIndex(pills, 3)).toBe(3)
  })

  it('sticks to the last passed pill while scrolling between pills', () => {
    expect(pickActivePillIndex(pills, 1)).toBe(0)
    expect(pickActivePillIndex(pills, 5)).toBe(3)
    expect(pickActivePillIndex(pills, 9)).toBe(7)
  })

  it('returns null for an empty rail', () => {
    expect(pickActivePillIndex([], 5)).toBe(null)
  })
})

describe('isPillGroup', () => {
  it('keeps real user turns', () => {
    expect(isPillGroup('user', false, false)).toBe(true)
  })

  it('skips bg-command outputs (role=user on the wire, tool card in pixels)', () => {
    expect(isPillGroup('user', true, false)).toBe(false)
  })

  it('skips compaction envelopes', () => {
    expect(isPillGroup('user', false, true)).toBe(false)
  })

  it('skips non-user roles', () => {
    expect(isPillGroup('assistant', false, false)).toBe(false)
    expect(isPillGroup('tool', false, false)).toBe(false)
  })
})
