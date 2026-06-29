import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useNavigationStore } from '../stores/navigation'

describe('navigation.peekPanel', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    // localStorage is touched by the store init; jsdom may not provide it cleanly.
    if (typeof localStorage === 'undefined' || typeof localStorage.clear !== 'function') {
      const store: Record<string, string> = {}
      vi.stubGlobal('localStorage', {
        getItem: (k: string) => (k in store ? store[k] : null),
        setItem: (k: string, v: string) => { store[k] = String(v) },
        removeItem: (k: string) => { delete store[k] },
        clear: () => { for (const k in store) delete store[k] },
        key: () => null,
        length: 0,
      })
    } else {
      localStorage.clear()
    }
  })

  it('peekPanel starts as null', () => {
    const nav = useNavigationStore()
    expect(nav.peekPanel).toBeNull()
  })

  it('openPeek sets the panel payload', () => {
    const nav = useNavigationStore()
    nav.openPeek({ sessionId: 'subagent_1_foo', agentName: 'foo', instruction: 'do X' })
    expect(nav.peekPanel).toEqual({
      sessionId: 'subagent_1_foo',
      agentName: 'foo',
      instruction: 'do X',
    })
  })

  it('closePeek clears the panel', () => {
    const nav = useNavigationStore()
    nav.openPeek({ sessionId: 'subagent_1_foo', agentName: 'foo', instruction: 'do X' })
    nav.closePeek()
    expect(nav.peekPanel).toBeNull()
  })

  it('peekPanel is reactive (opening updates the value)', () => {
    const nav = useNavigationStore()
    expect(nav.peekPanel).toBeNull()
    nav.openPeek({ sessionId: 's', agentName: 'a', instruction: 'i' })
    expect(nav.peekPanel).not.toBeNull()
    expect(nav.peekPanel?.sessionId).toBe('s')
  })

  it('openPeek replaces an existing panel payload', () => {
    const nav = useNavigationStore()
    nav.openPeek({ sessionId: 's1', agentName: 'a1', instruction: 'i1' })
    nav.openPeek({ sessionId: 's2', agentName: 'a2', instruction: 'i2' })
    expect(nav.peekPanel?.sessionId).toBe('s2')
    expect(nav.peekPanel?.agentName).toBe('a2')
  })
})