/**
 * Static source-grep tests for DesignView.vue (the top-level design
 * canvas component).
 *
 * DesignView is the host that ties DesignPageTabs + DesignElement +
 * LayersPanel + PropertiesPanel + AddDesignElementDialog together.
 * Static contract:
 *  - Renders the page tabs at the top, then the main split (canvas
 *    + right sidebar with Layers + Properties).
 *  - Two drag-resize handles (canvas↔sidebar, Layers↔Properties).
 *  - On mount fetches design pages; defaults activePageId to first page.
 *  - watch(activePageId) re-fetches elements for the new page.
 *  - Escape keypress clears selection; canvas background click clears selection.
 *  - 8 emits back to the parent (AppLayout wires them in Chunk 8).
 */
import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const SOURCE_PATH = path.resolve(__dirname, '../components/design/DesignView.vue')
const source = fs.readFileSync(SOURCE_PATH, 'utf-8')

describe('DesignView.vue static contract', () => {
  it('declares item, workspaceId, itemId props', () => {
    expect(source).toContain("item:")
    expect(source).toContain("workspaceId:")
    expect(source).toContain("itemId:")
  })

  it('emits the 7 parent events (page CRUD is owned by DesignView itself, not emitted upward)', () => {
    // Page CRUD (add / delete) is owned by DesignView since the 2026-07-27
    // fix that moved the API call into the component itself — see the
    // file header doc-comment. The parent no longer needs to mediate
    // these clicks because DesignView already updates its own `pages`
    // local state. The remaining events are what AppLayout actually
    // listens for (selectPage is informational; the others drive
    // store mutations for elements / chat toggle).
    expect(source).toContain("selectPage:")
    expect(source).toContain("selectElement:")
    expect(source).toContain("reorderElements:")
    expect(source).toContain("createElement:")
    expect(source).toContain("updateElement:")
    expect(source).toContain("deleteElement:")
    expect(source).toContain("htmlChanged:")
    // addPage / deletePage emits no longer exist (DesignView handles
    // the API + local mutation directly).
    expect(source).not.toMatch(/^\s*addPage:\s*\[/m)
    expect(source).not.toMatch(/^\s*deletePage:\s*\[/m)
  })

  // NEW (design-pages-in-workspace-tree plan, 2026-08-06): the
  // page tabs are no longer rendered inside DesignView — they live
  // in the workspace sidebar tree (WorkspaceItem.vue renders
  // DesignPageRow under expanded design items). The remaining
  // structural assertions (DesignElement, LayersPanel,
  // PropertiesPanel) are unchanged.
  it('renders the canvas + right sidebar with Layers + Properties', () => {
    expect(source).toContain("<DesignElement")
    expect(source).toContain("<LayersPanel")
    expect(source).toContain("<PropertiesPanel")
  })

  it('fetches design pages via listDesignPages on mount', () => {
    // The onMounted hook calls loadPages which uses the API directly
    // (the store doesn't yet have a listDesignPages action in this
    // chunk; the page state is local).
    expect(source).toContain("listDesignPages")
    expect(source).toContain("loadPages")
    expect(source).toContain("onMounted")
  })

  it('watches activePageId to refetch elements', () => {
    expect(source).toContain("watch(activePageId")
    expect(source).toContain("fetchDesignElements")
  })

  it('handles Escape keypress to clear selection', () => {
    expect(source).toContain("Escape")
    expect(source).toContain("keydown")
  })

  it('has the canvas + sidebar resize handles', () => {
    expect(source).toContain("design-sidebar-resize-handle")
    expect(source).toContain("design-layers-resize-handle")
    expect(source).toContain("startSidebarResize")
    expect(source).toContain("startLayersResize")
  })

  it('has the design-view and design-canvas data-testids', () => {
    expect(source).toContain('data-testid="design-view"')
    expect(source).toContain('data-testid="design-canvas"')
  })

  it('renders loading/error/empty states for the pages fetch', () => {
    expect(source).toContain("design-pages-loading")
    expect(source).toContain("design-pages-error")
    expect(source).toContain("design-pages-empty")
  })

  it('renders the + Element button + active page name + element count', () => {
    expect(source).toContain("design-add-element-button")
    expect(source).toContain("design-canvas-header")
  })

  it('persists sidebar width to localStorage', () => {
    // The drag-resize handle persists the sidebar width so the user's
    // preferred layout survives a page reload.
    expect(source).toContain("localStorage")
    expect(source).toContain("SIDEBAR_WIDTH_KEY")
  })

  // NEW (2026-07-14): top-right chat-toggle. The 💬 button in the
  // canvas header bar emits `openChat` upward; AppLayout's
  // handleDesignOpenChat handler finds or creates a per-page
  // "Design Chat: <pageName>" task on the design item and
  // switches to the 3-column (DesignView | resize-handle |
  // ChatView) layout. Without this contract, a future refactor
  // could silently drop the chat toggle and the user would lose
  // the primary way to interact with the LLM about the design.
  //
  // UPDATED (2026-07-28 per-page chat scoping, plan
  // docs/superpowers/plans/2026-07-28-design-per-page-chat-sessions.md):
  // the emit now carries the active page's {pageId, pageName} so
  // AppLayout can scope the chat task to this page only. Each
  // design page gets a disjoint chat; switching pages does NOT
  // swap the active chat.
  it('declares openChat in defineEmits (top-right chat toggle)', () => {
    // Per-page payload: `[payload: { pageId: string; pageName: string }]`.
    // The pre-fix shape `openChat: []` is the single-canonical
    // pattern and is no longer used here.
    expect(source).toMatch(/openChat:\s*\[\s*payload:\s*\{\s*pageId:[^}]*pageName:[^}]*\}\s*\]/)
  })

  it('renders the design-open-chat-button in the top-level toolbar', () => {
    expect(source).toContain('design-open-chat-button')
    expect(source).toContain('aria-label="Open design chat"')
    // The 💬 glyph should appear in the button (visual cue for
    // chat — same convention used by folder chats in nalar).
    expect(source).toMatch(/💬/)
  })

  it('chat button lives in a TOP-LEVEL toolbar that always renders', () => {
    // Regression test for the 2026-07-14 bug: the chat button
    // was initially placed inside the canvas header bar, which
    // only renders when pages.length > 0. Users on the empty
    // state ("No pages yet") couldn't reach the chat. The fix
    // moves the button to a top-level toolbar (`design-toolbar`)
    // that renders unconditionally.
    //
    // NEW (design-pages-in-workspace-tree plan, 2026-08-06): the
    // original assertion also checked that <DesignPageTabs came
    // AFTER the toolbar in the source. With the pages moved to
    // the sidebar tree, that ordering invariant no longer
    // applies (the toolbar is now the only top-level element
    // before the main split). The toolbar's `data-testid` is
    // still asserted to lock the top-level placement.
    expect(source).toContain('design-toolbar')
  })

  it('handleOpenChat emits the openChat event with the active page payload', () => {
    // The handler must call emit('openChat', { pageId, pageName })
    // — NOT a bare emit('openChat'). Verify both the literal
    // emit-name AND the object-shaped payload appear on the same
    // emit call.
    expect(source).toMatch(/emit\(\s*['"]openChat['"]\s*,\s*\{[\s\S]*?pageId[\s\S]*?pageName[\s\S]*?\}\s*\)/)
  })

  it('onUnmounted does NOT clear activeDesignPageId (chat-toggle regression)', () => {
    // Regression (2026-07-29): pre-fix, onUnmounted contained
    // `workspacesStore.setActiveDesignPage('')`. That wiped the
    // active page id whenever DesignView unmounted — including the
    // unmount→mount cycle triggered by AppLayout's v-else-if swap
    // when the user toggles the 💬 chat button. The freshly mounted
    // DesignView then fell back to fetched[0]?.id (the first page),
    // visually jumping the user's selected tab back to "AI Chat
    // View" every chat toggle. The clear is now removed; this
    // test locks the contract so a future "defensive" refactor
    // can't silently regress it.
    //
    // Match the `onUnmounted(() => { ... })` block and assert it
    // does NOT contain a setActiveDesignPage('') call.
    const unmountMatch = source.match(/onUnmounted\(\(\)\s*=>\s*\{([\s\S]*?)\n\}\)/)
    if (!unmountMatch || !unmountMatch[1]) {
      throw new Error('onUnmounted(() => { ... }) block not found in DesignView.vue')
    }
    const body = unmountMatch[1]
    if (/setActiveDesignPage\(\s*['"]['"]\s*\)/.test(body)) {
      throw new Error(
        'DesignView.vue onUnmounted clears activeDesignPageId to "" — this regresses the chat-toggle flow. Remove the setActiveDesignPage("") call.',
      )
    }
  })

  // NEW (Chunk 6 of grouped-layers plan): Cmd+G shortcut for
  // grouping the current selection. The handler MUST:
  //   - bind to key === 'g' / 'G' with ctrlKey || metaKey
  //   - silent no-op when shiftKey is held (deferred to Chunk 9)
  //   - call designHandlers.groupSelection() on plain Cmd+G
  //   - skip when the keystroke target is INPUT/TEXTAREA/contenteditable
  //     (already covered by the existing top-of-handler guard, but
  //     we explicitly assert the guard exists for the G key path)
  it('binds Cmd/Ctrl+G to designHandlers.groupSelection', () => {
    // Both `event.key === 'g'` AND `event.key === 'G'` must be
    // accepted (Shift modifier in the browser capitalizes key).
    expect(source).toMatch(/event\.key\s*===\s*['"]g['"][\s\S]{0,80}event\.key\s*===\s*['"]G['"]/)
  })

  it('Cmd+G branch checks both ctrlKey and metaKey (mac + win/linux)', () => {
    // The Cmd+G branch must accept BOTH modifiers — Cmd on macOS,
    // Ctrl on Linux/Windows. The original Cmd+P branch above is
    // the proven template.
    const gBranchMatch = source.match(/event\.key\s*===\s*['"]g['"][\s\S]{0,400}/)
    expect(gBranchMatch).not.toBeNull()
    const branch = gBranchMatch ? gBranchMatch[0] : ''
    expect(branch).toMatch(/\.ctrlKey/)
    expect(branch).toMatch(/\.metaKey/)
  })

  it('Cmd+G branch calls designHandlers.groupSelection()', () => {
    // Capture the entire Cmd+G branch — from the G-key check through
    // the closing brace. The branch has an inner `if (event.shiftKey)
    // return` so a naive `[\s\S]*?return\s*\n\s*\}` would match the
    // inner `return` and miss the call after it. Anchor on the next
    // branch's comment (`// Fit-to-viewport`) instead — that's the
    // known marker that comes after the outer brace.
    const branchMatch = source.match(/event\.key\s*===\s*['"]g['"][\s\S]*?(?=\/\/ Fit-to-viewport)/)
    expect(branchMatch).not.toBeNull()
    const branch = branchMatch ? branchMatch[0] : ''
    expect(branch).toMatch(/designHandlers\.groupSelection\(\)/)
  })

  it('Cmd+Shift+G is a no-op (ungroup reserved for Chunk 9)', () => {
    // The keycode for the deferred Ungroup is Cmd+Shift+G. The
    // handler MUST recognize the shiftKey path and return early
    // so the placeholder isn't accidentally consumed by a future
    // ungroup shortcut. Verify both the inner `if (event.shiftKey)`
    // guard AND the deferred-feature TODO comment are present.
    // Same anchor-on-next-comment trick as above — the inner
    // `return` would otherwise win the non-greedy match.
    const branchMatch = source.match(/event\.key\s*===\s*['"]g['"][\s\S]*?(?=\/\/ Fit-to-viewport)/)
    expect(branchMatch).not.toBeNull()
    const branch = branchMatch ? branchMatch[0] : ''
    expect(branch).toMatch(/event\.shiftKey/)
    expect(branch).toMatch(/ungroupSelection|TODO:\s*implement\s*ungroupSelection/)
  })

  it('handleKeydown top-of-handler target guard covers INPUT/TEXTAREA/contenteditable', () => {
    // The Cmd+G branch inherits the early-return guard at the top
    // of handleKeydown (matching existing handlers like Cmd+P).
    // If the guard is removed, the X/Y inputs in PropertiesPanel
    // would steal the G keystroke on focus. Assert the guard
    // exists by pattern-matching the standard 3-tag check.
    expect(source).toMatch(/INPUT/)
    expect(source).toMatch(/TEXTAREA/)
    expect(source).toMatch(/isContentEditable/)
  })

  it('imports useDesignHandlers composable + uses it in script setup', () => {
    // The composable is the wiring point — without this import the
    // Cmd+G handler has no destination. (Already covered by
    // bun run build type-check, but a static test pins the contract
    // without requiring a full compile run.)
    expect(source).toMatch(/import\s*\{[^}]*useDesignHandlers[^}]*\}\s*from\s*['"]\.\.\/\.\.\/composables\/useDesignHandlers['"]/)
    // The composable invocation must be present in <script setup>.
    expect(source).toMatch(/useDesignHandlers\s*\(\s*\{/)
  })
})

// ─── Behavioral tests: mirror activePageId to workspacesStore ─────────────
// NEW (Chunk 1, Task 1.2 of design-element-drag-and-drop plan).
// DesignView owns the local `activePageId` ref. AppLayout's design
// handlers (handleDesignUpdateElement / handleDesignDeleteElement) need
// the page id to route PATCH/PUT/DELETE to the right page, so DesignView
// mirrors activePageId to workspacesStore.activeDesignPageId on mount,
// tab switch, and unmount.

import { flushPromises, mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { afterEach, beforeEach, describe as describeRuntime, expect as expectRuntime, it as itRuntime, vi } from 'vitest'
import DesignView from '../components/design/DesignView.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem } from '../stores/workspaces'

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

function makeItem(): WorkspaceItem {
  return {
    id: ITEM_ID,
    name: 'Test',
    item_type: 'design',
    path: '/tmp/test',
    design_elements: [],
  }
}

describeRuntime('DesignView → workspacesStore active page id', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  itRuntime('publishes the active page id to the workspaces store on mount and on tab switch', async () => {
    fetchMock.mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({
        pages: [
          { id: 'page_first', workspace_item_id: ITEM_ID, name: 'A', width: 1440, height: 1024, position: 0, created_at: '', updated_at: '' },
          { id: 'page_second', workspace_item_id: ITEM_ID, name: 'B', width: 1440, height: 1024, position: 1, created_at: '', updated_at: '' },
        ],
        count: 2,
      }),
      text: () => Promise.resolve(''),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
    const wrapper = mount(DesignView, {
      props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
    })
    await flushPromises()
    expectRuntime(useWorkspacesStore().activeDesignPageId).toBe('page_first')
    wrapper.unmount()
    // Regression (2026-07-29): pre-fix unmount cleared
    // activeDesignPageId to ''. That broke the chat-toggle flow:
    // AppLayout's v-else-if chain renders TWO <DesignView>
    // instances for the same item (single-column + 3-column), and
    // clicking 💬 swaps them. Clearing on unmount meant the new
    // DesignView's loadPages() saw '' and fell back to
    // fetched[0]?.id — visually jumping back to the first tab.
    // The clear is now removed (see DesignView.vue onUnmounted
    // comment); the value stays for the next mount to pick up.
    expectRuntime(useWorkspacesStore().activeDesignPageId).toBe('page_first')
  })

  itRuntime('preserves activeDesignPageId across unmount/remount (chat-toggle regression)', async () => {
    // Direct reproduction of the user's reported bug: open the
    // design on a NON-default page (Kanban Mode, page_third),
    // then unmount + remount (which is exactly what happens when
    // the user clicks 💬 in AppLayout's v-else-if chain — the
    // single-column branch unmounts and the 3-column branch
    // mounts). The activeDesignPageId must NOT be wiped to ''.
    fetchMock.mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({
        pages: [
          { id: 'page_first', workspace_item_id: ITEM_ID, name: 'AI Chat View', width: 1440, height: 1024, position: 0, created_at: '', updated_at: '' },
          { id: 'page_second', workspace_item_id: ITEM_ID, name: 'Settings', width: 1440, height: 1024, position: 1, created_at: '', updated_at: '' },
          { id: 'page_third', workspace_item_id: ITEM_ID, name: 'Kanban Mode', width: 1440, height: 1024, position: 2, created_at: '', updated_at: '' },
        ],
        count: 3,
      }),
      text: () => Promise.resolve(''),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
    const ws = useWorkspacesStore()

    // First mount: user lands on first page (no URL restore).
    const wrapper1 = mount(DesignView, {
      props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
    })
    await flushPromises()
    expectRuntime(ws.activeDesignPageId).toBe('page_first')

    // User clicks the "Kanban Mode" tab.
    const vm1 = wrapper1.vm as unknown as {
      activePageId: string
      pages: Array<{ id: string }>
    }
    vm1.activePageId = 'page_third'
    await flushPromises()
    expectRuntime(ws.activeDesignPageId).toBe('page_third')

    // Simulate the chat-toggle unmount/remount cycle that
    // AppLayout's v-else-if chain performs when the user clicks 💬.
    wrapper1.unmount()
    await flushPromises()

    // Regression assertion: the store value must still be
    // 'page_third', NOT ''. Pre-fix, this was ''.
    expectRuntime(ws.activeDesignPageId).toBe('page_third')

    // Now remount (this is the 3-column DesignView).
    const wrapper2 = mount(DesignView, {
      props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
    })
    await flushPromises()

    // The user's last-clicked tab must be restored.
    const vm2 = wrapper2.vm as unknown as { activePageId: string }
    expectRuntime(vm2.activePageId).toBe('page_third')
    expectRuntime(ws.activeDesignPageId).toBe('page_third')

    wrapper2.unmount()
  })

  itRuntime('cross-item navigation: stale activeDesignPageId does not bleed across design items', async () => {
    // When the user navigates from designItem A (page PA) to
    // designItem B, the DesignView unmounts. The store still
    // holds PA's id. When DesignView B mounts and loads its
    // pages, loadPages() validates `fetched.some((p) => p.id ===
    // storePageId)` — if false, it falls back to fetched[0]?.id.
    // This test pins that contract.
    const ws = useWorkspacesStore()

    // Pre-seed the store with a stale page id from item A.
    ws.setActiveDesignPage('page_from_item_A')

    // Now mock fetch for item B (no overlap with item A's pages).
    fetchMock.mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({
        pages: [
          { id: 'page_B1', workspace_item_id: 'item_B', name: 'B-first', width: 1440, height: 1024, position: 0, created_at: '', updated_at: '' },
          { id: 'page_B2', workspace_item_id: 'item_B', name: 'B-second', width: 1440, height: 1024, position: 1, created_at: '', updated_at: '' },
        ],
        count: 2,
      }),
      text: () => Promise.resolve(''),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch

    const itemB: WorkspaceItem = {
      id: 'item_B',
      name: 'Design B',
      item_type: 'design',
      path: '/tmp/test',
      design_elements: [],
    }
    const wrapper = mount(DesignView, {
      props: { item: itemB, workspaceId: WS_ID, itemId: 'item_B' },
    })
    await flushPromises()

    // loadPages must have validated that 'page_from_item_A' is NOT
    // in item B's pages and fallen back to 'page_B1' (the first).
    const vm = wrapper.vm as unknown as { activePageId: string }
    expectRuntime(vm.activePageId).toBe('page_B1')
    expectRuntime(ws.activeDesignPageId).toBe('page_B1')

    wrapper.unmount()
  })

  itRuntime('picks the active page from the store when it exists in the loaded pages (URL restore)', async () => {
    // AppLayout's URL restore watcher sets activeDesignPageId from
    // the ?pageId=Z query before DesignView mounts. DesignView must
    // honor the store value (not always default to the first page)
    // so a page reload restores the user's last-clicked tab.
    fetchMock.mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({
        pages: [
          { id: 'page_first', workspace_item_id: ITEM_ID, name: 'A', width: 1440, height: 1024, position: 0, created_at: '', updated_at: '' },
          { id: 'page_second', workspace_item_id: ITEM_ID, name: 'B', width: 1440, height: 1024, position: 1, created_at: '', updated_at: '' },
        ],
        count: 2,
      }),
      text: () => Promise.resolve(''),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
    const ws = useWorkspacesStore()
    // Simulate AppLayout's pendingUrlRestore watcher having fired.
    ws.setActiveDesignPage('page_second')
    const wrapper = mount(DesignView, {
      props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
    })
    await flushPromises()
    // The internal activePageId should be page_second (from the store),
    // not page_first (the first page default).
    expectRuntime((wrapper.vm as unknown as { activePageId: string }).activePageId).toBe('page_second')
    // The store value is still page_second (unchanged by the load).
    expectRuntime(ws.activeDesignPageId).toBe('page_second')
    wrapper.unmount()
  })
})

// ─── Behavioral tests: page CRUD (add/delete) owned by DesignView ─────────
//
// Regression tests for the 2026-07-27 bug where clicking + or × in
// the page tab strip silently did nothing visible until the user
// reloaded the page. The root cause was an architectural bounce
// through AppLayout: DesignView emitted addPage/deletePage upward,
// AppLayout called api.createDesignPage/deleteDesignPage, but
// DesignView's local `pages.value` was never updated, so the new
// tab never appeared and the deleted tab stayed in place.
//
// The fix moved the API calls into DesignView itself, which mutates
// `pages.value` directly (same pattern as `commitPageSize` below).
// These tests verify the new behavior end-to-end via fetch mocks.

// NEW (design-pages-in-workspace-tree plan, 2026-08-06): the
// `DesignView page CRUD (add / delete)` suite was REMOVED — the
// 5 page-CRUD tests now live in
// `workspacesStoreDesignPages.spec.ts` where they call the store
// actions directly (the page CRUD logic moved from DesignView into
// the workspaces store as part of this PR).

