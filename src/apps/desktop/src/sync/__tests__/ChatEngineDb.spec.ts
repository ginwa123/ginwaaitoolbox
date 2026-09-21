import { describe, it, expect } from 'vitest'
import { ChatEngineDb } from '../ChatEngineDb'

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
      }),
    ).toBe('5')
    const a = {
      id: 'a',
      sortKey: 1,
      session_id: 's',
      created_at_nano: 1,
      created_at: 0,
      role: 'user',
      content: 'old',
    }
    const b = {
      id: 'b',
      sortKey: 2,
      session_id: 's',
      created_at_nano: 2,
      created_at: 0,
      role: 'assistant',
      content: 'new',
    }
    expect([a, b].sort((x, y) => eng.compareFn(x, y)).map((m) => m.id)).toEqual(['b', 'a'])
  })

  it('fetchDelta maps getChatHistory rows to ChatMessage (via syncOnMount)', async () => {
    const eng = new ChatEngineDb(async () => ({
      messages: [
        {
          id: 'm1',
          role: 'user',
          content: 'hello',
          created_at: 1700000000,
        },
      ],
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
    expect(await eng.getCursor('sess-1')).toBe('cur-9')
  })
})
