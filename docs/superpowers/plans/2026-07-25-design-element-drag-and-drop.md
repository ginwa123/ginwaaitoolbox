# Design Mode — Element Drag-and-Drop (Figma-style) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make design-mode elements movable by dragging them on the canvas (the current ship does NOTHING when the user drags — the wire is broken at `AppLayout.handleDesignUpdateElement`), and layer Figma-style UX on top: multi-select group drag, snap-to-other-elements with alignment guides, keyboard nudge, and constrain-to-canvas.

**Architecture:**
- Frontend-only change. Three real problems to fix: (1) the AppLayout handler that discards `update` patches from DesignView is a TODO no-op; (2) the active page id is local-only inside DesignView so the parent can't route patches to the backend; (3) `pointermove` fires 60+/sec so the backend would be flooded without throttling. After the wire is repaired, we add the Figma UX. The existing `updateDesignElementGeometry` backend endpoint (`PATCH /workspaces/:w/items/:i/design/pages/:p/elements/:e/geometry`) is already designed for 60+/sec traffic — it does sparse-merge and writes only `x`/`y`/`width`/`height`/`rotation`. We use it for drag/resize and `updateDesignElement` (full PUT) only for non-geometry edits coming from the PropertiesPanel.
- Selection becomes a `Set<string>` (was `string | null`) so Shift+click multi-select works. The LayersPanel row highlight + the PropertiesPanel content adapt (PropertiesPanel shows a "N elements selected" banner when multiple).
- Snap is computed in `DesignView` (it has the full element list and the page dimensions) and passed down to `DesignElement` as `snapGuides: { x: number | null; y: number | null }` props. While dragging, the parent overrides the cursor's `dx/dy` to snap onto matching edges/centers within a 6px threshold. Alignment guides render as 1px violet lines on top of the canvas.
- Keyboard nudge (arrow keys = 1px, Shift+arrow = 10px) is owned by DesignView's `handleKeydown` and dispatches the same `update` event the drag uses.

**Tech Stack:** Vue 3 + TypeScript (Composition API), Pinia, HTML5 Pointer Events, Pinia (workspaceStore extension). No backend changes — the geometry PATCH endpoint already exists from PR #120 / commit `bcc0ee34`. Tests: `@vue/test-utils` + Vitest. No Zig changes. No DB migrations.

---

## File Structure

### Modified files (production code)
- `src/apps/desktop/src/stores/workspaces.ts` — add `activeDesignPageId: string` ref + `setActiveDesignPage(pageId)` action; extend `updateDesignElement` to take a caller-supplied pageId (drop the implicit-fetch assumption).
- `src/apps/desktop/src/components/AppLayout.vue` — replace the no-op `handleDesignUpdateElement` (line ~1129) and `handleDesignDeleteElement` (line ~1145) with real handlers that read `activeDesignPageId` from the store and call `updateDesignElement` / `deleteDesignElement` on the right page. Remove the misleading "geometry-update path inside DesignView already calls workspacesStore.updateDesignElementGeometry directly" comment.
- `src/apps/desktop/src/components/design/DesignView.vue` — call `setActiveDesignPage` whenever the local `activePageId` ref changes (single source of truth mirror); add a 50ms-throttle + 16ms-trailing wrapper around the drag's `update` emit (drop the trailing emit on pointerup so the final position is the source of truth); add snap-to-edges logic; render alignment guides; add keyboard nudge.
- `src/apps/desktop/src/components/design/DesignElement.vue` — change `selected` prop semantics to "this element is in the selection set"; add `selectedIds: Set<string>` prop; add `constrainToCanvas: { width: number; height: number }` prop; shift the `cursor-move` class to apply when `selectedIds.has(this.id)` OR `readonly` is false AND selection is non-empty (Figma: hover-only cursor when nothing's selected, drag cursor only on hover of selected-or-draggable element).
- `src/apps/desktop/src/components/design/PropertiesPanel.vue` — when `selectedIds.size > 1`, hide the geometry/style/type/HTML sections and render a "N elements selected" banner with a single action: "Align left/right/top/bottom/center H/center V" buttons that issue batch updates.
- `src/apps/desktop/src/components/design/LayersPanel.vue` — add `selectedIds` prop (Set); rows highlight when their id is in the set; click toggles membership (Shift+click = additive, plain click = exclusive); add a small "□" indicator next to the element name when the element has children (frame/group containers).

### New files (tests)
- `src/apps/desktop/src/components/design/__tests__/DesignElement.drag.spec.ts` — 8 vitest tests covering: pointerdown → emit select; pointermove → emit update with x/y patch; pointerup → no extra emit; zoom-aware drag math (1/zoom applied); preview mode swallows drag; readonly swallows drag; resize handle emits width/height patch with handle sign flip; min size 10px clamp.
- `src/apps/desktop/src/components/design/__tests__/DesignView.dragWiring.spec.ts` — 6 vitest tests covering: throttle coalesces multiple pointermove into ≤1 emit per 50ms window; trailing emit fires on pointerup with final position; active page id is published to the store on mount and on tab switch; alignment guides render when dragging element within 6px of another element's edge; keyboard arrow nudge emits update with ±1px; keyboard Shift+arrow emits update with ±10px.
- `src/apps/desktop/src/__tests__/AppLayout.designHandlers.spec.ts` — 4 vitest tests covering: handleDesignUpdateElement calls store.updateDesignElement with active page id; handleDesignDeleteElement calls store.deleteDesignElement with active page id; both handlers no-op when active page id is empty (race during mount); both handlers bubble API errors via the notification store.

### Modified files (tests)
- `src/apps/desktop/src/__tests__/DesignElement.spec.ts` — update the static contract test for the `selected` prop to also accept `selectedIds` (both old single-selection and new multi-selection semantics).
- `src/apps/desktop/src/__tests__/DesignView.spec.ts` — add a test that the active page id is published to the workspaces store on mount.
- `src/apps/desktop/src/__tests__/workspacesStore.spec.ts` (if it exists; otherwise create `src/apps/desktop/src/stores/__tests__/workspacesStore.design.spec.ts`) — add tests for `activeDesignPageId` default and `setActiveDesignPage` setter.

### Total delta
- ~480 LoC production
- ~520 LoC tests
- 8 new files (all tests), 7 modified files

---

## Chunk 1: Fix the broken wire (drag actually moves the element)

> **Why this is Chunk 1:** the user can't drag at all today. Everything in Chunks 2-5 builds on top of "the wire is alive". This chunk delivers the MVP: click-and-drag moves the element, persists to backend, survives reload, reconciles via SSE.

### Task 1.1: Add `activeDesignPageId` to the workspaces store

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts` — near the existing state declarations (~line 200-300), add the ref; near `setActiveWorkspaceId` (~line 2156+), add the setter; export both.

- [ ] **Step 1: Read the existing state declarations** in `workspaces.ts` (search for `useWorkspacesStore` and `defineStore` to find the body) to confirm the import + state-shape pattern.

- [ ] **Step 2: Write the failing test**

Create `src/apps/desktop/src/stores/__tests__/workspacesStore.design.spec.ts`:

```ts
import { beforeEach, describe, expect, it } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { useWorkspacesStore } from '../workspaces'

describe('workspacesStore active design page', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('activeDesignPageId defaults to empty string', () => {
    const store = useWorkspacesStore()
    expect(store.activeDesignPageId).toBe('')
  })

  it('setActiveDesignPage updates the ref', () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_abc')
    expect(store.activeDesignPageId).toBe('page_abc')
  })

  it('setActiveDesignPage with empty string clears the ref', () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_abc')
    store.setActiveDesignPage('')
    expect(store.activeDesignPageId).toBe('')
  })
})
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run stores/__tests__/workspacesStore.design.spec.ts 2>&1 | tail -n 20`
Expected: FAIL with "store.activeDesignPageId is not a function" / "store.setActiveDesignPage is not a function".

- [ ] **Step 4: Implement the store additions**

In `workspaces.ts`:

1. Add the import (already at the top): `import { ref, computed } from 'vue'` — if not already imported, add.
2. Inside `useWorkspacesStore` body (after the existing state declarations), add:
   ```ts
   // The currently-edited design page id. Mirrors the local ref
   // inside DesignView so the AppLayout-level handlers (which
   // sit ABOVE DesignView) can route API calls to the right page.
   // DesignView is the source of truth — it calls setActiveDesignPage
   // on every activePageId change (mount + tab switch).
   const activeDesignPageId = ref<string>('')

   function setActiveDesignPage(pageId: string): void {
     activeDesignPageId.value = pageId
   }
   ```
3. In the `return { ... }` block at the bottom of `useWorkspacesStore`, add:
   ```ts
   activeDesignPageId,
   setActiveDesignPage,
   ```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run stores/__tests__/workspacesStore.design.spec.ts 2>&1 | tail -n 10`
Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/apps/desktop/src/stores/workspaces.ts src/apps/desktop/src/stores/__tests__/workspacesStore.design.spec.ts
git commit -m "feat(design): add activeDesignPageId ref + setActiveDesignPage to workspaces store"
```

### Task 1.2: Wire DesignView's activePageId to the store

**Files:**
- Modify: `src/apps/desktop/src/components/design/DesignView.vue` — add a `watch(activePageId)` that calls `workspacesStore.setActiveDesignPage(pageId)`. Mirror on unmount (clear the store's ref so a stale page id doesn't linger after the user navigates away).

- [ ] **Step 1: Find the existing `watch(activePageId, ...)` block** in DesignView.vue (around line 313). It already exists for re-fetching elements on tab switch. Add the store mirror next to it — same watcher, just an extra call.

- [ ] **Step 2: Write the failing test**

Append to `src/apps/desktop/src/__tests__/DesignView.spec.ts`:

```ts
it('publishes the active page id to the workspaces store on mount and on tab switch', async () => {
  // Mock the API so loadPages returns a couple of pages.
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

  const { useWorkspacesStore } = await import('../stores/workspaces')
  const wrapper = mount(DesignView, {
    props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
  })
  await flushPromises()
  // The store should reflect the first page (default on mount).
  expect(useWorkspacesStore().activeDesignPageId).toBe('page_first')
  wrapper.unmount()
  // Unmount clears the store ref so a stale id doesn't linger.
  expect(useWorkspacesStore().activeDesignPageId).toBe('')
})
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run __tests__/DesignView.spec.ts -t "publishes the active page" 2>&1 | tail -n 20`
Expected: FAIL — `activeDesignPageId` is still `''`.

- [ ] **Step 4: Wire the watcher**

In `DesignView.vue`, in the existing `watch(activePageId, (pageId) => { ... })` block (around line 313), ADD a store-mirror call at the top:

```ts
watch(activePageId, (pageId) => {
  workspacesStore.setActiveDesignPage(pageId)
  selectedElementId.value = null  // existing line — leave as is
  if (!pageId) return
  if (!props.workspaceId || !effectiveItemId.value) return
  void workspacesStore.fetchDesignElements(  // existing line
    props.workspaceId,
    effectiveItemId.value,
    pageId,
  )
})
```

And in the existing `onUnmounted(() => { ... })` block (around line 434), ADD:

```ts
onUnmounted(() => {
  // ... existing cleanup (event listeners, timers, body cursor) ...
  workspacesStore.setActiveDesignPage('')
})
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run __tests__/DesignView.spec.ts -t "publishes the active page" 2>&1 | tail -n 10`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/apps/desktop/src/components/design/DesignView.vue src/apps/desktop/src/__tests__/DesignView.spec.ts
git commit -m "feat(design): mirror DesignView activePageId to workspacesStore"
```

