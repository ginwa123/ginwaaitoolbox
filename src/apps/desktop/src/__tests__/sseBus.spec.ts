import { describe, it, expect, beforeEach, vi } from 'vitest'
import { createApp, type App } from 'vue'
import { installSseBus, useSseBus, __resetSseBus } from '../helpers/sseBus'

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
})
