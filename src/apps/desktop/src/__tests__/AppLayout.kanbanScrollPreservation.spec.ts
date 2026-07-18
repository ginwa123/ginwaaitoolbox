/**
 * End-to-end regression test for the kanban-horizontal-scroll-loss bug.
 *
 * Symptom:
 *   1. User scrolls the kanban board right (e.g. to see the
 *      "merged" column on an 8-column board).
 *   2. User clicks a task in that far-right column.
 *   3. The ChatView opens on the right (3-column layout). The
 *      kanban's columns-row container is REMOUNTED into the 3-column
 *      branch (`data-kanban-three-column`), so its `scrollLeft`
 *      starts back at 0. The user sees only the leftmost columns
 *      ("todo", "in progress"), even though they were just looking
 *      at "merged".
 *   4. User clicks ✕ to close the chat. Same re-mount, same loss.
 *
 * Root cause:
 *   AppLayout renders `<KanbanView>` in TWO separate v-else-if
 *   branches at different DOM positions: standalone (~line 1551)
 *   and 3-column (~line 1458 inside `data-kanban-three-column`).
 *   Vue 3 does not reuse the component instance across branches at
 *   different parents — the new mount's overflow-x-auto container
 *   starts at scrollLeft = 0.
 *
 * Fix:
 *   `useKanbanScrollRestore` composable (see
 *   `composables/useKanbanScrollRestore.ts` + its unit tests in
 *   `composables/__tests__/useKanbanScrollRestore.spec.ts`)
 *   persists the columns container's `scrollLeft` to `localStorage`
 *   on `scrollend` (fast path) + a 250 ms debounced `scroll`
 *   (fallback) and restores it on `onMounted` after
 *   `await rAF × 2`. Clamps to `scrollWidth - clientWidth` so the
 *   restored value is valid for the new (narrower) container.
 *
 * This file tests the FULL user flow end-to-end:
 *   - The standalone KanbanView's scrollLeft persists across the
 *     transition INTO the 3-column layout (clamped to the new max).
 *   - The 3-column KanbanView's scrollLeft persists across the
 *     transition BACK to standalone (clamped to the new max).
 *
 * Plan: docs/superpowers/plans/2026-07-23-preserve-kanban-horizontal-scroll.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises } from '@vue/test-utils'
import { createApp, nextTick } from 'vue'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import type { Workspace, WorkspaceItem, KanbanColumn, Task } from '../stores/workspaces'
import AppLayout from '../components/AppLayout.vue'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

// ─── Test infrastructure (mirrors AppLayout.kanban.spec.ts) ──────────

function makeStubClient(initial: SseState = 'open'): SseClient {
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => {
      stub.__stateListeners.push(cb)
      return () => {
        const i = stub.__stateListeners.indexOf(cb)
        if (i >= 0) stub.__stateListeners.splice(i, 1)
      }
    },
  }
  stub._state = initial
  stub.__stateListeners = [] as Array<(s: SseState, info: SseStateInfo) => void>
  return stub as SseClient
}

function installBusForTests() {
  __resetSseBus()
  installSseBus(createApp({}))
  __setSseBusGlobalClient(makeStubClient('open'))
}

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

// ─── Test fixture: an 8-column kanban with one task in the last column ─
//
// Mirrors the user's repro (8 columns: "todo" through "merged") so
// the test is realistic without dragging in unrelated routing
// complexity. The TASK_ID sits in `merged` (the 8th column) — the
// same column the user clicks in the real-world report.
const WS_ID = 'ws_1'
const KANBAN_ID = 'item_kanban_test'
const TASK_ID = 'task_in_merged'

const makeColumn = (
  id: string,
  name: string,
  position: number,
): KanbanColumn => ({
  id,
  workspace_item_id: KANBAN_ID,
  name,
  position,
  created_at: '2026-07-23 12:00:00',
})

const TASK: Task = {
  id: TASK_ID,
  name: 'task in merged',
  kanban_column_id: 'col_merged',
}

const KANBAN: WorkspaceItem = {
  id: KANBAN_ID,
  name: 'sprint scroll test',
  item_type: 'kanban',
  kanban_columns: [
    makeColumn('col_todo', 'todo', 0),
    makeColumn('col_progress', 'in progress', 1),
    makeColumn('col_review', 'in_review', 2),
    makeColumn('col_pr', 'in_review_pull_request', 3),
    makeColumn('col_hold', 'on_hold', 4),
    makeColumn('col_user_test', 'in_user_testing', 5),
    makeColumn('col_done', 'done', 6),
    makeColumn('col_merged', 'merged', 7),
  ],
  tasks: [TASK],
}

const WORKSPACE: Workspace = {
  id: WS_ID,
  name: 'WS',
  icon: '📁',
  expanded: true,
  items: [KANBAN],
} as Workspace

// Configure the jsdom geometry on the kanban columns container so
// the composable's clamp math has real numbers. Without this, the
// container's `scrollWidth = 0` in jsdom and the composable's
// "max <= 0" early-exit would skip the restore. Must be called
// for each NEW container (since each mount creates a new element
// with `scrollWidth` back to 0).
function configureContainerGeometry(
  container: HTMLElement,
  scrollWidth: number,
  clientWidth: number,
): void {
  Object.defineProperty(container, 'scrollWidth', {
    value: scrollWidth,
    writable: true,
    configurable: true,
  })
  Object.defineProperty(container, 'clientWidth', {
    value: clientWidth,
    writable: true,
    configurable: true,
  })
}

/**
 * Wait for the kanban-columns container's `scrollLeft` to settle.
 * The composable awaits 2× rAF + 1 microtask before applying the
 * restore. We wait the same.
 */
