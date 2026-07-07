<!--
  DesignView — the file-backed design canvas main view.

  Renders a tab strip across the top (one tab per page), the active
  page's elements as positioned <div> boxes inside a panzoom-wrapped
  container, and an optional chat panel that the user can toggle on/off.

  Data model (plan v5, docs/superpowers/plans/2026-07-06-design-fs-rewrite.md):
    - Pages are metadata-only containers — `id, name, width, height, x, y,
      position`. Their html lives in a per-page folder under
      `<workspace_item.path>/.nalar/design/<page_name>/`. Pages have NO
      inline html.
    - Elements are positioned HTML snippets with `id, page_id, name,
      file_path, x, y, width, height, z_index, position`. The html body
      is at `<workspace_item.path>/<file_path>`. The full element row
      (incl. `html`) is only fetched lazily on demand — the list endpoint
      returns just the geometry.

  Two-input modes (mirrors the v1 chunk-6 design):
    OFF (default): just the canvas. The user can flip the Chat toggle
                   at any time to open the chat.
    ON:           the canvas takes the left half, and a ChatView panel
                   appears on the right (mirrors the Kanban layout).

  User interaction (chunk 4 additions):
    - Each element renders at (page.x + element.x, page.y + element.y)
      with element's width × height. CSS `absolute` positioning inside
      a `position: relative` page canvas (auto-sized from `width ×
      height`).
    - A drag handle (top strip, ~6px tall) on each element lets the
      user reposition (mouse / touch / pen via pointermove / pointerup).
    - A resize handle (southeast corner, ~12px square) lets the user
      resize. Both drag and resize use optimistic UI updates — the
      local state moves immediately and the server PATCH follows;
      a server error snaps back to the prior geometry.
    - A "+ Add Element" button opens a small inline form (name +
      textarea for html); submitting POSTs and refreshes the list.
    - A delete × in each element's header removes it (DELETE, refresh).
    - A Refresh button (top-right) refetches pages + elements.

  SSE wire format:
    - The component opens its own SSE listener (via the project's
      `installSseBus` + `createUnifiedSseConnection`) for the 5 design
      event types: `design_page_updated`, `design_page_deleted`,
      `design_element_created`, `design_element_updated`,
      `design_element_deleted`. On any event, it refetches the
      affected page / element. The bus is shared app-wide so this
      listener coexists with the rest of the app's SSE channels.

  Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
    (Chunk 4) + docs/superpowers/plans/2026-07-05-design-mode.md
    (Chunk 6 — chat toggle + horizontal split).
-->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import panzoom from 'panzoom'
import * as api from '../api'
import type {
  DesignPageSummary,
  DesignElementSummary,
  DesignElementFull,
  Task,
} from '../api'
import ChatView from './ChatView.vue'
import { installSseBus, useSseBus } from '../helpers/sseBus'

const props = defineProps<{
  workspaceId: string
  item: { id: string; name: string }
}>()

// ─── Page + element state ────────────────────────────────────────────────

const pages = ref<DesignPageSummary[]>([])
const activePageId = ref<string | null>(null)
const activePage = computed<DesignPageSummary | null>(
  () => pages.value.find((p) => p.id === activePageId.value) ?? null,
)
const elements = ref<DesignElementSummary[]>([])
// Map of element_id → fetched DesignElementFull (with html). Elements
// without a fetched full row render a placeholder. Lazy fetch — only
// when the user opens / focuses an element, or when the SSE event
// says it was just updated.
const elementFullById = ref<Record<string, DesignElementFull>>({})

const newPageName = ref('')
const showAddPage = ref(false)
const pageLoading = ref(false)
const elementsLoading = ref(false)

// ─── Panzoom ────────────────────────────────────────────────────────────

const canvasContainerRef = ref<HTMLDivElement | null>(null)
// Panzoom instance lives outside Vue reactivity — it's a real DOM
// controller that wraps the canvas <div>. Keeping it as a plain `let`
// (not a ref) avoids unnecessary reactivity triggers.
let panzoomController: ReturnType<typeof panzoom> | null = null

