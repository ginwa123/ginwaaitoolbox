import { describe, it, expect, beforeEach, vi } from 'vitest'
import { useKanbanTagSuggestions } from '../composables/useKanbanTagSuggestions'
import * as api from '../api'

describe('useKanbanTagSuggestions', () => {
  beforeEach(() => {
    vi.resetAllMocks()
  })

  it('ensureLoaded() fetches the first page via the API', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'bug', count: 3, last_used_at: null }],
      has_more: true,
    })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledWith('ws_x', 'item_x', { limit: 8, offset: 0 })
    expect(c.tags.value).toHaveLength(1)
    expect(c.hasMore.value).toBe(true)
    expect(c.loaded.value).toBe(true)
  })

  it('loadNextPage() appends the next page when has_more was true', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions')
      .mockResolvedValueOnce({
        tags: [{ name: 'a', count: 1, last_used_at: null }],
        has_more: true,
      })
      .mockResolvedValueOnce({
        tags: [{ name: 'b', count: 1, last_used_at: null }],
        has_more: false,
      })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    await c.loadNextPage()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(2)
    expect(api.getKanbanTagSuggestions).toHaveBeenNthCalledWith(2, 'ws_x', 'item_x', { limit: 8, offset: 8 })
    expect(c.tags.value).toHaveLength(2)
    expect(c.tags.value[0].name).toBe('a')
    expect(c.tags.value[1].name).toBe('b')
    expect(c.hasMore.value).toBe(false)
  })

  it('loadNextPage() is a no-op when has_more is false (no extra fetch)', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: false,
    })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    await c.loadNextPage()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(1)
  })

  it('loadNextPage() is a no-op while another loadNextPage is in flight (no double-fetch)', async () => {
    let resolveFirst!: (v: any) => void
    let resolveSecond!: (v: any) => void
    vi.spyOn(api, 'getKanbanTagSuggestions')
      .mockReturnValueOnce(new Promise((r) => { resolveFirst = r }) as any)
      .mockReturnValueOnce(new Promise((r) => { resolveSecond = r }) as any)
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    resolveFirst({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: true,
    })
    await c.ensureLoaded()
    const p1 = c.loadNextPage()
    const p2 = c.loadNextPage()
    resolveSecond({
      tags: [{ name: 'b', count: 1, last_used_at: null }],
      has_more: false,
    })
    await Promise.all([p1, p2])
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(2)
  })

  it('ensureLoaded() does NOT re-fetch on subsequent calls when already loaded', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: false,
    })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    await c.ensureLoaded()
    await c.ensureLoaded()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(1)
  })

  it('reset() clears the loaded list so ensureLoaded() can start fresh', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: false,
    })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    expect(c.tags.value).toHaveLength(1)
    c.reset()
    expect(c.tags.value).toHaveLength(0)
    expect(c.loaded.value).toBe(false)
    await c.ensureLoaded()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(2)
  })

  it('loading flag is true while a fetch is in flight', async () => {
    let resolveFetch!: (v: any) => void
    vi.spyOn(api, 'getKanbanTagSuggestions').mockReturnValueOnce(
      new Promise((r) => { resolveFetch = r }) as any,
    )
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    const p = c.ensureLoaded()
    expect(c.loading.value).toBe(true)
    resolveFetch({ tags: [], has_more: false })
    await p
    expect(c.loading.value).toBe(false)
  })

  it('returns empty + has_more=false on API failure (graceful degradation)', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockRejectedValue(new Error('boom'))
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    expect(c.tags.value).toEqual([])
    expect(c.hasMore.value).toBe(false)
    expect(c.loading.value).toBe(false)
  })
})
