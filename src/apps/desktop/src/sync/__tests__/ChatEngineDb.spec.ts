import { describe, it, expect, vi } from 'vitest'
import { ChatEngineDb, toChatMessage } from '../ChatEngineDb'
import type { ChatRawRow } from '../ChatEngineDb'

const rawRow = (over: Partial<ChatRawRow> = {}): ChatRawRow =>
  ({
    id: 'm1',
    role: 'user',
    content: 'hello',
    created_at: 1700000000,
    ...over,
  }) as ChatRawRow

describe('ChatEngineDb mapping', () => {
  it('cursorOf returns created_at_nano string and compareFn sorts newest-first', () => {
    const eng = new ChatEngineDb(async () => ({
      messages: [],
      has_more: false,
      next_cursor: null,
    }))
    expect(
      eng.cursorOf({
        id: 'row-1',
        sortKey: 5,
        session_id: 's',
        created_at_nano: 5,
        created_at: 0,
        role: 'user',
        content: 'hi',
        raw: rawRow({ id: 'row-1' }),
      }),
    ).toBe('5')
    const a = toChatMessage('s', rawRow({ id: 'a', created_at: 1 }))
    const b = toChatMessage('s', rawRow({ id: 'b', created_at: 2 }))
    expect([a, b].sort((x, y) => eng.compareFn(x, y)).map((m) => m.id)).toEqual(['b', 'a'])
  })

  it('fetchDelta maps getChatHistory rows to ChatMessage (via syncOnMount)', async () => {
    const eng = new ChatEngineDb(async () => ({
      messages: [rawRow()],
      has_more: true,
      next_cursor: 'cur-9',
    }))
    const res = await eng.syncOnMount('sess-1', 50)
    expect(res.items).toHaveLength(1)
    const first = res.items[0]!
    expect(first.id).toBe('m1')
    expect(first.session_id).toBe('sess-1')
    expect(first.created_at).toBe(1700000000)
    expect(res.delta?.nextCursor).toBe('cur-9')
    // Sync cursor tracks the newest row, not the pagination cursor, so the
    // next mount fetches the tail instead of re-fetching the same page.
    expect(await eng.getCursor('sess-1')).toBe(String(1700000000 * 1e9))
  })

  it('stores the full server row in raw (tool calls / images / reasoning survive)', async () => {
    const eng = new ChatEngineDb(async () => ({
      messages: [
        rawRow({
          tool_calls_json: [{ name: 'edit' }],
          image_url: 'a.png|b.png',
          reasoning_content: 'thinking…',
        }),
      ],
      has_more: false,
      next_cursor: 'cur-1',
    }))
    const res = await eng.syncOnMount('sess-raw', 50)
    const cached = await eng.primeFromCache('sess-raw', 50)
    expect(cached).toHaveLength(1)
    const stored = cached[0]!
    expect(stored.raw.tool_calls_json).toEqual([{ name: 'edit' }])
    expect((stored.raw as { image_url?: string }).image_url).toBe('a.png|b.png')
    expect(stored.raw.reasoning_content).toBe('thinking…')
    expect(res.items[0]!.raw).toEqual(stored.raw)
  })

  it('delta-with-cursor sends cursor+asc; cold start sends no cursor (desc default)', async () => {
    const fetchFn = vi.fn(
      async (_sid: string, _limit: number, _cursor?: string, _dir?: string) => ({
        messages: [],
        has_more: false,
        next_cursor: 'cur-next',
      }),
    )
    const eng = new ChatEngineDb(fetchFn as never)
    // Cold start: no stored cursor → full load, direction left as default.
    await eng.loadDelta('sess-cold', 60)
    expect(fetchFn).toHaveBeenCalledTimes(1)
    expect(fetchFn.mock.calls[0]![2]).toBeUndefined()
    expect(fetchFn.mock.calls[0]![3] ?? 'desc').toBe('desc')

    // Warm mount: stored cursor → tail-only fetch with cursor+asc.
    fetchFn.mockClear()
    await eng.setCursor('sess-warm', 'stored-cur')
    await eng.putLocal('sess-warm', [toChatMessage('sess-warm', rawRow({ id: 'old' }))])
    const delta = await eng.loadDelta('sess-warm', 60)
    expect(fetchFn).toHaveBeenCalledTimes(1)
    expect(fetchFn.mock.calls[0]).toEqual(['sess-warm', 60, 'stored-cur', 'asc'])
    expect(delta?.cursorToSave).toBe('cur-next')
    expect(await eng.getCursor('sess-warm')).toBe('cur-next')
  })

  it('small delta (has_more=false, next_cursor=null) advances cursor to newest row', async () => {
    const fetchFn = vi.fn(
      async (_sid: string, _limit: number, _cursor?: string, _dir?: string) => ({
        messages: [rawRow({ id: 'n1', created_at: 100 }), rawRow({ id: 'n2', created_at: 200 })],
        has_more: false,
        next_cursor: null,
      }),
    )
    const eng = new ChatEngineDb(fetchFn as never)
    await eng.setCursor('sess-small', '1700000000')
    const delta = await eng.loadDelta('sess-small', 1000)
    // Tail-only fetch with the stored cursor…
    expect(fetchFn.mock.calls[0]).toEqual(['sess-small', 1000, '1700000000', 'asc'])
    // …and the cursor advances to the newest row instead of being wiped to null.
    expect(delta?.cursorToSave).toBe(String(200 * 1e9))
    expect(await eng.getCursor('sess-small')).toBe(String(200 * 1e9))
  })

  it('empty delta keeps the previous cursor instead of wiping it to null', async () => {
    const fetchFn = vi.fn(
      async (_sid: string, _limit: number, _cursor?: string, _dir?: string) => ({
        messages: [],
        has_more: false,
        next_cursor: null,
      }),
    )
    const eng = new ChatEngineDb(fetchFn as never)
    await eng.setCursor('sess-empty', '999')
    const delta = await eng.loadDelta('sess-empty', 1000)
    expect(delta?.cursorToSave).toBe('999')
    expect(await eng.getCursor('sess-empty')).toBe('999')
  })

  it('cold full load derives cursor from newest row when next_cursor is null', async () => {
    const fetchFn = vi.fn(
      async (_sid: string, _limit: number, _cursor?: string, _dir?: string) => ({
        messages: [rawRow({ id: 'a', created_at: 10 }), rawRow({ id: 'b', created_at: 30 })],
        has_more: false,
        next_cursor: null,
      }),
    )
    const eng = new ChatEngineDb(fetchFn as never)
    const delta = await eng.loadDelta('sess-fresh', 1000)
    expect(fetchFn.mock.calls[0]![2]).toBeUndefined()
    expect(delta?.cursorToSave).toBe(String(30 * 1e9))
    expect(await eng.getCursor('sess-fresh')).toBe(String(30 * 1e9))
  })

  it('older-from-cache hit serves rows with zero network calls', async () => {
    const fetchFn = vi.fn(async () => ({
      messages: [],
      has_more: false,
      next_cursor: null,
    }))
    const eng = new ChatEngineDb(fetchFn as never)
    const newer = toChatMessage('sess-older', rawRow({ id: 'new', created_at: 200 }))
    const older = toChatMessage('sess-older', rawRow({ id: 'old', created_at: 100 }))
    await eng.putLocal('sess-older', [newer, older])
    const rows = await eng.loadOlderFromCache('sess-older', newer.sortKey, 50)
    expect(rows.map((r) => r.id)).toEqual(['old'])
    // Full-fidelity raw rides along for the view mapper.
    expect(rows[0]!.raw.content).toBe('hello')
    expect(fetchFn).not.toHaveBeenCalled()
  })
})