### Task 1.3: Replace the no-op `handleDesignUpdateElement` in AppLayout

**Files:**
- Modify: `src/apps/desktop/src/components/AppLayout.vue` — line ~1129-1143. The current code is:
  ```ts
  const handleDesignUpdateElement = async (elementId: string, patch: unknown) => {
    const ws = activeWorkspace.value
    const item = activeWorkspaceItem.value
    if (!ws || !item) return
    void elementId
    void patch
    console.warn('[handleDesignUpdateElement] pageId not yet tracked ...')
  }
  ```
  Replace with a real call to the store, routing through `updateDesignElementGeometry` for x/y/width/height/rotation-only patches (the high-frequency drag/resize path) and `updateDesignElement` for everything else (the PropertiesPanel form-edit path).

- [ ] **Step 1: Read the existing handler** in AppLayout.vue (line ~1129) plus the imports at the top of the file to confirm `useWorkspacesStore` is already imported.

- [ ] **Step 2: Write the failing test**

Create `src/apps/desktop/src/__tests__/AppLayout.designHandlers.spec.ts`:

```ts
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { useWorkspacesStore } from '../stores/workspaces'

// Stub the workspace store action so we can assert it was called.
vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    updateDesignElement: vi.fn().mockResolvedValue({ id: 'el_1' }),
    updateDesignElementGeometry: vi.fn().mockResolvedValue({ id: 'el_1' }),
    deleteDesignElement: vi.fn().mockResolvedValue({ success: true }),
  }
})

describe('AppLayout design handlers (Chunk 1, Task 1.3)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('handleDesignUpdateElement routes a geometry-only patch to updateDesignElementGeometry', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_xyz')
    const { handleDesignUpdateElement } = await import('../components/AppLayout.vue')
    // (Can't import the SFC directly — but AppLayout's handlers are
    //  top-level. The right way to test is to mount AppLayout with
    //  a design-item active and emit `update-element`. See alternative
    //  test below.)
  })
})
```

> **Note:** if the SFC-direct import doesn't work, fall back to mounting `<DesignView>` directly with `app.use(pinia)` + stubbing `<AppLayout>`'s parent. The simpler approach is to extract the handler into a separate composable file (see Task 1.4 below) and unit-test that. **Pivot to Task 1.4's approach for the actual test.**

- [ ] **Step 3: Pivot — extract the design handlers into a composable**

Create `src/apps/desktop/src/composables/useDesignHandlers.ts`:

```ts
import { useNotificationStore } from '../stores/notifications'
import { useWorkspacesStore } from '../stores/workspaces'

/**
 * AppLayout's design-mode handlers, extracted into a composable so
 * they're directly testable (SFC <script setup> functions aren't
 * importable as named exports). The composable owns NO state — it
 * reads the active workspace/item/page from the store and dispatches
 * to the store actions. Errors surface via the notification store.
 */
export function useDesignHandlers() {
  const workspacesStore = useWorkspacesStore()
  const notificationStore = useNotificationStore()

  /**
   * Route an element patch to the right endpoint.
   *   - geometry-only (x / y / width / height / rotation) → PATCH
   *     /geometry (60+/sec safe; smaller payload; sparse validation)
   *   - anything else → full PUT (PropertiesPanel edits, type
   *     changes, fill / stroke / opacity changes from outside the
   *     drag flow)
   */
  async function updateElement(
    workspaceId: string,
    itemId: string,
    elementId: string,
    patch: Record<string, unknown>,
  ): Promise<void> {
    const pageId = workspacesStore.activeDesignPageId
    if (!pageId) {
      console.warn(
        '[useDesignHandlers.updateElement] no activeDesignPageId; ignoring patch',
        { workspaceId, itemId, elementId, patch },
      )
      return
    }
    const keys = Object.keys(patch)
    const isGeometryOnly =
      keys.length > 0 &&
      keys.every((k) =>
        k === 'x' || k === 'y' || k === 'width' || k === 'height' || k === 'rotation',
      )
    try {
      if (isGeometryOnly) {
        await workspacesStore.updateDesignElementGeometry(
          workspaceId, itemId, pageId, elementId,
          patch as { x?: number; y?: number; width?: number; height?: number; rotation?: number },
        )
      } else {
        await workspacesStore.updateDesignElement(
          workspaceId, itemId, pageId, elementId, patch,
        )
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError('Failed to update element', message)
    }
  }

  async function deleteElement(
    workspaceId: string,
    itemId: string,
    elementId: string,
  ): Promise<void> {
    const pageId = workspacesStore.activeDesignPageId
    if (!pageId) {
      console.warn(
        '[useDesignHandlers.deleteElement] no activeDesignPageId; ignoring',
        { workspaceId, itemId, elementId },
      )
      return
    }
    if (!confirm('Delete this element?')) return
    try {
      await workspacesStore.deleteDesignElement(
        workspaceId, itemId, pageId, elementId,
      )
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError('Failed to delete element', message)
    }
  }

  return { updateElement, deleteElement }
}
```

- [ ] **Step 4: Write the unit tests for the composable**

In the new file `src/apps/desktop/src/composables/__tests__/useDesignHandlers.spec.ts`:

```ts
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { useDesignHandlers } from '../useDesignHandlers'
import { useWorkspacesStore } from '../../stores/workspaces'

// Stub the store actions so we can assert routing.
const updateDesignElementGeometrySpy = vi.fn().mockResolvedValue({ id: 'el_1' })
const updateDesignElementSpy = vi.fn().mockResolvedValue({ id: 'el_1' })
const deleteDesignElementSpy = vi.fn().mockResolvedValue({ success: true })

vi.mock('../../stores/workspaces', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../stores/workspaces')>()
  return {
    ...actual,
    useWorkspacesStore: () => ({
      activeDesignPageId: 'page_test',
      updateDesignElementGeometry: updateDesignElementGeometrySpy,
      updateDesignElement: updateDesignElementSpy,
      deleteDesignElement: deleteDesignElementSpy,
    }),
  }
})

describe('useDesignHandlers', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
    vi.stubGlobal('confirm', vi.fn(() => true))
  })

  it('routes a geometry-only patch to updateDesignElementGeometry', async () => {
    const { updateElement } = useDesignHandlers()
    await updateElement('ws_1', 'item_1', 'el_1', { x: 100, y: 200 })
    expect(updateDesignElementGeometrySpy).toHaveBeenCalledWith(
      'ws_1', 'item_1', 'page_test', 'el_1',
      { x: 100, y: 200 },
    )
    expect(updateDesignElementSpy).not.toHaveBeenCalled()
  })

  it('routes a non-geometry patch to updateDesignElement', async () => {
    const { updateElement } = useDesignHandlers()
    await updateElement('ws_1', 'item_1', 'el_1', { fill: '#ff0000' })
    expect(updateDesignElementSpy).toHaveBeenCalledWith(
      'ws_1', 'item_1', 'page_test', 'el_1',
      { fill: '#ff0000' },
    )
    expect(updateDesignElementGeometrySpy).not.toHaveBeenCalled()
  })

  it('routes a mixed patch to updateDesignElement (full PUT, not geometry-only)', async () => {
    const { updateElement } = useDesignHandlers()
    await updateElement('ws_1', 'item_1', 'el_1', { x: 50, fill: 'red' })
    expect(updateDesignElementSpy).toHaveBeenCalled()
    expect(updateDesignElementGeometrySpy).not.toHaveBeenCalled()
  })

  it('deleteElement routes to deleteDesignElement', async () => {
    const { deleteElement } = useDesignHandlers()
    await deleteElement('ws_1', 'item_1', 'el_1')
    expect(deleteDesignElementSpy).toHaveBeenCalledWith(
      'ws_1', 'item_1', 'page_test', 'el_1',
    )
  })

  it('updateElement no-ops when no active page id', async () => {
    vi.doMock('../../stores/workspaces', () => ({
      useWorkspacesStore: () => ({
        activeDesignPageId: '',
        updateDesignElementGeometry: updateDesignElementGeometrySpy,
        updateDesignElement: updateDesignElementSpy,
        deleteDesignElement: deleteDesignElementSpy,
      }),
    }))
    const { updateElement } = useDesignHandlers()
    await updateElement('ws_1', 'item_1', 'el_1', { x: 100 })
    expect(updateDesignElementGeometrySpy).not.toHaveBeenCalled()
    vi.doUnmock('../../stores/workspaces')
  })
})
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run composables/__tests__/useDesignHandlers.spec.ts 2>&1 | tail -n 20`
Expected: 5 tests pass.

