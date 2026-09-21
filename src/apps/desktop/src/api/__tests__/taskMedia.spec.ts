/**
 * Tests for the lazy task-media endpoint client (Migration 092).
 *
 * List/get return only `is_have_image` / `is_have_video` flags so board
 * fetches stay small; `getTaskMedia` fetches the full `||`-delimited
 * base64 TEXT columns on demand (called only when a flag is true).
 *
 * Contract:
 *   1. Hits `GET /api/workspaces/:ws/items/:item/tasks/:task_id/media`
 *      with encoded path segments.
 *   2. Splits the raw `||`-delimited strings into arrays (empty → []).
 *   3. 404 resolves null (task deleted / wrong item) — same as getTask.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'

import { getTaskMedia } from '@/api/index'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('getTaskMedia', () => {
  it('hits the media endpoint with encoded ids', async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ image_urls: '', video_urls: '' }))
    vi.stubGlobal('fetch', fetchMock)

    const data = await getTaskMedia('ws 1/2', 'item 3', 'task 4')
    expect(data).toEqual({ imageUrls: [], videoUrls: [] })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url] = fetchMock.mock.calls[0] as unknown as [string]
    expect(url).toBe('/api/workspaces/ws%201%2F2/items/item%203/tasks/task%204/media')
  })

  it('splits ||-delimited wire strings and drops empty segments', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () =>
        jsonResponse({
          image_urls: 'data:image/png;base64,AAA||data:image/png;base64,BBB',
          video_urls: 'data:video/mp4;base64,CCC',
        }),
      ),
    )

    const data = await getTaskMedia('ws', 'item', 'task')
    expect(data?.imageUrls).toEqual(['data:image/png;base64,AAA', 'data:image/png;base64,BBB'])
    expect(data?.videoUrls).toEqual(['data:video/mp4;base64,CCC'])
  })

  it('resolves null on 404', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse({ error: 'task not found' }, 404)),
    )

    const data = await getTaskMedia('ws', 'item', 'no_such_task')
    expect(data).toBeNull()
  })
})
