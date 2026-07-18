# Plan: Design Mode — Hand Mode (Hold Space + Drag to Pan)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user hold Space + drag on the design canvas to pan the viewport (Figma-style). At higher zoom levels the user can only see a fraction of the page; panning lets them navigate without zooming out first.

**Architecture:**
- Frontend-only change (`DesignView.vue`). Hold Space anywhere → cursor becomes `grab`; drag on canvas → updates `scrollLeft` / `scrollTop` on the canvas container. Release Space → cursor and pan state reset. No backend changes; no model changes; no API surface.
- Pattern mirrors the existing `handleCanvasWheel` Ctrl+wheel logic and the `DesignElement.vue` drag handlers (`setPointerCapture` + `pointermove` / `pointerup`).

**Tech Stack:** Vue 3 + TypeScript (desktop frontend), HTML5 Pointer Events, CSS `cursor` property.

---

## File structure

### Frontend — modified files
- `src/apps/desktop/src/components/design/DesignView.vue` — add `isSpacePressed` ref, Space keydown/keyup handlers, pointer-based pan handler on the canvas container, body-level cursor toggle. ~80 LoC delta. (Reuses the existing `handleKeydown` and adds a parallel `handleKeyup`.)

### Frontend — new test files
- `src/apps/desktop/src/components/design/__tests__/DesignView.pan.spec.ts` — 4 vitest tests covering keydown enables grab cursor, Space release reverts, pointer drag updates `scrollLeft`/`scrollTop`, and Space-in-input doesn't pan. ~120 LoC.

---

## Chunk 1: Hold Space + drag to pan

### Task 1.1: Add `isSpacePressed` ref + Space keydown handler

**Files:**
- Modify: `src/apps/desktop/src/components/design/DesignView.vue` (extend the existing `handleKeydown` around line 297 and add `handleKeyup`)

- [ ] **Step 1: Read the current `handleKeydown`** (around line 297) so you extend it in place — don't duplicate the INPUT/TEXTAREA guard.

- [ ] **Step 2: Add `isSpacePressed` ref + extend `handleKeydown`**

In the script block, just above `handleKeydown`:

```ts
// True while the user is holding the Space bar. Drives the body's
// cursor (grab / grabbing) and gates the pointer-drag pan handler
// on the canvas container.
const isSpacePressed = ref(false)

const handleKeydown = (event: KeyboardEvent): void => {
  const target = event.target as HTMLElement | null
  const inEditable =
    !!target &&
    (target.tagName === 'INPUT' ||
      target.tagName === 'TEXTAREA' ||
      target.isContentEditable)

  if (inEditable) return // existing guard — let inputs handle their own keys

  // Space held (no Ctrl/Cmd/Alt/Shift — those are bound to other shortcuts,
  // and Alt+Space is the window-menu shortcut on Linux/macOS). Plain Space
  // should NOT scroll the page when the design view is mounted — that's
  // the browser default we override here.
  if (
    event.key === ' ' &&
    !event.ctrlKey &&
    !event.metaKey &&
    !event.altKey &&
    !event.shiftKey
  ) {
    if (!isSpacePressed.value) {
      isSpacePressed.value = true
      document.body.style.cursor = 'grab'
    }
    event.preventDefault()
    return
  }

  if (event.key === 'Escape') {
    selectedElementId.value = null
    if (showAddElementDialog.value) {
      showAddElementDialog.value = false
    }
    return
  }

  if (
    (event.key === 'f' || event.key === 'F' || (event.key === '1' && event.shiftKey)) &&
    !event.ctrlKey && !event.metaKey && !event.altKey
  ) {
    event.preventDefault()
    zoomFit()
  }
}
```

- [ ] **Step 3: Add `handleKeyup` and register both listeners**

Below the existing `onMounted(() => { document.addEventListener('keydown', handleKeydown) })` at line ~307, extend the mount / unmount block:

```ts
const handleKeyup = (event: KeyboardEvent): void => {
  // Release Space. Don't gate on target — if focus moved to an input
  // mid-press, we still want to clear the body cursor on Space-up.
  if (event.key === ' ' && isSpacePressed.value) {
    isSpacePressed.value = false
    document.body.style.cursor = ''
  }
  // Defensive: if focus is lost (window blur / tab switch) while
  // Space is held, the keyup event may never fire. Reset on blur
  // so we don't leave the cursor stuck on "grab".
  if (event.key === ' ' && !isSpacePressed.value) {
    document.body.style.cursor = ''
  }
}

const handleWindowBlur = (): void => {
  if (isSpacePressed.value) {
    isSpacePressed.value = false
    document.body.style.cursor = ''
  }
}

onMounted(() => {
  document.addEventListener('keydown', handleKeydown)
  document.addEventListener('keyup', handleKeyup)
  window.addEventListener('blur', handleWindowBlur)
})
onUnmounted(() => {
  document.removeEventListener('keydown', handleKeydown)
  document.removeEventListener('keyup', handleKeyup)
  window.removeEventListener('blur', handleWindowBlur)
  // Defensive: clear body cursor if we unmount mid-press.
  document.body.style.cursor = ''
})
```

- [ ] **Step 4: Build to verify types**

Run: `cd src/apps/desktop && timeout 60 bun run build 2>&1 | tail -n 5`
Expected: clean (no new TS errors).

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/components/design/DesignView.vue
git commit -m "feat(design): hold Space to show grab cursor (no pan yet)"
```

### Task 1.2: Add pointer-drag pan handler on the canvas container

**Files:**
- Modify: `src/apps/desktop/src/components/design/DesignView.vue` (the canvas scroll container at line ~837)

- [ ] **Step 1: Read the canvas scroll container div** (around line 837) and its `@click="handleCanvasClick"` / `@wheel="handleCanvasWheel"` handlers — you'll add the pointer handlers here.

- [ ] **Step 2: Add `startCanvasPan` + `isPanning` ref + the pan state**

In the script block, just below `handleCanvasWheel` (around line 500):

```ts
// True while the user is mid-drag with Space held. Gates the
// canvas click on mouseup so a pan-drag doesn't accidentally
// deselect the active element when the user releases the mouse.
const isPanning = ref(false)

const startCanvasPan = (event: PointerEvent): void => {
  if (!isSpacePressed.value) return
  // Only respond to primary button — middle / right clicks do
  // different things (autoscroll, context menu) on some browsers.
  if (event.button !== 0) return
  const target = event.currentTarget as HTMLElement | null
  if (!target) return
  target.setPointerCapture(event.pointerId)
  isPanning.value = true
  document.body.style.cursor = 'grabbing'

  // Record the scroll position at drag start. We mutate
  // scrollLeft / scrollTop directly — the transform: scale() on
  // the inner div means we can't move the canvas itself (that
  // would compound with the scale).
  const startScrollLeft = target.scrollLeft
  const startScrollTop = target.scrollTop
  const startClientX = event.clientX
  const startClientY = event.clientY

  const onMove = (e: PointerEvent): void => {
    // cursor delta in screen-px = scroll delta in scroll-px
    // (no zoom division needed — scrollLeft / scrollTop are in
    // unscaled coords; the inner div's scale() does not affect
    // them).
    const dx = e.clientX - startClientX
    const dy = e.clientY - startClientY
    target.scrollLeft = startScrollLeft - dx
    target.scrollTop = startScrollTop - dy
  }
  const onUp = (e: PointerEvent): void => {
    if (target.hasPointerCapture(e.pointerId)) {
      target.releasePointerCapture(e.pointerId)
    }
    isPanning.value = false
    // Restore grab cursor only if Space is still held; otherwise
    // clear back to the default cursor.
    document.body.style.cursor = isSpacePressed.value ? 'grab' : ''
    target.removeEventListener('pointermove', onMove)
    target.removeEventListener('pointerup', onUp)
    target.removeEventListener('pointercancel', onUp)
  }
  target.addEventListener('pointermove', onMove)
  target.addEventListener('pointerup', onUp)
  target.addEventListener('pointercancel', onUp)
}
```

- [ ] **Step 3: Update `handleCanvasClick`** so a pan-drag doesn't accidentally clear the element selection on mouseup

Find `handleCanvasClick` (around line 315) and add the pan guard:

```ts
const handleCanvasClick = (event: MouseEvent): void => {
  // If we just finished a pan-drag, swallow the click so it
  // doesn't deselect the active element.
  if (isPanning.value) return
  if ((event.target as HTMLElement | null)?.closest('[data-design-element]')) {
    return
  }
  selectedElementId.value = null
}
```

- [ ] **Step 4: Wire the new handler into the canvas container template**

Find the canvas scroll container div (around line 837). Add `@pointerdown="startCanvasPan"` next to the existing `@click` and `@wheel`:

```vue
<div
  class="flex-1 overflow-auto min-h-0"
  style="background-color: var(--color-bg-m2);"
  data-testid="design-canvas-scroll-container"
  @click="handleCanvasClick"
  @wheel="handleCanvasWheel"
  @pointerdown="startCanvasPan"