- [ ] **Step 6: Wire the composable into AppLayout and remove the no-op**

In `src/apps/desktop/src/components/AppLayout.vue`:

1. Add the import near the other composable imports:
   ```ts
   import { useDesignHandlers } from '../composables/useDesignHandlers'
   ```
2. Inside the `<script setup>` body, add:
   ```ts
   const designHandlers = useDesignHandlers()
   ```
3. Replace the no-op `handleDesignUpdateElement` (line ~1129) with:
   ```ts
   const handleDesignUpdateElement = async (
     elementId: string,
     patch: Partial<{
       x: number; y: number; width: number; height: number; rotation: number;
       [k: string]: unknown;
     }>,
   ): Promise<void> => {
     const ws = activeWorkspace.value
     const item = activeWorkspaceItem.value
     if (!ws || !item) return
     await designHandlers.updateElement(ws.id, item.id, elementId, patch)
   }
   ```
4. Replace the no-op `handleDesignDeleteElement` (line ~1145) with:
   ```ts
   const handleDesignDeleteElement = async (elementId: string): Promise<void> => {
     const ws = activeWorkspace.value
     const item = activeWorkspaceItem.value
     if (!ws || !item) return
     await designHandlers.deleteElement(ws.id, item.id, elementId)
   }
   ```

- [ ] **Step 7: Build to verify types**

Run: `cd src/apps/desktop && timeout 60 bun run build 2>&1 | tail -n 5`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add src/apps/desktop/src/composables/useDesignHandlers.ts \
        src/apps/desktop/src/composables/__tests__/useDesignHandlers.spec.ts \
        src/apps/desktop/src/components/AppLayout.vue
git commit -m "feat(design): wire update/delete handlers to the workspaces store (via composable)"
```

### Task 1.4: Throttle the drag-update stream in DesignView

**Files:**
- Modify: `src/apps/desktop/src/components/design/DesignElement.vue` — the `onMove` handler (line ~152) emits `update` on EVERY `pointermove`. Wrap in a 50ms-throttle so we cap at ~20 emits/sec (still smooth, doesn't flood the backend). On `pointerup`, cancel the throttle and fire a final trailing emit with the EXACT final position (in case the throttle swallowed it).

- [ ] **Step 1: Read the existing `startDrag` body** in DesignElement.vue (line ~122-200) to understand the closure structure. The throttle must be scoped to a single drag — created in `startDrag`, cancelled in `onUp`.

- [ ] **Step 2: Write the failing test**

Create `src/apps/desktop/src/components/design/__tests__/DesignElement.drag.spec.ts`:

```ts
import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import DesignElement from '../DesignElement.vue'
import type { DesignElement as DesignElementApi } from '../../../api'

const ELEMENT: DesignElementApi = {
  id: 'el_1', name: 'Box', type: 'rectangle',
  page_id: 'page_1', x: 100, y: 100, width: 200, height: 200,
  rotation: 0, opacity: 1, fill: '#fff', stroke: '', stroke_width: 0,
  corner_radius: 0, text_content: '', text_style: '', image_url: '',
  parent_id: '', z_index: 0, position: 0,
  file_path: '', created_at: '', updated_at: '',
}

describe('DesignElement drag', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('emits update with x/y patch on pointermove', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    // Stub pointer-capture so jsdom doesn't error.
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = () => true
    ;(root as any).addEventListener = vi.fn()
    ;(root as any).removeEventListener = vi.fn()

    await wrapper.trigger('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100 })

    // Move handler was registered on addEventListener('pointermove', ...)
    const moveHandler = (root as any).addEventListener.mock.calls.find(
      (c: any[]) => c[0] === 'pointermove',
    )?.[1]
    expect(moveHandler).toBeDefined()

    // Simulate a +50, +30 move.
    moveHandler(new PointerEvent('pointermove', { clientX: 150, clientY: 130, pointerId: 1 }))
    // Within the throttle window — may or may not have emitted yet.
    // Use the wrapper's emitted() after waiting.
    await new Promise((r) => setTimeout(r, 60))  // wait past throttle
    const updates = wrapper.emitted('update') ?? []
    const lastUpdate = updates[updates.length - 1]?.[0] as any
    expect(lastUpdate).toMatchObject({ x: 150, y: 130 })
  })

  it('emits a trailing update on pointerup with the final position', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = () => true
    let moveHandler: any, upHandler: any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
      if (type === 'pointerup') upHandler = cb
    }
    ;(root as any).removeEventListener = () => {}

    await wrapper.trigger('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100 })
    moveHandler(new PointerEvent('pointermove', { clientX: 999, clientY: 999, pointerId: 1 }))
    // Fire pointerup immediately (within throttle window).
    upHandler(new PointerEvent('pointerup', { pointerId: 1 }))

    // The trailing emit must include the final position even if the
    // throttle hadn't fired.
    const updates = wrapper.emitted('update') ?? []
    const lastUpdate = updates[updates.length - 1]?.[0] as any
    expect(lastUpdate).toMatchObject({ x: 999, y: 999 })
  })

  it('applies 1/zoom to the delta so zoomed canvases stay 1:1 with cursor', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 0.5 },  // 50% zoom
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = () => true
    let moveHandler: any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
    }
    ;(root as any).removeEventListener = () => {}

    await wrapper.trigger('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100 })
    moveHandler(new PointerEvent('pointermove', { clientX: 200, clientY: 100, pointerId: 1 }))
    // 100 screen-px move at 50% zoom = 200 design-px move.
    // Start: x=100, dx = (200-100)/0.5 = 200 → x = 100+200 = 300
    await new Promise((r) => setTimeout(r, 60))
    const updates = wrapper.emitted('update') ?? []
    const lastUpdate = updates[updates.length - 1]?.[0] as any
    expect(lastUpdate.x).toBe(300)
  })

  it('preview mode swallows drag (no emit)', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, previewMode: true },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    await wrapper.trigger('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100 })
    expect(wrapper.emitted('update')).toBeUndefined()
  })

  it('readonly swallows drag (no emit)', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, readonly: true },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    await wrapper.trigger('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100 })
    expect(wrapper.emitted('update')).toBeUndefined()
  })

  it('resize handle emits width/height patch with sign flip', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const nwHandle = wrapper.find(`[data-testid="design-element-handle-${ELEMENT.id}-nw"]`)
    const nwEl = nwHandle.element as HTMLElement
    nwEl.setPointerCapture = () => {}
    nwEl.releasePointerCapture = () => {}
    nwEl.hasPointerCapture = () => true
    let moveHandler: any
    ;(nwEl as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
    }
    ;(nwEl as any).removeEventListener = () => {}

    await nwHandle.trigger('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100 })
    // Drag NW handle up-left by (-30, -40): width grows by 30, height grows by 40,
    // x shrinks by 30, y shrinks by 40.
    moveHandler(new PointerEvent('pointermove', { clientX: 70, clientY: 60, pointerId: 1 }))
    await new Promise((r) => setTimeout(r, 60))
    const updates = wrapper.emitted('update') ?? []
    const lastUpdate = updates[updates.length - 1]?.[0] as any
    expect(lastUpdate.width).toBe(230)   // 200 + 30
    expect(lastUpdate.height).toBe(240)  // 200 + 40
    expect(lastUpdate.x).toBe(70)        // 100 - 30
    expect(lastUpdate.y).toBe(60)        // 100 - 40
  })

  it('resize clamps width/height to minimum 10px', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const eHandle = wrapper.find(`[data-testid="design-element-handle-${ELEMENT.id}-e"]`)
    const eEl = eHandle.element as HTMLElement
    eEl.setPointerCapture = () => {}
    eEl.releasePointerCapture = () => {}
    eEl.hasPointerCapture = () => true
    let moveHandler: any
    ;(eEl as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
    }
    ;(eEl as any).removeEventListener = () => {}

    await eHandle.trigger('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100 })
    // Drag E handle -1000px left: width would go to -800, clamped to 10.
    moveHandler(new PointerEvent('pointermove', { clientX: -900, clientY: 100, pointerId: 1 }))
    await new Promise((r) => setTimeout(r, 60))
    const updates = wrapper.emitted('update') ?? []
    const lastUpdate = updates[updates.length - 1]?.[0] as any
    expect(lastUpdate.width).toBe(10)
  })
})
```

- [ ] **Step 3: Run the tests to verify the baseline failures**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run components/design/__tests__/DesignElement.drag.spec.ts 2>&1 | tail -n 30`
Expected: most tests FAIL — the throttle doesn't exist yet, so move-handler emits synchronously and the tests' 60ms wait picks up the immediate emit. The "trailing on pointerup" test will fail.

