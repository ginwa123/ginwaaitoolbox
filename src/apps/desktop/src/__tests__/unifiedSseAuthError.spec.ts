/* eslint-disable @typescript-eslint/no-explicit-any -- test mocks legitimately use loose types */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { createUnifiedSseConnection } from '../api'
import * as sseClient from '../helpers/sseClient'

describe('createUnifiedSseConnection: auth_error rejection', () => {
  const spy = vi.spyOn(sseClient, 'createSseClient')
  let capturedOpts: sseClient.SseClientOptions | null = null

  beforeEach(() => {
    capturedOpts = null
    spy.mockImplementation(((opts: sseClient.SseClientOptions) => {
      capturedOpts = opts
      return {
        close: vi.fn(),
        reconnect: vi.fn(),
        getState: () => 'open' as const,
        onStateChange: () => () => {},
      }
    }) as unknown as typeof sseClient.createSseClient)
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("pre-registers 'auth_error' so the browser does not drop the rejection", () => {
    createUnifiedSseConnection({
      channels: { workers: () => {}, sessions: () => {} },
    })
    expect(capturedOpts).not.toBeNull()
    expect(capturedOpts!.additionalEventTypes).toContain('auth_error')
  })

  it('bounces to /login on auth_error without touching channel callbacks', () => {
    const workersCb = vi.fn()
    const sessionsCb = vi.fn()
    createUnifiedSseConnection({
      channels: { workers: workersCb, sessions: sessionsCb },
    })
    const fakeLoc = { pathname: '/app', search: '?view=chat', href: '' }
    vi.stubGlobal('location', fakeLoc)

    expect(() => capturedOpts!.onEvent('{"error":"Unauthenticated"}', 'auth_error')).not.toThrow()
    expect(fakeLoc.href).toBe('/login?redirect=%2Fapp%3Fview%3Dchat')
    expect(workersCb).not.toHaveBeenCalled()
    expect(sessionsCb).not.toHaveBeenCalled()
  })
})
