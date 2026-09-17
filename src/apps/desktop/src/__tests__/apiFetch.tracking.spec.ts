import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { apiFetch, ApiError } from '../api/index'
import { useLoadingStore } from '../stores/loading'

describe('apiFetch loading-bar tracking', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  function loading() {
    return useLoadingStore()
  }

  it('clears the api counter after a successful request', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    )
    await apiFetch('/test')
    expect(loading().apiPending).toBe(0)
    expect(loading().isBarVisible).toBe(false)
  })

  it('clears the api counter after a failed request', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('boom', { status: 500 }))
    await expect(apiFetch('/test', { silent: true })).rejects.toBeInstanceOf(ApiError)
    expect(loading().apiPending).toBe(0)
  })

  it('holds the counter while the request is in flight', async () => {
    let resolveFetch!: (r: Response) => void
    vi.spyOn(globalThis, 'fetch').mockReturnValue(
      new Promise<Response>((r) => {
        resolveFetch = r
      }),
    )
    const pending = apiFetch('/test')
    expect(loading().apiPending).toBe(1)
    expect(loading().isBarVisible).toBe(true)
    resolveFetch(new Response(JSON.stringify({ ok: true }), { status: 200 }))
    await pending
    expect(loading().apiPending).toBe(0)
  })

  it('track:false skips the counter (background pollers)', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    )
    await apiFetch('/test', { track: false })
    expect(loading().apiPending).toBe(0)
    expect(loading().isBarVisible).toBe(false)
  })

  it('silent:true requests still drive the bar', async () => {
    let resolveFetch!: (r: Response) => void
    vi.spyOn(globalThis, 'fetch').mockReturnValue(
      new Promise<Response>((r) => {
        resolveFetch = r
      }),
    )
    const pending = apiFetch('/test', { silent: true })
    expect(loading().apiPending).toBe(1)
    resolveFetch(new Response(JSON.stringify({ ok: true }), { status: 200 }))
    await pending
    expect(loading().apiPending).toBe(0)
  })
})