- [ ] **Step 4: Implement the throttle**

In `DesignElement.vue`, modify `startDrag` (around line 122) to introduce a 50ms-throttle:

```ts
const startDrag = (event: PointerEvent, mode: DragMode): void => {
  if (props.readonly) return
  if (props.previewMode) return
  if (event.button !== 0) return
  emit('select', props.element.id)
  event.preventDefault()

  const target = event.currentTarget as HTMLElement | null
  if (!target) return
  target.setPointerCapture(event.pointerId)
  isDragging.value = true

  const startX = event.clientX
  const startY = event.clientY
  const start = {
    x: props.element.x, y: props.element.y,
    width: props.element.width, height: props.element.height,
  }

  // The latest patch we intend to emit. Throttled: we only emit when
  // either (a) 50ms has elapsed since the last emit, or (b) pointerup
  // fires (the trailing emit captures the final position even if the
  // throttle window hasn't elapsed).
  let pendingPatch: Partial<DesignElement> | null = null
  let lastEmitMs = 0
  const THROTTLE_MS = 50

  const flushEmit = (): void => {
    if (pendingPatch) {
      emit('update', pendingPatch)
      pendingPatch = null
      lastEmitMs = performance.now()
    }
  }

  const computePatch = (dx: number, dy: number): Partial<DesignElement> => {
    if (mode === 'move') {
      return {
        x: Math.round(start.x + dx),
        y: Math.round(start.y + dy),
      }
    }
    const patch: Partial<DesignElement> = {}
    const h = mode.resize
    if (h.includes('e')) patch.width = Math.max(10, Math.round(start.width + dx))
    if (h.includes('s')) patch.height = Math.max(10, Math.round(start.height + dy))
    if (h.includes('w')) {
      patch.width = Math.max(10, Math.round(start.width - dx))
      patch.x = Math.round(start.x + (start.width - (patch.width ?? start.width)))
    }
    if (h.includes('n')) {
      patch.height = Math.max(10, Math.round(start.height - dy))
      patch.y = Math.round(start.y + (start.height - (patch.height ?? start.height)))
    }
    return patch
  }

  const onMove = (e: PointerEvent): void => {
    const inv = 1 / Math.max(0.01, props.zoom)
    const dx = (e.clientX - startX) * inv
    const dy = (e.clientY - startY) * inv
    pendingPatch = computePatch(dx, dy)
    const now = performance.now()
    if (now - lastEmitMs >= THROTTLE_MS) {
      flushEmit()
    }
  }

  const onUp = (e: PointerEvent): void => {
    if (target.hasPointerCapture(e.pointerId)) {
      target.releasePointerCapture(e.pointerId)
    }
    isDragging.value = false
    // Trailing emit: capture the final position regardless of throttle.
    flushEmit()
    target.removeEventListener('pointermove', onMove)
    target.removeEventListener('pointerup', onUp)
    target.removeEventListener('pointercancel', onUp)
  }

  target.addEventListener('pointermove', onMove)
  target.addEventListener('pointerup', onUp)
  target.addEventListener('pointercancel', onUp)
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run components/design/__tests__/DesignElement.drag.spec.ts 2>&1 | tail -n 20`
Expected: 7 tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/apps/desktop/src/components/design/DesignElement.vue \
        src/apps/desktop/src/components/design/__tests__/DesignElement.drag.spec.ts
git commit -m "feat(design): throttle drag-update stream (50ms cap, trailing emit on pointerup)"
```

### Task 1.5: End-to-end manual smoke test (drag actually moves the element)

**Files:** none (manual test only).

- [ ] **Step 1: Build the desktop app**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
rm -rf zig-out/bin
timeout 360 zig build nalar-desktop 2>&1 | tail -n 5
```
Expected: `zig-out/bin/nalar-desktop` produced.

- [ ] **Step 2: Open the desktop app** and navigate to a design item with at least one element on the canvas. Click on the element to select it (violet outline + 8 resize handles appear).

- [ ] **Step 3: Click-and-drag the element body**

- The cursor should be `move` on hover.
- Drag to a new position. The element should follow the cursor smoothly.
- Release the mouse. The element stays in the new position.

- [ ] **Step 4: Verify persistence**

- Reload the app (Cmd/Ctrl+R or close + reopen).
- The element should be at the new position.

- [ ] **Step 5: Verify SSE sync**

- Open the same design item in TWO browser tabs / windows.
- Drag the element in tab 1.
- Tab 2 should see the element jump to the new position (via SSE design_element_updated).

- [ ] **Step 6: Verify PropertiesPanel X/Y inputs reflect the new position**

- After the drag, click the element to re-select.
- The X and Y inputs in the right sidebar should show the new position values.

- [ ] **Step 7: Verify resize still works**

- Drag one of the 8 resize handles. The element should resize, with the opposite edge anchoring in place.
- Min size 10px is enforced (drag the east handle past the west edge; the element clamps to 10×200).

- [ ] **Step 8: Verify undo / error path**

- Backend offline test: stop the backend, then try to drag. The console should show "Failed to update element" notification; the local element should snap back to its previous position when the next SSE event lands.

- [ ] **Step 9: Commit the smoke-test results to NALAR.md (no code change)**

Append to `/home/ginwa/agentic_coding_zig/ginwaaitoolbox/NALAR.md` (or a per-feature doc):

```
## 2026-07-25: Design element drag-and-drop wire repaired

### Symptom (pre-fix)
Click on a design element → violet outline + 8 resize handles appear (selection works).
Click-and-drag → element does NOT move.

### Root cause
`AppLayout.handleDesignUpdateElement` (src/apps/desktop/src/components/AppLayout.vue:1129)
was a TODO no-op (`void elementId; void patch`). DesignElement's pointermove emitted
`update` patches, DesignView re-emitted them upward as `updateElement`, but the parent
silently discarded them.

### Fix
- Added `activeDesignPageId` + `setActiveDesignPage` to workspaces store (Task 1.1).
- DesignView mirrors its local `activePageId` to the store on mount + tab switch (Task 1.2).
- Extracted design handlers into `useDesignHandlers` composable for testability (Task 1.3).
- Replaced the no-op with a real handler that routes geometry-only patches to
  `PATCH /geometry` and full patches to `PUT /elements/:id` (Task 1.3).
- Throttled the drag stream to 50ms with a trailing emit on pointerup (Task 1.4).
```

---

## Chunk 2: Multi-select + group drag (Figma core UX)

> **Why Chunk 2:** Selection is the foundation of every other Figma UX feature (alignment, distribute, lock, hide). Get multi-select right and the rest of the Figma parity features are incremental.

### Task 2.1: Change selection from `string | null` to `Set<string>`

**Files:**
- Modify: `src/apps/desktop/src/components/design/DesignView.vue` — `selectedElementId` ref → `selectedIds: ref<Set<string>>(new Set())`. `activeElement` computed → `activeElements` computed returning the array. `handleElementSelect` → `handleElementToggle` (additive on Shift, exclusive otherwise).
- Modify: `src/apps/desktop/src/components/design/DesignElement.vue` — `selected: boolean` prop → keep `selected` for backward compat, add `selectedIds: string[]` prop for multi-aware cursor handling.
- Modify: `src/apps/desktop/src/components/design/LayersPanel.vue` — `selectedElementId` → `selectedIds`. Rows highlight when their id is in the set. Click on row = exclusive select; Shift+click = toggle membership.
- Modify: `src/apps/desktop/src/components/design/PropertiesPanel.vue` — `element: DesignElement | null` → `elements: DesignElement[]`. When `elements.length === 0`: empty state. When `elements.length === 1`: existing single-element form. When `elements.length > 1`: "N elements selected" banner with batch-action buttons (alignment, distribute, etc. — out of scope for this plan but the banner is needed now).

- [ ] **Step 1: Read the existing `selectedElementId` ref** in DesignView.vue (around line 118) and trace every reader/writer.

- [ ] **Step 2: Update DesignView's selection state**

Replace:
```ts
const selectedElementId = ref<string | null>(null)
const activeElement = computed<DesignElementApi | null>(() => {
  if (!selectedElementId.value) return null
  return elements.value.find((e) => e.id === selectedElementId.value) ?? null
})
```

With:
```ts
// Multi-select state. Empty Set = nothing selected. Figma model:
// plain click = exclusive select; Shift+click = toggle membership;
// Escape = clear all. Drag from empty selection to draw a marquee
// (deferred to Chunk 5).
const selectedIds = ref<Set<string>>(new Set())

const activeElements = computed<DesignElementApi[]>(() => {
  return elements.value.filter((e) => selectedIds.value.has(e.id))
})

const isSingleSelect = computed(() => selectedIds.value.size === 1)
const activeElement = computed<DesignElementApi | null>(() =>
  isSingleSelect.value ? activeElements.value[0] ?? null : null,
)
```

- [ ] **Step 3: Update `handleElementSelect` → multi-aware**

Replace:
```ts
const handleElementSelect = (elementId: string): void => {
  selectedElementId.value = elementId
  emit('selectElement', elementId)
}
```

With:
```ts
const handleElementToggle = (elementId: string, additive: boolean): void => {
  if (additive) {
    const next = new Set(selectedIds.value)
    if (next.has(elementId)) next.delete(elementId)
    else next.add(elementId)
    selectedIds.value = next
  } else {
    selectedIds.value = new Set([elementId])
  }
  emit('selectElement', elementId)
}
```

- [ ] **Step 4: Update the template** to pass the additive flag through

