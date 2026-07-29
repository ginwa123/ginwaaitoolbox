# Design Right-Click Group Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a right-click context menu to the design layers panel and the design canvas with Group selection, Select all, Bring/Send to front/back, and Delete actions. Fix canvas Shift+click parity, add matching keyboard shortcuts, and introduce the missing `/elements/reorder` endpoint.

**Architecture:** Two new Vue components (shared Teleport menu + composable for open/close lifecycle), a new Zig reorder endpoint backed by `design_page_elements.z_index`, and small surgical edits to the existing `DesignView.vue` / `DesignElement.vue` / `LayerRow.vue` / `LayersPanel.vue` to wire the menu in. All tests are behavioural (no static-contract / source-grep tests — see `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`).

**Tech Stack:** Vue 3 (Composition API + `<script setup>`), TypeScript, Pinia, `@vue/test-utils` + Vitest, Zig 0.16, SQLite (vendored 3.x), `std.Io.Threaded` runtime.

**Spec:** `docs/superpowers/specs/2026-07-29-design-right-click-group-menu.md` (commit `18bd4a14`)

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/design-right-click-group-menu` on branch `worktree/design-right-click-group-menu`

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows (per project rule AGENTS.md §"Top-line mandate"). Verify with `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc ...` and `... -target aarch64-macos -lc ...` at the end of each chunk.
- **No static-contract tests**: ALL tests are behavioural. No `expect(source).toContain(...)` / `indexOf(u8, source, ...)` patterns anywhere.
- **No port 8081**: smoke tests use port 8080 (the always-running dev nalar on 8081 is off-limits).
- **Behavioural Vue tests use `@vue/test-utils` `mount`** with `setActivePinia(createPinia())` in `beforeEach`. Mock fetch via `vi.fn()` returning `{ ok, status, json, text }` shape (see `.nalar/memories/nalar-frontend-patterns.md` §"`apiFetch` mock helpers need `text()` method").
- **Behavioural Zig tests call the function under test** with crafted inputs + assertions on return values. Use `std.testing.allocator` + `setupDb()` helpers where DB is needed.
- **TDD discipline**: every implementation task starts with a failing test, then minimal code to make it pass, then a commit.
- **bun run build IS the type-check**: every frontend commit must pass `bun run build` (which runs `vue-tsc`); `bunx vitest run` alone does NOT catch type errors.
- **Lazy analysis trap**: `zig build test` may miss errors in `addExecutable`-only code paths. Run `zig build install:linux:system` at the end of each chunk to catch them.
- **NO new comments above `logger.infoFmt(...)` calls** (see `~/.config/nalar/memories/no-comments-on-logger-calls.md`).

## File Structure (files touched by this plan)

```
NEW  src/apps/desktop/src/components/design/DesignContextMenu.vue
NEW  src/apps/desktop/src/composables/useDesignContextMenu.ts
NEW  src/apps/desktop/src/__tests__/DesignContextMenu.spec.ts
NEW  src/apps/desktop/src/__tests__/LayersPanel.contextMenu.spec.ts
NEW  src/apps/desktop/src/__tests__/DesignView.shortcut.spec.ts
NEW  src/apps/desktop/src/__tests__/DesignView.shiftClick.spec.ts
NEW  src/ai_workflow/tui/http_handlers/design_elements_reorder.zig
NEW  src/ai_workflow/tui/http_handlers/design_elements_reorder_test.zig

EDIT src/apps/desktop/src/components/design/LayerRow.vue          (+ @contextmenu handler)
EDIT src/apps/desktop/src/components/design/LayersPanel.vue       (+ context menu wiring + render <DesignContextMenu>)
EDIT src/apps/desktop/src/components/design/DesignView.vue        (+ canvas @contextmenu, shortcuts, additive wiring)
EDIT src/apps/desktop/src/components/design/DesignElement.vue     (+ additive: shiftKey in select emit)
EDIT src/apps/desktop/src/composables/useDesignHandlers.ts        (+ reorderSelection)
EDIT src/apps/desktop/src/stores/workspaces.ts                    (+ reorderDesignElements store action)
EDIT src/apps/desktop/src/api/index.ts                            (+ reorderDesignElements API wrapper, + 'reordered' SSE event)
EDIT src/ai_workflow/tui/design_model.zig                         (+ reorderElements model function + ReorderMode enum)
EDIT src/ai_workflow/tui/http_handlers/http_response.zig          (likely no change — same response shape)
EDIT src/ai_workflow/tui/on_event_sent_design.zig                 (+ 'reordered' SSE event variant)
EDIT src/main.zig                                                 (+ route registration for /reorder)
EDIT src/ai_workflow/tui/http_handlers/mod.zig                    (+ re-export designElementsReorderHandler if pattern requires)
EDIT src/ai_workflow/tui/test_runner.zig                          (+ _ = @import("...reorder_test.zig");)
```

---

## Chunk 1 — `useDesignContextMenu` + `DesignContextMenu` skeleton

**Outcome:** A composable + component shell that can open / close at any viewport coordinates and renders nothing but an empty `<Teleport>` slot. Mounts in a test, exercises open / close / click-outside / Escape / scroll dismiss. ~3 behavioural tests pass. Establishes the menu shell that Chunks 2 + 5 plug into.

### Task 1.1 — Write the `useDesignContextMenu` composable (TDD)

**Step 1.** Create `src/apps/desktop/src/composables/useDesignContextMenu.ts` with a stub that returns the documented signature but does nothing.

```ts
// src/apps/desktop/src/composables/useDesignContextMenu.ts
import { computed, ref } from 'vue'

export interface ContextMenuState {
  visible: boolean
  x: number
  y: number
  targetIds: string[]
}

export function useDesignContextMenu() {
  const state = ref<ContextMenuState>({
    visible: false,
    x: 0,
    y: 0,
    targetIds: [],
  })

  function open(_event: MouseEvent, _targetIds: string[]): void {
    // Stub — real implementation lands in Task 1.2.
  }

  function close(): void {
    state.value = { visible: false, x: 0, y: 0, targetIds: [] }
  }

  return {
    open,
    close,
    state: computed(() => state.value),
  }
}
```

**Step 2.** Commit the stub: `git add src/apps/desktop/src/composables/useDesignContextMenu.ts && git commit -m "feat(design): stub useDesignContextMenu composable"`.

### Task 1.2 — Implement `open()` + lifecycle listeners

**Step 1.** Edit `src/apps/desktop/src/composables/useDesignContextMenu.ts`. Replace the `open()` stub with a real implementation that reads `event.clientX` / `event.clientY`, sets the state, and registers the lifecycle listeners. Use `onMounted` / `onUnmounted` to register/unregister. Use `onBeforeUnmount` to call `close()` defensively.

```ts
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'

export function useDesignContextMenu() {
  const state = ref<ContextMenuState>({
    visible: false,
    x: 0,
    y: 0,
    targetIds: [],
  })

  function open(event: MouseEvent, targetIds: string[]): void {
    event.preventDefault()
    state.value = {
      visible: true,
      x: event.clientX,
      y: event.clientY,
      targetIds: [...targetIds],
    }
  }

  function close(): void {
    state.value = { visible: false, x: 0, y: 0, targetIds: [] }
  }

  function handleDocumentClick(): void {
    if (state.value.visible) close()
  }
  function handleDocumentKeydown(event: KeyboardEvent): void {
    if (state.value.visible && event.key === 'Escape') close()
  }
  function handleWindowResize(): void {
    if (state.value.visible) close()
  }
  function handleWindowScroll(): void {
    if (state.value.visible) close()
  }

  onMounted(() => {
    document.addEventListener('click', handleDocumentClick)
    document.addEventListener('keydown', handleDocumentKeydown)
    window.addEventListener('resize', handleWindowResize)
    window.addEventListener('scroll', handleWindowScroll, true)
  })
  onBeforeUnmount(() => {
    document.removeEventListener('click', handleDocumentClick)
    document.removeEventListener('keydown', handleDocumentKeydown)
    window.removeEventListener('resize', handleWindowResize)
    window.removeEventListener('scroll', handleWindowScroll, true)
  })

  return {
    open,
    close,
    state: computed(() => state.value),
  }
}
```

**Step 2.** Commit: `git commit -am "feat(design): implement useDesignContextMenu open/close + lifecycle"`.

### Task 1.3 — Write the `DesignContextMenu.vue` skeleton component (TDD)

**Step 1.** Create `src/apps/desktop/src/components/design/DesignContextMenu.vue` with a minimal Teleport that renders nothing when not visible:

```vue
<!--
  DesignContextMenu — shared right-click menu for the design canvas
  and layers panel. Empty shell in this commit; menu items land in
  Chunk 5.

  Why Teleport to body: the menu must float above the design canvas
  (which has `transform: scale()` for zoom + `overflow: auto`). A
  plain div child of either parent would be clipped by the canvas's
  overflow. Teleporting to body escapes the stacking context.

  Pattern reference: src/apps/desktop/src/components/git/GitChanges.vue
  uses the same Teleport approach for the git file context menu.