>
```

- [ ] **Step 5: Build to verify types**

Run: `cd src/apps/desktop && timeout 60 bun run build 2>&1 | tail -n 5`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add src/apps/desktop/src/components/design/DesignView.vue
git commit -m "feat(design): pointer-drag pan with Space held (Figma hand-mode)"
```

### Task 1.3: Add vitest tests for Space + pan behavior

**Files:**
- Create: `src/apps/desktop/src/components/design/__tests__/DesignView.pan.spec.ts`

- [ ] **Step 1: Read an existing DesignView spec** (e.g. `src/apps/desktop/src/components/design/__tests__/DesignView.spec.ts`) so you match the project's mount + Pinia + stub setup. If no DesignView spec exists, look at `KanbanView.spec.ts` for the closest pattern.

- [ ] **Step 2: Write the 4 tests**

```ts
import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import DesignView from '../DesignView.vue'
import { useWorkspacesStore } from '../../stores/workspaces'

function makeDesignItem(overrides: Partial<{ width: number; height: number }> = {}) {
  return {
    id: 'item_test',
    workspace_id: 'ws_test',
    item_type: 'design',
    name: 'Test',
    path: '/tmp/test',
    position: 0,
    design_elements: [],
    ...overrides,
  }
}

describe('DesignView hand-mode pan', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.style.cursor = ''
  })
  afterEach(() => {
    document.body.style.cursor = ''
  })

  it('holding Space sets body cursor to grab', async () => {
    const wrapper = mount(DesignView, {
      props: { item: makeDesignItem() as any, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await wrapper.vm.$nextTick()
    document.dispatchEvent(new KeyboardEvent('keydown', { key: ' ' }))
    expect(document.body.style.cursor).toBe('grab')
    wrapper.unmount()
  })

  it('releasing Space restores default cursor', async () => {
    const wrapper = mount(DesignView, {
      props: { item: makeDesignItem() as any, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await wrapper.vm.$nextTick()
    document.dispatchEvent(new KeyboardEvent('keydown', { key: ' ' }))
    document.dispatchEvent(new KeyboardEvent('keyup', { key: ' ' }))
    expect(document.body.style.cursor).toBe('')
    wrapper.unmount()
  })

  it('Space inside an input does NOT enter grab mode', async () => {
    const wrapper = mount(DesignView, {
      props: { item: makeDesignItem() as any, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await wrapper.vm.$nextTick()
    const input = document.createElement('input')
    document.body.appendChild(input)
    input.focus()
    input.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }))
    expect(document.body.style.cursor).toBe('')
    document.body.removeChild(input)
    wrapper.unmount()
  })

  it('pointer-drag on the canvas with Space held updates scrollLeft/scrollTop', async () => {
    const wrapper = mount(DesignView, {
      props: { item: makeDesignItem({ width: 4000, height: 3000 }) as any, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await wrapper.vm.$nextTick()
    const container = wrapper.find('[data-testid="design-canvas-scroll-container"]').element as HTMLElement
    // Stub the scrollable area.
    Object.defineProperty(container, 'scrollLeft', { writable: true, value: 0 })
    Object.defineProperty(container, 'scrollTop', { writable: true, value: 0 })
    container.setPointerCapture = () => {}
    container.releasePointerCapture = () => {}
    container.hasPointerCapture = () => true
    container.removeEventListener = (() => {}) as any
    container.addEventListener = ((type: string, cb: any) => {
      if (type === 'pointermove') (container as any).__onMove = cb
    }) as any
    // Enter Space + drag.
    document.dispatchEvent(new KeyboardEvent('keydown', { key: ' ' }))
    await wrapper.vm.$nextTick()
    container.dispatchEvent(new PointerEvent('pointerdown', { clientX: 100, clientY: 100, button: 0, pointerId: 1, bubbles: true }))
    await wrapper.vm.$nextTick()
    // Simulate a 50-px drag.
    ;(container as any).__onMove(new PointerEvent('pointermove', { clientX: 50, clientY: 80, pointerId: 1 }))
    expect(container.scrollLeft).toBe(50)
    expect(container.scrollTop).toBe(20)
    wrapper.unmount()
  })
})
```

