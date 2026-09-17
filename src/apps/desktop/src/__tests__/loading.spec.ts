import { beforeEach, describe, expect, it } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { useLoadingStore } from '../stores/loading'

describe('useLoadingStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('starts hidden with zero counters', () => {
    const store = useLoadingStore()
    expect(store.routeDepth).toBe(0)
    expect(store.apiPending).toBe(0)
    expect(store.isBarVisible).toBe(false)
  })

  it('shows the bar while navigating', () => {
    const store = useLoadingStore()
    store.startRoute()
    expect(store.isNavigating).toBe(true)
    expect(store.isBarVisible).toBe(true)
    store.finishRoute()
    expect(store.isBarVisible).toBe(false)
  })

  it('shows the bar while an api request is in flight', () => {
    const store = useLoadingStore()
    store.startApi()
    expect(store.isApiBusy).toBe(true)
    expect(store.isBarVisible).toBe(true)
    store.finishApi()
    expect(store.isBarVisible).toBe(false)
  })

  it('supports overlapping requests without flicker', () => {
    const store = useLoadingStore()
    store.startApi()
    store.startApi()
    store.finishApi()
    expect(store.isBarVisible).toBe(true)
    store.finishApi()
    expect(store.isBarVisible).toBe(false)
  })

  it('clamps finishers at zero so the bar can never wedge visible', () => {
    const store = useLoadingStore()
    store.finishRoute()
    store.finishApi()
    expect(store.routeDepth).toBe(0)
    expect(store.apiPending).toBe(0)
    expect(store.isBarVisible).toBe(false)
  })

  it('reset clears both counters', () => {
    const store = useLoadingStore()
    store.startRoute()
    store.startApi()
    store.startApi()
    store.reset()
    expect(store.isBarVisible).toBe(false)
  })
})
