// src/apps/desktop/src/composables/useCurrentMainView.spec.ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
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
  useRouteMock.mockReturnValue(obj as any)
  return obj
}

describe('useCurrentMainView', () => {
  beforeEach(() => { useRouteMock.mockReset() })

  it('returns chat view when URL is ?view=chat&session=X', () => {
    mockRoute({ view: 'chat', session: 'session_abc' })
    // `!` asserts definite-assignment: setup() always assigns v.
    let v!: ReturnType<typeof useCurrentMainView>
    // Composable needs a component context; use a fake `currentInstance`-less
    // call by reading the route directly via the mock, then asserting the
    // composable's return shape equivalent.
    // Simpler: we test the route-derivation logic by minting a tiny harness
    // that calls useRoute() inside a setup-like function.
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({ kind: 'chat', sessionId: 'session_abc' })
  })

  it('returns task view when URL is ?view=task&task=X', () => {
    mockRoute({ view: 'task', task: 'task_xyz' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({
      kind: 'task',
      taskId: 'task_xyz',
      workspaceId: undefined,
      itemId: undefined,
    })
  })

  it('returns workspace view with pageId when URL is ?view=workspace&itemId=Y&pageId=Z', () => {
    mockRoute({ view: 'workspace', workspaceId: 'ws_1', itemId: 'item_design', pageId: 'page_42' })
    let v!: ReturnType<typeof useCurrentMainView>
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({
      kind: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_design',
      pageId: 'page_42',
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
})