function mountPanzoom() {
  if (panzoomController) return
  const el = canvasContainerRef.value
  if (!el) return
  // `canvas` (scoped CSS class) is the element we want to pan/zoom.
  // We pass the canvas container so the user can drag anywhere on
  // the surrounding grey area; the elements inside the canvas have
  // their own pointer event handlers that opt out of panzoom (see
  // `data-no-panzoom="true"` below).
  const target = el.querySelector<HTMLElement>('.design-canvas-inner')
  if (!target) return
  panzoomController = panzoom(target, {
    maxZoom: 4,
    minZoom: 0.1,
    bounds: false,
    // Smooth wheel zoom — feels nicer than the default step-by-step.
    smoothScroll: false,
  })
}

function disposePanzoom() {
  if (panzoomController) {
    panzoomController.dispose()
    panzoomController = null
  }
}

// ─── Pan/zoom helpers exposed to toolbar ────────────────────────────────

function resetPanzoom() {
  if (!panzoomController) return
  panzoomController.zoomAbs(0, 0, 1)
  panzoomController.moveTo(0, 0)
}

// ─── Page CRUD ──────────────────────────────────────────────────────────

async function loadPages() {
  if (!props.workspaceId || !props.item.id) return
  pageLoading.value = true
  try {
    pages.value = await api.listDesignPages(props.workspaceId, props.item.id)
    if (!activePageId.value && pages.value.length > 0) {
      await selectPage(pages.value[0]!.id)
    } else if (pages.value.length === 0) {
      activePageId.value = null
      elements.value = []
    }
  } catch (err) {
    console.error('[DesignView] loadPages failed:', err)
  } finally {
    pageLoading.value = false
  }
}

async function selectPage(pageId: string) {
  activePageId.value = pageId
  // Drop cached element html on page switch (different page → different
  // elements). Lazy fetch happens again when the user opens each one.
  elementFullById.value = {}
  await loadElements(pageId)
}

async function loadElements(pageId: string) {
  elementsLoading.value = true
  try {
    elements.value = await api.listDesignElements(
      props.workspaceId,
      props.item.id,
      pageId,
    )
  } catch (err) {
    console.error('[DesignView] loadElements failed:', err)
  } finally {
    elementsLoading.value = false
  }
}

async function addPage() {
  const name = newPageName.value.trim()
  if (!name) return
  try {
    const created = await api.createDesignPage(props.workspaceId, props.item.id, {
      name,
    })
    newPageName.value = ''
    showAddPage.value = false
    await loadPages()
    // Select the freshly created page so the user sees the empty canvas.
    if (created?.id) {
      await selectPage(created.id)
    }
  } catch (err) {
    console.error('[DesignView] addPage failed:', err)
  }
}

async function deletePage(pageId: string) {
  if (!window.confirm('Delete this page and all its elements?')) return
  try {
    await api.deleteDesignPage(props.workspaceId, props.item.id, pageId)
    const wasActive = activePageId.value === pageId
    activePageId.value = null
    elements.value = []
    await loadPages()
    if (wasActive && pages.value.length > 0) {
      await selectPage(pages.value[0]!.id)
    }
  } catch (err) {
    console.error('[DesignView] deletePage failed:', err)
  }
}

async function refreshCanvas() {
  await loadPages()
  if (activePageId.value) {
    await loadElements(activePageId.value)
  }
}

// ─── Element CRUD ───────────────────────────────────────────────────────

const showAddElement = ref(false)
const newElementName = ref('')
const newElementHtml = ref('')

async function addElement() {
  if (!activePageId.value) return
  const name = newElementName.value.trim()
  const html = newElementHtml.value
  if (!name || !html) return
  try {
    await api.createDesignElement(
      props.workspaceId,
      props.item.id,
      activePageId.value,
      { name, html },
    )
    newElementName.value = ''
    newElementHtml.value = ''
    showAddElement.value = false
    await loadElements(activePageId.value)
  } catch (err) {
    console.error('[DesignView] addElement failed:', err)
  }
}