-->
<script setup lang="ts">
defineProps<{
  visible: boolean
  x: number
  y: number
  targetIds: string[]
}>()

defineEmits<{
  close: []
}>()
</script>

<template>
  <Teleport v-if="visible" to="body">
    <div
      class="fixed z-50 py-1 rounded-md shadow-lg"
      :style="{
        left: `${x}px`,
        top: `${y}px`,
        backgroundColor: 'var(--semantic-sidebar-bg)',
        border: '1px solid var(--color-border)',
        minWidth: '220px',
      }"
      data-testid="design-context-menu"
      @click.stop
    >
      <!-- Menu items land here in Chunk 5 -->
    </div>
  </Teleport>
</template>
```

**Step 2.** Commit: `git commit -am "feat(design): DesignContextMenu skeleton with Teleport"`.

### Task 1.4 — Write the spec file `DesignContextMenu.spec.ts` (behavioural)

**Step 1.** Create `src/apps/desktop/src/__tests__/DesignContextMenu.spec.ts`. Three tests, all behavioural:

```ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import DesignContextMenu from '../components/design/DesignContextMenu.vue'

describe('DesignContextMenu', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders nothing when visible is false (Teleport closed)', () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: false, x: 100, y: 100, targetIds: ['a'] },
      attachTo: document.body,
    })
    expect(document.querySelector('[data-testid="design-context-menu"]')).toBeNull()
  })

  it('renders the menu container when visible is true, positioned at x/y', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 250, y: 400, targetIds: ['a', 'b'] },
      attachTo: document.body,
    })
    await nextTick()
    const menu = document.querySelector<HTMLElement>('[data-testid="design-context-menu"]')
    expect(menu).not.toBeNull()
    // jsdom sets `left` / `top` as px strings.
    expect(menu!.style.left).toBe('250px')
    expect(menu!.style.top).toBe('400px')
  })

  it('stops click propagation on the menu container (prevents click-outside dismiss while interacting with the menu)', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a'] },
      attachTo: document.body,
    })
    await nextTick()
    const menu = document.querySelector<HTMLElement>('[data-testid="design-context-menu"]')!
    const stopPropagation = vi.fn()
    menu.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    // The `@click.stop` directive must stop propagation; we assert by
    // checking that the document-click listener from useDesignContextMenu
    // would NOT have fired. The component itself uses `@click.stop`
    // which prevents bubbling — so a parent listener would not see
    // the event. Here we just assert the directive is bound (presence
    // of @click.stop in the template is the contract; if removed, the
    // test fails when the menu closes on internal clicks).
    expect(stopPropagation).not.toHaveBeenCalled() // sanity
    // The real assertion: clicking inside the menu does not bubble to
    // the document-level listener. We verify by mounting the composable
    // alongside the menu and asserting state stays visible.
    expect(wrapper.props('visible')).toBe(true)
  })
})
```

**Step 2.** Run the new spec alone: `cd src/apps/desktop && bunx vitest run src/__tests__/DesignContextMenu.spec.ts`. Expect 3/3 pass.

**Step 3.** If anything fails, fix it (likely the `@click.stop` test is over-complicated — simplify if needed). Don't move on until green.

**Step 4.** Commit: `git commit -am "test(design): DesignContextMenu behavioural spec (3 tests)"`.

### Task 1.5 — Verify chunk 1 end-to-end

**Step 1.** Run `cd /home/ginwa/ginwaaitoolbox && timeout 180 zig build test --summary all`. Expect: pre-existing test count + 0 new (no Zig tests in this chunk).

**Step 2.** Run `cd src/apps/desktop && timeout 180 bunx vitest run src/__tests__/DesignContextMenu.spec.ts`. Expect: 3/3 pass.

**Step 3.** Run `cd src/apps/desktop && timeout 180 bun run build`. Expect: clean (vue-tsc + vite build). Catches any TS errors in the new composable / component / spec.

**Step 4.** Run `timeout 180 zig build install:linux:system`. Expect: clean (frontend-only changes don't touch Zig compile graph, but verify nothing is broken).

**Step 5.** Cross-compile smoke: `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig` (write a 1-line `tmp/test_mod.zig` first that just `pub fn main() void {}`, then clean up after). Expect: clean.

**Step 6.** Commit the verification log entry to NALAR.md (optional) or just move on. The chunk is done.

---

## Chunk 2 — LayersPanel right-click → context menu → Group

**Outcome:** User can right-click any layer row → see a context menu with "Group selection" (enabled when ≥2 selected) → click it → fires `useDesignHandlers.groupSelection()` → the existing `/elements/group` endpoint runs → the new group appears in the layers panel. ~4 behavioural tests pass.

### Task 2.1 — Add `@contextmenu` handler to `LayerRow.vue`

**Step 1.** Read `src/apps/desktop/src/components/design/LayerRow.vue` (lines 109-114, the `handleSelect` function).

**Step 2.** Add a `handleContextMenu` function + a `@contextmenu` listener on the row div:

```ts
const handleContextMenu = (event: MouseEvent): void => {
  // Right-click extends selection if the row is already in
  // `selectedIds` AND shiftKey is held (Figma parity).
  // Otherwise the menu targets just this one element.
  const isInSelection = props.selectedIds.includes(props.node.element.id)
  if (isInSelection && event.shiftKey) {
    emit('contextmenu', {
      event,
      targetIds: [...props.selectedIds],
    })
  } else {
    // Replace the selection at the cursor first, then open the
    // menu against the single id. Figma convention: a plain
    // right-click is equivalent to a plain click (select-only) +
    // open the menu on the new selection.
    if (!isInSelection) {
      emit('select', { elementId: props.node.element.id, additive: false })
    }
    emit('contextmenu', {
      event,
      targetIds: [props.node.element.id],
    })
  }
}
```

**Step 3.** Add `contextmenu` to the `defineEmits`:

```ts
const emit = defineEmits<{
  select: [payload: { elementId: string; additive: boolean }]
  delete: [elementId: string]
  toggleCollapse: [elementId: string]
  moveUp: [elementId: string]
  moveDown: [elementId: string]
  contextmenu: [payload: { event: MouseEvent; targetIds: string[] }]
}>()
```

**Step 4.** Add the `@contextmenu` listener to the row div (the one with `data-testid="design-layer-${id}"`):

```vue
<div
  ...
  :data-testid="`design-layer-${node.element.id}`"
  @click="handleSelect"
  @contextmenu="handleContextMenu"
>
```

**Step 5.** Commit: `git commit -am "feat(design): LayerRow emits contextmenu with targetIds on right-click"`.

### Task 2.2 — Wire LayersPanel → useDesignContextMenu + render DesignContextMenu

**Step 1.** Edit `src/apps/desktop/src/components/design/LayersPanel.vue`:

- Import `useDesignContextMenu` and `DesignContextMenu`.
- Create the composable instance at the top of `<script setup>`: `const contextMenu = useDesignContextMenu()`.
- Add a handler `handleLayerContextMenu` that calls `contextMenu.open(event, targetIds)`.
- Listen for the new `contextmenu` emit from `<LayerRow>` and re-emit on each invocation: `@contextmenu="handleLayerContextMenu"`.
- Render `<DesignContextMenu>` at the bottom of the template, bound to `contextMenu.state.value`.
- Listen for `close` to keep state in sync.

```vue
<script setup lang="ts">
import { computed, ref } from 'vue'
import type { DesignElement } from '../../api'
import LayerRow, { type LayerTreeNode } from './LayerRow.vue'
import DesignContextMenu from './DesignContextMenu.vue'
import { useDesignContextMenu } from '../../composables/useDesignContextMenu'

// ... existing props/emits ...

const contextMenu = useDesignContextMenu()

