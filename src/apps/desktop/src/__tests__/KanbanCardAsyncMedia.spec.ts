/**
 * Card-first async media: cards render from the flag-only list payload
 * first, then thumbnails load behind via GET .../tasks/:id/media.
 *
 * Contract:
 *   1. fetchKanbanTasks with a flagged-but-unloaded task triggers a
 *      background getTasksMedia and patches imageUrls in place
 *      (badge -> thumb, no extra caller needed).
 *   2. fetchKanbanTasks with no media flags never calls getTasksMedia.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { flushPromises } from '@vue/test-utils'
import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const TINY_PNG_DATA_URL =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

const baseItem = {
  id: 'item_1',
  name: 'Board',
  item_type: 'kanban',
  kanban_columns: [
    {
      id: 'colA',
      name: 'todo',
      workspace_item_id: 'item_1',
      position: 0,
      created_at: '2026-01-01',
    },
  ],
}

function seedBoard() {
  const store = useWorkspacesStore()
  store.workspaces = [
    {
      id: 'ws_1',
      name: 'WS',
      icon: '📁',
      expanded: true,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      items: [{ ...baseItem, tasks: [] } as any],
    },
  ]
  return store
}

describe('Kanban card async media — list first, thumbnails after', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('patches thumbnails in the background after a flagged list lands', async () => {
    const store = seedBoard()
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      tasks: [
        {
          id: 'task_media_1',
          name: 'media task',
          kanban_column_id: 'colA',
          kanban_position: 0,
          is_have_image: true,
        },
      ] as any,
      has_more: false,
      next_cursor: null,
    })
    const mediaSpy = vi
      .spyOn(api, 'getTasksMedia')
      .mockResolvedValue(
        new Map([['task_media_1', { imageUrls: [TINY_PNG_DATA_URL], videoUrls: [] }]]),
      )

    await store.fetchKanbanTasks('ws_1', 'item_1', 'colA', 10)
    // Cards rendered from flags first…
    let tasks = store.workspaces[0]!.items[0]!.tasks!
    expect(tasks).toHaveLength(1)
    expect(tasks[0]!.is_have_image).toBe(true)
    // …then the background media round-trip lands.
    await flushPromises()
    await flushPromises()
    tasks = store.workspaces[0]!.items[0]!.tasks!
    expect(mediaSpy).toHaveBeenCalledWith('ws_1', 'item_1', ['task_media_1'])
    expect(tasks[0]!.imageUrls).toEqual([TINY_PNG_DATA_URL])
  })

  it('skips the media round-trip when no task is flagged', async () => {
    const store = seedBoard()
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      tasks: [
        { id: 'task_plain', name: 'plain', kanban_column_id: 'colA', kanban_position: 0 },
      ] as any,
      has_more: false,
      next_cursor: null,
    })
    const mediaSpy = vi.spyOn(api, 'getTasksMedia').mockResolvedValue(new Map())

    await store.fetchKanbanTasks('ws_1', 'item_1', 'colA', 10)
    await flushPromises()

    expect(mediaSpy).not.toHaveBeenCalled()
  })
})