In DesignView.vue's `<DesignElement>` invocation, change `@select="handleElementSelect"` → `@select="(id) => handleElementToggle(id, $event.shiftKey)"`.

- [ ] **Step 5: Update the canvas-click deselection** in `handleCanvasClick`

Currently:
```ts
selectedElementId.value = null
```
Becomes:
```ts
selectedIds.value = new Set()
```

- [ ] **Step 6: Update the Escape handler** in `handleKeydown` (around line 365)

Currently:
```ts
selectedElementId.value = null
```
Becomes:
```ts
selectedIds.value = new Set()
```

- [ ] **Step 7: Update the watcher** at the top of the file that clears selection on page change (around line 314)

Currently:
```ts
selectedElementId.value = null
```
Becomes:
```ts
selectedIds.value = new Set()
```

- [ ] **Step 8: Update the watcher** at the top of the file that clears selection when exiting Preview mode (around line 149-151)

Same replacement.

- [ ] **Step 9: Update DesignElement.vue** — accept `selectedIds: string[]` prop and use it for the violet outline

Replace:
```ts
selected: boolean
```
With:
```ts
// Single-element shortcut (kept for backward compat with tests + simple
// use cases). True iff `selectedIds` has exactly this element and
// nothing else. The wrapper's `.selected` class is applied iff this
// is true OR the element is in a multi-selection that includes it.
selected?: boolean
// The full selection set (Figma multi-select model). When non-empty
// AND this element's id is in it, render the violet outline + resize
// handles. When only `selected === true` (no multi-selection context),
// the wrapper renders the legacy single-selection chrome.
selectedIds?: string[]
```

Add to the default values:
```ts
selectedIds: () => [] as string[],
```

Update the `:class` binding on the wrapper div to include the selection check:
```ts
:class="[
  (selected || selectedIds.includes(element.id)) ? 'selected' : '',
  readonly ? 'cursor-default' : 'cursor-move',
  isDragging ? 'dragging' : '',
]"
```

Update `handleKeydown` (line ~291) so Delete/Backspace fires for every selected id, not just the focused one:
```ts
const handleKeydown = (e: KeyboardEvent): void => {
  if (selectedIds.length === 0 && !props.selected) return
  if (props.readonly) return
  if (e.key !== 'Delete' && e.key !== 'Backspace') return
  const target = e.target as HTMLElement | null
  if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) {
    return
  }
  e.preventDefault()
  for (const id of (selectedIds.length > 0 ? selectedIds : [props.element.id])) {
    emit('delete', id)
  }
}
```

- [ ] **Step 10: Update LayersPanel.vue** — accept `selectedIds: string[]` and pass the additive flag through

Replace the `selectedElementId` prop with:
```ts
selectedIds: string[]  // multi-aware; a row highlights if its id is in the set
```

Update `handleSelect` (line ~99):
```ts
const handleSelect = (elementId: string, event: MouseEvent): void => {
  emit('select', { elementId, additive: event.shiftKey })
}
```

Update the template row click:
```vue
@click="(e) => handleSelect(element.id, e)"
```

- [ ] **Step 11: Update PropertiesPanel.vue** — accept `elements` array and render the multi-select banner

Replace the `element: DesignElement | null` prop with:
```ts
elements: DesignElement[]  // length 0 = nothing selected, length 1 = single, length > 1 = multi
```

Add to the template:

```vue
<template v-if="elements.length > 1">
  <div class="flex-1 flex items-center justify-center p-6 text-sm" data-testid="properties-panel-multi">
    <div class="text-center">
      <div class="text-3xl mb-2" aria-hidden="true">▦</div>
      <div>{{ elements.length }} elements selected</div>
      <div class="text-xs mt-1" style="opacity: 0.7;">Press Esc to deselect all</div>
    </div>
  </div>
</template>
<template v-else-if="elements.length === 1">
  <!-- The existing single-element template, unchanged -->
</template>
```

Add the empty state and preview-mode banners unchanged.

- [ ] **Step 12: Update AppLayout.vue** to pass `selectedIds` instead of `selectedElementId`

Find the two `<DesignView>` instances (around line 1623 and 1674) and the `selected-element-id` bindings. Pass `:selected-ids="[]"` initially — DesignView still owns the selection state internally.

- [ ] **Step 13: Write the multi-select tests**

Append to `DesignElement.drag.spec.ts`:

```ts
it('emits select with the element id on pointerdown', async () => {
  const wrapper = mount(DesignElement, {
    props: { element: ELEMENT, selectedIds: [], zoom: 1.0 },
  })
  await wrapper.find('[data-design-element]').trigger('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100 })
  expect(wrapper.emitted('select')?.[0]).toEqual(['el_1'])
})

it('Delete key emits delete for every selected element', async () => {
  const wrapper = mount(DesignElement, {
    props: { element: ELEMENT, selectedIds: ['el_1', 'el_2', 'el_3'], zoom: 1.0 },
  })
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Delete' }))
  const deletes = wrapper.emitted('delete') ?? []
  expect(deletes.map((d) => d[0])).toEqual(['el_1', 'el_2', 'el_3'])
})

it('Delete inside an input does NOT fire delete', async () => {
  const wrapper = mount(DesignElement, {
    props: { element: ELEMENT, selectedIds: ['el_1'], zoom: 1.0 },
  })
  const input = document.createElement('input')
  document.body.appendChild(input)
  input.focus()
  input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Delete', bubbles: true }))
  document.body.removeChild(input)
  expect(wrapper.emitted('delete')).toBeUndefined()
})
```

- [ ] **Step 14: Run all tests**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run components/design/__tests__/ 2>&1 | tail -n 20`
Expected: all existing tests + 3 new = pass.

- [ ] **Step 15: Build to verify types**

Run: `cd src/apps/desktop && timeout 60 bun run build 2>&1 | tail -n 5`
Expected: clean.

- [ ] **Step 16: Commit**

```bash
git add src/apps/desktop/src/components/design/DesignView.vue \
        src/apps/desktop/src/components/design/DesignElement.vue \
        src/apps/desktop/src/components/design/LayersPanel.vue \
        src/apps/desktop/src/components/design/PropertiesPanel.vue \
        src/apps/desktop/src/components/AppLayout.vue \
        src/apps/desktop/src/components/design/__tests__/DesignElement.drag.spec.ts
git commit -m "feat(design): multi-select via Shift+click; group delete; multi-aware PropertiesPanel"
```

### Task 2.2: Drag-to-move for the entire selection

**Files:**
- Modify: `src/apps/desktop/src/components/design/DesignElement.vue` — when the user starts a drag on an element that's part of a multi-selection, the WHOLE selection moves, not just the clicked one.

- [ ] **Step 1: Write the failing test**

```ts
it('drag on a multi-selected element moves the whole selection, not just this one', async () => {
  // Mount a wrapper that injects both elements into a selection set.
  const wrapper = mount({
    components: { DesignElement },
    template: `
      <div>
        <DesignElement
          ref="first"
          :element="ELEMENT"
          :selected-ids="['el_1', 'el_2']"
          :zoom="1.0"
          @update="onUpdate('el_1', $event)"
          @select="onSelect"
        />
      </div>
    `,
    data: () => ({ ELEMENT: { ...ELEMENT, id: 'el_1' } }),
    methods: {
      onUpdate(id: string, patch: any) { this.emitted_updates.push({ id, patch }) },
      onSelect(id: string) { this.emitted_selects.push(id) },
    },
    created() { this.emitted_updates = []; this.emitted_selects = [] },
  }, { attachTo: document.body })
  // ... (mount both elements in the same selection; drag one; assert
  //  the OTHER one also got an emit. Implementation: when the user
  //  pointerdowns on an element in a multi-selection, the parent's
  //  drag handler emits an `update` for EACH selected element, with
  //  the SAME dx/dy applied to each one's start position.)
})
```

- [ ] **Step 2: Implement the group drag**

In `DesignElement.vue`, modify `startDrag` to compute the patch differently when `selectedIds.length > 1` and the element being dragged is in the set:

```ts
const startDrag = (event: PointerEvent, mode: DragMode): void => {
  // ... existing readonly / previewMode guards ...
  emit('select', props.element.id)

  // In multi-select, dragging one element moves them all. The parent
  // applies the dx/dy to every selected element's start position.
  // We emit a `groupDrag` event with the dx/dy (design-px, zoom-adjusted);
  // the parent translates that into N individual `update` emits.
  if (props.selectedIds.length > 1 && props.selectedIds.includes(props.element.id)) {
    if (mode !== 'move') return  // resize is per-element, not group
    event.preventDefault()
    const target = event.currentTarget as HTMLElement | null
    if (!target) return
    target.setPointerCapture(event.pointerId)
    isDragging.value = true
    const startClientX = event.clientX
    const startClientY = event.clientY
    let pendingDx = 0
    let pendingDy = 0
    let lastEmitMs = 0
    const THROTTLE_MS = 50
    const onMove = (e: PointerEvent): void => {
      const inv = 1 / Math.max(0.01, props.zoom)
      pendingDx = (e.clientX - startClientX) * inv
      pendingDy = (e.clientY - startClientY) * inv
      const now = performance.now()
      if (now - lastEmitMs >= THROTTLE_MS) {
        emit('groupDrag', { dx: pendingDx, dy: pendingDy })
        lastEmitMs = now
      }
    }
    const onUp = (e: PointerEvent): void => {
      if (target.hasPointerCapture(e.pointerId)) target.releasePointerCapture(e.pointerId)
      isDragging.value = false
      emit('groupDrag', { dx: pendingDx, dy: pendingDy })
      target.removeEventListener('pointermove', onMove)
      target.removeEventListener('pointerup', onUp)
      target.removeEventListener('pointercancel', onUp)
    }
    target.addEventListener('pointermove', onMove)
    target.addEventListener('pointerup', onUp)
    target.addEventListener('pointercancel', onUp)
    return
  }

  // Single-element drag: existing throttled-emit logic from Chunk 1.
  // ... (unchanged) ...
}
```

- [ ] **Step 3: Update DesignView.vue** to listen for `groupDrag` and translate it

Add to DesignView.vue's `<DesignElement>` invocation:
```vue
@group-drag="handleGroupDrag"
```

Add the handler:
```ts
const handleGroupDrag = (dx: number, dy: number): void => {
  for (const id of selectedIds.value) {
    const el = elements.value.find((e) => e.id === id)
    if (!el) continue
    void workspacesStore.updateDesignElementGeometry(
      props.workspaceId,
      effectiveItemId.value,
      activePageId.value,
      id,
      {
        x: Math.round(el.x + dx),
        y: Math.round(el.y + dy),
      },
    )
  }
}
```

> **Note:** the group drag bypasses the AppLayout round-trip — it calls the store directly because we already have the activePageId locally. This is intentional for performance: a 3-element drag would otherwise generate 3 emits per pointermove × the AppLayout throttle (already none) × the store's throttle. Direct-store calls keep the latency at one round-trip per 50ms.

- [ ] **Step 4: Update the static contract test** in `DesignElement.spec.ts` to accept the new `groupDrag` emit:

```ts
it('emits select, update, groupDrag, htmlChanged, delete', () => {
  expect(source).toContain("select:")
  expect(source).toContain("update:")
  expect(source).toContain("groupDrag:")
  expect(source).toContain("htmlChanged:")
  expect(source).toContain("delete:")
})
```

- [ ] **Step 5: Run tests + build**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run components/design/__tests__/ 2>&1 | tail -n 10`
Expected: green.