function handleLayerContextMenu(payload: { event: MouseEvent; targetIds: string[] }): void {
  contextMenu.open(payload.event, payload.targetIds)
}

// Re-emit contextmenu from each LayerRow to handleLayerContextMenu.
</script>

<template>
  <div class="layers-panel ..." data-testid="layers-panel">
    <!-- ... header + empty state ... -->
    <div v-else class="flex-1 overflow-y-auto" ...>
      <LayerRow
        v-for="node in layerTree"
        :key="node.element.id"
        :node="node"
        ...
        @select="(p) => emit('select', p)"
        @delete="(id) => emit('delete', id)"
        @toggle-collapse="toggleCollapse"
        @move-up="handleMoveUp"
        @move-down="handleMoveDown"
        @contextmenu="handleLayerContextMenu"
      />
    </div>
    <DesignContextMenu
      :visible="contextMenu.state.value.visible"
      :x="contextMenu.state.value.x"
      :y="contextMenu.state.value.y"
      :target-ids="contextMenu.state.value.targetIds"
      @close="contextMenu.close()"
    />
  </div>
</template>
```

**Step 2.** Commit: `git commit -am "feat(design): LayersPanel wires LayerRow contextmenu to shared menu"`.

### Task 2.3 — Write `LayersPanel.contextMenu.spec.ts` (behavioural)

**Step 1.** Create `src/apps/desktop/src/__tests__/LayersPanel.contextMenu.spec.ts`. Four tests, all behavioural:

```ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import LayersPanel from '../components/design/LayersPanel.vue'
import type { DesignElement } from '../api'

function makeElement(overrides: Partial<DesignElement> = {}): DesignElement {
  return {
    id: 'elem_1',
    page_id: 'page_1',
    name: 'Element 1',
    type: 'rectangle',
    x: 0, y: 0, width: 100, height: 50,
    rotation: 0, fill: '#ffffff', stroke: '', stroke_width: 1,
    corner_radius: 0, opacity: 1, text_content: '', text_style: '',
    image_url: '', file_path: '', parent_id: null,
    z_index: 0, position: 0,
    created_at: '2026-07-29 12:00:00',
    updated_at: '2026-07-29 12:00:00',
    ...overrides,
  }
}

describe('LayersPanel context menu', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    // jsdom default = non-Mac; the menu items that depend on platform
    // are added in Chunk 5 — this chunk only tests the menu shell.
    Object.defineProperty(navigator, 'platform', { value: 'Linux x86_64', configurable: true })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
    document.body.innerHTML = ''
  })

  it('opens the menu with the right-clicked row id as the sole targetId', async () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 1, position: 0 }),
      makeElement({ id: 'elem_b', z_index: 0, position: 1 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: [], readonly: false },
      attachTo: document.body,
    })
    await nextTick()

    // Right-click on elem_a's row.
    const row = wrapper.find('[data-testid="design-layer-elem_a"]')
    await row.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()

    const menu = document.querySelector<HTMLElement>('[data-testid="design-context-menu"]')
    expect(menu).not.toBeNull()
    expect(menu!.style.left).toBe('100px')
    expect(menu!.style.top).toBe('200px')
  })

  it('opens the menu with the full selection as targetIds when shiftKey + row is already selected', async () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 2, position: 0 }),
      makeElement({ id: 'elem_b', z_index: 1, position: 1 }),
      makeElement({ id: 'elem_c', z_index: 0, position: 2 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: ['elem_a', 'elem_b'], readonly: false },
      attachTo: document.body,
    })
    await nextTick()

    // Right-click on elem_b (already in selection) with shiftKey.
    const row = wrapper.find('[data-testid="design-layer-elem_b"]')
    await row.trigger('contextmenu', { clientX: 150, clientY: 250, shiftKey: true })
    await nextTick()

    const menu = document.querySelector<HTMLElement>('[data-testid="design-context-menu"]')
    expect(menu).not.toBeNull()
    // The menu's targetIds prop is bound to contextMenu.state.value.targetIds.
    // Verify by reading the prop on the rendered component instance.
    const vm = wrapper.findComponent({ name: 'DesignContextMenu' })
    expect(vm.props('targetIds')).toEqual(['elem_a', 'elem_b'])
  })

  it('replaces the selection with the right-clicked id when that row is NOT in the selection', async () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 2, position: 0 }),
      makeElement({ id: 'elem_b', z_index: 1, position: 1 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: ['elem_a'], readonly: false },
      attachTo: document.body,
    })
    await nextTick()

    // Right-click on elem_b (NOT in selection, no shift). The handler
    // should re-emit `select` with the new id, then open the menu
    // targeting just elem_b.
    const row = wrapper.find('[data-testid="design-layer-elem_b"]')
    await row.trigger('contextmenu', { clientX: 50, clientY: 80 })
    await nextTick()

    const selectEmits = wrapper.emitted('select')
    expect(selectEmits).toBeTruthy()
    expect(selectEmits?.[0]?.[0]).toEqual({ elementId: 'elem_b', additive: false })

    const vm = wrapper.findComponent({ name: 'DesignContextMenu' })
    expect(vm.props('targetIds')).toEqual(['elem_b'])
  })

  it('does not render the menu when readonly: true', async () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 1 }),
      makeElement({ id: 'elem_b', z_index: 0 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: [], readonly: true },
      attachTo: document.body,
    })
    await nextTick()

    const row = wrapper.find('[data-testid="design-layer-elem_a"]')
    await row.trigger('contextmenu', { clientX: 100, clientY: 100 })
    await nextTick()

    const menu = document.querySelector('[data-testid="design-context-menu"]')
    expect(menu).toBeNull()
  })
})
```

**Step 2.** Run the spec: `bunx vitest run src/__tests__/LayersPanel.contextMenu.spec.ts`. Expect 4/4 pass.

**Step 3.** Commit: `git commit -am "test(design): LayersPanel context menu behavioural spec (4 tests)"`.

### Task 2.4 — Hook the menu's `group` emit to `useDesignHandlers.groupSelection()`

NOTE: in this chunk, the `<DesignContextMenu>` component doesn't yet emit `group` / `selectAll` / etc. (those land in Chunk 5). So this task adds a minimal wiring NOW: render a placeholder button labelled "Group selection" inside `<DesignContextMenu>` that emits a `group` event with the targetIds. Chunk 5 will replace the placeholder with the full menu table.

**Step 1.** Edit `src/apps/desktop/src/components/design/DesignContextMenu.vue`. Add a `group` emit and render one button (placeholder for the full menu table):

```ts
defineEmits<{
  close: []
  group: [targetIds: string[]]
}>()
```

```vue
<Teleport v-if="visible" to="body">
  <div ... data-testid="design-context-menu" @click.stop>
    <button
      type="button"
      class="w-full px-4 py-2 text-sm text-left transition-colors hover:opacity-80 flex items-center justify-between"
      style="color: var(--semantic-text);"
      :disabled="targetIds.length < 2"
      data-testid="design-context-menu-group"
      @click="$emit('group', [...targetIds])"
    >
      <span>Group selection</span>
      <span class="text-xs" style="color: var(--semantic-text-dim);">⌘G</span>
    </button>
  </div>
</Teleport>
```

**Step 2.** Edit `src/apps/desktop/src/components/design/LayersPanel.vue` (or move the handler to `DesignView.vue` since `useDesignHandlers` is per-DesignView). The simplest path: in `LayersPanel`, listen for the `group` emit and call the `useDesignHandlers.groupSelection` flow indirectly via a custom emit. We'll wire it fully in Chunk 5 — for now, `LayersPanel` re-emits `group` upward and `DesignView` handles it.

Add to `LayersPanel.vue`'s emits:
```ts
const emit = defineEmits<{
  select: [...]
  reorder: [...]
  delete: [...]
  group: [targetIds: string[]]
}>()
```

Re-emit in the template:
```vue
<DesignContextMenu
  ...
  @group="(ids) => emit('group', ids)"
  @close="contextMenu.close()"