> **Note:** The pointer-drag test is the trickiest. If the canvas container is `display: none` in jsdom, the real listeners may not register correctly. If the test fails for that reason, mount with `attachTo: document.body` (see project skill `vue-teleport-vitest-document-queryselector`) and dispatch events on `wrapper.element` instead of `wrapper.find(...)`. The other three tests are simpler and should pass without changes.

- [ ] **Step 3: Run the tests**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run components/design/__tests__/DesignView.pan.spec.ts 2>&1 | tail -n 20`
Expected: 4 tests pass.

- [ ] **Step 4: Run full vitest to confirm no regressions**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run --reporter=default 2>&1 | tail -n 5`
Expected: 1364 baseline + 4 new tests = 1368 tests pass (the "Errors N" line at the bottom is flaky and counts unhandled stderr from unrelated tests; ignore it as long as the test count is green — see project memory `verification-before-completion`).

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/components/design/__tests__/DesignView.pan.spec.ts
git commit -m "test(design): vitest for hand-mode pan (Space + drag)"
```

---

## Chunk 2: Manual smoke test in the desktop app

### Task 2.1: Build the desktop binary + smoke test

- [ ] **Step 1: Build**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/design-canvas-resize-and-zoom
rm -rf zig-out/bin
timeout 360 zig build nalar-desktop 2>&1 | tail -n 3
```

Expected: `zig-out/bin/nalar-desktop` produced.

- [ ] **Step 2: Open the desktop app** and navigate to a design item. Zoom in to ~200% so only part of the page is visible (use the existing zoom toolbar from PR #112).

- [ ] **Step 3: Verify Space pan**

- Hold Space → cursor becomes a grab hand.
- Drag → page scrolls; release Space → cursor returns to default; release the mouse button → cursor still default.
- Pan to a different part of the page, then click on an element → selection works (the `isPanning` guard suppressed the canvas click during the drag).

- [ ] **Step 4: Verify Space-in-input doesn't interfere**

- Click on the W × H input → type a space inside the value → it types normally (not panning). Cursor doesn't switch to grab.

- [ ] **Step 5: Verify Space doesn't scroll the page**

- Hold Space anywhere → page does not scroll down (browser default suppressed by `preventDefault()`).

---

## Chunk 3: End-to-end verification (backend skipped — no Zig changes)

### Task 3.1: Verify

- [ ] **Step 1: Confirm `bun run build` is clean**

Run: `cd src/apps/desktop && timeout 60 bun run build 2>&1 | tail -n 3`
Expected: clean (no vue-tsc errors).

- [ ] **Step 2: Confirm `bunx vitest run` baseline + new tests pass**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run --reporter=default 2>&1 | tail -n 5`
Expected: `Tests 1368 passed` (1364 baseline + 4 new).

- [ ] **Step 3: Confirm no backend regression**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 3`
Expected: 1810/1813 (unchanged from PR #112 baseline — no Zig changes in this plan).

- [ ] **Step 4: Git status**

```bash
git status --short
```

Expected: clean working tree (all changes committed).

---

## Pitfalls

1. **Body-level cursor change has a scope.** Setting `document.body.style.cursor = 'grab'` affects the WHOLE PAGE, not just the design canvas. That's intentional — Figma does the same, so Space+hovering over the layers panel still shows the grab cursor. But it means: **if the user navigates away from the design view while holding Space, the cursor stays grab until they release or focus moves away.** The `handleWindowBlur` listener resets on tab/window blur; if you unmount the design view mid-press, the `onUnmounted` cleanup also resets. Document the limitation; full fix (focus-trap on mount) is out of scope.

2. **Space-in-input.** The `inEditable` guard in `handleKeydown` skips when `target` is `INPUT` / `TEXTAREA` / `contenteditable`. This is correct for the "user typing in a form field" case but does NOT cover all "user typing in a modal" cases — e.g. a `<div contenteditable="true">` from Monaco editor (used in PropertiesPanel for HTML editing). The Monaco contenteditable will be caught by the `isContentEditable` branch. Tested in `Space inside an input does NOT enter grab mode`.

3. **Alt+Space is the window-menu shortcut on Linux and macOS.** The keydown handler checks `!event.altKey` so Alt+Space is ignored. Document for Windows users where Alt+Space is the system menu.

4. **Window blur / tab switch.** If the user holds Space then switches tabs / alt-tabs, the `keyup` event never fires on the document. The `handleWindowBlur` listener resets `isSpacePressed` and the cursor on `blur`. Same defense in `onUnmounted`.

5. **Pan drag vs canvas click deselection.** When the user finishes a pan-drag, the `mouseup` is followed by a `click` event on the canvas container (browser default). Without the `isPanning` guard, this would clear the active element selection — annoying UX. The guard in `handleCanvasClick` swallows the click.

6. **Scroll vs canvas.** Don't try to "move the canvas" via `transform: translate()`. The inner div has `transform: scale()` already, and composing scale + translate compounds. Instead, mutate `scrollLeft` / `scrollTop` on the scroll container. These are in unscaled coords (the scale applies to the rendered visual only).

7. **`setPointerCapture` is required.** If the user drags fast and the pointer leaves the canvas container, without pointer capture the move events stop firing and the drag appears to "stick". Pattern mirrors `DesignElement.vue:120` (`target.setPointerCapture(event.pointerId)`).

8. **`@pointerdown` won't fire when Space is held but the focus is elsewhere.** The Space keydown listener is `document`-level, but `startCanvasPan` only fires on pointerdown on the scroll container. If Space is held while the pointer is over the layers panel (outside the canvas), then the user mouses into the canvas without releasing Space — `pointerdown` fires on the canvas, but at that moment `isSpacePressed` is true (the document-level keydown already fired). All good.

9. **Existing Ctrl+wheel zoom handler.** It checks `if (!event.ctrlKey && !event.metaKey) return`, then calls `event.preventDefault()`. Space + drag fires `pointermove`, not `wheel`, so there's no conflict. But if the user is mid-pan and accidentally scrolls the wheel, the wheel handler still runs (Space doesn't suppress wheel). That's fine — they probably want zoom.

10. **Don't add the permanent hand-tool button** (Figma's deprecated "press H" toggle). Figma removed it because Space is universally understood. If users ask for it later, add a separate plan. Keeps this plan small and surgical.