async function fetchElementFull(elementId: string): Promise<void> {
  // Skip the round-trip if we already have a fresh enough copy.
  if (elementFullById.value[elementId]) return
  if (!activePageId.value) return
  try {
    const full = await api.getDesignElement(
      props.workspaceId,
      props.item.id,
      activePageId.value,
      elementId,
    )
    elementFullById.value = {
      ...elementFullById.value,
      [elementId]: full,
    }
  } catch (err) {
    console.error('[DesignView] fetchElementFull failed:', err)
  }
}

async function deleteElement(elementId: string) {
  if (!activePageId.value) return
  try {
    await api.deleteDesignElement(
      props.workspaceId,
      props.item.id,
      activePageId.value,
      elementId,
    )
    await loadElements(activePageId.value)
  } catch (err) {
    console.error('[DesignView] deleteElement failed:', err)
  }
}

// ─── Drag-to-move (pointer events; works for mouse + touch) ─────────────

interface DragState {
  pointerId: number
  startClientX: number
  startClientY: number
  // Original element geometry at drag-start (for revert on failure
  // and to compute the delta in pixels).
  origX: number
  origY: number
  // Element ref so we can apply live transform during the drag and
  // read back the final geometry on `pointerup`.
  el: DesignElementSummary
}

const dragState = ref<DragState | null>(null)

function onElementDragStart(
  ev: PointerEvent,
  el: DesignElementSummary,
): void {
  if (!activePage.value) return
  // Mark this element as opting out of panzoom — panzoom listens for
  // pointerdown on the wrapper and would otherwise start panning on
  // top of the drag. The `data-no-panzoom` attribute makes panzoom
  // skip the event.
  ev.stopPropagation()
  if (panzoomController) panzoomController.pause()
  ;(ev.currentTarget as HTMLElement).setPointerCapture(ev.pointerId)
  dragState.value = {
    pointerId: ev.pointerId,
    startClientX: ev.clientX,
    startClientY: ev.clientY,
    origX: el.x,
    origY: el.y,
    el,
  }
}

function onElementDragMove(ev: PointerEvent): void {
  const state = dragState.value
  if (!state || state.pointerId !== ev.pointerId) return
  // Apply the live transform locally so the user sees the element
  // follow the cursor (optimistic UI). We translate by delta in CSS
  // pixels — panzoom's scale doesn't affect the canvas coordinate
  // space, only the rendered zoom level. (deltaX is already in CSS
  // pixels.)
  const target = (ev.currentTarget as HTMLElement).parentElement
  if (!target) return
  const dxCss = ev.clientX - state.startClientX
  const dyCss = ev.clientY - state.startClientY
  // Convert CSS pixels to page coordinates by dividing by the current
  // panzoom scale. Read the live scale off the element's transform.
  const transform = target.parentElement?.style.transform ?? ''
  const scale = parseScale(transform)
  const newX = Math.round(state.origX + dxCss / scale)
  const newY = Math.round(state.origY + dyCss / scale)
  target.style.left = `${newX}px`
  target.style.top = `${newY}px`
}

async function onElementDragEnd(ev: PointerEvent): Promise<void> {
  const state = dragState.value
  if (!state || state.pointerId !== ev.pointerId) return
  dragState.value = null
  if (panzoomController) panzoomController.resume()
  // Read the final geometry off the DOM (the pointer-move handler
  // wrote it directly into the inline style for snappy visual
  // feedback — we now compute the committed geometry to send to the
  // server).
  const target = (ev.currentTarget as HTMLElement).parentElement
  if (!target || !activePageId.value) return
  const transform = target.parentElement?.style.transform ?? ''
  const scale = parseScale(transform)
  const finalX = Math.round(state.origX + (ev.clientX - state.startClientX) / scale)
  const finalY = Math.round(state.origY + (ev.clientY - state.startClientY) / scale)
  // Optimistic mutation already in the DOM — `updateLocalElement`
  // patches the element in the `elements` array so the next render
  // starts from the new position. The server PATCH follows; if it
  // fails we revert.
  updateLocalElement(state.el.id, { x: finalX, y: finalY })
  try {
    await api.moveDesignElement(
      props.workspaceId,
      props.item.id,
      activePageId.value,
      state.el.id,
      finalX,
      finalY,
    )
  } catch (err) {
    console.error('[DesignView] moveDesignElement failed:', err)
    // Revert on failure.
    updateLocalElement(state.el.id, { x: state.origX, y: state.origY })
    target.style.left = `${state.origX}px`
    target.style.top = `${state.origY}px`
  }
}