Run: `cd src/apps/desktop && timeout 60 bun run build 2>&1 | tail -n 5`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add src/apps/desktop/src/components/design/DesignElement.vue \
        src/apps/desktop/src/components/design/DesignView.vue \
        src/apps/desktop/src/__tests__/DesignElement.spec.ts \
        src/apps/desktop/src/components/design/__tests__/DesignElement.drag.spec.ts
git commit -m "feat(design): group drag — multi-selected elements move together"
```

### Task 2.3: Manual smoke test for multi-select + group drag

- [ ] **Step 1: Build + open** the desktop app.

- [ ] **Step 2: Click** on element 1 → it becomes the only selection. Click on element 2 → element 1 deselects, element 2 is the only one selected.

- [ ] **Step 3: Shift+click** element 1 → both elements are now selected (violet outlines + resize handles on both).

- [ ] **Step 4: Drag** either selected element → both elements move together (same dx/dy applied).

- [ ] **Step 5: Delete** key with multi-selection → both elements get deleted (verify via the LayersPanel — they vanish).

- [ ] **Step 6: Escape** key with multi-selection → all selections clear.

---

## Chunk 3: Snap-to-edges with alignment guides (Figma core UX)

> **Why Chunk 3:** Snap is THE Figma feature that makes precise layout possible without pixel-peeping. Without it, users fight the canvas.

### Task 3.1: Snap math in DesignView (read-only)

**Files:**
- Modify: `src/apps/desktop/src/components/design/DesignView.vue` — add a `useSnapGuides` composable that computes which edges/centers of the dragged element's bbox align with edges/centers of other elements within a 6px threshold.

- [ ] **Step 1: Write the failing test**

Create `src/apps/desktop/src/components/design/__tests__/DesignView.snap.spec.ts`:

```ts
import { describe, expect, it } from 'vitest'
import { computeSnapDelta } from '../useSnapGuides'

describe('computeSnapDelta', () => {
  const elements = [
    { id: 'a', x: 100, y: 100, width: 200, height: 100 },
    { id: 'b', x: 400, y: 100, width: 100, height: 100 },
  ]

  it('snaps left edge to another element\'s left edge', () => {
    // Drag element A from (100, 100) to (105, 100) — within 6px of
    // its own start position. No snap target within 6px on left.
    const result = computeSnapDelta(elements, 'a', 5, 0)
    expect(result.dx).toBe(0)  // already aligned to start
    expect(result.guides).toEqual([])
  })

  it('snaps right edge of moving element to left edge of nearby element', () => {
    // Element A's right edge starts at x=300. Element B's left edge
    // is at x=400. To snap A's right edge onto B's left edge, dx = 100.
    const result = computeSnapDelta(elements, 'a', 105, 0)
    expect(result.dx).toBe(100)
    expect(result.guides).toContainEqual({ axis: 'x', position: 400 })
  })

  it('snaps center H of moving element to center H of nearby element', () => {
    // Element A's center H starts at x=200. Element B's center H is
    // at x=450. To align, dx = 250.
    const result = computeSnapDelta(elements, 'a', 252, 0)
    expect(result.dx).toBe(250)
    expect(result.guides).toContainEqual({ axis: 'x', position: 450 })
  })

  it('snaps to canvas center when no other element is nearby', () => {
    const elementsNoNearby = [
      { id: 'a', x: 100, y: 100, width: 200, height: 100 },
    ]
    const result = computeSnapDelta(elementsNoNearby, 'a', 0, 0, { width: 1440, height: 1024 })
    // Canvas center V is x=720. Element A's center V starts at x=200.
    // To snap onto canvas center V, dx = 520.
    expect(result.dx).toBe(520)
    expect(result.guides).toContainEqual({ axis: 'x', position: 720 })
  })

  it('returns no snap when moving element is far from all targets', () => {
    const result = computeSnapDelta(elements, 'a', 50, 50)
    expect(result.dx).toBe(50)
    expect(result.dy).toBe(50)
    expect(result.guides).toEqual([])
  })

  it('applies 6px threshold — snap fires only when within 6 design-px of target', () => {
    // Element A right edge starts at x=300. Element B left edge at x=400.
    // dx = 95 → A's right edge ends up at x=395 (5px from B's left).
    // dx = 89 → A's right edge at x=389 (11px from B's left). NO snap.
    const snap1 = computeSnapDelta(elements, 'a', 95, 0)
    expect(snap1.dx).toBe(100)  // snapped
    const snap2 = computeSnapDelta(elements, 'a', 89, 0)
    expect(snap2.dx).toBe(89)   // not snapped
  })
})
```

- [ ] **Step 2: Implement `useSnapGuides`** in a new file

Create `src/apps/desktop/src/components/design/useSnapGuides.ts`:

```ts
/**
 * Snap-to-edges math for design-mode drag.
 *
 * Algorithm:
 *   1. The dragged element's bbox at the cursor's current position.
 *   2. For every OTHER element on the page, compute the distance from
 *      each of the 4 edges + 2 centers of the dragged bbox to the
 *      matching edge/center of the target.
 *   3. The closest pair within 6 design-px wins. The dx/dy needed to
 *      align them is the snap delta.
 *   4. If the dragged bbox is not near any other element, fall back
 *      to canvas-center snapping (canvas H/V center as targets).
 *
 * Returns:
 *   - dx: design-px delta to ADD to the user's input dx
 *   - dy: same for y
 *   - guides: array of { axis, position } pairs to render as 1px lines
 *
 * Why a separate file: the math is pure (no DOM, no Vue) so it's
 * trivially testable in isolation. DesignView imports the function
 * and calls it on every pointermove.
 */

export interface Bbox { x: number; y: number; width: number; height: number }
export interface SnapGuide { axis: 'x' | 'y'; position: number }
export interface SnapResult {
  dx: number
  dy: number
  guides: SnapGuide[]
}

const SNAP_THRESHOLD = 6  // design-px

const EDGES_X = ['left', 'right', 'cx'] as const
const EDGES_Y = ['top', 'bottom', 'cy'] as const

function snapAxis(
  draggedValue: number,
  targets: number[],
  threshold: number,
): { snapped: number; guidePosition: number | null } {
  let bestDist = threshold
  let bestTarget = draggedValue
  let bestPos: number | null = null
  for (const t of targets) {
    const dist = Math.abs(draggedValue - t)
    if (dist < bestDist) {
      bestDist = dist
      bestTarget = t
      bestPos = t
    }
  }
  return { snapped: bestTarget, guidePosition: bestPos }
}