async function waitForScrollRestore(): Promise<void> {
  await flushPromises()
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await flushPromises()
}

function mountAppLayout() {
  const ws = useWorkspacesStore()
  ws.workspaces = [WORKSPACE]
  // AppLayout's onMounted calls initializeFromSystemFolder → init(),
  // which would overwrite `workspaces` with the mocked (empty) API
  // response. Spy on it to no-op so our pre-seeded workspace
  // survives the mount cycle.
  vi.spyOn(ws, 'initializeFromSystemFolder').mockImplementation(async () => {
    // No-op: the tests below drive workspaces manually via
    // setActiveWorkspaceItem / setActiveTask.
  })
  return mount(AppLayout, {
    global: {
      stubs: {
        // Stub heavy / unrelated children to keep the test focused
        // on the kanban ↔ 3-column layout flip. Critically, we do
        // NOT stub <KanbanView> — that's the component under test.
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        // Lightweight ChatView stub — we don't need real chat logic,
        // just the layout signal that 3-column is "active".
        ChatView: {
          template: '<div data-testid="chatview-stub" />',
          props: ['chatId', 'chatName', 'type', 'cwd', 'taskId', 'taskName', 'projectName', 'showHeader'],
        },
        Chats: { template: '<div data-testid="chats-stub" />' },
        SettingsView: true,
        CodeEditor: true,
        DesignView: true,
      },
    },
  })
}