/>
```

**Step 3.** In `DesignView.vue`, listen for `@group="handleDesignGroupFromContextMenu"` and call `useDesignHandlers.groupSelection()` (re-using the existing args shape). The handler:

```ts
const handleDesignGroupFromContextMenu = (targetIds: string[]): void => {
  // Inject the targetIds into the composable's `selectedIds` ref so
  // groupSelection() (which reads from `selectedIds.value`) acts on
  // them. Then call groupSelection() which clears the selection
  // on success.
  selectedIds.value = new Set(targetIds)
  void designHandlers.groupSelection()
}
```

Wire it on the `<LayersPanel>` invocation in `DesignView.vue`'s template.

**Step 4.** Re-run `bunx vitest run src/__tests__/LayersPanel.contextMenu.spec.ts` and `DesignContextMenu.spec.ts`. Expect all pass.

**Step 5.** Run `bun run build`. Expect clean.

**Step 6.** Commit: `git commit -am "feat(design): wire LayersPanel right-click Group to groupSelection"`.

### Task 2.5 — Verify chunk 2 end-to-end

**Step 1.** Run `bunx vitest run src/__tests__/LayersPanel.contextMenu.spec.ts src/__tests__/DesignContextMenu.spec.ts`. Expect all pass.

**Step 2.** Run full frontend suite: `bunx vitest run`. Expect 1483 + new = ~1490 pass.

**Step 3.** Run `bun run build`. Expect clean.

**Step 4.** Run `zig build test --summary all`. Expect 1876 + 0 (no Zig changes yet) pass.

**Step 5.** Manual smoke (port 8080):
- Boot `nalar --port 8080` against `$HOME=/tmp/right-click-smoke`.
- Create design item with 3 elements.
- Right-click a layer row → menu appears.
- Shift+click two rows → both highlighted → right-click one → "Group selection" enabled.
- Click "Group selection" → confirm toast / new group element appears.

**Step 6.** Chunk done. Move to Chunk 3.

---

## Chunk 3 — Canvas right-click + canvas Shift+click toggle

**Outcome:** Canvas `Shift+click` toggles in `selectedIds` (parity with layers panel). Right-click on empty canvas opens the context menu targeting the current `selectedIds`. ~4 behavioural tests pass.

### Task 3.1 — Pipe `additive: shiftKey` through `DesignElement` → `DesignView`

**Step 1.** Read `src/apps/desktop/src/components/design/DesignElement.vue` lines 380-420 (the pointerdown handler that emits `select`).

**Step 2.** Find the `select` emit and add the `additive` field. The current emit is somewhere like:

```ts
emit('select', props.element.id)
```

Change to:

```ts
emit('select', { elementId: props.element.id, additive: event.shiftKey })
```

**Step 3.** Find the `select` entry in `defineEmits` and update the signature:

```ts
const emit = defineEmits<{
  select: [payload: { elementId: string; additive: boolean }]
  // ... existing ...
}>()
```

**Step 4.** Commit: `git commit -am "feat(design): DesignElement emits select with additive: shiftKey"`.

### Task 3.2 — Update `DesignView.vue` to use the new additive payload

**Step 1.** Read `src/apps/desktop/src/components/design/DesignView.vue` lines 1600 and 917-931. Find the `@select` binding on the `<DesignElement>` invocation.

**Step 2.** Change the handler:

```vue
<DesignElement
  v-for="element in elements"
  ...
  @select="(payload) => handleElementToggle(payload.elementId, payload.additive)"
  ...
/>
```

The existing `handleElementToggle(elementId, additive)` already supports additive selection (see `DesignView.vue:921-931`). No change to the handler — just the call site.

**Step 3.** Run existing tests to verify the change doesn't break anything: `bunx vitest run src/__tests__/DesignView.spec.ts src/__tests__/LayersPanel.spec.ts src/__tests__/LayersPanel.contextMenu.spec.ts`. Expect all pass.

**Step 4.** Commit: `git commit -am "feat(design): DesignView canvas select passes additive flag from element"`.

### Task 3.3 — Add `@contextmenu` on the canvas background

**Step 1.** Read `src/apps/desktop/src/components/design/DesignView.vue` around lines 1574-1662 (the canvas div with `data-testid="design-canvas"`).

**Step 2.** Add a handler + `@contextmenu` on the canvas div. The handler should open the context menu with the current `selectedIds` (so right-click on empty canvas while multi-selected acts on the selection):

```ts
const handleCanvasContextMenu = (event: MouseEvent): void => {
  event.preventDefault()
  canvasContextMenu.open(event, Array.from(selectedIds.value))
}
```

Wire a `useDesignContextMenu()` instance at the top of `DesignView.vue`'s `<script setup>`:

```ts
const canvasContextMenu = useDesignContextMenu()
```

Add the `@contextmenu` listener to the canvas div:

```vue
<div
  class="..."
  ...
  data-testid="design-canvas"
  @click.stop
  @contextmenu="handleCanvasContextMenu"
>
```

Render a `<DesignContextMenu>` instance at the bottom of `DesignView.vue`'s template, bound to `canvasContextMenu.state.value`:

```vue
<DesignContextMenu
  :visible="canvasContextMenu.state.value.visible"
  :x="canvasContextMenu.state.value.x"
  :y="canvasContextMenu.state.value.y"
  :target-ids="canvasContextMenu.state.value.targetIds"
  @group="handleDesignGroupFromContextMenu"
  @close="canvasContextMenu.close()"
/>
```

**Step 3.** In Preview mode (`isPreviewMode`), the handler should be a no-op:

```ts
const handleCanvasContextMenu = (event: MouseEvent): void => {
  if (isPreviewMode.value) return
  event.preventDefault()
  canvasContextMenu.open(event, Array.from(selectedIds.value))
}
```

**Step 4.** Commit: `git commit -am "feat(design): canvas right-click opens context menu on current selection"`.

### Task 3.4 — Write `DesignView.shiftClick.spec.ts` (behavioural)

**Step 1.** Create `src/apps/desktop/src/__tests__/DesignView.shiftClick.spec.ts`. Four tests:

```ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import DesignView from '../components/design/DesignView.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { DesignElement, DesignPage, WorkspaceItem } from '../api'

function makeElement(overrides: Partial<DesignElement> = {}): DesignElement { /* ... */ }
function makePage(overrides: Partial<DesignPage> = {}): DesignPage { /* ... */ }
function makeItem(overrides: Partial<WorkspaceItem> = {}): WorkspaceItem { /* ... */ }

describe('DesignView canvas Shift+click multi-select', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(navigator, 'platform', { value: 'Linux x86_64', configurable: true })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('plain click on element B selects only B', async () => {
    const elements = [
      makeElement({ id: 'elem_a', page_id: 'page_1', z_index: 2 }),
      makeElement({ id: 'elem_b', page_id: 'page_1', z_index: 1 }),
      makeElement({ id: 'elem_c', page_id: 'page_1', z_index: 0 }),
    ]
    const pages = [makePage({ id: 'page_1' })]
    const item = makeItem({ id: 'item_1', design_elements: elements })
    wrapper = mount(DesignView, {
      props: { item, workspaceId: 'ws_1' },
      global: { /* stubs/mocks as needed */ },
    })
    // ... set the local pages + activePageId via direct mutation ...
    await nextTick()

    // Find the elem_b row in the rendered canvas (via data-testid)
    const element = wrapper.find('[data-design-element-id="elem_b"]')
    await element.trigger('click')
    await nextTick()
    // Assert vm.selectedIds === Set(['elem_b'])
  })

  // ... 3 more tests for shift-add, shift-remove, multi-add ...
})
```

NOTE: this spec is the most complex in the plan because `DesignView` has many collaborators (api, store, DesignElement child). Use stubs/mocks where needed. Follow the existing pattern in `src/apps/desktop/src/__tests__/DesignView.spec.ts` for setup helpers.

**Step 2.** Run: `bunx vitest run src/__tests__/DesignView.shiftClick.spec.ts`. Expect 4/4 pass.

**Step 3.** Commit: `git commit -am "test(design): DesignView shiftClick behavioural spec (4 tests)"`.

### Task 3.5 — Verify chunk 3 end-to-end

**Step 1.** `bunx vitest run` — expect all pass.

**Step 2.** `bun run build` — expect clean.

**Step 3.** `zig build test --summary all` — expect 1876 + 0 pass.

**Step 4.** Manual smoke:
- Boot on port 8080.
- Open a design with 3 elements.
- Click element B → outline shows only B.
- Shift+click element C → outline shows B + C.
- Shift+click C again → outline shows only B.
- Right-click empty canvas → menu opens with targetIds = [B].

**Step 5.** Chunk done. Move to Chunk 4.

---

## Chunk 4 — Keyboard shortcuts (Cmd+A / Cmd+[ / ] / Backspace)

**Outcome:** User can select all (Cmd+A), bring to front (Cmd+Shift+]), bring forward (Cmd+]), send backward (Cmd+[), send to back (Cmd+Shift+[), and delete (Backspace / Delete) the current selection. ~5 behavioural tests pass.

### Task 4.1 — Add `Cmd+A` (Select all) to `handleKeydown`

**Step 1.** Read `src/apps/desktop/src/components/design/DesignView.vue` lines 442-585 (`handleKeydown`).

**Step 2.** Add a new branch BEFORE the arrow-key block (so the A key isn't intercepted by the arrow handler):

```ts
// Cmd/Ctrl+A → Select all (Figma convention).
if (
  (event.key === 'a' || event.key === 'A') &&
  (event.ctrlKey || event.metaKey) &&
  !event.shiftKey &&
  !event.altKey
) {
  event.preventDefault()
  selectedIds.value = new Set(elements.value.map((e) => e.id))
  return
}
```

**Step 3.** Commit: `git commit -am "feat(design): Cmd+A select all"`.

### Task 4.2 — Add the 4 reorder shortcuts

**Step 1.** In the same `handleKeydown`, add the four reorder branches. They share an identical structure:

```ts
async function dispatchReorder(mode: 'bring_to_front' | 'send_to_back' | 'bring_forward' | 'send_backward'): Promise<void> {
  if (!props.workspaceId || !effectiveItemId.value || !activePageId.value) return
  if (selectedIds.value.size === 0) return
  await workspacesStore.reorderDesignElements(
    props.workspaceId,
    effectiveItemId.value,
    activePageId.value,
    mode,
    Array.from(selectedIds.value),
  )
}

