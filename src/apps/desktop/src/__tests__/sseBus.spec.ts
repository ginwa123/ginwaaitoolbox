import { describe, it, expect, beforeEach, vi } from 'vitest'
import { createApp, nextTick, type App, watch } from 'vue'
import {
  installSseBus,
  useSseBus,
  __resetSseBus,
  __dispatchSseBus,
  __setSseBusGlobalClient,
  __getSseBusGlobalClient,
  __setSseBusSessionFactory,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

/**
 * Test-only stub SseClient. Tracks state-listener callbacks on a
 * non-public `__stateListeners` array so `emitStubState` can fan out
 * a transition to all subscribers (the production `SseClient` keeps
 * the listener list in a closure; tests reach it via `as any`).
 */
function makeStubClient(initial: SseState): SseClient {
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => {
      stub.__stateListeners.push(cb)
      return () => {
        const i = stub.__stateListeners.indexOf(cb)
        if (i >= 0) stub.__stateListeners.splice(i, 1)
      }
    },
  }
  stub._state = initial
  stub.__stateListeners = [] as Array<(s: SseState, info: SseStateInfo) => void>
  return stub as SseClient
}

function emitStubState(c: SseClient, s: SseState): void {
  // Walk the internal listener list. The stub stores it as a non-public
  // property — we use `as any` to reach it from the test.
  const listeners = (c as any).__stateListeners as
    | Array<(s: SseState, info: SseStateInfo) => void>
    | undefined
  if (listeners) {
    for (const cb of listeners) cb(s, {} as SseStateInfo)
  }
}

describe('sseBus', () => {
  let app: App
  beforeEach(() => {
    __resetSseBus()
    app = createApp({})
  })

  it('installSseBus is idempotent — second call returns the same instance', () => {
    const a = installSseBus(app)
    const b = installSseBus(app)
    expect(a).toBe(b)
  })

  it('useSseBus throws if not installed', () => {
    expect(() => useSseBus()).toThrow(/installSseBus/)
  })

  it('useSseBus returns the installed bus after installSseBus', () => {
    const bus = installSseBus(app)
    expect(useSseBus()).toBe(bus)
  })

  it('on(type, cb) — dispatch fires the listener', () => {
    const bus = installSseBus(app)
    const cb = vi.fn()
    bus.on('session', cb)
    __dispatchSseBus('session', {
      id: 's_1',
      action: 'updated',
      name: 'Renamed',
    } as any)
    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith({
      id: 's_1',
      action: 'updated',
      name: 'Renamed',
    })
  })

  it('on(type, cb) — multiple subscribers all fire', () => {
    const bus = installSseBus(app)
    const a = vi.fn(),
      b = vi.fn()
    bus.on('worker', a)
    bus.on('worker', b)
    __dispatchSseBus('worker', { id: 'w_1', action: 'created' } as any)
    expect(a).toHaveBeenCalledTimes(1)
    expect(b).toHaveBeenCalledTimes(1)
  })

  it('on(type, cb) — unsubscribe stops delivery', () => {
    const bus = installSseBus(app)
    const cb = vi.fn()
    const off = bus.on('session', cb)
    off()
    __dispatchSseBus('session', { id: 's_1', action: 'updated' } as any)
    expect(cb).not.toHaveBeenCalled()
  })

  it('off(type, cb) — removes a specific listener', () => {
    const bus = installSseBus(app)
    const cb = vi.fn()
    bus.on('session', cb)
    bus.off('session', cb)
    __dispatchSseBus('session', { id: 's_1', action: 'updated' } as any)
    expect(cb).not.toHaveBeenCalled()
  })

  it('__setSseBusGlobalClient replaces the global SseClient and re-wires state', async () => {
    const bus = installSseBus(app)
    const stateChanges: SseState[] = []
    const watchUnsub = watch(bus.state, (s) => stateChanges.push(s))

    const stub = makeStubClient('connecting')
    __setSseBusGlobalClient(stub)
    expect(bus.state.value).toBe('connecting')

    // Drive a state change on the stub
    emitStubState(stub, 'open')
    expect(bus.state.value).toBe('open')

    // Vue's `watch` defaults to async (post-flush), so the subscriber
    // hasn't been called yet. Drain a microtask so the watcher fires
    // before we assert on the collected transitions.
    await nextTick()
    expect(stateChanges).toContain('open')

    watchUnsub()
  })

  it('__setSseBusGlobalClient closes the old client when replacing', () => {
    installSseBus(app)
    const old = __getSseBusGlobalClient()
    expect(old).not.toBeNull()
    const closeSpy = vi.spyOn(old!, 'close')
    const stub = makeStubClient('closed')
    __setSseBusGlobalClient(stub)
    expect(closeSpy).toHaveBeenCalled()
  })

  it('bus.close() closes the SWAPPED-IN global client, not the original', () => {
    installSseBus(app)
    const original = __getSseBusGlobalClient()!
    const originalCloseSpy = vi.spyOn(original, 'close')

    const stub = makeStubClient('connecting')
    const stubCloseSpy = vi.spyOn(stub, 'close')
    __setSseBusGlobalClient(stub)

    // The swap itself already called `original.close()` exactly once
    // (the `_globalClient && _globalClient !== client` branch in
    // __setSseBusGlobalClient). The test asserts bus.close() does NOT
    // call it again — which would happen if bus.close() reads the
    // closure-scoped `globalClient` (the pre-fix bug).
    expect(originalCloseSpy).toHaveBeenCalledTimes(1)

    const bus = useSseBus()
    bus.close()

    // After bus.close(): still exactly 1 close on the original
    // (only the swap called it). If the fix regresses, this jumps
    // to 2 because bus.close() would call original.close() again.
    expect(originalCloseSpy).toHaveBeenCalledTimes(1)
    // bus.close() must close the SWAPPED-IN stub.
    expect(stubCloseSpy).toHaveBeenCalledTimes(1)
  })

  it('subscribeSessionChannels — first call opens a client; second is a no-op (refcount)', () => {
    // Track how many times the factory is invoked
    const factoryCalls: Array<{ sid: string }> = []
    __setSseBusSessionFactory((sid) => {
      factoryCalls.push({ sid })
      // Return a minimal SseClient stub (use the existing makeStubClient helper)
      return makeStubClient('connecting')
    })

    const bus = installSseBus(app)
    bus.subscribeSessionChannels('s_1')
    bus.subscribeSessionChannels('s_1')
    // Refcount is 2, factory invoked ONCE
    expect(factoryCalls).toHaveLength(1)
    expect(factoryCalls[0]?.sid).toBe('s_1')

    bus.unsubscribeSessionChannels('s_1') // refcount → 1
    bus.unsubscribeSessionChannels('s_1') // refcount → 0, client closed
    expect(factoryCalls).toHaveLength(1) // still only one open call
  })

  it('subscribeSessionChannels — listener fires once per event even with multiple subscribes', () => {
    __setSseBusSessionFactory((_sid) => makeStubClient('connecting'))
    const bus = installSseBus(app)
    const a = vi.fn(),
      b = vi.fn()
    bus.on('llm', a)
    bus.on('llm', b)
    bus.subscribeSessionChannels('s_1')
    bus.subscribeSessionChannels('s_1')
    // Two subscribes, one underlying client. Dispatch an llm event.
    __dispatchSseBus('llm', { session_id: 's_1', content: 'hi' } as any)
    expect(a).toHaveBeenCalledTimes(1)
    expect(b).toHaveBeenCalledTimes(1)
    // Cleanup
    bus.unsubscribeSessionChannels('s_1')
    bus.unsubscribeSessionChannels('s_1')
  })
})