export function computeSnapDelta(
  elements: Bbox[],
  draggedId: string,
  rawDx: number,
  rawDy: number,
  canvasSize: { width: number; height: number } | null = null,
): SnapResult {
  const dragged = elements.find((e) => e.id === draggedId)
  if (!dragged) return { dx: rawDx, dy: rawDy, guides: [] }

  // The dragged bbox at the cursor's current position.
  const movedX = dragged.x + rawDx
  const movedY = dragged.y + rawDy
  const movedRight = movedX + dragged.width
  const movedBottom = movedY + dragged.height
  const movedCx = movedX + dragged.width / 2
  const movedCy = movedY + dragged.height / 2

  // Targets: every OTHER element's matching edge/center.
  const otherEdgesX: number[] = []
  const otherEdgesY: number[] = []
  for (const e of elements) {
    if (e.id === draggedId) continue
    otherEdgesX.push(e.x, e.x + e.width, e.x + e.width / 2)
    otherEdgesY.push(e.y, e.y + e.height, e.y + e.height / 2)
  }

  // Canvas-center fallback targets.
  if (canvasSize) {
    otherEdgesX.push(canvasSize.width / 2)
    otherEdgesY.push(canvasSize.height / 2)
    otherEdgesX.push(0, canvasSize.width)         // canvas edges
    otherEdgesY.push(0, canvasSize.height)
  }

  // Snap x: pick the closest matching edge among the moved bbox's
  // 3 x-values vs. the targets.
  const movedEdgesX = [movedX, movedRight, movedCx]
  const movedEdgesY = [movedY, movedBottom, movedCy]

  let bestSnapX = { dist: SNAP_THRESHOLD, correction: 0, position: 0 }
  let bestSnapY = { dist: SNAP_THRESHOLD, correction: 0, position: 0 }
  const guides: SnapGuide[] = []

  for (const movedEdgeX of movedEdgesX) {
    const target = otherEdgesX.find((t) => Math.abs(movedEdgeX - t) < bestSnapX.dist)
    if (target !== undefined) {
      bestSnapX = {
        dist: Math.abs(movedEdgeX - target),
        correction: target - movedEdgeX,
        position: target,
      }
    }
  }
  for (const movedEdgeY of movedEdgesY) {
    const target = otherEdgesY.find((t) => Math.abs(movedEdgeY - t) < bestSnapY.dist)
    if (target !== undefined) {
      bestSnapY = {
        dist: Math.abs(movedEdgeY - target),
        correction: target - movedEdgeY,
        position: target,
      }
    }
  }

  const finalDx = rawDx + bestSnapX.correction
  const finalDy = rawDy + bestSnapY.correction
  if (bestSnapX.dist < SNAP_THRESHOLD) {
    guides.push({ axis: 'x', position: bestSnapX.position })
  }
  if (bestSnapY.dist < SNAP_THRESHOLD) {
    guides.push({ axis: 'y', position: bestSnapY.position })
  }

  return { dx: finalDx, dy: finalDy, guides }
}
```

- [ ] **Step 3: Run the tests**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run components/design/__tests__/DesignView.snap.spec.ts 2>&1 | tail -n 20`
Expected: 6 tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/components/design/useSnapGuides.ts \
        src/apps/desktop/src/components/design/__tests__/DesignView.snap.spec.ts
git commit -m "feat(design): snap-to-edges math (6px threshold, canvas-center fallback)"
```

### Task 3.2: Apply snap to the drag stream

**Files:**
- Modify: `src/apps/desktop/src/components/design/DesignView.vue` — wrap the `groupDrag` handler so the dx/dy is snap-corrected before being applied. The selected bbox is the union of all selected elements' bboxes.

- [ ] **Step 1: Add `snapGuides: SnapGuide[]` state to DesignView**

```ts
const snapGuides = ref<SnapGuide[]>([])
```

- [ ] **Step 2: Modify `handleGroupDrag`** to apply snap

```ts
const handleGroupDrag = (rawDx: number, rawDy: number): void => {
  if (selectedIds.value.size === 0) return
  // Compute the union bbox of the selection (at the cursor's current
  // proposed position). The snap function operates on this union bbox.
  const selected = elements.value.filter((e) => selectedIds.value.has(e.id))
  const unionBbox = selected.reduce(
    (acc, el) => ({
      x: Math.min(acc.x, el.x + rawDx),
      y: Math.min(acc.y, el.y + rawDy),
      width: Math.max(acc.x + acc.width, el.x + rawDx + el.width) - Math.min(acc.x, el.x + rawDx),
      height: Math.max(acc.y + acc.height, el.y + rawDy + el.height) - Math.min(acc.y, el.y + rawDy),
    }),
    { x: Infinity, y: Infinity, width: 0, height: 0 },
  )
  // Synthetic id 'union' so computeSnapDelta treats it as one moving
  // bbox. The other elements list excludes the union id.
  const unionElement = { id: 'union', ...unionBbox }
  const snapResult = computeSnapDelta(
    [unionElement, ...elements.value.filter((e) => !selectedIds.value.has(e.id))],
    'union',
    0,  // rawDx/Dy are baked into the bbox above
    0,
    { width: canvasWidth.value, height: canvasHeight.value },
  )
  // snapResult.dx is the correction to apply on top of rawDx.
  const finalDx = rawDx + snapResult.dx
  const finalDy = rawDy + snapResult.dy
  snapGuides.value = snapResult.guides

  // Apply the snapped delta to every selected element.
  for (const el of selected) {
    void workspacesStore.updateDesignElementGeometry(
      props.workspaceId,
      effectiveItemId.value,
      activePageId.value,
      el.id,
      {
        x: Math.round(el.x + finalDx),
        y: Math.round(el.y + finalDy),
      },
    )
  }
}
```

- [ ] **Step 3: Clear snap guides on pointerup**

Modify the existing pointerup path (currently in DesignElement) to also clear the guides via an emit. The cleanest way is to add a `dragEnd` emit from DesignElement and listen for it in DesignView.

In DesignElement.vue, after the `onUp` handler, before the cleanup:
```ts
emit('dragEnd')
```

In DesignView.vue's `<DesignElement>` invocation:
```vue
@drag-end="snapGuides = []"
```

- [ ] **Step 4: Render the guides**

Add to the canvas div (around line 1044 in DesignView.vue, the `mx-auto my-6` div):

```vue
<svg
  v-if="snapGuides.length > 0"
  class="absolute inset-0 pointer-events-none"
  :width="canvasWidth"
  :height="canvasHeight"
  data-testid="design-snap-guides"
>
  <line
    v-for="(guide, idx) in snapGuides.filter(g => g.axis === 'x')"
    :key="`x-${idx}`"
    :x1="guide.position" :y1="0"
    :x2="guide.position" :y2="canvasHeight"
    stroke="var(--color-violet)"
    stroke-width="1"
  />
  <line
    v-for="(guide, idx) in snapGuides.filter(g => g.axis === 'y')"
    :key="`y-${idx}`"
    :x1="0" :y1="guide.position"
    :x2="canvasWidth" :y2="guide.position"
    stroke="var(--color-violet)"
    stroke-width="1"
  />
</svg>
```

- [ ] **Step 5: Build + run all tests**

Run: `cd src/apps/desktop && timeout 60 bun run build 2>&1 | tail -n 5`
Run: `cd src/apps/desktop && timeout 120 bunx vitest run components/design/__tests__/ 2>&1 | tail -n 10`
Expected: both clean.

- [ ] **Step 6: Commit**

```bash
git add src/apps/desktop/src/components/design/DesignView.vue \
        src/apps/desktop/src/components/design/DesignElement.vue
git commit -m "feat(design): apply snap during drag + render 1px alignment guides"
```

### Task 3.3: Manual smoke test for snap

- [ ] **Step 1: Build + open** the desktop app.

- [ ] **Step 2: Add 2-3 elements** on the canvas at varied positions.

- [ ] **Step 3: Drag** an element near another element's left edge (within 6px). The element should SNAP to align with the target. A violet vertical line should appear spanning the canvas at the snap position.

- [ ] **Step 4: Drag** an element near the canvas's vertical centerline (within 6px). The element should snap to center. A violet vertical line should appear at canvas center.

- [ ] **Step 5: Drag** an element far from any target. No snap, no guide.

- [ ] **Step 6: Multi-select** two elements and drag them near a third. Both should snap together as a group.

---

## Chunk 4: Keyboard nudge (Figma core UX)

> **Why Chunk 4:** keyboard nudge is the cheapest Figma feature and unlocks sub-pixel precision.

### Task 4.1: Arrow keys + Shift modifier

**Files:**
- Modify: `src/apps/desktop/src/components/design/DesignView.vue` — extend the existing `handleKeydown` to nudge the selection by 1px (or 10px with Shift) on arrow keys.

- [ ] **Step 1: Write the failing test**

Append to `DesignView.dragWiring.spec.ts`:

```ts
it('arrow key nudges selection by 1 design-px', async () => {
  const wrapper = mount(DesignView, {
    props: {
      item: {
        ...makeItem(),
        design_elements: [
          { ...ELEMENT_API, id: 'el_1', x: 100, y: 100 },
        ],
      },
      workspaceId: WS_ID, itemId: ITEM_ID,
    },
  })
  await flushPromises()
  // Select the element by clicking it.
  const element = wrapper.find('[data-design-element]')
  await element.trigger('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100 })
  await flushPromises()
  // Arrow right
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }))
  // Element should have moved +1px on x (assert via emitted update
  // events; the store is mocked so we just check the call).
  const calls = updateDesignElementGeometrySpy.mock.calls
  expect(calls.some((c: any[]) => c[4]?.x === 101)).toBe(true)
})

it('Shift+arrow nudges by 10 design-px', async () => {
  // Same setup, but ArrowRight with shiftKey: true.
  // Expect x=110.
})

it('arrow keys are no-op when nothing is selected', async () => {
  // Mount with no selection; press arrow; assert no emit.
})
```

- [ ] **Step 2: Implement the keyboard nudge**

In DesignView.vue's `handleKeydown`, AFTER the existing Space / Escape / Cmd+P / F / Shift+1 branches, add:

```ts
// Arrow keys nudge the selection by 1 design-px; Shift+arrow by 10.
// Gated on `selectedIds.size > 0` (Figma-style: arrows do nothing
// when there's nothing to nudge).
if (selectedIds.value.size > 0 && (
  event.key === 'ArrowLeft' || event.key === 'ArrowRight' ||
  event.key === 'ArrowUp' || event.key === 'ArrowDown'
)) {
  event.preventDefault()
  const step = event.shiftKey ? 10 : 1
  const dx =
    event.key === 'ArrowLeft' ? -step :
    event.key === 'ArrowRight' ? step : 0
  const dy =
    event.key === 'ArrowUp' ? -step :
    event.key === 'ArrowDown' ? step : 0
  for (const id of selectedIds.value) {
    const el = elements.value.find((e) => e.id === id)
    if (!el) continue
    void workspacesStore.updateDesignElementGeometry(
      props.workspaceId,
      effectiveItemId.value,
      activePageId.value,
      id,
      { x: el.x + dx, y: el.y + dy },
    )
  }
  return
}
```

- [ ] **Step 3: Run tests + build**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run components/design/__tests__/DesignView.dragWiring.spec.ts 2>&1 | tail -n 10`
Expected: green.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/components/design/DesignView.vue \
        src/apps/desktop/src/components/design/__tests__/DesignView.dragWiring.spec.ts