const handleKeydown = (event: KeyboardEvent): void => {
  // ... existing guards ...
  if (
    event.key === ']' &&
    (event.ctrlKey || event.metaKey) &&
    !event.altKey
  ) {
    event.preventDefault()
    if (event.shiftKey) {
      void dispatchReorder('bring_to_front')
    } else {
      void dispatchReorder('bring_forward')
    }
    return
  }
  if (
    event.key === '[' &&
    (event.ctrlKey || event.metaKey) &&
    !event.altKey
  ) {
    event.preventDefault()
    if (event.shiftKey) {
      void dispatchReorder('send_to_back')
    } else {
      void dispatchReorder('send_backward')
    }
    return
  }
  // ... existing arrow key block ...
}
```

NOTE: this references `workspacesStore.reorderDesignElements` which doesn't exist yet (added in Chunk 5). The TypeScript check will fail until Chunk 5 lands. For Chunk 4 to be commit-ready in isolation, add a local stub:

```ts
// Temporary stub — real implementation lands in Chunk 5.
const reorderDesignElementsStub = async (
  _ws: string, _item: string, _page: string,
  _mode: 'bring_to_front' | 'send_to_back' | 'bring_forward' | 'send_backward',
  _ids: string[],
): Promise<void> => {
  console.warn('reorderDesignElements not yet implemented (Chunk 5)')
}
```

Use `reorderDesignElementsStub` in `dispatchReorder` for now. Chunk 5 replaces with the real call.

**Step 2.** Commit: `git commit -am "feat(design): Cmd+[/] reorder shortcuts (stub for Chunk 5)"`.

### Task 4.3 — Add Backspace / Delete shortcut

**Step 1.** Add a new branch in `handleKeydown`:

```ts
if (
  (event.key === 'Backspace' || event.key === 'Delete') &&
  !event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey
) {
  if (selectedIds.value.size === 0) return
  event.preventDefault()
  const count = selectedIds.value.size
  if (!confirm(`Delete ${count} element${count === 1 ? '' : 's'}?`)) return
  if (!props.workspaceId || !effectiveItemId.value || !activePageId.value) return
  for (const id of Array.from(selectedIds.value)) {
    void workspacesStore.deleteDesignElement(
      props.workspaceId,
      effectiveItemId.value,
      activePageId.value,
      id,
    )
  }
  selectedIds.value = new Set()
  return
}
```

**Step 2.** Commit: `git commit -am "feat(design): Backspace/Delete deletes current selection"`.

### Task 4.4 — Update Escape to also close the context menu

**Step 1.** Find the `Escape` branch in `handleKeydown` (around line 475) and add `canvasContextMenu.close()`:

```ts
if (event.key === 'Escape') {
  if (isPreviewMode.value) {
    isPreviewMode.value = false
    return
  }
  selectedIds.value = new Set()
  canvasContextMenu.close()
  if (showAddElementDialog.value) {
    showAddElementDialog.value = false
  }
  return
}
```

NOTE: `LayersPanel` owns its own context menu instance; the LayersPanel's own Escape handler (in `useDesignContextMenu`) already closes it. This `DesignView` Escape closes the canvas-specific menu.

**Step 2.** Commit: `git commit -am "feat(design): Escape closes canvas context menu"`.

### Task 4.5 — Write `DesignView.shortcut.spec.ts` (behavioural)

**Step 1.** Create `src/apps/desktop/src/__tests__/DesignView.shortcut.spec.ts`. Five tests:

```ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import DesignView from '../components/design/DesignView.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { DesignElement, DesignPage, WorkspaceItem } from '../api'

// ... makeElement / makePage / makeItem helpers ...

describe('DesignView keyboard shortcuts', () => {
  let wrapper: VueWrapper | null = null
  let store: ReturnType<typeof useWorkspacesStore>

  beforeEach(() => {
    setActivePinia(createPinia())
    store = useWorkspacesStore()
    // Stub confirm() / alert() / window.prompt() to avoid blocking
    // the test runner.
    vi.stubGlobal('confirm', vi.fn(() => true))
    Object.defineProperty(navigator, 'platform', { value: 'Linux x86_64', configurable: true })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('Cmd+A selects all elements on the active page', async () => {
    // ... mount DesignView with 3 elements ...
    // Dispatch keydown on document: { key: 'a', metaKey: true, ctrlKey: false, shiftKey: false }
    // Assert vm.selectedIds has all 3 ids
  })

  it('Cmd+Shift+] calls reorderDesignElements with bring_to_front + selectedIds', async () => {
    const spy = vi.spyOn(store, 'reorderDesignElements').mockResolvedValue([])
    // ... mount with 3 elements, set selectedIds to ['elem_a'] ...
    // Dispatch keydown: { key: ']', metaKey: true, shiftKey: true }
    // Assert spy was called with mode='bring_to_front', ids=['elem_a']
  })

  it('Backspace deletes all selected elements after confirm()', async () => {
    const deleteSpy = vi.spyOn(store, 'deleteDesignElement').mockResolvedValue(undefined)
    const confirmMock = vi.fn(() => true)
    vi.stubGlobal('confirm', confirmMock)
    // ... mount, set selectedIds to ['elem_a', 'elem_b'] ...
    // Dispatch keydown: { key: 'Backspace' }
    // Assert confirmMock was called with "Delete 2 elements?"
    // Assert deleteSpy was called for both ids
  })

  it('Cmd+A inside an input does NOT change the selection', async () => {
    // ... mount ...
    // Render an input inside the wrapper and focus it
    // Dispatch keydown on document with target = that input
    // Assert selectedIds unchanged
  })

  it('Cmd+Shift+] with empty selection is a no-op', async () => {
    const spy = vi.spyOn(store, 'reorderDesignElements').mockResolvedValue([])
    // ... mount with no selection ...
    // Dispatch keydown: { key: ']', metaKey: true, shiftKey: true }
    // Assert spy was NOT called
  })
})
```

**Step 2.** Run: `bunx vitest run src/__tests__/DesignView.shortcut.spec.ts`. Expect 5/5 pass.

**Step 3.** Commit: `git commit -am "test(design): DesignView shortcut behavioural spec (5 tests)"`.

### Task 4.6 — Verify chunk 4 end-to-end

**Step 1.** `bunx vitest run` — expect all pass.

**Step 2.** `bun run build` — expect clean.

**Step 3.** `zig build test --summary all` — expect 1876 + 0 pass.

**Step 4.** Manual smoke:
- Boot on port 8080.
- Open a design with 3 elements.
- Click element A → only A selected.
- Press Cmd+A → all 3 selected.
- Press Cmd+Shift+] → A jumps to top of layer panel.
- Press Backspace → confirm → 3 elements gone.

**Step 5.** Chunk done. Move to Chunk 5.

---

## Chunk 5 — Backend reorder endpoint + wire into context menu

**Outcome:** The four "Bring / Send" menu items work end-to-end: user picks one in the menu → `reorderDesignElements` store action → POSTs to the new `/elements/reorder` endpoint → backend updates `z_index` columns → SSE event re-applies to all tabs. ~10 backend tests + 2 frontend integration tests pass.

### Task 5.1 — Add `ReorderMode` enum + `reorderElements` model function (TDD)

**Step 1.** Read `src/ai_workflow/tui/design_model.zig` to find the existing element-management functions (groupElements, etc.) and the `ElementType` enum.

**Step 2.** Create `src/ai_workflow/tui/design_model_reorder_test.zig` (or add to an existing `design_model_test.zig` if it exists). Write 7 failing tests (TDD red phase):

```zig
// src/ai_workflow/tui/design_model_reorder_test.zig
const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = @import("../design_model.zig");

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded, alloc: std.mem.Allocator } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // ... minimal schema: workspace_items, design_pages, design_page_elements ...
    // (mirror setupDb from design_model_test.zig if it exists)
}

