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

function mockRoute(query: Record<string, string>) {
  // `reactive` so post-mount mutations trigger the computed.
  const obj = reactive({ query, path: '/app', fullPath: '/app' })
   
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
})