/**
 * Parse the current panzoom scale factor out of an element's
 * `style="transform: …"`. Panzoom sets `transform: matrix(s, 0, 0,
 * s, tx, ty)`, so the first entry of the matrix is the scale. Falls
 * back to 1.0 if no matrix is set (initial render or no panzoom yet).
 */
function parseScale(transform: string): number {
  const m = transform.match(/matrix\(([-\d.]+),\s*([-\d.]+),/)
  if (!m) return 1
  const s = parseFloat(m[1]!)
  return Number.isFinite(s) && s > 0 ? s : 1
}

// ─── Resize handle (southeast corner; mouse + touch) ────────────────────

interface ResizeState {
  pointerId: number
  startClientX: number
  startClientY: number
  origWidth: number
  origHeight: number
  el: DesignElementSummary
}

const resizeState = ref<ResizeState | null>(null)

function onElementResizeStart(
  ev: PointerEvent,
  el: DesignElementSummary,
): void {
  if (!activePage.value) return
  ev.stopPropagation()
  if (panzoomController) panzoomController.pause()
  ;(ev.currentTarget as HTMLElement).setPointerCapture(ev.pointerId)
  resizeState.value = {
    pointerId: ev.pointerId,
    startClientX: ev.clientX,
    startClientY: ev.clientY,
    origWidth: el.width,
    origHeight: el.height,
    el,
  }
}

function onElementResizeMove(ev: PointerEvent): void {
  const state = resizeState.value
  if (!state || state.pointerId !== ev.pointerId) return
  const target = (ev.currentTarget as HTMLElement).parentElement?.parentElement
  if (!target) return
  const transform = target.parentElement?.style.transform ?? ''
  const scale = parseScale(transform)
  const newWidth = Math.max(
    20,
    Math.round(state.origWidth + (ev.clientX - state.startClientX) / scale),
  )
  const newHeight = Math.max(
    20,
    Math.round(state.origHeight + (ev.clientY - state.startClientY) / scale),
  )
  target.style.width = `${newWidth}px`
  target.style.height = `${newHeight}px`
}

async function onElementResizeEnd(ev: PointerEvent): Promise<void> {
  const state = resizeState.value
  if (!state || state.pointerId !== ev.pointerId) return
  resizeState.value = null
  if (panzoomController) panzoomController.resume()
  if (!activePageId.value) return
  const target = (ev.currentTarget as HTMLElement).parentElement?.parentElement
  if (!target) return
  const transform = target.parentElement?.style.transform ?? ''
  const scale = parseScale(transform)
  const finalWidth = Math.max(
    20,
    Math.round(state.origWidth + (ev.clientX - state.startClientX) / scale),
  )
  const finalHeight = Math.max(
    20,
    Math.round(state.origHeight + (ev.clientY - state.startClientY) / scale),
  )
  updateLocalElement(state.el.id, { width: finalWidth, height: finalHeight })
  try {
    await api.resizeDesignElement(
      props.workspaceId,
      props.item.id,
      activePageId.value,
      state.el.id,
      finalWidth,
      finalHeight,
    )
  } catch (err) {
    console.error('[DesignView] resizeDesignElement failed:', err)
    updateLocalElement(state.el.id, {
      width: state.origWidth,
      height: state.origHeight,
    })
    target.style.width = `${state.origWidth}px`
    target.style.height = `${state.origHeight}px`
  }
}

/**
 * Patch a single element in the `elements` array (used by the optimistic
 * update + revert paths). Immutably replaces the row with a shallow copy
 * so Vue's reactivity picks up the change.
 */
function updateLocalElement(
  id: string,
  patch: Partial<DesignElementSummary>,
): void {
  const idx = elements.value.findIndex((e) => e.id === id)
  if (idx === -1) return
  const current = elements.value[idx]!
  elements.value = [
    ...elements.value.slice(0, idx),
    { ...current, ...patch },
    ...elements.value.slice(idx + 1),
  ]
}

// ─── SSE: live updates from other clients (incl. the LLM) ──────────────

let sseBus: ReturnType<typeof installSseBus> | null = null
let sseUnsubs: Array<() => void> = []

function subscribeSse() {
  if (sseBus) return // already subscribed
  sseBus = installSseBus()
  // We use the bus's `on('design', …)` channel which fans out all 5
  // design_* named events through the unified SSE factory
  // (see api/index.ts `UnifiedChannels.design` and
  // helpers/sseBus.ts `SseEventMap['design']`).
  const unsub = sseBus.on('design', (event) => {
    // Discriminate by the payload shape — each design_* event has a
    // distinct field set. We only refresh when the event affects the
    // current active page / our workspace+item; other events we
    // ignore (other users in other design items).
    const wsMatch = (event as { workspace_id?: string }).workspace_id === props.workspaceId
    const itemMatch = (event as { item_id?: string }).item_id === props.item.id
    const pageId = (event as { page?: { id?: string }; page_id?: string; element?: { page_id?: string } }).page?.id
      ?? (event as { page_id?: string }).page_id
      ?? (event as { element?: { page_id?: string } }).element?.page_id
    const matchesCurrentPage = !pageId || pageId === activePageId.value
    if (!wsMatch || !itemMatch || !matchesCurrentPage) return
    // Refresh pages list (cheap); the page-list endpoint is the
    // single source of truth for page geometry changes anyway.
    void loadPages()
    // For element-scoped events we can refresh just the current
    // page's elements. Always reload the page's element list to keep
    // it simple (mirrors how a chat "Refresh" button works).
    if (activePageId.value) {
      void loadElements(activePageId.value)
    }
  })
  sseUnsubs.push(unsub)
}

function unsubscribeSse() {
  for (const unsub of sseUnsubs) unsub()
  sseUnsubs = []
  sseBus = null
}

// ─── Chat toggle (preserved from chunk 6) ───────────────────────────────

const DESIGN_CHAT_TASK_NAME = 'Chat'
const showChat = ref(false)
const chatTaskId = ref<string | null>(null)
const chatLoading = ref(false)
const chatReady = ref(false)

async function resolveExistingChatTask() {
  if (!props.workspaceId || !props.item.id) {
    chatReady.value = true
    return
  }
  try {
    const { tasks } = await api.getTasks(props.workspaceId, props.item.id, 20)
    const existing = tasks.find((t) => t.name === DESIGN_CHAT_TASK_NAME)
    if (existing) chatTaskId.value = existing.id
  } catch (err) {
    console.error('[DesignView] resolveExistingChatTask failed:', err)
  } finally {
    chatReady.value = true
  }
}

async function handleToggleChat() {
  if (showChat.value) {
    showChat.value = false
    return
  }
  if (!chatReady.value) {
    chatLoading.value = true
    try {
      await resolveExistingChatTask()
    } finally {
      chatLoading.value = false
    }
  }
  if (!chatTaskId.value) {
    chatLoading.value = true
    try {
      const task: Task = await api.createTask(
        props.workspaceId,
        props.item.id,
        { name: DESIGN_CHAT_TASK_NAME, taskType: 'standard' },
      )
      chatTaskId.value = task.id
    } catch (err) {
      console.error('[DesignView] toggleChat create failed:', err)
      return
    } finally {
      chatLoading.value = false
    }
  }
  showChat.value = true
}

function handleChatClose() {
  showChat.value = false
}

// ─── Lifecycle ─────────────────────────────────────────────────────────

onMounted(async () => {
  void loadPages()
  void resolveExistingChatTask()
  subscribeSse()
  // Mount the panzoom controller on next tick (the canvas DOM must
  // exist first). `mountPanzoom` is idempotent — calling it again
  // after a re-render is safe.
  await nextTick()
  mountPanzoom()
})

watch(activePageId, async () => {
  // Re-mount panzoom on page switch (the inner canvas DOM is rebuilt
  // by the v-if/v-for; old controller was disposed above).
  disposePanzoom()
  await nextTick()
  mountPanzoom()
})

watch(
  () => props.item.id,
  () => {
    // Switching to a different design item: drop the previous
    // toggle/chat state and re-resolve against the new item.
    showChat.value = false
    chatTaskId.value = null
    chatReady.value = false
    elementFullById.value = {}
    unsubscribeSse()
    void loadPages()
    void resolveExistingChatTask()
    subscribeSse()
  },
)

onBeforeUnmount(() => {
  disposePanzoom()
  unsubscribeSse()
})
</script>

<template>
  <div class="flex flex-col h-full min-h-0">
    <!-- Tab strip + chat toggle -->
    <div
      class="flex items-center gap-1 px-3 py-2 overflow-x-auto border-b shrink-0"
      style="border-color: var(--color-border)"
      data-testid="design-tab-strip"
    >
      <button
        v-for="page in pages"
        :key="page.id"
        @click="selectPage(page.id)"
        :data-testid="`design-tab-${page.id}`"
        class="px-3 py-1.5 rounded-md text-xs flex items-center gap-2 transition-colors shrink-0"
        :style="
          activePageId === page.id
            ? 'background: var(--semantic-active-bg); color: var(--semantic-text);'
            : 'color: var(--semantic-text-dim);'
        "
      >
        {{ page.name }}
        <span
          @click.stop="deletePage(page.id)"
          class="text-xs opacity-50 hover:opacity-100"
          aria-label="Close tab"
        >×</span>
      </button>

      <button
        @click="showAddPage = !showAddPage"
        data-testid="design-tab-add"
        class="px-3 py-1.5 rounded-md text-xs shrink-0"
        style="color: var(--semantic-text-dim);"
      >
        + Add Page
      </button>

      <input
        v-if="showAddPage"
        v-model="newPageName"
        @keyup.enter="addPage"
        @blur="showAddPage = false"
        class="px-2 py-1 rounded-md text-xs shrink-0"
        placeholder="Page name"
        style="
          background: var(--semantic-sidebar-bg);
          color: var(--semantic-text);
          border: 1px solid var(--color-border);
        "
      />

      <!-- Refresh button -->
      <button
        @click="refreshCanvas"
        :disabled="pageLoading || elementsLoading"
        data-testid="design-refresh"
        title="Refresh"
        class="ml-1 px-2 py-1.5 rounded-md text-xs shrink-0"
        style="color: var(--semantic-text-dim);"
      >
        ↻
      </button>

      <!-- Reset panzoom button -->
      <button
        @click="resetPanzoom"
        title="Reset zoom (1:1)"
        class="px-2 py-1.5 rounded-md text-xs shrink-0"
        style="color: var(--semantic-text-dim);"
      >
        1×
      </button>

      <div
        v-if="pageLoading || elementsLoading"
        class="ml-auto text-xs"
        style="color: var(--semantic-text-dim);"
      >loading…</div>

      <!-- Chat toggle (right-aligned; the highlighted box in the
           v1 screenshot). Disabled until chatReady (i.e., the
           existing-task lookup has resolved). Shows the current
           state via the icon + label. -->
      <button
        v-if="chatReady"
        @click="handleToggleChat"
        :disabled="chatLoading"
        :aria-pressed="showChat"
        data-testid="design-toggle-chat"
        :title="
          showChat
            ? 'Hide chat panel (task row is kept)'
            : chatTaskId
              ? 'Show chat panel'
              : 'Create + show chat panel'
        "
        class="ml-auto px-3 py-1.5 rounded-md text-xs flex items-center gap-1.5 shrink-0 transition-colors disabled:opacity-50"
        :style="
          showChat
            ? 'background: var(--semantic-active-bg); color: var(--semantic-text); border: 1px solid var(--color-border);'
            : 'color: var(--semantic-text-dim); border: 1px solid var(--color-border); background: transparent;'
        "
      >
        <span aria-hidden="true">{{ showChat ? '💬✓' : '💬' }}</span>
        {{ showChat ? 'Chat On' : 'Chat' }}
      </button>
    </div>

    <!-- Body: canvas + (optional) chat panel -->
    <div class="flex-1 min-h-0 flex">
      <!-- Pan/zoom canvas container. The inner `.design-canvas-inner`
           is the element panzoom wraps; positioning context for the
           elements. -->
      <div
        ref="canvasContainerRef"
        class="design-canvas-container bg-white overflow-hidden"
        :class="showChat ? 'flex-1 min-h-0 border-r' : 'flex-1 min-h-0 w-full'"
        :style="showChat ? 'border-color: var(--color-border)' : ''"
      >
        <template v-if="activePage">
          <div
            class="design-canvas-inner absolute top-0 left-0 origin-top-left"
            :data-testid="`design-page-canvas-${activePage.id}`"
            :style="{
              width: activePage.width + 'px',
              height: activePage.height + 'px',
              background: 'white',
            }"
          >
            <!-- Each element renders at (page.x + element.x, page.y + element.y) in
                 the page's CSS coordinate space, with element width × height. -->
            <div
              v-for="el in elements"
              :key="el.id"
              :data-testid="`design-element-${el.id}`"
              class="design-element absolute border border-slate-300 overflow-hidden"
              :style="{
                left: el.x + 'px',
                top: el.y + 'px',
                width: el.width + 'px',
                height: el.height + 'px',
                zIndex: el.z_index,
              }"
              @pointerdown.stop
              @dblclick="fetchElementFull(el.id)"
            >
              <!-- Drag handle (top strip; ~6px tall) — drag this to move.
                   Pointer events (mouse + touch + pen) with optimistic UI;
                   reverts on server PATCH failure. `data-no-panzoom` makes
                   panzoom skip pointerdown on this element. -->
              <div
                class="design-element-drag-handle flex items-center justify-between gap-1 px-1 cursor-move"
                style="height: 18px; background: rgba(0,0,0,0.05); font-size: 11px;"
                :data-no-panzoom="'true'"
                data-testid="design-element-drag-handle"
                @pointerdown="(ev) => onElementDragStart(ev, el)"
                @pointermove="onElementDragMove"
                @pointerup="onElementDragEnd"
                @pointercancel="onElementDragEnd"
              >
                <span class="truncate select-none">{{ el.name }}</span>
                <button
                  @click.stop="deleteElement(el.id)"
                  class="text-xs opacity-50 hover:opacity-100 px-0.5"
                  aria-label="Delete element"
                  data-testid="design-element-delete"
                >×</button>
              </div>

              <!-- Element body — shows the rendered html (lazy-fetched
                   on first render or after a server update). Falls
                   back to a placeholder while the GET is in flight so
                   the layout doesn't jiggle. `pointer-events: none` keeps
                   panzoom from blocking interactions here (panzoom
                   listens on the parent .design-canvas-inner). -->
              <div
                class="design-element-body relative"
                style="height: calc(100% - 18px);"
              >
                <div
                  v-if="elementFullById[el.id]"
                  class="absolute inset-0 pointer-events-none"
                  v-html="elementFullById[el.id]!.html"
                />
                <div
                  v-else
                  class="absolute inset-0 flex items-center justify-center pointer-events-none"
                  style="color: var(--semantic-text-dim); font-size: 11px;"
                >
                  double-click to load
                </div>
              </div>

              <!-- Resize handle (southeast corner). Pointer events for
                   mouse + touch + pen; same pattern as drag. -->
              <div
                class="design-element-resize-handle absolute right-0 bottom-0 cursor-se-resize"
                style="width: 12px; height: 12px; background: rgba(0,0,0,0.25);"
                :data-no-panzoom="'true'"
                data-testid="design-element-resize-handle"
                @pointerdown="(ev) => onElementResizeStart(ev, el)"
                @pointermove="onElementResizeMove"
                @pointerup="onElementResizeEnd"
                @pointercancel="onElementResizeEnd"
              />
            </div>
          </div>

          <!-- Add element inline form. Floats at the top-left corner
               of the canvas (above the elements). -->
          <div class="absolute top-2 left-2 z-50" style="background: rgba(255,255,255,0.95); border: 1px solid var(--color-border); border-radius: 6px; padding: 8px;">
            <button
              v-if="!showAddElement"
              @click="showAddElement = true"
              data-testid="design-add-element-toggle"
              class="px-3 py-1.5 rounded-md text-xs"
              style="background: var(--semantic-active-bg); color: var(--semantic-text);"
            >
              + Add Element
            </button>
            <form v-else @submit.prevent="addElement" class="flex flex-col gap-2" style="width: 280px;">
              <input
                v-model="newElementName"
                placeholder="Element name"
                class="px-2 py-1 rounded text-xs"
                style="border: 1px solid var(--color-border);"
                data-testid="design-add-element-name"
              />
              <textarea
                v-model="newElementHtml"
                placeholder='<div>...</div>'
                rows="4"
                class="px-2 py-1 rounded text-xs font-mono"
                style="border: 1px solid var(--color-border); resize: vertical;"
                data-testid="design-add-element-html"
              />
              <div class="flex justify-end gap-2">
                <button
                  type="button"
                  @click="showAddElement = false; newElementName = ''; newElementHtml = ''"
                  class="px-2 py-1 rounded text-xs"
                  style="color: var(--semantic-text-dim);"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  :disabled="!newElementName.trim() || !newElementHtml.trim()"
                  data-testid="design-add-element-submit"
                  class="px-2 py-1 rounded text-xs"
                  style="background: var(--semantic-active-bg); color: var(--semantic-text);"
                >
                  Add
                </button>
              </div>
            </form>
          </div>
        </template>
        <div
          v-else
          class="w-full h-full flex items-center justify-center"
          style="color: var(--semantic-text-dim); background: var(--semantic-sidebar-bg);"
        >
          <p v-if="pages.length === 0" class="text-sm">
            No pages yet. Click "+ Add Page" to create one.
          </p>
          <p v-else class="text-sm">Select a page tab to view it.</p>
        </div>
      </div>

      <!-- Chat panel — only mounted when the toggle is ON. Mirrors the
           v1 chunk-6 Kanban layout: canvas left, chat right, separated
           by a vertical border. The ChatView owns its own SSE
           connection + message rendering. -->
      <div
        v-if="showChat && chatTaskId"
        class="flex-1 min-h-0 border-l"
        style="background: var(--semantic-card-bg); border-color: var(--color-border);"
      >
        <ChatView
          :key="'design-chat-' + chatTaskId"
          :chat-id="chatTaskId"
          :chat-name="DESIGN_CHAT_TASK_NAME"
          type="task"
          show-header
          cwd=""
          style="height: 100%"
          @close="handleChatClose"
        />
      </div>
    </div>
  </div>
