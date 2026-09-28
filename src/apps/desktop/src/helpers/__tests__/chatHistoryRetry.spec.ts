import { describe, expect, it, vi } from 'vitest'

import {
  fetchInitialHistoryWithRetry,
  INITIAL_HISTORY_RETRY_DELAYS_MS,
  INITIAL_HISTORY_TIMEOUT_MS,
} from '../chatHistoryRetry'

/** Never waits — records what it was asked to wait for instead. */
const fakeSleep = () => {
  const waits: number[] = []
  return {
    waits,
    sleep: (ms: number) => {
      waits.push(ms)
      return Promise.resolve()
    },
  }
}

describe('INITIAL_HISTORY_TIMEOUT_MS', () => {
  it("outlives apiFetch's 15 s default — that abort is what faked an empty session", () => {
    // apiFetch: `timeoutMs = 15_000`. A transcript page of PAGE_SIZE rows
    // with base64 image_urls routinely exceeds it.
    expect(INITIAL_HISTORY_TIMEOUT_MS).toBeGreaterThan(15_000)
  })

  it('is still finite, so a hung backend cannot park the skeleton forever', () => {
    expect(INITIAL_HISTORY_TIMEOUT_MS).toBeGreaterThan(0)
    expect(INITIAL_HISTORY_TIMEOUT_MS).toBeLessThan(120_000)
  })
})

describe('INITIAL_HISTORY_RETRY_DELAYS_MS', () => {
  it('starts at 0 — the first load must not wait', () => {
    expect(INITIAL_HISTORY_RETRY_DELAYS_MS[0]).toBe(0)
  })

  it('backs off monotonically from the second entry on', () => {
    const backoff = INITIAL_HISTORY_RETRY_DELAYS_MS.slice(1)
    expect(backoff.length).toBeGreaterThan(0)
    for (let i = 1; i < backoff.length; i++) {
      expect(backoff[i]!).toBeGreaterThan(backoff[i - 1]!)
    }
  })
})

describe('fetchInitialHistoryWithRetry', () => {
  it('returns the first success without sleeping at all', async () => {
    const { waits, sleep } = fakeSleep()
    const attempt = vi.fn().mockResolvedValue('transcript')

    await expect(fetchInitialHistoryWithRetry(attempt, { sleep })).resolves.toBe('transcript')
    expect(attempt).toHaveBeenCalledTimes(1)
    expect(waits).toEqual([])
  })

  it('keeps going after failures and returns the eventual success', async () => {
    const { waits, sleep } = fakeSleep()
    const attempt = vi
      .fn()
      .mockRejectedValueOnce(new Error('503'))
      .mockRejectedValueOnce(new Error('timeout'))
      .mockResolvedValue('transcript')

    await expect(fetchInitialHistoryWithRetry(attempt, { sleep })).resolves.toBe('transcript')
    expect(attempt).toHaveBeenCalledTimes(3)
    // Slept the backoff after attempt 1 and attempt 2 — never after the
    // success, and never before the first try.
    expect(waits).toEqual([
      INITIAL_HISTORY_RETRY_DELAYS_MS[1]!,
      INITIAL_HISTORY_RETRY_DELAYS_MS[2]!,
    ])
  })

  it('rejects with the LAST error once the schedule is exhausted', async () => {
    const { waits, sleep } = fakeSleep()
    const last = new Error('still down')
    const attempt = vi.fn().mockRejectedValueOnce(new Error('a')).mockRejectedValue(last)

    await expect(fetchInitialHistoryWithRetry(attempt, { sleep })).rejects.toBe(last)
    expect(attempt).toHaveBeenCalledTimes(INITIAL_HISTORY_RETRY_DELAYS_MS.length)
    expect(waits).toHaveLength(INITIAL_HISTORY_RETRY_DELAYS_MS.length - 1)
  })

  it('reports each retry with the error that caused it', async () => {
    const { sleep } = fakeSleep()
    const boom = new Error('boom')
    const attempt = vi.fn().mockRejectedValueOnce(boom).mockResolvedValue('ok')
    const onRetry = vi.fn()

    await fetchInitialHistoryWithRetry(attempt, { sleep, onRetry })

    expect(onRetry).toHaveBeenCalledTimes(1)
    expect(onRetry).toHaveBeenCalledWith({
      attempt: 1,
      delayMs: INITIAL_HISTORY_RETRY_DELAYS_MS[1],
      error: boom,
    })
  })

  it('honours a custom schedule', async () => {
    const { waits, sleep } = fakeSleep()
    const attempt = vi.fn().mockRejectedValue(new Error('nope'))

    await expect(
      fetchInitialHistoryWithRetry(attempt, { sleep, delaysMs: [0, 5] }),
    ).rejects.toThrow('nope')
    expect(attempt).toHaveBeenCalledTimes(2)
    expect(waits).toEqual([5])
  })

  it('makes exactly one attempt when the schedule is empty', async () => {
    const { sleep } = fakeSleep()
    const attempt = vi.fn().mockRejectedValue(new Error('nope'))

    await expect(fetchInitialHistoryWithRetry(attempt, { sleep, delaysMs: [] })).rejects.toThrow(
      'nope',
    )
    expect(attempt).toHaveBeenCalledTimes(1)
  })
})
