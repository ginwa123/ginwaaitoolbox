import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { apiTranscribe } from '../api/transcribe'

describe('apiTranscribe', () => {
  let fetchMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
  })

  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('POSTs the audio Blob to /api/transcribe and returns { text }', async () => {
    const blob = new Blob(['fake-audio-bytes'], { type: 'audio/webm' })
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: () => Promise.resolve({ text: 'hello world' }),
      text: () => Promise.resolve('{"text":"hello world"}'),
    })

    const result = await apiTranscribe(blob)

    expect(result).toEqual({ text: 'hello world' })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/transcribe')
    expect(init.method).toBe('POST')
    expect(init.body).toBe(blob) // raw Blob, NOT JSON-stringified
    const headers = init.headers as Record<string, string>
    expect(headers['Content-Type']).toBe('audio/webm')
  })

  it('uses the Blob mime type for the Content-Type header', async () => {
    const blob = new Blob(['ogg'], { type: 'audio/ogg' })
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: () => Promise.resolve({ text: 'hi' }),
      text: () => Promise.resolve('{"text":"hi"}'),
    })

    await apiTranscribe(blob)

    const secondCall = fetchMock.mock.calls[0] as [string, RequestInit]
    const headers = secondCall[1].headers as Record<string, string>
    expect(headers['Content-Type']).toBe('audio/ogg')
  })

  it('throws Error on 4xx response with the body in the message', async () => {
    const blob = new Blob(['x'], { type: 'audio/webm' })
    fetchMock.mockResolvedValueOnce({
      ok: false,
      status: 501,
      statusText: 'Not Implemented',
      json: () => Promise.resolve({ error: 'Whisper is not configured' }),
      text: () => Promise.resolve('{"error":"Whisper is not configured"}'),
    })

    await expect(apiTranscribe(blob)).rejects.toThrow(/Whisper is not configured/)
  })

  it('falls back to statusText when the body is empty', async () => {
    const blob = new Blob(['x'], { type: 'audio/webm' })
    fetchMock.mockResolvedValueOnce({
      ok: false,
      status: 502,
      statusText: 'Bad Gateway',
      json: () => Promise.reject(new Error('no json')),
      text: () => Promise.resolve(''),
    })

    await expect(apiTranscribe(blob)).rejects.toThrow(/502/)
  })
})