</template>

<style scoped>
/* Panzoom manipulates the .design-canvas-inner element via the
   `transform: matrix(...)` CSS property. We keep the parent
   `.design-canvas-container` as `position: relative` (so the inner
   is positioned absolute from it) and let panzoom's transform origin
   do the rest. The :deep() selector targets elements mounted inside
   <div v-html> (the element body) so panzoom's pointer-down on the
   outer .design-canvas-inner doesn't intercept child clicks (those
   have pointer-events: none for body anyway). */
.design-canvas-container {
  position: relative;
  /* Allow the inner canvas to extend beyond the container so the user
     can pan/zoom past the page's edges. */
  overflow: hidden;
  cursor: grab;
}
.design-canvas-inner {
  /* The transform comes from panzoom; we just set the box model. */
  box-shadow: 0 0 0 1px #e2e8f0;
}
.design-element {
  /* Live CSS transforms apply during drag/resize — the parent
     transforms back to identity on pointerup so the inline left/top
     values carry the committed geometry. */
  background: white;
}
.design-element-drag-handle {
  user-select: none;
  -webkit-user-select: none;
}
.design-element-resize-handle:hover {
  background: rgba(0, 0, 0, 0.4) !important;
}
/* The `pointer-events: none` on the body makes panzoom's drag-to-pan
   skip over the html content (the body is the largest click surface
   after the drag handle). The text inside is still selectable when
   the user double-clicks to open the element. */
.design-element-body :deep(*) {
  pointer-events: none;
}
</style>
