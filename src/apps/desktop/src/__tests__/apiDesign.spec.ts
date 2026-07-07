/**
 * Tests for the file-backed design-mode API functions (plan v5,
 * docs/superpowers/plans/2026-07-06-design-fs-rewrite.md).
 *
 * Covers the public surface after Chunk 4 of the design-fs-rewrite
 * plan:
 *   - createDesign             (POST   /items/design)
 *   - listDesignPages          (GET    /design/pages)
 *   - getDesignPage            (GET    /design/pages/:pid)
 *   - createDesignPage         (POST   /design/pages)
 *   - updateDesignPage         (PUT    /design/pages/:pid)
 *   - deleteDesignPage         (DELETE /design/pages/:pid)
 *   - listDesignElements       (GET    /design/pages/:pid/elements)
 *   - getDesignElement         (GET    /design/pages/:pid/elements/:eid)
 *   - createDesignElement      (POST   /design/pages/:pid/elements)
 *   - updateDesignElement      (PUT    /design/pages/:pid/elements/:eid)
 *   - moveDesignElement        (PATCH  .../move)
 *   - resizeDesignElement      (PATCH  .../resize)
 *   - deleteDesignElement      (DELETE /design/pages/:pid/elements/:eid)
 *
 * Uses the apiFetch-mock-must-include-text-and-pinia pattern: every
 * fetch mock must implement both `json()` and `text()` (apiFetch reads
 * the body on non-2xx for the error notification toast), and Pinia
 * must be active before the tests run (apiFetch invokes
 * useNotificationStore().notifyError).
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import {
  createDesign,
  listDesignPages,
  getDesignPage,
  createDesignPage,
  updateDesignPage,
  deleteDesignPage,
  listDesignElements,
  getDesignElement,
  createDesignElement,
  updateDesignElement,
  moveDesignElement,
  resizeDesignElement,
  deleteDesignElement,
} from '../api'

function mockFetchOnce(status: number, body: unknown) {
  vi.mocked(globalThis.fetch).mockResolvedValueOnce({
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 || status === 201 ? 'OK' : 'Error',
    // apiFetch reads .json() on success and .text() on error to build
    // the toast body. Both must be present.
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(JSON.stringify(body)),
  } as Response)
}

describe('design-mode API functions', () => {
  const originalFetch = globalThis.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    globalThis.fetch = fetchMock as unknown as typeof fetch
  })

  afterEach(() => {
    fetchMock.mockReset()
    globalThis.fetch = originalFetch
  })

  // ─── Page CRUD ───────────────────────────────────────────────────────────

  describe('createDesign', () => {
    it('POSTs to /items/design with the name and path', async () => {
      mockFetchOnce(201, {
        id: 'item_design_1',
        workspace_id: 'ws_1',
        item_type: 'design',
        name: 'My Design',
        path: '/home/user/projects/auth-ui',
        position: 0,
      })

      const item = await createDesign(
        'ws_1',
        'My Design',
        '/home/user/projects/auth-ui',
      )
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe('/api/workspaces/ws_1/items/design')
      expect(init.method).toBe('POST')
      expect(JSON.parse(init.body as string)).toEqual({
        name: 'My Design',
        path: '/home/user/projects/auth-ui',
      })
      expect(item.id).toBe('item_design_1')
      expect(item.item_type).toBe('design')
      expect(item.path).toBe('/home/user/projects/auth-ui')
    })

    it('defaults path to "" when omitted', async () => {
      mockFetchOnce(201, {
        id: 'item_design_2',
        workspace_id: 'ws_1',
        item_type: 'design',
        name: 'Scratch',
        position: 0,
      })

      await createDesign('ws_1', 'Scratch')

      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [, init] = call
      expect(JSON.parse(init.body as string)).toEqual({
        name: 'Scratch',
        path: '',
      })
    })
  })

  describe('listDesignPages', () => {
    it('GETs the pages list and unwraps the {pages, count} envelope', async () => {
      mockFetchOnce(200, {
        pages: [
          {
            id: 'page_1',
            name: 'Login',
            width: 1440,
            height: 1024,
            x: 0,
            y: 0,
            position: 0,
          },
          {
            id: 'page_2',
            name: 'Dashboard',
            width: 1440,
            height: 1024,
            x: 1600,
            y: 0,
            position: 1,
          },
        ],
        count: 2,
      })

      const pages = await listDesignPages('ws_1', 'item_design_1')
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe('/api/workspaces/ws_1/items/item_design_1/design/pages')
      expect(init.method).toBe('GET')
      expect(pages).toHaveLength(2)
      expect(pages[0]?.id).toBe('page_1')
      expect(pages[0]?.name).toBe('Login')
      expect(pages[0]?.width).toBe(1440)
      // No html field — pages are metadata-only containers in v5.
      expect((pages[0] as { html?: unknown }).html).toBeUndefined()
    })
  })

  describe('getDesignPage', () => {
    it('GETs the single page and unwraps {page: DesignPageFull}', async () => {
      mockFetchOnce(200, {
        page: {
          id: 'page_1',
          workspace_item_id: 'item_design_1',
          name: 'Login',
          width: 1440,
          height: 1024,
          x: 0,
          y: 0,
          position: 0,
          created_at: '2026-07-06 10:00:00',
          updated_at: '2026-07-06 10:00:00',
        },
      })

      const page = await getDesignPage('ws_1', 'item_design_1', 'page_1')
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe(
        '/api/workspaces/ws_1/items/item_design_1/design/pages/page_1',
      )
      expect(init.method).toBe('GET')
      expect(page.id).toBe('page_1')
      expect(page.workspace_item_id).toBe('item_design_1')
      expect(page.width).toBe(1440)
      // Pages still have no html in v5.
      expect((page as { html?: unknown }).html).toBeUndefined()
    })
  })

  describe('createDesignPage', () => {
    it('POSTs the new page body and unwraps {page: DesignPageFull}', async () => {
      mockFetchOnce(201, {
        page: {
          id: 'page_new',
          workspace_item_id: 'item_design_1',
          name: 'Login',
          width: 1440,
          height: 1024,
          x: 0,
          y: 0,
          position: 0,
          created_at: 't',
          updated_at: 't',
        },
      })

      const page = await createDesignPage('ws_1', 'item_design_1', {
        name: 'Login',
      })
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe('/api/workspaces/ws_1/items/item_design_1/design/pages')
      expect(init.method).toBe('POST')
      expect(JSON.parse(init.body as string)).toEqual({ name: 'Login' })
      expect(page.id).toBe('page_new')
      expect(page.name).toBe('Login')
    })

    it('forwards optional geometry fields when set', async () => {
      mockFetchOnce(201, {
        page: {
          id: 'page_wide',
          workspace_item_id: 'item_design_1',
          name: 'Hi Chef',
          width: 1920,
          height: 1080,
          x: 200,
          y: 100,
          position: 0,
          created_at: 't',
          updated_at: 't',
        },
      })

      await createDesignPage('ws_1', 'item_design_1', {
        name: 'Hi Chef',
        width: 1920,
        height: 1080,
        x: 200,
        y: 100,
      })

      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [, init] = call
      expect(JSON.parse(init.body as string)).toEqual({
        name: 'Hi Chef',
        width: 1920,
        height: 1080,
        x: 200,
        y: 100,
      })
    })
  })

  describe('updateDesignPage', () => {
    it('PUTs the geometry body and unwraps {page: DesignPageFull}', async () => {
      mockFetchOnce(200, {
        page: {
          id: 'page_1',
          workspace_item_id: 'item_design_1',
          name: 'Login',
          width: 1920,
          height: 1080,
          x: 100,
          y: 50,
          position: 0,
          created_at: 't',
          updated_at: 't2',
        },
      })

      const page = await updateDesignPage(
        'ws_1',
        'item_design_1',
        'page_1',
        { width: 1920, height: 1080 },
      )
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe(
        '/api/workspaces/ws_1/items/item_design_1/design/pages/page_1',
      )
      expect(init.method).toBe('PUT')
      expect(JSON.parse(init.body as string)).toEqual({
        width: 1920,
        height: 1080,
      })
      expect(page.width).toBe(1920)
      expect(page.updated_at).toBe('t2')
    })
  })

  describe('deleteDesignPage', () => {
    it('DELETEs the page and returns the deleted flag', async () => {
      mockFetchOnce(200, { deleted: true, page_id: 'page_1' })

      const result = await deleteDesignPage('ws_1', 'item_design_1', 'page_1')
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe(
        '/api/workspaces/ws_1/items/item_design_1/design/pages/page_1',
      )
      expect(init.method).toBe('DELETE')
      expect(result.deleted).toBe(true)
      expect(result.page_id).toBe('page_1')
    })
  })

  // ─── Element CRUD ────────────────────────────────────────────────────────

  describe('listDesignElements', () => {
    it('GETs the elements list and unwraps {elements, count}', async () => {
      mockFetchOnce(200, {
        elements: [
          {
            id: 'el_1',
            page_id: 'page_1',
            name: 'Background',
            file_path: '.nalar/design/Login/background.html',
            x: 0,
            y: 0,
            width: 1440,
            height: 1024,
            z_index: -1,
            position: 0,
          },
          {
            id: 'el_2',
            page_id: 'page_1',
            name: 'Hero card',
            file_path: '.nalar/design/Login/hero.html',
            x: 120,
            y: 80,
            width: 375,
            height: 250,
            z_index: 1,
            position: 1,
          },
        ],
        count: 2,
      })

      const elements = await listDesignElements(
        'ws_1',
        'item_design_1',
        'page_1',
      )
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe(
        '/api/workspaces/ws_1/items/item_design_1/design/pages/page_1/elements',
      )
      expect(init.method).toBe('GET')
      expect(elements).toHaveLength(2)
      expect(elements[0]?.name).toBe('Background')
      expect(elements[0]?.z_index).toBe(-1)
      // List payload does NOT include html — saved for `getDesignElement`.
      expect((elements[0] as { html?: unknown }).html).toBeUndefined()
    })
  })

  describe('getDesignElement', () => {
    it('GETs the single element with html and unwraps {element}', async () => {
      mockFetchOnce(200, {
        element: {
          id: 'el_1',
          page_id: 'page_1',
          name: 'Hero card',
          file_path: '.nalar/design/Login/hero.html',
          x: 120,
          y: 80,
          width: 375,
          height: 250,
          z_index: 1,
          position: 0,
          created_at: 't',
          updated_at: 't',
          html: '<div class="hero">Hi Chef</div>',
        },
      })

      const el = await getDesignElement(
        'ws_1',
        'item_design_1',
        'page_1',
        'el_1',
      )
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe(
        '/api/workspaces/ws_1/items/item_design_1/design/pages/page_1/elements/el_1',
      )
      expect(init.method).toBe('GET')
      expect(el.id).toBe('el_1')
      expect(el.html).toBe('<div class="hero">Hi Chef</div>')
      expect(el.file_path).toBe('.nalar/design/Login/hero.html')
    })
  })

  describe('createDesignElement', () => {
    it('POSTs the new element body and unwraps {element}', async () => {
      mockFetchOnce(201, {
        element: {
          id: 'el_new',
          page_id: 'page_1',
          name: 'Hero card',
          file_path: '.nalar/design/Login/hero.html',
          x: 120,
          y: 80,
          width: 375,
          height: 250,
          z_index: 1,
          position: 0,
          created_at: 't',
          updated_at: 't',
          html: '<div class="hero">Hi Chef</div>',
        },
      })

      const el = await createDesignElement(
        'ws_1',
        'item_design_1',
        'page_1',
        { name: 'Hero card', html: '<div class="hero">Hi Chef</div>' },
      )
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe(
        '/api/workspaces/ws_1/items/item_design_1/design/pages/page_1/elements',
      )
      expect(init.method).toBe('POST')
      expect(JSON.parse(init.body as string)).toEqual({
        name: 'Hero card',
        html: '<div class="hero">Hi Chef</div>',
      })
      expect(el.id).toBe('el_new')
      expect(el.html).toBe('<div class="hero">Hi Chef</div>')
    })

    it('forwards optional geometry fields when set', async () => {
      mockFetchOnce(201, {
        element: {
          id: 'el_1',
          page_id: 'page_1',
          name: 'Phone',
          file_path: '.nalar/design/Login/phone.html',
          x: 600,
          y: 200,
          width: 375,
          height: 667,
          z_index: 2,
          position: 0,
          created_at: 't',
          updated_at: 't',
          html: '<div class="phone">phone</div>',
        },
      })

      await createDesignElement('ws_1', 'item_design_1', 'page_1', {
        name: 'Phone',
        html: '<div class="phone">phone</div>',
        x: 600,
        y: 200,
        z_index: 2,
      })

      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [, init] = call
      expect(JSON.parse(init.body as string)).toEqual({
        name: 'Phone',
        html: '<div class="phone">phone</div>',
        x: 600,
        y: 200,
        z_index: 2,
      })
    })
  })

  describe('updateDesignElement', () => {
    it('PUTs the partial element body', async () => {
      mockFetchOnce(200, {
        element: {
          id: 'el_1',
          page_id: 'page_1',
          name: 'Hero card',
          file_path: '.nalar/design/Login/hero.html',
          x: 150,
          y: 90,
          width: 375,
          height: 250,
          z_index: 2,
          position: 0,
          created_at: 't',
          updated_at: 't2',
          html: '<div class="hero v2">Hi</div>',
        },
      })

      const el = await updateDesignElement(
        'ws_1',
        'item_design_1',
        'page_1',
        'el_1',
        { x: 150, y: 90, html: '<div class="hero v2">Hi</div>' },
      )
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe(
        '/api/workspaces/ws_1/items/item_design_1/design/pages/page_1/elements/el_1',
      )
      expect(init.method).toBe('PUT')
      expect(JSON.parse(init.body as string)).toEqual({
        x: 150,
        y: 90,
        html: '<div class="hero v2">Hi</div>',
      })
      expect(el.x).toBe(150)
      expect(el.html).toBe('<div class="hero v2">Hi</div>')
    })
  })

  describe('moveDesignElement', () => {
    it('PATCHes /move with {x, y} (dedicated endpoint)', async () => {
      mockFetchOnce(200, {
        element: {
          id: 'el_1',
          page_id: 'page_1',
          name: 'Hero card',
          file_path: '.nalar/design/Login/hero.html',
          x: 200,
          y: 120,
          width: 375,
          height: 250,
          z_index: 1,
          position: 0,
          created_at: 't',
          updated_at: 't2',
          html: '<div class="hero">Hi Chef</div>',
        },
      })

      const el = await moveDesignElement(
        'ws_1',
        'item_design_1',
        'page_1',
        'el_1',
        200,
        120,
      )
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe(
        '/api/workspaces/ws_1/items/item_design_1/design/pages/page_1/elements/el_1/move',
      )
      expect(init.method).toBe('PATCH')
      expect(JSON.parse(init.body as string)).toEqual({ x: 200, y: 120 })
      expect(el.x).toBe(200)
      expect(el.y).toBe(120)
    })
  })

  describe('resizeDesignElement', () => {
    it('PATCHes /resize with {width, height} (dedicated endpoint)', async () => {
      mockFetchOnce(200, {
        element: {
          id: 'el_1',
          page_id: 'page_1',
          name: 'Hero card',
          file_path: '.nalar/design/Login/hero.html',
          x: 120,
          y: 80,
          width: 500,
          height: 300,
          z_index: 1,
          position: 0,
          created_at: 't',
          updated_at: 't2',
          html: '<div class="hero">Hi Chef</div>',
        },
      })

      const el = await resizeDesignElement(
        'ws_1',
        'item_design_1',
        'page_1',
        'el_1',
        500,
        300,
      )
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe(
        '/api/workspaces/ws_1/items/item_design_1/design/pages/page_1/elements/el_1/resize',
      )
      expect(init.method).toBe('PATCH')
      expect(JSON.parse(init.body as string)).toEqual({
        width: 500,
        height: 300,
      })
      expect(el.width).toBe(500)
      expect(el.height).toBe(300)
    })
  })

  describe('deleteDesignElement', () => {
    it('DELETEs the element and returns the deleted flag', async () => {
      mockFetchOnce(200, { deleted: true, element_id: 'el_1' })

      const result = await deleteDesignElement(
        'ws_1',
        'item_design_1',
        'page_1',
        'el_1',
      )
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
      const [url, init] = call
      expect(url).toBe(
        '/api/workspaces/ws_1/items/item_design_1/design/pages/page_1/elements/el_1',
      )
      expect(init.method).toBe('DELETE')
      expect(result.deleted).toBe(true)
      expect(result.element_id).toBe('el_1')
    })
  })
})
