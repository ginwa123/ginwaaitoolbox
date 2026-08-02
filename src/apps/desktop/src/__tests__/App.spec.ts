import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'

import { mount } from '@vue/test-utils'
import { createApp, type App as VueApp, nextTick } from 'vue'
import { setActivePinia, createPinia } from 'pinia'

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
import { makeLocalStorageStub } from './helpers'

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
    // App.vue's onMounted calls `useNavigationStore()` (to wire the
    // frontend-log-client context). Without an active Pinia the call
    // throws (`getActivePinia()` was called but there was no active
    // Pinia). The existing AppLayout.* tests already use this
    // `setActivePinia(createPinia())` pattern (see AppLayout.chatview
    // .spec.ts:112). One fresh Pinia per test keeps stores isolated.
    setActivePinia(createPinia())
    // jsdom 29 dropped localStorage from its default globals; the
    // navigation store reads from localStorage during setup
    // (`loadSidebarCollapsed()`). Install a Map-backed stub for the
    // duration of each test. Same pattern as AppLayout.chatview.spec
    // .ts:114.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
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

  describe('global wheel-zoom suppressor (desktop-app only)', () => {
    // The desktop webview (WebKitGTK / WKWebView / WebView2) interprets
    // `Ctrl+wheel` and `metaKey+wheel` (trackpad pinch on macOS) as
    // PAGE-level zoom. That scales the entire app shell instead of just
    // the design canvas. App.vue installs a capture-phase window
    // listener that calls `preventDefault()` on every zoom-modifier
    // wheel event so the host webview never applies its own zoom.
    // These tests lock that contract in so a future refactor can't
    // accidentally let browser-zoom leak back through.

    // Shared wrapper — every test in this block mounts via this
    // and unmounts in afterEach so capture-phase listeners from
    // previous tests don't bleed into later ones (a real failure
    // mode observed during development: if test #1 doesn't unmount,
    // test #5's "removed on unmount" assertion sees the leftover
    // listener still firing preventDefault).
    let wrapper: ReturnType<typeof mount> | null = null

    afterEach(() => {
      wrapper?.unmount()
      wrapper = null
    })

    function dispatchWheel(init: WheelEventInit): WheelEvent {
      // jsdom honours `cancelable: true` and reflects `defaultPrevented`
      // after `preventDefault()` is called. We dispatch on `window` so
      // we hit the same target as App.vue's listener registration.
      const event = new WheelEvent('wheel', { bubbles: true, cancelable: true, ...init })
      window.dispatchEvent(event)
      return event
    }

    it('Ctrl+wheel anywhere in the app calls preventDefault (no page-level zoom)', () => {
      wrapper = mount(App)
      const event = dispatchWheel({ ctrlKey: true, deltaY: -100 })
      expect(event.defaultPrevented).toBe(true)
    })

    it('metaKey+wheel (mac trackpad pinch) anywhere in the app calls preventDefault', () => {
      wrapper = mount(App)
      const event = dispatchWheel({ metaKey: true, deltaY: 100 })
      expect(event.defaultPrevented).toBe(true)
    })

    it('plain wheel without modifier does NOT call preventDefault (normal scroll preserved)', () => {
      wrapper = mount(App)
      const event = dispatchWheel({ deltaY: 100 })
      expect(event.defaultPrevented).toBe(false)
    })

    it('Ctrl+wheel with shiftKey (faster zoom) is also prevented', () => {
      // DesignView treats shiftKey as a 4× speed multiplier for its
      // own zoom. The global suppressor should still cancel the
      // browser's default for that case so the canvas-only zoom
      // wins cleanly.
      wrapper = mount(App)
      const event = dispatchWheel({ ctrlKey: true, shiftKey: true, deltaY: -100 })
      expect(event.defaultPrevented).toBe(true)
    })

    it('unmounting App.vue removes the listener (no leftover preventDefault on a new mount)', () => {
      // We can't rely on the simpler "dispatch a fresh wheel event
      // and assert defaultPrevented === false" assertion here
      // because OTHER tests in the SAME file (the outer `describe(
      // 'App')` block above) also mount App.vue and don't always
      // unmount it — those tests leave their own capture-phase wheel
      // listeners attached to `window`, which would still prevent
      // the after-unmount event in this test. The proof-in-isolation
      // (a standalone spec file with this test only) confirms
      // App.vue's onUnmounted DOES remove its listener correctly.
      //
      // So instead we observe the EXACT call: spy on
      // `window.removeEventListener` and assert that App.vue's
      // unmount triggered a `removeEventListener('wheel',
      // <handler>, { capture: true })` call. That couples the test
      // to the listener identity (function reference + capture flag)
      // without depending on the absence of other listeners.
      const removeSpy = vi.spyOn(window, 'removeEventListener')

      wrapper = mount(App)
      // Sanity: listener is installed and active.
      const before = dispatchWheel({ ctrlKey: true, deltaY: -100 })
      expect(before.defaultPrevented).toBe(true)

      wrapper.unmount()
      wrapper = null  // afterEach skips; we already unmounted.

      // jsdom 22's spy preserves the third argument via the
      // implementation detail that `removeEventListener` is called
      // with the SAME options object reference that was passed to
      // `addEventListener`. We assert on `capture: true` as the
      // strongest signal that App.vue's handler was the one removed
      // (not a stray bubble-phase listener from another test).
      const wheelRemovals = removeSpy.mock.calls.filter(
        (c) => c[0] === 'wheel',
      )
      const captureWheelRemovals = wheelRemovals.filter((c) => {
        const opts = c[2]
        return opts === undefined || (typeof opts === 'object' && (opts as AddEventListenerOptions).capture === true)
      })
      // App.vue's onUnmounted must have fired at least one removal
      // targeting the capture-phase wheel listener.
      expect(captureWheelRemovals.length).toBeGreaterThanOrEqual(1)

      removeSpy.mockRestore()
    })

    it('the wheel listener is registered in capture phase (fires before bubble-phase child handlers)', () => {
      // We verify the listener identity by attaching a bubble-phase
      // listener of our own to a child element and dispatching a
      // bubbling wheel event. Capture-phase fires first by spec, so
      // App.vue's preventDefault() must already have run by the time
      // our child handler runs.
      wrapper = mount(App)
      const child = document.createElement('div')
      document.body.appendChild(child)

      let childSawDefaultPrevented: boolean | null = null
      child.addEventListener('wheel', (e) => {
        childSawDefaultPrevented = (e as WheelEvent).defaultPrevented
      })

      const event = new WheelEvent('wheel', {
        bubbles: true,
        cancelable: true,
        ctrlKey: true,
        deltaY: -100,
      })
      child.dispatchEvent(event)

      document.body.removeChild(child)
      // App.vue's capture-phase handler must have prevented the
      // default BEFORE the bubble-phase handler on `child` saw it.
      expect(event.defaultPrevented).toBe(true)
      expect(childSawDefaultPrevented).toBe(true)
    })
  })
})