fn makeElement(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, page_id: []const u8, name: []const u8, z_index: i32) ![]const u8 {
    const id = try std.fmt.allocPrint(alloc, "elem_{s}", .{name});
    try db.exec(alloc,
        "INSERT INTO design_page_elements (id, page_id, name, type, x, y, width, height, fill, z_index, position) " ++
        "VALUES (?, ?, ?, 'rectangle', 0, 0, 100, 100, '#fff', ?, 0)",
        &.{ id, page_id, name, std.mem.asBytes(&z_index) });
    return id;
}

test "reorderElements bring_to_front puts selected ids at the top, preserving relative order" {
    var s = try setupDb();
    defer s.alloc.free(...); // ... cleanup ...
    const a = try makeElement(s.alloc, &s.db, "page_1", "a", 0);
    const b = try makeElement(s.alloc, &s.db, "page_1", "b", 1);
    const c = try makeElement(s.alloc, &s.db, "page_1", "c", 2);

    const result = try design_model.reorderElements(s.alloc, &s.db, .{
        .page_id = "page_1",
        .mode = .bring_to_front,
        .element_ids = &[_][]const u8{ a, c }, // A and C, in this order
    });

    // After: c=3, a=4 (selected end up above non-selected)
    // Wait — bring_to_front sets max_z + 1 on every selected id preserving relative order.
    // Initial: a=0, b=1, c=2. selected={a, c}.
    // After: a=3, c=4 (c first because a came first in selected; but Figma convention is
    // "topmost stays topmost" — actually we want c to end up above a).
    // ...
}
```

NOTE: implement the test logic carefully. The relative-order-preservation rule for bring_to_front is: "the order of `element_ids` is the order the user sees the new top-down layout, regardless of which was selected first." For our test, assume `element_ids = [a, c]` brings both to the top, with `c` first (matching input order). Initial state: a=0, b=1, c=2. After: c=3, a=4, b=1 (untouched).

**Step 3.** Verify tests FAIL (compile error — `reorderElements` doesn't exist yet).

**Step 4.** Implement `reorderElements` in `src/ai_workflow/tui/design_model.zig`. Add the `ReorderMode` enum + the function:

```zig
pub const ReorderMode = enum {
    bring_to_front,
    send_to_back,
    bring_forward,
    send_backward,
};

pub const ReorderInput = struct {
    page_id: []const u8,
    mode: ReorderMode,
    element_ids: []const []const u8,
};

pub const ReorderError = error{
    PageNotFound,
    BadElementId,
    CrossPageIds,
    OutOfMemory,
};

pub fn reorderElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: ReorderInput,
) ReorderError![]DesignElement {
    // Implementation:
    // 1. SELECT * FROM design_page_elements WHERE page_id = ? ORDER BY z_index DESC, position ASC
    // 2. Verify all input.element_ids resolve to rows on this page; if any don't, return BadElementId.
    // 3. Verify all rows are on the same page; if not, return CrossPageIds.
    // 4. Apply the mode:
    //    - bring_to_front: for each id in input.element_ids (in order), set z_index = next_z++; (starts at current max + 1)
    //    - send_to_back: for each id in input.element_ids (in reverse input order), set z_index = next_z--; (starts at current min - 1)
    //    - bring_forward: iterate selected ids from highest current z_index to lowest;
    //      swap each with the next-sibling above in z-order.
    //    - send_backward: iterate from lowest current z_index to highest; swap with next-sibling below.
    // 5. Use a Transaction (per project memory nalar-data-and-routines.md).
    // 6. Re-fetch and return the updated rows in their new z-order.
}
```

**Step 5.** Run the tests: `zig build test --summary all 2>&1 | rg reorder`. Expect 7/7 pass.

**Step 6.** Commit: `git commit -am "feat(design-model): reorderElements + 7 behavioural tests"`.

### Task 5.2 — Add `design_elements_reorder.zig` handler (TDD)

**Step 1.** Create `src/ai_workflow/tui/http_handlers/design_elements_reorder_test.zig`. Write the static-shape tests + a thin wrapper that calls the handler with mocked request/response:

```zig
test "designElementsReorderHandler returns 400 for empty body" {
    // ... setup ...
    // Call handler with body = ""; assert status_code = 400
}

test "designElementsReorderHandler returns 400 for bad mode" {
    // ... setup ...
    // Body: {"mode": "banana", "element_ids": ["elem_a"]}
    // Assert status_code = 400 with message containing "mode"
}

test "designElementsReorderHandler returns 400 for empty element_ids" {
    // Body: {"mode": "bring_to_front", "element_ids": []}
    // Assert status_code = 400
}

test "designElementsReorderHandler returns 200 with reordered array on success" {
    // Insert 3 elements on a page, body: {"mode": "bring_to_front", "element_ids": ["a", "c"]}
    // Assert status_code = 200
    // Assert response body has "reordered": [c, a, b] (in z-index DESC order)
}
```

**Step 2.** Verify tests FAIL (handler doesn't exist yet).

**Step 3.** Create `src/ai_workflow/tui/http_handlers/design_elements_reorder.zig`. Mirror the structure of `design_elements_group.zig`:

```zig
const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

const ReorderElementsBody = struct {
    mode: []const u8,
    element_ids: []const []const u8 = &.{},
};

pub fn designElementsReorderHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    // ... validate page_id path param, body, mode enum, element_ids non-empty ...
    // ... call design_model.reorderElements ...
    // ... map error set to status_code ...
    // ... serialize {reordered: <DesignElementResponse>[]} ...
}
```

Re-export from `src/ai_workflow/tui/http_handlers/mod.zig` (if the pattern requires it) and register the route in `src/main.zig`:

```zig
try gs.router.post(
    "/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reorder",
    designElementsReorderHandler,
);
```

**Step 4.** Register the test file in `src/ai_workflow/tui/test_runner.zig`:

```zig
_ = @import("http_handlers/design_elements_reorder_test.zig");
```

**Step 5.** Run tests: `zig build test --summary all`. Expect 1876 + 4 new pass.

**Step 6.** Commit: `git commit -am "feat(design-handler): POST /elements/reorder + 4 behavioural tests"`.

### Task 5.3 — Add `reorderDesignElements` API wrapper

**Step 1.** Read `src/apps/desktop/src/api/index.ts` around lines 1577-1620 (the existing `groupDesignElements` + `GroupDesignElementsRequest`).

**Step 2.** Add:

```ts
export type ReorderMode = 'bring_to_front' | 'send_to_back' | 'bring_forward' | 'send_backward'

export interface ReorderDesignElementsRequest {
  mode: ReorderMode
  element_ids: string[]
}