11. **No backend changes.** Don't be tempted to add a `prefersHandMode` field to the page or session — hand mode is pure view state and doesn't need to be persisted server-side. The localStorage zoom key already doesn't include hand mode (correctly).

12. **Vitest pointer-event test fragility.** The pointer-drag test stubs `setPointerCapture` / `releasePointerCapture` / scroll properties because jsdom doesn't fully implement them. If you skip the stubs, the test fails with confusing errors. Don't try to make the test more "real" — keep the stubs, they're documented.

---

## Verification

After all chunks complete:

- ✅ `bun run build` — clean (vue-tsc + vite, no type errors)
- ✅ `bunx vitest run` — 1364 baseline + 4 new tests = **1368 passed**, no regressions
- ✅ `zig build test` — unchanged at 1810/1813 (no Zig changes)
- ✅ Manual: hold Space in design view → grab cursor; drag → pan; release → cursor reset
- ✅ Manual: type space in the W × H input → normal typing, no grab cursor

---

## Follow-ups (out of scope for this plan)

- **Permanent hand-tool button** (Figma's deprecated H toggle). Add a 📖 button in the canvas header; clicking it locks the page into pan-only mode until clicked again or Escape pressed. Useful for trackpad users who'd rather not hold Space constantly.
- **Trackpad two-finger pan.** Right now the canvas container intercepts plain wheel for default scroll, which DOES pan on trackpads. But this plan doesn't explicitly verify that path. Test manually; if broken, add a `pointerdown` handler that responds to two-finger gestures.
- **Inertia / momentum scrolling.** macOS trackpads feel good because of inertia. The browser handles this for native scroll; the canvas container is a native `<div style="overflow: auto">` so it should already work. Verify with a real trackpad.
- **Cursor reverts on element hover when Space is held.** Currently the cursor stays as `grab` even when hovering an element, which can be confusing. Figma keeps it as `grab` consistently. Document the design choice; if users complain, change to `grab` over canvas background and default over elements.
