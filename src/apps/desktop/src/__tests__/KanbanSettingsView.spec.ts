/**
 * Tests for KanbanSettingsView — the dedicated full-page route for
 * per-board kanban settings. Replaces KanbanSettingsDialog (the
 * centered modal that used to pop up when the user clicked ⚙ on a
 * kanban board header).
 *
 * URL: /app/kanban/:itemId/settings (path-based vue-router route).
 * The page reads itemId from route.params and derives workspaceId
 * from the store by walking workspaces.
 *
 * Mount pattern: same as KanbanSettingsDialog.spec.ts. The
 * KanbanColumnEditor child uses <Teleport to="body">, so the rendered
 * DOM lives outside wrapper.element when the rename/delete editor is
 * open. We use `attachTo: document.body` and query the teleported
 * content via `document.querySelector` / `document.querySelectorAll`
 * (NOT `wrapper.find`). `wrapper.emitted` still works because it
 * tracks the vm, not the DOM tree.
 *
 * Plan: docs/superpowers/plans/2026-09-02-kanban-settings-as-page.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { reactive } from 'vue'

import KanbanSettingsView from '@/components/views/KanbanSettingsView.vue'
import { useWorkspacesStore, type WorkspaceItem } from '@/stores/workspaces'

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
  useRouterMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRoute: useRouteMock,
    useRouter: useRouterMock,
  }
})

const baseItem: WorkspaceItem = {
  id: 'wi_test',
  name: 'Sprint 12',
  item_type: 'kanban',
  path: null,
  kanban_columns: [
    {
      id: 'col_a',
      workspace_item_id: 'wi_test',
      name: 'todo',
      description: 'Not started',
      position: 0,
      created_at: '2026-06-26T10:00:00Z',
    },
    {
      id: 'col_b',
      workspace_item_id: 'wi_test',
      name: 'done',
      description: '',
      position: 1,
      created_at: '2026-06-26T10:00:00Z',
    },
  ],
}

function setupRoute(
  query: Record<string, string>,
  path = '/app/kanban/wi_test/settings',
  params: Record<string, string> = { itemId: 'wi_test' },
) {
  const obj = reactive({ query, path, params, fullPath: path })
  useRouteMock.mockReturnValue(obj as any)
  const push = vi.fn()
  const replace = vi.fn()
  const back = vi.fn()
  useRouterMock.mockReturnValue({ push, replace, back, currentRoute: obj } as any)
  return { route: obj, router: { push, replace, back } }
}

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

function setInputValue(selector: string, value: string) {
  const el = findInDom<HTMLInputElement | HTMLTextAreaElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.value = value
  el.dispatchEvent(new Event('input', { bubbles: true }))
}

/**
 * Seed the workspacesStore with a workspace that contains the given
 * kanban item. Returns the store so tests can inspect/assert.
 */
function seedWorkspaces(item: WorkspaceItem | null = baseItem) {
  const store = useWorkspacesStore()
  // Force-create the workspace + items arrays; we don't need the full
  // initializeFromSystemFolder fetch since the page only reads
  // workspaces[].items[].
  store.workspaces = [
    {
      id: 'ws_1',
      name: 'Test Workspace',
      icon: '📁',
      items: item ? [item] : [],
      expanded: true,
    },
  ]
  // activeWorkspaceItemId is set via setActiveWorkspaceItem so the
  // computed works as expected.
  if (item) {
    store.setActiveWorkspaceItem(item.id)
  }
  return store
}