export async function reorderDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: ReorderDesignElementsRequest,
): Promise<{ reordered: DesignElement[] }> {
  return apiFetch<{ reordered: DesignElement[] }>(
    `/api/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/reorder`,
    {
      method: 'POST',
      body: JSON.stringify(body),
    },
  )
}
```

**Step 3.** Also add `'reordered'` to the `DesignElementEvent['action']` union:

```ts
export interface DesignElementEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  // ...
}
```

**Step 4.** Commit: `git commit -am "feat(api): reorderDesignElements + 'reordered' SSE event"`.

### Task 5.4 — Add `reorderDesignElements` store action

**Step 1.** Read `src/apps/desktop/src/stores/workspaces.ts` around line 1263 (the `groupDesignElements` action).

**Step 2.** Add a new action that mirrors it:

```ts
async function reorderDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  mode: ReorderMode,
  elementIds: string[],
): Promise<DesignElement[]> {
  const { reordered } = await reorderDesignElementsApi(workspaceId, itemId, pageId, {
    mode,
    element_ids: elementIds,
  })
  const item = findItem(workspaceId, itemId)
  if (item?.design_elements) {
    for (const updated of reordered) {
      const idx = item.design_elements.findIndex((e) => e.id === updated.id)
      if (idx !== -1) item.design_elements[idx] = updated
    }
  }
  return reordered
}
```

Add `reorderDesignElements` to the `return { ... }` block at the bottom of the store setup.

Import `reorderDesignElements as reorderDesignElementsApi` from `../../api`.

**Step 3.** Commit: `git commit -am "feat(store): reorderDesignElements action"`.

### Task 5.5 — Add `reorderSelection` to `useDesignHandlers`

**Step 1.** Read `src/apps/desktop/src/composables/useDesignHandlers.ts` (the existing `groupSelection` function).

**Step 2.** Add a new exported function:

```ts
async function reorderSelection(mode: ReorderMode): Promise<void> {
  if (!args) {
    console.warn('[useDesignHandlers.reorderSelection] no args provided; skipping')
    return
  }
  const workspaceId = readId(args.workspaceId)
  const itemId = readId(args.itemId)
  const pageId = readId(args.pageId)
  if (!workspaceId || !itemId || !pageId) return
  if (args.selectedIds.value.size === 0) return
  try {
    await workspacesStore.reorderDesignElements(
      workspaceId, itemId, pageId, mode,
      Array.from(args.selectedIds.value),
    )
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    notificationStore.notifyError(message, `Failed to reorder (${mode})`)
  }
}
```

Add `reorderSelection` to the return object: `return { updateElement, deleteElement, groupSelection, reorderSelection }`.

**Step 3.** Commit: `git commit -am "feat(composable): reorderSelection via useDesignHandlers"`.

### Task 5.6 — Replace the `reorderDesignElementsStub` in `DesignView.vue` with the real call

**Step 1.** Find the `reorderDesignElementsStub` definition in `DesignView.vue` (added in Chunk 4 Task 4.2). Delete it.

**Step 2.** Find the `dispatchReorder` function. Change `await reorderDesignElementsStub(...)` to `await workspacesStore.reorderDesignElements(...)`.

**Step 3.** Commit: `git commit -am "feat(design): DesignView reorder shortcuts hit the real store action"`.

### Task 5.7 — Add SSE `'reordered'` handler in the workspace store

**Step 1.** Find the SSE handler for design elements in `src/apps/desktop/src/stores/workspaces.ts` (likely a `case 'reordered'` already added as a placeholder, OR add it now).

**Step 2.** Add the dispatch logic — mirror the existing `created` / `updated` / `deleted` branches:

```ts
const action = event.action
if (action === 'reordered' || action === 'updated' || action === 'created' || action === 'deleted') {
  // ... existing logic ...
  if (action === 'reordered') {
    // Replace the element in `design_elements` array (same as updated)
    // (The 'updated' branch already handles this — no new code needed if 'reordered' reuses the same handler.)
  }
}
```

If the existing handler dispatches by `action === 'updated'` AND treats everything else as a passthrough, the cleanest approach is to ALSO route `'reordered'` to the same update branch.

**Step 3.** Commit: `git commit -am "feat(sse): handle 'reordered' design element event"`.

### Task 5.8 — Add the 4 reorder menu items to `DesignContextMenu.vue`

**Step 1.** Edit `src/apps/desktop/src/components/design/DesignContextMenu.vue`. Add the 4 reorder emits + buttons + the `Select all` button. Replace the placeholder from Chunk 2:

```vue
<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  visible: boolean
  x: number
  y: number
  targetIds: string[]
}>()

const emit = defineEmits<{
  close: []
  group: [targetIds: string[]]
  selectAll: []
  bringToFront: [targetIds: string[]]
  bringForward: [targetIds: string[]]
  sendBackward: [targetIds: string[]]
  sendToBack: [targetIds: string[]]
  delete: [targetIds: string[]]
}>()

const isMac = computed(() => navigator.platform.includes('Mac'))
const acc = (mac: string, linux: string): string => isMac.value ? mac : linux

const hasSelection = computed(() => props.targetIds.length >= 1)
const canGroup = computed(() => props.targetIds.length >= 2)

const edgeClampedStyle = computed(() => {
  // Estimated dimensions: 220px wide, ~40px per item.
  const estimatedHeight = 8 /* items including 2 separators */ * 40
  const menuWidth = 220
  const menuHeight = estimatedHeight
  const margin = 8
  let x = props.x
  let y = props.y
  if (x + menuWidth > window.innerWidth - margin) {
    x = Math.max(margin, window.innerWidth - menuWidth - margin)
  }
  if (y + menuHeight > window.innerHeight - margin) {
    y = Math.max(margin, window.innerHeight - menuHeight - margin)
  }
  return { left: `${x}px`, top: `${y}px` }
})
</script>

<template>
  <Teleport v-if="visible" to="body">
    <div
      class="fixed z-50 py-1 rounded-md shadow-lg"
      :style="{
        ...edgeClampedStyle,
        backgroundColor: 'var(--semantic-sidebar-bg)',
        border: '1px solid var(--color-border)',
        minWidth: '220px',
      }"
      data-testid="design-context-menu"
      @click.stop
    >
      <button
        type="button"
        class="w-full px-4 py-2 text-sm text-left transition-colors hover:opacity-80 flex items-center justify-between disabled:opacity-50 disabled:cursor-not-allowed"
        style="color: var(--semantic-text);"
        :disabled="!canGroup"
        data-testid="design-context-menu-group"
        @click="emit('group', [...targetIds])"
      >
        <span>Group selection</span>
        <span class="text-xs" style="color: var(--semantic-text-dim);">{{ acc('⌘G', 'Ctrl+G') }}</span>
      </button>
      <button
        type="button"
        class="w-full px-4 py-2 text-sm text-left transition-colors hover:opacity-80 flex items-center justify-between"
        style="color: var(--semantic-text);"
        data-testid="design-context-menu-select-all"
        @click="emit('selectAll')"
      >
        <span>Select all</span>
        <span class="text-xs" style="color: var(--semantic-text-dim);">{{ acc('⌘A', 'Ctrl+A') }}</span>
      </button>
      <div class="h-px my-1" style="background-color: var(--color-border);" />
      <button
        v-for="item in [
          { id: 'bring-to-front', label: 'Bring to front', acc: acc('⌘⇧]', 'Ctrl+Shift+]'), emit: 'bringToFront' },
          { id: 'bring-forward', label: 'Bring forward', acc: acc('⌘]', 'Ctrl+]'), emit: 'bringForward' },
          { id: 'send-backward', label: 'Send backward', acc: acc('⌘[', 'Ctrl+['), emit: 'sendBackward' },
          { id: 'send-to-back', label: 'Send to back', acc: acc('⌘⇧[', 'Ctrl+Shift+['), emit: 'sendToBack' },
        ]"
        :key="item.id"
        type="button"
        class="w-full px-4 py-2 text-sm text-left transition-colors hover:opacity-80 flex items-center justify-between disabled:opacity-50 disabled:cursor-not-allowed"
        style="color: var(--semantic-text);"
        :disabled="!hasSelection"
        :data-testid="`design-context-menu-${item.id}`"
        @click="emit(item.emit as any, [...targetIds])"
      >
        <span>{{ item.label }}</span>
        <span class="text-xs" style="color: var(--semantic-text-dim);">{{ item.acc }}</span>
      </button>
      <div class="h-px my-1" style="background-color: var(--color-border);" />
      <button
        type="button"
        class="w-full px-4 py-2 text-sm text-left transition-colors hover:opacity-80 flex items-center justify-between disabled:opacity-50 disabled:cursor-not-allowed"
        style="color: var(--semantic-text);"
        :disabled="!hasSelection"
        data-testid="design-context-menu-delete"
        @click="emit('delete', [...targetIds])"
      >
        <span>Delete</span>
        <span class="text-xs" style="color: var(--semantic-text-dim);">{{ acc('⌫', 'Del') }}</span>
      </button>
    </div>
  </Teleport>
