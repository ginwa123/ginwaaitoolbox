/**
 * Tests for the design-mode API functions (createDesign, listDesignPages,
 * getDesignPage, updateDesignPage, deleteDesignPage).
 *
 * Uses the apiFetch-mock-must-include-text-and-pinia pattern: every
 * fetch mock must implement both `json()` and `text()` (apiFetch reads
 * the body on non-2xx for the error notification toast), and Pinia
 * must be active before the tests run (apiFetch invokes
 * useNotificationStore().notifyError).
 */

import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import {
  createDesign,
  deleteDesignPage,
  getDesignPage,
  listDesignPages,
  updateDesignPage,
} from '../api'

function mockFetchOnce(status: number, body: unknown) {
  vi.mocked(globalThis.fetch).mockResolvedValueOnce({
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : 'Error',
    // apiFetch reads .json() on success and .text() on error to build
    // the toast body. Both must be present.
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(JSON.stringify(body)),
  } as Response)
}

describe('design-mode API functions', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    globalThis.fetch = vi.fn()
  })

  it('createDesign POSTs to /items/design with the name', async () => {
    mockFetchOnce(201, {
      id: 'item_design_1',
      workspace_id: 'ws_1',
      item_type: 'design',
      name: 'My Design',
      position: 0,
      pages: [],
    })

    const item = await createDesign('ws_1', 'My Design')

    expect(fetch).toHaveBeenCalledTimes(1)
    const [url, init] = vi.mocked(fetch).mock.calls[0]!
    expect(url).toBe('/api/workspaces/ws_1/items/design')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({ name: 'My Design' })
    expect(item.id).toBe('item_design_1')
    expect(item.item_type).toBe('design')
  })

  it('listDesignPages GETs the page summary list (no html)', async () => {
    mockFetchOnce(200, [
      { id: 'page_1', name: 'Login', position: 0, created_at: 't', updated_at: 't' },
      { id: 'page_2', name: 'Dashboard', position: 1, created_at: 't', updated_at: 't' },
    ])

    const pages = await listDesignPages('ws_1', 'item_design_1')

    expect(fetch).toHaveBeenCalledTimes(1)
    const [url, init] = vi.mocked(fetch).mock.calls[0]!
    expect(url).toBe('/api/workspaces/ws_1/items/item_design_1/design/pages')
    expect(init.method).toBe('GET')
    expect(pages).toHaveLength(2)
    expect(pages[0].name).toBe('Login')
  })

  it('getDesignPage GETs the single page including html', async () => {
    mockFetchOnce(200, {
      id: 'page_1',
      name: 'Login',
      position: 0,
      created_at: 't',
      updated_at: 't',
      html: '<!doctype html><h1>Login</h1>',
    })

    const page = await getDesignPage('ws_1', 'item_design_1', 'page_1')

    expect(fetch).toHaveBeenCalledTimes(1)
    const [url, init] = vi.mocked(fetch).mock.calls[0]!
    expect(url).toBe('/api/workspaces/ws_1/items/item_design_1/design/pages/page_1')
    expect(init.method).toBe('GET')
    expect(page.html).toBe('<!doctype html><h1>Login</h1>')
  })

  it('updateDesignPage PUTs the html body', async () => {
    mockFetchOnce(200, {
      id: 'page_1',
      name: 'Login',
      position: 0,
      created_at: 't',
      updated_at: 't2',
      html: '<!doctype html><h1>v2</h1>',
    })

    const page = await updateDesignPage(
      'ws_1',
      'item_design_1',
      'page_1',
      '<!doctype html><h1>v2</h1>',
    )

    expect(fetch).toHaveBeenCalledTimes(1)
    const [url, init] = vi.mocked(fetch).mock.calls[0]!
    expect(url).toBe('/api/workspaces/ws_1/items/item_design_1/design/pages/page_1')
    expect(init.method).toBe('PUT')
    expect(JSON.parse(init.body as string)).toEqual({
      html: '<!doctype html><h1>v2</h1>',
    })
    expect(page.html).toBe('<!doctype html><h1>v2</h1>')
  })

  it('deleteDesignPage DELETEs the page and returns the deleted flag', async () => {
    mockFetchOnce(200, { deleted: true, page_id: 'page_1' })

    const result = await deleteDesignPage('ws_1', 'item_design_1', 'page_1')

    expect(fetch).toHaveBeenCalledTimes(1)
    const [url, init] = vi.mocked(fetch).mock.calls[0]!
    expect(url).toBe('/api/workspaces/ws_1/items/item_design_1/design/pages/page_1')
    expect(init.method).toBe('DELETE')
    expect(result.deleted).toBe(true)
    expect(result.page_id).toBe('page_1')
  })
})