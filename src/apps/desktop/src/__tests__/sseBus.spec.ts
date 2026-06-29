import { describe, it, expect, beforeEach, vi } from 'vitest'
import { createApp, type App } from 'vue'
import {
  installSseBus,
  useSseBus,
  __resetSseBus,
  __dispatchSseBus,
} from '../helpers/sseBus'

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
})
