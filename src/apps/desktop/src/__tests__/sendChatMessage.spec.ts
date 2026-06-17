import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { sendChatMessage } from '../api'

describe('sendChatMessage', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  it('returns { status: "bad_request" } on 400', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"error":"bad"}', {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    expect(await sendChatMessage('s1', 'msg', '/cwd')).toEqual({ status: 'bad_request' })
  })

  it('returns { status: "unprocessable_entity" } on 422', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"error":"bad"}', {
        status: 422,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    expect(await sendChatMessage('s1', 'msg', '/cwd')).toEqual({ status: 'unprocessable_entity' })
  })

  it('returns { status: "offline" } on network failure', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('NetworkError'))
    expect(await sendChatMessage('s1', 'msg', '/cwd')).toEqual({ status: 'offline' })
  })

  it('returns parsed body on 2xx', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"status":"queued"}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    expect(await sendChatMessage('s1', 'msg', '/cwd')).toEqual({ status: 'queued' })
  })

  it('does not fire a notification on 400 (silent: true)', async () => {
    const { useNotificationStore } = await import('../stores/notifications')
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"error":"bad"}', {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    await sendChatMessage('s1', 'msg', '/cwd')
    const store = useNotificationStore()
    expect(store.notifications).toHaveLength(0)
  })
})
