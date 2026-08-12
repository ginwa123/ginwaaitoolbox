// src/apps/desktop/src/__tests__/apiFetch.spec.ts
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { apiFetch, ApiError } from '../api/index'

describe('apiFetch', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  it('returns parsed JSON on 2xx response', async () => {
    const fakeResponse = new Response(JSON.stringify({ ok: true, value: 42 }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(fakeResponse)

    const result = await apiFetch<{ ok: boolean; value: number }>('/test')
    expect(result).toEqual({ ok: true, value: 42 })
  })

  it('notifies and throws ApiError on 4xx response with JSON .error field', async () => {
    const { useNotificationStore } = await import('../stores/notifications')
    const fakeResponse = new Response(JSON.stringify({ error: 'Invalid name' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    })
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(fakeResponse)

    await expect(apiFetch('/test')).rejects.toBeInstanceOf(ApiError)

    const store = useNotificationStore()
    expect(store.notifications).toHaveLength(1)
    expect(store.notifications[0]?.message).toBe('Invalid name')
    expect(store.notifications[0]?.details).toBe('{"error":"Invalid name"}')
  })

  it('notifies and throws ApiError on 5xx response', async () => {
    const { useNotificationStore } = await import('../stores/notifications')
    const fakeResponse = new Response('Internal Server Error', { status: 500, statusText: 'Internal Server Error' })
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(fakeResponse)

    await expect(apiFetch('/test')).rejects.toBeInstanceOf(ApiError)

    const store = useNotificationStore()
    expect(store.notifications).toHaveLength(1)
    expect(store.notifications[0]?.message).toBe('HTTP 500 Internal Server Error')
    expect(store.notifications[0]?.details).toBe('Internal Server Error')
  })

  it('does not notify when silent:true is passed', async () => {
    const { useNotificationStore } = await import('../stores/notifications')
    const fakeResponse = new Response('{"error":"bad"}', { status: 400 })
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(fakeResponse)

    await expect(apiFetch('/test', { silent: true })).rejects.toBeInstanceOf(ApiError)

    const store = useNotificationStore()
    expect(store.notifications).toHaveLength(0)
  })

  it('does not notify on fetch rejection (network failure)', async () => {
    const { useNotificationStore } = await import('../stores/notifications')
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('NetworkError'))

    await expect(apiFetch('/test')).rejects.toThrow('NetworkError')

    const store = useNotificationStore()
    expect(store.notifications).toHaveLength(0)
  })

  it('serializes JSON body automatically', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{}', { status: 200 }),
    )

    await apiFetch('/test', { method: 'POST', body: { foo: 'bar' } })
    const init = fetchSpy.mock.calls[0]?.[1] as RequestInit | undefined
    expect(init?.body).toBe('{"foo":"bar"}')
  })

  it('uses API_BASE prefix on the URL', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{}', { status: 200 }),
    )

    await apiFetch('/workspaces')
    const calledUrl = fetchSpy.mock.calls[0]?.[0] as string | undefined
    expect(calledUrl?.endsWith('/api/workspaces')).toBe(true)
  })
})