git commit -m "feat(design): keyboard nudge — arrow keys = 1px, Shift+arrow = 10px"
```

### Task 4.2: Manual smoke test for keyboard nudge

- [ ] **Step 1: Select an element** → click it.

- [ ] **Step 2: Press →** → element moves +1px right. Hold for repeat (browser auto-repeat at OS rate).

- [ ] **Step 3: Press Shift+→** → element moves +10px right.

- [ ] **Step 4: Select 3 elements** → press ↑ → all 3 move up 1px together.

- [ ] **Step 5: Focus an input** (e.g. PropertiesPanel X input) → arrow keys move the input cursor, not the canvas element.

---

## Chunk 5: Constrain-to-canvas + safety net

> **Why Chunk 5:** prevent users from dragging elements off-canvas where they're invisible / unsaveable. This is the "polish" chunk.

### Task 5.1: Constrain drag to canvas bounds

**Files:**
- Modify: `src/apps/desktop/src/components/design/DesignView.vue` — in the `handleGroupDrag` (and the single-element drag path through DesignElement), clamp the final dx/dy so no element ends up entirely outside the canvas. (Partial-off-canvas is OK; entirely-off-canvas is not.)

- [ ] **Step 1: Write the failing test**

Append to `DesignView.dragWiring.spec.ts`:

```ts
it('drag that would move element entirely off-canvas is clamped', async () => {
  // Element at x=10 (very close to left edge). Drag -1000px → would
  // put x=-990 (entirely off-canvas). Expect clamp to x=0.
})
```

- [ ] **Step 2: Implement the clamp**

```ts
const clampToCanvas = (el: DesignElementApi, dx: number, dy: number): { x: number; y: number } => {
  const newX = el.x + dx
  const newY = el.y + dy
  return {
    x: Math.max(-el.width + 10, Math.min(canvasWidth.value - 10, newX)),
    y: Math.max(-el.height + 10, Math.min(canvasHeight.value - 10, newY)),
  }
}
```

Apply inside `handleGroupDrag` and pass to DesignElement as a `constrainToCanvas` prop.

- [ ] **Step 3: Run + build + commit**

```bash
git add src/apps/desktop/src/components/design/DesignView.vue \
        src/apps/desktop/src/components/design/__tests__/DesignView.dragWiring.spec.ts
git commit -m "feat(design): clamp drag to canvas bounds (prevent invisible off-canvas elements)"
```

### Task 5.2: End-to-end manual smoke test + handoff

- [ ] **Step 1: Build the desktop binary**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
rm -rf zig-out/bin
timeout 360 zig build nalar-desktop 2>&1 | tail -n 5
```

- [ ] **Step 2: Full manual smoke test** covering all 5 chunks:

1. **Chunk 1**: drag works (basic move).
2. **Chunk 2**: Shift+click multi-select; group drag; multi-delete.
3. **Chunk 3**: snap fires near other elements / canvas edges; alignment guides render.
4. **Chunk 4**: arrow keys nudge; Shift+arrow = 10px.
5. **Chunk 5**: drag that goes off-canvas clamps.

- [ ] **Step 3: Document** the new UX in NALAR.md and the design plan file:

Append to `/home/ginwa/agentic_coding_zig/ginwaaitoolbox/NALAR.md`:

```markdown
## 2026-07-25: Design mode element drag-and-drop (Figma-style)

Plan: docs/superpowers/plans/2026-07-25-design-element-drag-and-drop.md

### What landed
- **Drag-to-move works** (was a TODO no-op in AppLayout.handleDesignUpdateElement).
- **Multi-select** via Shift+click; group drag; multi-delete with one Delete key.
- **Snap-to-edges** with 1px violet alignment guides (6px threshold; canvas-center fallback).
- **Keyboard nudge** — arrow keys = 1px, Shift+arrow = 10px.
- **Constrain-to-canvas** — drag that would push an element entirely off-canvas clamps.

### What was deferred
- Marquee drag-select (draw a rectangle to select everything inside). Lower priority — Shift+click is enough for the common 1-5-element case.
- Smart-spacing/distribute-horizontal/vertical (would need a server endpoint for batch geometry updates; the existing `PATCH /geometry` endpoint already handles 1-element-at-a-time fast).
- Snap-to-grid (Figma toggle; can be added once snap-to-edges is comfortable).
- Drag-from-layers-panel to canvas (next plan if requested).
```

- [ ] **Step 4: Move the kanban task to "done"**

```bash
# Use the kanban_move_task tool with:
# workspace_id: ws_1779002584293_e52cd134532e1f00
# item_id: item_1783240301811922624
# task_id: task_1784914060242
# target_column_id: col_3c48fb9ad67f0000 (done)
```

---

## Reviewer Notes

### Why these chunks?

- **Chunk 1** is the bug fix. Without it, NOTHING else works. The user can select elements (which is why the violet outline + resize handles show) but the move never reaches the backend. This chunk delivers the MVP.
- **Chunk 2** (multi-select) is the foundation of every other Figma feature. Without it, alignment/distribute/lock/hide all need separate selection models.
- **Chunk 3** (snap) is the precision-UX feature. Without it, the canvas feels "loose" and users fight pixel-precise placement.
- **Chunk 4** (keyboard nudge) is the cheapest Figma feature. ~30 lines, no new state, just an arrow-key handler in the existing `handleKeydown`.
- **Chunk 5** (constrain) is polish. Prevents the user from accidentally dragging elements off-canvas where they become invisible.

### Out-of-scope (explicitly NOT in this plan)

- **Marquee drag-select** — defer to a future plan. Requires drawing an SVG rectangle on the canvas during drag and detecting which elements intersect it.
- **Smart-spacing/distribute** — defer. Backend already supports batch updates via the geometry endpoint; the UI just needs the buttons.
- **Snap-to-grid** — defer. Figma has a toggle for this. Add when the user requests it.
- **Drag-from-layers-panel** — defer. The LayersPanel already supports click-to-select and ▲▼ to reorder. Adding drag-to-reorder is a separate feature.
- **Lock/hide** — defer. Requires new element fields (`is_locked`, `is_hidden`) and a server-side migration.
- **Group containers** (`frame` / `group` element types) — already exist on the backend (per the prior `design-mode-redesign` plan) but the UI doesn't yet support dragging elements INTO a frame. Out of scope.

### Project conventions applied

- **TDD**: every task writes a failing test first, then implements, then re-runs the test. The Vue + Bun + Vitest setup is already established (`bunx vitest run` works out of the box).
- **Bun build as type-check**: after each chunk, `cd src/apps/desktop && timeout 60 bun run build` catches the TS errors that `bunx vitest run` misses (per project memory `desktop-typescript-bun-build-as-typecheck`).
- **Static contract tests**: the existing `DesignElement.spec.ts` and `DesignView.spec.ts` use source-grep assertions. New contracts (e.g. `groupDrag` emit, `selectedIds` prop) are added there.
- **Composable extraction for testability**: `useDesignHandlers` is extracted as a composable so the AppLayout wiring can be tested without mounting the whole SFC. Mirrors the pattern used by `useSnapGuides`.
- **Worktree workflow**: this plan should be executed in `.worktrees/design-element-drag-and-drop` (branch `worktree/design-element-drag-and-drop`) so the working tree stays clean. The build verification in Chunk 5 uses `rm -rf zig-out/bin` first to avoid the cached-binary bug.

### Order of execution

Each chunk builds on the previous one. The review loop should consider:

1. **Chunk 1 review**: Does the drag actually move an element on the live desktop app? (Smoke test in Task 1.5 is the source of truth.)
2. **Chunk 2 review**: Does Shift+click multi-select work? Does the group drag track the cursor on both elements together?
3. **Chunk 3 review**: Do the alignment guides render at the right positions? Does snap fire within 6px and not beyond?
4. **Chunk 4 review**: Does arrow nudge work for both single and multi-selection? Does the input-focus guard prevent stealing arrow keys from the PropertiesPanel?
5. **Chunk 5 review**: Does the clamp prevent invisible off-canvas elements while still allowing partial overlap?

---

## Plan metadata

- **Created**: 2026-07-25
- **Author**: AI agent (writing-plans skill)
- **Skill used**: writing-plans
- **Estimated LoC**: ~480 production + ~520 tests
- **Estimated chunks**: 5 (each independently testable)
- **Breaking changes**: None (the existing `selectedElementId: string | null` prop is replaced by `selectedIds: string[]`, but the new prop name communicates multi-select intent; tests that asserted `selected: true` will need to change to `selectedIds: ['el_1']`).
- **Backend changes**: None (the `updateDesignElementGeometry` endpoint already exists from PR #120 and was designed for 60+/sec drag traffic).
- **Frontend-only**: Yes — no Zig, no DB migration, no MCP changes.

### What landed
- **Drag-to-move works** (was a TODO no-op in App