import { describe, it, expect } from 'vitest'
import {
  buildItemIdWithChat,
  parseItemIdWithChat,
  CHAT_SUFFIX,
} from '../buildItemIdWithChat'

describe('buildItemIdWithChat', () => {
  it('returns bare itemId when chatTaskId is null', () => {
    expect(buildItemIdWithChat('item_y', null)).toBe('item_y')
  })

  it('appends /chat/<taskId> when chatTaskId is provided', () => {
    expect(buildItemIdWithChat('item_y', 'task_w')).toBe('item_y/chat/task_w')
  })

  it('throws if the item id already contains the /chat/ separator', () => {
    expect(() => buildItemIdWithChat('item_y/chat/task_w', 'task_new')).toThrow(
      /item id cannot contain "\/chat\/"/,
    )
  })

  it('throws on empty itemId', () => {
    expect(() => buildItemIdWithChat('', 'task_w')).toThrow(/non-empty string/)
  })
})

describe('parseItemIdWithChat', () => {
  it('returns chatTaskId=null for a bare item id', () => {
    expect(parseItemIdWithChat('item_y')).toEqual({ itemId: 'item_y', chatTaskId: null })
  })

  it('returns itemId + chatTaskId for the suffixed form', () => {
    expect(parseItemIdWithChat('item_y/chat/task_w')).toEqual({
      itemId: 'item_y',
      chatTaskId: 'task_w',
    })
  })

  it('returns empty itemId + null chatTaskId for empty input', () => {
    expect(parseItemIdWithChat('')).toEqual({ itemId: '', chatTaskId: null })
  })

  it('round-trips through buildItemIdWithChat', () => {
    const original = 'item_y'
    const taskId = 'task_w'
    const built = buildItemIdWithChat(original, taskId)
    expect(parseItemIdWithChat(built)).toEqual({ itemId: original, chatTaskId: taskId })
  })

  it('round-trips with chatTaskId=null', () => {
    const built = buildItemIdWithChat('item_y', null)
    expect(parseItemIdWithChat(built)).toEqual({ itemId: 'item_y', chatTaskId: null })
  })
})

describe('CHAT_SUFFIX constant', () => {
  it('equals /chat/', () => {
    expect(CHAT_SUFFIX).toBe('/chat/')
  })
})