describe('AppLayout — Kanban horizontal scroll preservation across layout transitions', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    localStorage.clear()
    useRouteMock.mockReturnValue({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    } as any)
    // Mock the workspace-store API calls fired by onMounted.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
    })
    vi.spyOn(api, 'listKanbanColumns').mockResolvedValue({ columns: [], count: 0 })
  })

  afterEach(() => {
    vi.restoreAllMocks()
    localStorage.clear()
  })

  it('preserves scrollLeft when transitioning from full-bleed kanban → 3-column kanban+chat', async () => {
    const ws = useWorkspacesStore()
    const wrapper = mountAppLayout()
    ws.setActiveWorkspaceItem(KANBAN_ID)
    await nextTick()

    // The standalone KanbanView is now mounted inside the main
    // content area (NOT inside `data-kanban-three-column`).
    // Find its columns-row container BEFORE waiting for the
    // composable's rAF × 2 — we need to configure its jsdom
    // geometry NOW so the composable reads real scrollWidth on
    // its first restore attempt.
    const standaloneContainer = wrapper.find(
      `[data-testid="kanban-view-${KANBAN_ID}-columns"]`,
    ).element as HTMLElement
    expect(standaloneContainer).toBeTruthy()

    // Simulate a wide standalone container (full-bleed kanban).
    configureContainerGeometry(standaloneContainer, 4000, 1500)

    await waitForScrollRestore()

    // First mount with no saved value → composable leaves scrollLeft
    // at 0 and just attaches listeners. (Setup only — no assertion.)

    // Simulate the user scrolling right to see the "merged"
    // column. scrollLeft = 2500 (in a 4000-wide canvas visible
    // 1500-px at a time = max = 2500, so this lands at the
    // rightmost columns).
    standaloneContainer.scrollLeft = 2500
    // Persist the scroll: dispatch scrollend (the fast path).
    standaloneContainer.dispatchEvent(new Event('scrollend'))

    expect(localStorage.getItem(`kanban-scroll-${KANBAN_ID}`)).toBe('2500')

    // Now simulate the user clicking the task. This flips the
    // v-else-if chain: standalone unmounts, 3-column
    // (`data-kanban-three-column`) mounts a NEW KanbanView with
    // a narrower column container.
    ws.setActiveTask(TASK_ID)
    await nextTick()

    // The 3-column branch should be active (ChatView stub is in DOM).
    expect(wrapper.find('[data-kanban-three-column]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="chatview-stub"]').exists()).toBe(true)

    // The NEW kanban columns container is the 3-column one —
    // narrower than the standalone (kanban takes ~40% of main
    // area). Configure its jsdom geometry BEFORE the composable's
    // rAF × 2: scrollWidth unchanged at 4000, clientWidth down to 480.
    const threeColContainer = wrapper
      .find('[data-kanban-three-column]')
      .find(`[data-testid="kanban-view-${KANBAN_ID}-columns"]`)
      .element as HTMLElement
    expect(threeColContainer).toBeTruthy()
    expect(threeColContainer).not.toBe(standaloneContainer) // proof of re-mount

    configureContainerGeometry(threeColContainer, 4000, 480)
    // max in 3-column = 4000 - 480 = 3520. Saved scrollLeft = 2500
    // is <= 3520, so the restore lands at exactly 2500.

    await waitForScrollRestore()

    expect(threeColContainer.scrollLeft).toBe(2500)

    wrapper.unmount()
  })

  it('preserves scrollLeft when transitioning from 3-column → standalone kanban', async () => {
    const ws = useWorkspacesStore()
    const wrapper = mountAppLayout()

    // Start in the 3-column layout (task already active).
    ws.setActiveWorkspaceItem(KANBAN_ID)
    ws.setActiveTask(TASK_ID)
    await nextTick()

    // The 3-column KanbanView is now mounted inside
    // `data-kanban-three-column`. Find its columns-row container
    // BEFORE the composable's rAF × 2 — we need to configure its
    // jsdom geometry NOW so the composable reads real scrollWidth.
    const threeColContainer = wrapper
      .find('[data-kanban-three-column]')
      .find(`[data-testid="kanban-view-${KANBAN_ID}-columns"]`)
      .element as HTMLElement
    expect(threeColContainer).toBeTruthy()

    // Simulate the narrow 3-column kanban (~480 px).
    configureContainerGeometry(threeColContainer, 4000, 480)
    await waitForScrollRestore()

    // Simulate the user scrolling within the 3-column kanban.
    threeColContainer.scrollLeft = 3520 // at the rightmost edge (max)
    threeColContainer.dispatchEvent(new Event('scrollend'))
    expect(localStorage.getItem(`kanban-scroll-${KANBAN_ID}`)).toBe('3520')

    // Now close the task → flip back to standalone. The 3-column
    // KanbanView unmounts, the standalone one mounts. Container is
    // wider now (~1500 clientWidth), so the saved 3520 is beyond
    // the new max (4000 - 1500 = 2500). Expect the restore to
    // CLAMP to 2500 instead of jumping to 0.
    ws.setActiveTask(null)
    await nextTick()

    expect(wrapper.find('[data-kanban-three-column]').exists()).toBe(false)

    const standaloneContainer = wrapper
      .find(`[data-testid="kanban-view-${KANBAN_ID}-columns"]`)
      .element as HTMLElement
    expect(standaloneContainer).toBeTruthy()
    expect(standaloneContainer).not.toBe(threeColContainer) // proof of re-mount

    // Configure the WIDER standalone container BEFORE the
    // composable's rAF × 2 fires.
    configureContainerGeometry(standaloneContainer, 4000, 1500)
    await waitForScrollRestore()

    expect(standaloneContainer.scrollLeft).toBe(2500)

    wrapper.unmount()
  })
})