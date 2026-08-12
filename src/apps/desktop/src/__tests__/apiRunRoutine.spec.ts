/**
 * Unit tests for the api.runRoutine function and the modified
 * createTask / updateTaskSimple signatures (Chunk 5 of the
 * task-routines plan). Mocks global.fetch to assert URL, method,
 * headers, and body shape.
 *
 * Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunks-5.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { createTask, runRoutine, updateTaskSimple } from '../api'

describe('api.runRoutine', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    fetchMock.mockReset()
    global.fetch = fetchMock as unknown as typeof fetch
  })

  afterEach(() => {
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
  }

  it('POSTs to /api/workspaces/:w/items/:i/tasks/:tid/run with an empty body', async () => {
    mockFetchOnce(200, { session_id: 'task_alpha' })

    const result = await runRoutine('ws_1', 'item_1', 'task_alpha')

    expect(result).toEqual({ session_id: 'task_alpha' })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url.endsWith('/api/workspaces/ws_1/items/item_1/tasks/task_alpha/run')).toBe(true)
    expect(init.method).toBe('POST')
    // Body is empty (the backend doesn't need any input — it
    // already knows the routine from the path).
    expect(init.body).toBeUndefined()
  })

  it('returns { session_id } on 200', async () => {
    mockFetchOnce(200, { session_id: 'task_xyz' })
    const result = await runRoutine('ws', 'item', 'task_xyz')
    expect(result.session_id).toBe('task_xyz')
  })

  it('throws on non-2xx (409 if routine is disabled / already running)', async () => {
    mockFetchOnce(409, { error: 'routine disabled' })
    await expect(runRoutine('ws', 'item', 'task_off')).rejects.toThrow(/HTTP 409/)
  })
})

describe('api.createTask (extended signature)', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    fetchMock.mockReset()
    global.fetch = fetchMock as unknown as typeof fetch
  })

  afterEach(() => {
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
  }

  it('sends taskType="routine" + routine fields in the body for a routine task', async () => {
    mockFetchOnce(200, { id: 'task_1', name: 'Daily', task_type: 'routine' })

    await createTask('ws_1', 'item_1', {
      name: 'Daily',
      description: 'standup summary',
      taskType: 'routine',
      routine: {
        schedule: '0 9 * * 1-5',
        initial_prompt: 'summarize commits',
        enabled: true,
      },
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url.endsWith('/api/workspaces/ws_1/items/item_1/tasks')).toBe(true)
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      name: 'Daily',
      description: 'standup summary',
      task_type: 'routine',
      schedule: '0 9 * * 1-5',
      initial_prompt: 'summarize commits',
      enabled: true,
    })
  })

  it('sends taskType="standard" with no routine fields for a standard task', async () => {
    mockFetchOnce(200, { id: 'task_2', name: 'Chat', task_type: 'standard' })

    await createTask('ws_1', 'item_1', {
      name: 'Chat',
      description: undefined,
      taskType: 'standard',
    })

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(init.body as string)
    expect(body.task_type).toBe('standard')
    expect(body.schedule).toBeUndefined()
    expect(body.initial_prompt).toBeUndefined()
  })
})

describe('api.updateTaskSimple (routine fields)', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    fetchMock.mockReset()
    global.fetch = fetchMock as unknown as typeof fetch
  })

  afterEach(() => {
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
  }

  it('forwards schedule + initial_prompt + enabled through the body for an EditRoutine submit', async () => {
    mockFetchOnce(200, { success: true })

    await updateTaskSimple('task_1', {
      name: 'Daily standup',
      schedule: '0 10 * * 1-5',
      initial_prompt: 'summarize commits',
      enabled: true,
    })

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url.endsWith('/api/workspaces/tasks/task_1')).toBe(true)
    expect(init.method).toBe('PUT')
    expect(JSON.parse(init.body as string)).toEqual({
      name: 'Daily standup',
      schedule: '0 10 * * 1-5',
      initial_prompt: 'summarize commits',
      enabled: true,
    })
  })
})
