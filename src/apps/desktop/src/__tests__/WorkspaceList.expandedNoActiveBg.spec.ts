/**
 * Lock in the new contract: an EXPANDED workspace renders with no
 * background fill. Only the active content item (driven by the URL,
 * set elsewhere — see WorkspaceItem.activeFromUrl.spec.ts) gets the
 * `--semantic-active-bg` background + violet accent bar.
 *
 * Pre-fix this would fail because the workspace header used
 * `--semantic-active-bg` whenever `workspace.expanded === true`,
 * conflating "expanded (UI state)" with "active (content
 * relationship)". Two workspaces expanded → two `active-bg` rows.
 *
 * The chevron still rotates 90° when expanded (visual cue for the
 * open state) — that's the only expanded-state styling the row gets.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceList from '../components/workspace/WorkspaceList.vue'
import { makeLocalStorageStub } from './helpers'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

const baseWorkspace = {
  id: 'ws_1',
  name: 'agentic coding',
  icon: 'folder',
  expanded: true,
  items: [
    {
      id: 'item_design',
      name: 'design',
      item_type: 'design',
      path: '/tmp',
      tasks: [],
      design_elements: [],
      kanban_columns: [],
      isLoaded: true,
      isLoading: false,
    },
  ],
}

function mountList() {
  // Stub WorkspaceItem so the test focuses on the workspace-row
  // styling only — not the items' internal state. The stub still
  // renders so the parent layout (workspace header + items) is
  // exercised.
  return mount(WorkspaceList, {
    props: {
      workspaces: [baseWorkspace],
      activeWorkspaceItemId: null,
    },
    global: {
      provide: { processingState: ref<Record<string, boolean>>({}) },
      stubs: { WorkspaceItem: true },
    },
  })
}

describe('WorkspaceList — expanded workspace has NO active background', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    useRouteMock.mockReturnValue({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
  })
  afterEach(() => { vi.restoreAllMocks() })

  it('expanded workspace does NOT have --semantic-active-bg in its inline style', async () => {
    const wrapper = mountList()
    await nextTick()
    // First <button> inside the workspaces section is the section
    // header (Workspaces / + button). The workspace header button
    // is the one whose text contains the workspace name.
    const buttons = wrapper.findAll('button')
    const wsButton = buttons.find((b) => b.text().includes('agentic coding'))
    expect(wsButton).toBeDefined()
    // Lock in the new contract: expanded state alone does NOT
    // trigger the active background. Only the active item below
    // gets the active bg.
    expect(wsButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

  it('expanded workspace still rotates the chevron (visual cue for expand state)', async () => {
    const wrapper = mountList()
    await nextTick()
    // The chevron rotates via inline `:style="{ transform: 'rotate(90deg)' }"`
    // when the workspace is expanded. The rotated span is the one
    // whose inline style contains rotate(90deg).
    const chevrons = wrapper.findAll('span[style*="rotate(90deg)"]')
    expect(chevrons.length).toBeGreaterThan(0)
  })
})