describe('KanbanSettingsView', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    setupRoute({})
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.innerHTML = ''
  })

  function mountView() {
    document.body.innerHTML = ''
    wrapper = mount(KanbanSettingsView, {
      attachTo: document.body,
      global: {
        stubs: {
          // Stub the memories view — it's heavy (renders a full
          // memories panel) and we only test its presence/absence.
          WorkspaceItemMemoriesView: { template: '<div data-testid="stub-memories"></div>' },
          // Stub KanbanColumnEditor to avoid the Teleport + nested
          // dialog complexity in the rename/delete tests. Mirrors the
          // real editor's `kanban-column-editor-<mode>-submit`
          // data-testid so the 2-step delete test can confirm via
          // the submit button (same shape as the original
          // KanbanSettingsDialog test at line 180).
          KanbanColumnEditor: {
            template:
              '<div v-if="show" :data-testid="`kanban-column-editor-${mode}`">' +
              '<button v-if="mode===\'delete\'" :data-testid="`kanban-column-editor-${mode}-submit`" @click="$emit(\'delete\')">Delete</button>' +
              '</div>',
            props: ['show', 'mode', 'initialName', 'initialDescription'],
          },
        },
      },
    })
    return wrapper
  }

  it('renders the kanban name in the header', async () => {
    seedWorkspaces()
    mountView()
    await flushPromises()
    const page = findInDom<HTMLElement>('[data-testid="kanban-settings-page"]')
    expect(page).not.toBeNull()
    expect(page?.textContent).toContain('Sprint 12')
  })

  it('renders one row per column sorted by position', async () => {
    seedWorkspaces()
    mountView()
    await flushPromises()
    const rows = findAllInDom<HTMLElement>(
      '[data-testid^="kanban-settings-page-column-row-"]',
    )
    expect(rows).toHaveLength(2)
    expect(rows[0]!.getAttribute('data-testid')).toBe(
      'kanban-settings-page-column-row-col_a',
    )
    expect(rows[1]!.getAttribute('data-testid')).toBe(
      'kanban-settings-page-column-row-col_b',
    )
  })

  it('adds a column via the inline form', async () => {
    seedWorkspaces()
    mountView()
    await flushPromises()
    setInputValue('[data-testid="kanban-settings-page-add-name"]', 'Review')
    await flushPromises()
    clickInDom('[data-testid="kanban-settings-page-add-submit"]')
    expect(wrapper!.emitted('addColumn')).toEqual([['Review', '']])
  })

  it('deletes a column via the per-row Delete button (opens editor, then confirms)', async () => {
    // The per-row Delete button opens the editor in delete mode
    // (mirrors KanbanSettingsDialog's 2-step flow). The editor's
    // Delete submit is what fires `deleteColumn`. Mirrors the
    // original KanbanSettingsDialog test at line 166.
    seedWorkspaces()
    mountView()
    await flushPromises()
    // 1. Click the per-row Delete button on col_a.
    clickInDom('[data-testid="kanban-settings-page-delete-col_a"]')
    await flushPromises()
    // 2. Click the editor's Delete submit to confirm.
    clickInDom('[data-testid="kanban-column-editor-delete-submit"]')
    expect(wrapper!.emitted('deleteColumn')).toEqual([['col_a']])
  })

  it('renames the kanban via the inline pencil', async () => {
    seedWorkspaces()
    mountView()
    await flushPromises()
    const renameDisplay = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-page-rename-display"]',
    )
    expect(renameDisplay).not.toBeNull()
    renameDisplay!.click()
    await flushPromises()
    setInputValue(
      '[data-testid="kanban-settings-page-rename-input"]',
      'Sprint 13',
    )
    clickInDom('[data-testid="kanban-settings-page-rename-save"]')
    expect(wrapper!.emitted('renameItem')).toEqual([['Sprint 13']])
  })

  it('copies spec via the footer button', async () => {
    seedWorkspaces()
    mountView()
    await flushPromises()
    clickInDom('[data-testid="kanban-settings-page-copy-spec"]')
    expect(wrapper!.emitted('copySpec')).toBeDefined()
  })

  it('navigates back to the kanban board on the Back button (workspaceId derived from store)', async () => {
    seedWorkspaces()
    const { router } = setupRoute({})
    mountView()
    await flushPromises()
    clickInDom('[data-testid="kanban-settings-page-back"]')
    expect(router.replace).toHaveBeenCalledWith({
      path: '/app',
      query: { view: 'workspace', workspaceId: 'ws_1', itemId: 'wi_test' },
    })
  })

  it('shows the Local Memories tab when the kanban has a path', async () => {
    seedWorkspaces({ ...baseItem, path: '/tmp/some-folder' })
    mountView()
    await flushPromises()
    const tab = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-page-tab-memories"]',
    )
    expect(tab).not.toBeNull()
  })

  it('hides the Local Memories tab when the kanban has no path', async () => {
    seedWorkspaces({ ...baseItem, path: null })
    mountView()
    await flushPromises()
    const tab = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-page-tab-memories"]',
    )
    expect(tab).toBeNull()
  })

  it('switches to the Local Memories tab on click', async () => {
    seedWorkspaces({ ...baseItem, path: '/tmp/some-folder' })
    mountView()
    await flushPromises()
    const tab = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-page-tab-memories"]',
    )
    expect(tab).not.toBeNull()
    tab!.click()
    await flushPromises()
    // Memories panel renders (stubbed) and columns list is hidden.
    const stubPanel = findInDom<HTMLElement>('[data-testid="stub-memories"]')
    expect(stubPanel).not.toBeNull()
  })

  it('shows a "no kanban selected" hint when the URL itemId is empty', async () => {
    setupRoute({}, '/app/kanban//settings', { itemId: '' })
    seedWorkspaces()
    mountView()
    await flushPromises()
    const hint = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-page-no-item"]',
    )
    expect(hint).not.toBeNull()
  })

  it('falls back to a "not found" hint if itemId is missing from the store', async () => {
    setupRoute({}, '/app/kanban/wi_missing/settings', { itemId: 'wi_missing' })
    seedWorkspaces() // store has wi_test, NOT wi_missing
    mountView()
    await flushPromises()
    const hint = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-page-not-found"]',
    )
    expect(hint).not.toBeNull()
  })
})
