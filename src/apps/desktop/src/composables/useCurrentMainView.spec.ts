// src/apps/desktop/src/composables/useCurrentMainView.spec.ts
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { reactive, nextTick } from 'vue'
import { useCurrentMainView } from './useCurrentMainView'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

function mockRoute(
  query: Record<string, string>,
  path = '/app',
  params: Record<string, string> = {},
) {
  // `reactive` so post-mount mutations trigger the computed.
  const fullPath =
    path +
    (Object.keys(query).length
      ? '?' + new URLSearchParams(query).toString()
      : '')
  const obj = reactive({ query, path, params, fullPath })

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  useRouteMock.mockReturnValue(obj as any)
  return obj
}

describe('useCurrentMainView', () => {
  beforeEach(() => { useRouteMock.mockReset() })

  it('returns chat view when URL is ?view=chat&session=X', () => {
    mockRoute({ view: 'chat', session: 'session_abc' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({ kind: 'chat', sessionId: 'session_abc' })
  })

  it('returns workspace view with chatTaskId when URL is ?view=workspace&itemId=Y/chat/task_Z', () => {
    mockRoute({
      view: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_kanban/chat/task_xyz',
    })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({
      kind: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_kanban',
      pageId: undefined,
      chatTaskId: 'task_xyz',
    })
  })

  it('returns workspace view without chatTaskId when itemId is bare', () => {
    mockRoute({
      view: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_kanban',
    })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({
      kind: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_kanban',
      pageId: undefined,
      chatTaskId: undefined,
    })
  })

  it('returns workspace view with pageId when URL has pageId', () => {
    mockRoute({
      view: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_design',
      pageId: 'page_42',
    })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({
      kind: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_design',
      pageId: 'page_42',
      chatTaskId: undefined,
    })
  })

  it('returns none when URL is empty', () => {
    mockRoute({})
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
  })

  it('returns none when URL is a non-content view (settings)', () => {
    mockRoute({ view: 'settings' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
  })

  it('reacts to URL changes (computed re-runs when route.query mutates)', async () => {
    const route = mockRoute({})
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
    route.query = { view: 'chat', session: 'session_now' }
    await nextTick()
    expect(v.value).toEqual({ kind: 'chat', sessionId: 'session_now' })
  })

  it('does NOT have a kind=task variant (legacy view=task URLs are auto-rewritten on mount)', () => {
    // Sanity: the legacy shape ?view=task&task=X is not handled by
    // this composable — AppLayout.onMounted silently rewrites those
    // URLs to the new shape before the composable is consulted. This
    // test pins the contract.
    mockRoute({ view: 'task', task: 'task_old' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value.kind).toBe('none')
  })

  // ──────────────────────────────────────────────────────────────────
  // kanban-settings variant (plan: 2026-09-02-kanban-settings-as-page)
  // Path-based vue-router route /app/kanban/:itemId/settings.
  // itemId comes from route.params; workspaceId is optional and
  // comes from ?workspaceId=X query (used by the back navigation).
  // ──────────────────────────────────────────────────────────────────

  it('returns kanban-settings view when URL is /app/kanban/:itemId/settings', () => {
    mockRoute({}, '/app/kanban/item_kanban/settings', { itemId: 'item_kanban' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({
      kind: 'kanban-settings',
      workspaceId: undefined,
      itemId: 'item_kanban',
    })
  })

  it('returns kanban-settings view with workspaceId when ?workspaceId=X is on the path', () => {
    mockRoute(
      { workspaceId: 'ws_1' },
      '/app/kanban/item_kanban/settings',
      { itemId: 'item_kanban' },
    )
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({
      kind: 'kanban-settings',
      workspaceId: 'ws_1',
      itemId: 'item_kanban',
    })
  })

  it('returns kanban-settings view with empty itemId when the path lacks :itemId (defensive)', () => {
    // Path is /app/kanban//settings (double slash) — Vue Router would
    // normally reject this, but we want the composable to degrade
    // gracefully so the sidebar can still react.
    mockRoute({}, '/app/kanban//settings', { itemId: '' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value.kind).toBe('kanban-settings')
    expect(v.value).toEqual({
      kind: 'kanban-settings',
      workspaceId: undefined,
      itemId: '',
    })
  })

  it('reacts to URL changes for kanban-settings (computed re-runs when route.path mutates)', async () => {
    const route = mockRoute({}, '/app', {})
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
    // Simulate vue-router's navigation — both path and params update.
    route.path = '/app/kanban/item_now/settings'
    route.params = { itemId: 'item_now' }
    await nextTick()
    expect(v.value).toEqual({
      kind: 'kanban-settings',
      workspaceId: undefined,
      itemId: 'item_now',
    })
  })

  it('does NOT match kanban-settings for unrelated paths like /app/settings', () => {
    mockRoute({}, '/app/settings', {})
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    // /app/settings is its own view — the composable's chat/workspace
    // branches don't match it either, so it falls through to 'none'.
    expect(v.value).toEqual({ kind: 'none' })
  })
})
