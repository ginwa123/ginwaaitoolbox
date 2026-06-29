import { describe, it, expect, beforeEach, vi } from 'vitest'

import { mount } from '@vue/test-utils'
import { createApp, type App as VueApp, nextTick } from 'vue'

import App from '../App.vue'
import * as api from '../api'
import {
  installSseBus,
  useSseBus,
  __resetSseBus,
  __dispatchSseBus,
  __setSseBusGlobalClient,
  __getSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

/**
 * Test-only stub SseClient. Mirrors the helper in `sseBus.spec.ts`
 * (kept inline rather than shared to avoid coupling between the two
 * spec files). Tracks state-listener callbacks on a non-public
 * `__stateListeners` array so `emitStubState` can fan out a
 * transition to all subscribers — the production `SseClient` keeps
 * the listener list in a closure; tests reach it via `as any`.
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
  const listeners = (c as any).__stateListeners as
    | Array<(s: SseState, info: SseStateInfo) => void>
    | undefined
  if (listeners) {
    for (const cb of listeners) cb(s, {} as SseStateInfo)
  }
}

describe('App', () => {
  let app: VueApp
  let stub: SseClient

  beforeEach(() => {
    __resetSseBus()
    app = createApp({})
    // Install the bus BEFORE mounting App.vue so the singleton exists
    // when App.vue's `useSseBus().close()` runs in onUnmounted. Plan's
    // gotcha #6: `useSseBus` throws if not installed.
    installSseBus(app)
    // Replace the underlying global SseClient (otherwise it would call
    // `new EventSource(...)` and silently idle in jsdom) with a
    // deterministic fake we drive through 'open' in the
    // reconnect-resync test.
    stub = makeStubClient('connecting')
    __setSseBusGlobalClient(stub)
    // fetchInitialWorkers hits the network — stub it so the tests
    // don't try to fetch. Tests that need to assert call counts use
    // `vi.mocked(api.getWorkers).mockClear()` after mount.
    vi.spyOn(api, 'getWorkers').mockResolvedValue({
      workers: [],
      count: 0,
    })
  })

  it('mounts without throwing', () => {
    // Smoke test: App.vue should mount cleanly. EventSource is
    // polyfilled in src/__tests__/setup.ts so the SSE connection opened
    // in onMounted does not crash. The template is a <router-view />,
    // so we only assert that the component instance exists — no router
    // is provided here.
    const wrapper = mount(App)
    expect(wrapper.exists()).toBe(true)
  })

  it("App.vue subscribes to bus.on('worker'); handleWorkerEvent fires when the bus dispatches", async () => {
    const wrapper = mount(App)
    // Read the provided `processingState` ref. When `mount(App)` is
    // used (root mount with no outer app), provides go to the root
    // component instance under `vm.$.provides` (NOT `vm.$.appContext
    // .provides` — that's only for nested-app ancestors).
    const provides = (wrapper.vm as any).$.provides as Record<string, unknown>
    const processingState = provides['processingState'] as {
      value: Record<string, boolean>
    }
    expect(processingState).toBeDefined()

    // Dispatch a synthetic 'created' worker event for 'sess_w1'.
    __dispatchSseBus('worker', {
      action: 'created',
      id: 'w_1',
      session_id: 'sess_w1',
      working_directory: '/tmp',
      last_activity: 0,
      last_activity_description: '',
      created_at: '',
    } as unknown as api.WorkerEvent)
    await nextTick()
    expect(processingState.value['sess_w1']).toBe(true)

    // Dispatch a 'deleted' for the same session and verify removal.
    __dispatchSseBus('worker', {
      action: 'deleted',
      id: 'w_1',
      session_id: 'sess_w1',
      working_directory: '/tmp',
      last_activity: 0,
      last_activity_description: '',
      created_at: '',
    } as unknown as api.WorkerEvent)
    await nextTick()
    expect(processingState.value['sess_w1']).toBeUndefined()
  })

  it("App.vue calls fetchInitialWorkers when bus.state transitions to 'open' (reconnect-resync)", async () => {
    mount(App)
    // Clear any calls that may have happened during mount. The
    // { immediate: true } watcher fires synchronously during setup
    // but the stub was 'connecting' at that point, so getWorkers
    // should not have been called yet — mockClear() is defensive.
    const getWorkersSpy = vi.mocked(api.getWorkers).mockClear()
    expect(getWorkersSpy).not.toHaveBeenCalled()

    // Flip the stub to 'open' — the watcher must call
    // fetchInitialWorkers in response.
    emitStubState(stub, 'open')
    // The watcher is async by default; drain a microtask.
    await nextTick()
    expect(getWorkersSpy).toHaveBeenCalled()
  })

  it('unmounting App.vue calls bus.close() on the bus singleton', () => {
    const wrapper = mount(App)
    // `bus.close()` should clear the singleton — verify by checking
    // that a subsequent `useSseBus()` throws. We don't spy on any
    // specific SseClient's close() because App.vue's onUnmounted
    // delegates to `useSseBus().close()`, which delegates to the
    // bus's internal global client (the closure-scoped one from
    // installSseBus). Spying on it would couple the test to bus
    // internals; checking the singleton-cleared invariant is a
    // stronger behavioral contract anyway.
    expect(() => useSseBus()).not.toThrow()

    wrapper.unmount()

    // bus.close() was called → singleton is null → useSseBus() throws.
    expect(() => useSseBus()).toThrow(/installSseBus/)
    // The test handle also goes to null.
    expect(__getSseBusGlobalClient()).toBeNull()
  })
})