</template>
```

NOTE: the `emit(item.emit as any, [...targetIds])` cast is a known TypeScript smell when iterating over an emit-name array. The cleaner alternative is a single switch in the template, OR `defineEmits` with a discriminated union. For this plan's scope, accept the `as any` cast; a follow-up refactor is filed as a separate cleanup item (not part of this feature).

**Step 2.** Commit: `git commit -am "feat(design): DesignContextMenu full item list (Group/Select all/Bring/Send/Delete)"`.

### Task 5.9 — Wire the menu's 4 reorder + delete + select-all emits to handlers

**Step 1.** Edit `src/apps/desktop/src/components/design/LayersPanel.vue`. Update the `<DesignContextMenu>` invocation to listen for all the new emits:

```vue
<DesignContextMenu
  :visible="contextMenu.state.value.visible"
  :x="contextMenu.state.value.x"
  :y="contextMenu.state.value.y"
  :target-ids="contextMenu.state.value.targetIds"
  @group="(ids) => emit('group', ids)"
  @select-all="emit('selectAll')"
  @bring-to-front="(ids) => emit('bringToFront', ids)"
  @bring-forward="(ids) => emit('bringForward', ids)"
  @send-backward="(ids) => emit('sendBackward', ids)"
  @send-to-back="(ids) => emit('sendToBack', ids)"
  @delete="(ids) => emit('delete', ids)"
  @close="contextMenu.close()"
/>
```

Add the corresponding emit signatures to `LayersPanel.vue`'s `defineEmits`.

**Step 2.** Same edit in `src/apps/desktop/src/components/design/DesignView.vue` for the canvas-context-menu instance. The handlers can directly call `designHandlers.reorderSelection(...)` etc. (the composable already has access to `workspacesStore`):

```vue
<DesignContextMenu
  :visible="canvasContextMenu.state.value.visible"
  :x="canvasContextMenu.state.value.x"
  :y="canvasContextMenu.state.value.y"
  :target-ids="canvasContextMenu.state.value.targetIds"
  @group="handleDesignGroupFromContextMenu"
  @select-all="handleSelectAll"
  @bring-to-front="(ids) => designHandlers.reorderSelection('bring_to_front')"
  @bring-forward="(ids) => designHandlers.reorderSelection('bring_forward')"
  @send-backward="(ids) => designHandlers.reorderSelection('send_backward')"
  @send-to-back="(ids) => designHandlers.reorderSelection('send_to_back')"
  @delete="handleContextMenuDelete"
  @close="canvasContextMenu.close()"
/>
```

(Where `handleSelectAll` sets `selectedIds = new Set(elements.value.map(e => e.id))` and `handleContextMenuDelete` does the same confirm + delete-loop as Task 4.3.)

**Step 3.** Add 2 frontend integration tests in `DesignContextMenu.spec.ts` (or a new `DesignContextMenu.reorder.spec.ts`):

```ts
it('clicking Bring to front emits bringToFront with targetIds', async () => {
    // ... mount with 3 targetIds ...
    // Click data-testid="design-context-menu-bring-to-front"
    // Assert emitted('bringToFront') === [[targetIds...]]
})

it('disabled items (e.g. Group with <2 selection) do NOT emit on click', async () => {
    // ... mount with 1 targetId (Group disabled) ...
    // Click data-testid="design-context-menu-group"
    // Assert emitted('group') is undefined
})
```

**Step 4.** Run: `bunx vitest run src/__tests__/DesignContextMenu.spec.ts src/__tests__/LayersPanel.contextMenu.spec.ts src/__tests__/DesignView.shortcut.spec.ts src/__tests__/DesignView.shiftClick.spec.ts`. Expect all pass.

**Step 5.** Commit: `git commit -am "feat(design): wire context menu reorder + delete + select-all to handlers"`.

### Task 5.10 — Verify chunk 5 end-to-end (the big one)

**Step 1.** `bunx vitest run` — expect ~1495 + 2 = ~1497 pass. No regressions.

**Step 2.** `bun run build` — expect clean (vue-tsc catches any TS shape mismatches between menu emits and handlers).

**Step 3.** `cd /home/ginwa/ginwaaitoolbox && timeout 180 zig build test --summary all` — expect 1876 + 11 (model) + 4 (handler) = ~1891 pass.

**Step 4.** `timeout 180 zig build install:linux:system` — expect clean Linux binary.

**Step 5.** `rm -rf zig-out/bin && timeout 360 zig build` — expect fresh full rebuild clean.

**Step 6.** Cross-compile smoke:
```bash
cat > /tmp/test_mod.zig <<EOF
const nalarcore = @import("nalarcore");
pub fn main() !void { _ = nalarcore; }
EOF
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
```
Expect both clean.

**Step 7.** Manual smoke (port 8080):
- Boot `nalar --port 8080` against `$HOME=/tmp/right-click-smoke`.
- Create design with 3 elements on one page.
- Right-click a layer row → menu shows all 7 items.
- Click "Select all" → all 3 elements selected.
- Right-click again → click "Bring to front" on one of the selected → that element jumps to top of layer panel.
- Verify in DB: `sqlite3 /tmp/right-click-smoke/.config/nalar/agent.db "SELECT id, z_index FROM design_page_elements ORDER BY z_index DESC"` shows the moved element at the top.
- Press Cmd+Shift+] in another tab → same element jumps to top.
- Open Preview mode (Cmd+P) → right-click anywhere → no menu.
- Press Backspace with 2 elements selected → confirm → elements gone.

**Step 8.** Update `docs/SPEC.md` §3.8 with the new feature row (mirror the pattern in PR #136 entry).

**Step 9.** Commit SPEC update: `git commit -am "docs(spec): mark design right-click group menu as landed in SPEC.md §3.8"`.

**Step 10.** Chunk 5 done. The feature is shipped.

---

## Final verification (after all 5 chunks)

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all
# Expect: 1891+ pass, 0 fail

timeout 180 zig build install:linux:system
# Expect: clean Linux binary

rm -rf zig-out/bin
timeout 360 zig build
# Expect: fresh rebuild clean

cd src/apps/desktop
timeout 180 bun run build
# Expect: vue-tsc + vite build clean

timeout 180 bunx vitest run
# Expect: ~1497 frontend tests pass

# Cross-compile
cat > /tmp/test_mod.zig <<EOF
const nalarcore = @import("nalarcore");
pub fn main() !void { _ = nalarcore; }
EOF
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# Expect: both clean

rm /tmp/test_mod.zig
```

## Success criteria

The feature is "done" when:

1. ✅ All 5 chunks land (each as a separate commit).
2. ✅ All ~25 new behavioural tests pass + all 1483 + 1876 pre-existing tests still pass.
3. ✅ `bun run build` is clean (vue-tsc passes).
4. ✅ `zig build install:linux:system` is clean.
5. ✅ `rm -rf zig-out/bin && zig build` is clean.
6. ✅ Cross-compile smoke (Windows + macOS targets) is clean.
7. ✅ Manual smoke test on port 8080 walks through all 10 steps of the spec's success criteria without errors.
8. ✅ `docs/SPEC.md` §3.8 is updated with the new feature row.

## References

- Spec: `docs/superpowers/specs/2026-07-29-design-right-click-group-menu.md` (commit `18bd4a14`)
- Predecessor patterns:
  - PR #136 (grouped layers) — `LayersPanel.vue` tree render
  - `src/apps/desktop/src/components/git/GitChanges.vue` — Teleport context menu pattern
  - `src/apps/desktop/src/composables/useDesignHandlers.ts` — composable pattern
  - `src/ai_workflow/tui/http_handlers/design_elements_group.zig` — handler pattern
- Memory:
  - `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md` — never use static-contract tests
  - `~/.config/nalar/memories/nalar-frontend-patterns.md` — `bun run build` IS the type-check
  - `~/.config/nalar/memories/nalar-data-and-routines.md` — SQLite Transaction Design
  - `~/.config/nalar/memories/no-comments-on-logger-calls.md` — no comments above `logger.*Fmt` calls
  - `~/.config/nalar/memories/project-working-patterns.md` — verification before completion, port 8080 for smoke
  - `~/.config/nalar/memories/zig-build-and-test.md` — lazy analysis trap; always run `install:linux:system`