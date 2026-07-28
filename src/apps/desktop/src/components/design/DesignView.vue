<!--
  DesignView — top-level design canvas for a `item_type === 'design'`
  workspace item.

  Layout (top → bottom):
    1. <DesignPageTabs> — page tab strip
    2. Main split (horizontal):
       - Canvas (flex-1, on the left): renders <DesignElement v-for>
         over a fixed-size viewport (the page's width × height).
       - Right sidebar split (vertical):
         - <LayersPanel> on top
         - Resize handle (drag to resize)
         - <PropertiesPanel> on bottom
    3. Canvas header bar (inside the canvas, top): + Element button +
       active page name + element count.

  State (all local — no Pinia here, the parent AppLayout wires the
  store actions):
    pages           DesignPage[]   fetched on mount
    activePageId    string         defaults to first page
    elements        DesignElement[]  fetched on activePageId change
    selectedElementId  string | null
    rightSidebarWidth  number     persisted via localStorage

  On mount: fetch design pages via api.listDesignPages; default
  activePageId to the first page; fetch elements for that page via
  workspacesStore.fetchDesignElements.

  watch(activePageId): re-fetch elements for the new page.

  Canvas click on empty area clears selectedElementId. Escape keypress
  clears selectedElementId.

  Public API:
    props:
      item        WorkspaceItem    the parent design item
      workspaceId string            parent workspace id
      itemId      string            parent design item id (overrides item.id)
    emits:
      selectPage                          (tab change)
      selectElement, reorderElements      (layers)
      createElement, updateElement, deleteElement, htmlChanged  (mutations)
      openChat                            (top-right chat toggle)

  Page CRUD (add/delete) is OWNED by DesignView — the click handler
  calls the API directly and mutates `pages.value` so the tab strip
  updates without a re-fetch. This is the same pattern as the
  page-size resize handler (`commitPageSize` below) which also calls
  the API directly + mutates `pages.value`. The previous design
  bounced addPage/deletePage through AppLayout's handlers, which
  called the API but never told DesignView to refresh — leaving the
  user staring at stale tabs until they reloaded the page.
-->
<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import DesignPageTabs from './DesignPageTabs.vue'
import DesignElement from './DesignElement.vue'
import LayersPanel from './LayersPanel.vue'
import PropertiesPanel from './PropertiesPanel.vue'
import AddDesignElementDialog from './AddDesignElementDialog.vue'
import { useWorkspacesStore, type WorkspaceItem } from '../../stores/workspaces'
import { useNotificationStore } from '../../stores/notifications'
import { useDesignHandlers } from '../../composables/useDesignHandlers'
import {
  listDesignPages,
  createDesignPage as createDesignPageApi,
  deleteDesignPage as deleteDesignPageApi,
  type DesignElement as DesignElementApi,
} from '../../api'
import { computeSnapDelta, type SnapGuide } from './useSnapGuides'

const props = withDefaults(
  defineProps<{
    item: WorkspaceItem
    workspaceId?: string
    itemId?: string
  }>(),
  {
    workspaceId: '',
    itemId: '',
  },
)

const emit = defineEmits<{
  selectPage: [pageId: string]
  selectElement: [elementId: string]
  reorderElements: [orderedElementIds: string[]]
  createElement: [body: { name: string; type: DesignElementApi['type']; html: string }]
  updateElement: [elementId: string, patch: Partial<DesignElementApi>]
  deleteElement: [elementId: string]
  htmlChanged: [elementId: string, html: string]
  // NEW: top-right chat toggle. AppLayout finds or creates a
  // "Design Chat" task on this design item and sets it as the
  // active task so the existing 3-column layout (DesignView |
  // resize-handle | ChatView) renders alongside the canvas.
  // Plan: docs/superpowers/plans/2026-06-13-design-mode.md
  // (chat integration, added 2026-07-14 after user feedback).
  //
  // 2026-07-28 per-page scoping (plan:
  // docs/superpowers/plans/2026-07-28-design-per-page-chat-sessions.md):
  // the emit now carries the active page's {pageId, pageName} so
  // AppLayout can look up the chat task for THIS page only.
  // Empty values (page not loaded yet) → AppLayout short-circuits
  // and does NOT create a chat task with an empty name.
  openChat: [payload: { pageId: string; pageName: string }]
}>()

const workspacesStore = useWorkspacesStore()

// ─── Effective ids ─────────────────────────────────────────────────────

const effectiveItemId = computed(() => props.itemId || props.item.id)

// ─── Pages state ───────────────────────────────────────────────────────

const pages = ref<import('../../api').DesignPage[]>([])
const activePageId = ref('')
const pagesLoading = ref(false)
const pagesError = ref<string | null>(null)

const activePage = computed(() =>
  pages.value.find((p) => p.id === activePageId.value) ?? null,
)

// ─── Elements state (mirrors item.design_elements) ─────────────────────

const elements = computed<DesignElementApi[]>(() => {
  // The store's `design_elements` array is the source of truth (other
  // tabs / SSE events update it). When it doesn't match the active
  // page id (because the user just switched pages), fall back to [].
  const stored = props.item.design_elements ?? []
  return stored.filter((e) => e.page_id === activePageId.value)
})

// ─── Selection state ───────────────────────────────────────────────────
//
// Multi-select (Figma model). Empty Set = nothing selected. Plain
// click = exclusive select (replaces the selection); Shift+click =
// toggle membership (adds/removes without affecting the rest); Escape
// = clear all. The PropertiesPanel and LayersPanel use the same Set so
// the right rail stays in sync with the canvas outline.
const selectedIds = ref<Set<string>>(new Set())

// Per-element nudge offset accumulator. The keyboard handler reads
// `el.x + offset[id].x` instead of `el.x` so consecutive ArrowLeft
// presses compose (the second press starts where the first one ended).
// `updateDesignElementGeometry` is a fire-and-forget PATCH that does
// NOT mirror the response back into `elements.value` (see the
// performance comment in stores/workspaces.ts around the function),
// so without this accumulator the element would only move on the
// FIRST press and stay frozen on every subsequent press.
//
// Reset on page change (different elements scope).
const nudgeOffsets = new Map<string, { x: number; y: number }>()

const activeElements = computed<DesignElementApi[]>(() => {
  return elements.value.filter((e) => selectedIds.value.has(e.id))
})

const isSingleSelect = computed(() => selectedIds.value.size === 1)
// PropertiesPanel only renders its single-element form when exactly one
// element is selected. Otherwise it shows a "N elements selected" banner
// (multi-aware) or the empty state.
const activeElement = computed<DesignElementApi | null>(() =>
  isSingleSelect.value ? activeElements.value[0] ?? null : null,
)

// NEW (Chunk 6 of grouped-layers plan): useDesignHandlers composable
// providing `groupSelection` for the Cmd+G shortcut. We pass the
// args this component owns (`selectedIds` is local; the ids come
// from props + activePageId). AppLayout uses a SEPARATE
// `useDesignHandlers()` invocation (no args) for updateElement /
// deleteElement — those handlers re-read activeDesignPageId from
// the store on each call so they don't need DesignView-local refs.
const designHandlers = useDesignHandlers({
  workspaceId: computed(() => props.workspaceId),
  itemId: computed(() => effectiveItemId.value),
  pageId: computed(() => activePageId.value),
  selectedIds,
})

// ─── Snap guides state ────────────────────────────────────────────────
//
// While a drag is in progress, snap math (computeSnapDelta) emits the
// 1px violet alignment guides the user should see. Rendered as an
// SVG overlay INSIDE the canvas div (above the elements but below the
// resize handles). Cleared on drag-end (DesignElement emits `dragEnd`
// on pointerup; the parent listens via @drag-end on the canvas's
// <DesignElement> invocation).
const snapGuides = ref<SnapGuide[]>([])

// ─── Preview/Edit mode ──────────────────────────────────────────────────
//
// When `isPreviewMode === true`, each element's iframe gets
// `pointer-events: auto` (so the user can type into inputs / click
// buttons inside the rendered HTML) and the edit chrome (resize
// handles, selection outline, drag handler) is suppressed. State is
// transient — no localStorage, no backend roundtrip — a "play the
// mockup" affordance. Default false.
//
// Keyboard:
//   - Cmd/Ctrl+P: toggle Preview ↔ Edit
//   - Esc: exit Preview (return to Edit)
const isPreviewMode = ref<boolean>(false)

const togglePreviewMode = (): void => {
  isPreviewMode.value = !isPreviewMode.value
}
const exitPreviewMode = (): void => {
  if (isPreviewMode.value) isPreviewMode.value = false
}

// Exiting Preview mode clears the selection so the user isn't surprised
// by a now-visible resize handle on an element they didn't pick during
// preview. Doing this in a watcher keeps the prop drill minimal — we
// only need to react to the toggle, not poll for it.
watch(isPreviewMode, (now) => {
  if (!now) selectedIds.value = new Set()
})

// ─── Right sidebar width (drag-resize handle) ──────────────────────────

const SIDEBAR_WIDTH_KEY = 'design-view-sidebar-width'
const SIDEBAR_DEFAULT_WIDTH = 320
const SIDEBAR_MIN_WIDTH = 220
const SIDEBAR_MAX_WIDTH = 600

const loadSidebarWidth = (): number => {
  try {
    const raw = localStorage.getItem(SIDEBAR_WIDTH_KEY)
    if (!raw) return SIDEBAR_DEFAULT_WIDTH
    const n = Number(raw)
    if (!Number.isFinite(n)) return SIDEBAR_DEFAULT_WIDTH
    return Math.max(SIDEBAR_MIN_WIDTH, Math.min(SIDEBAR_MAX_WIDTH, n))
  } catch {
    return SIDEBAR_DEFAULT_WIDTH
  }
}
const saveSidebarWidth = (n: number): void => {
  try {
    localStorage.setItem(SIDEBAR_WIDTH_KEY, String(n))
  } catch {
    /* no-op — localStorage may be disabled */
  }
}

const sidebarWidth = ref<number>(loadSidebarWidth())
const isSidebarResizing = ref(false)

const startSidebarResize = (event: MouseEvent): void => {
  event.preventDefault()
  const startX = event.clientX
  const startWidth = sidebarWidth.value
  isSidebarResizing.value = true
  document.body.style.cursor = 'col-resize'
  document.body.style.userSelect = 'none'

  const onMove = (e: MouseEvent): void => {
    const dx = startX - e.clientX
    const next = Math.max(
      SIDEBAR_MIN_WIDTH,
      Math.min(SIDEBAR_MAX_WIDTH, startWidth + dx),
    )
    sidebarWidth.value = next
  }
  const onUp = (): void => {
    isSidebarResizing.value = false
    document.body.style.cursor = ''
    document.body.style.userSelect = ''
    saveSidebarWidth(sidebarWidth.value)
    document.removeEventListener('mousemove', onMove)
    document.removeEventListener('mouseup', onUp)
  }
  document.addEventListener('mousemove', onMove)
  document.addEventListener('mouseup', onUp)
}

// ─── Vertical split between Layers and Properties (within sidebar) ─────

const LAYERS_HEIGHT_KEY = 'design-view-layers-height'
const LAYERS_DEFAULT_HEIGHT_RATIO = 0.4

const loadLayersHeightRatio = (): number => {
  try {
    const raw = localStorage.getItem(LAYERS_HEIGHT_KEY)
    if (!raw) return LAYERS_DEFAULT_HEIGHT_RATIO
    const n = Number(raw)
    if (!Number.isFinite(n)) return LAYERS_DEFAULT_HEIGHT_RATIO
    return Math.max(0.15, Math.min(0.7, n))
  } catch {
    return LAYERS_DEFAULT_HEIGHT_RATIO
  }
}
const saveLayersHeightRatio = (n: number): void => {
  try {
    localStorage.setItem(LAYERS_HEIGHT_KEY, String(n))
  } catch {
    /* no-op */
  }
}

const layersHeightRatio = ref<number>(loadLayersHeightRatio())
const isLayersResizing = ref(false)

const startLayersResize = (event: MouseEvent): void => {
  event.preventDefault()
  const sidebarEl = (event.currentTarget as HTMLElement | null)?.parentElement
  if (!sidebarEl) return
  const startY = event.clientY
  const startRatio = layersHeightRatio.value
  const sidebarHeight = sidebarEl.getBoundingClientRect().height
  isLayersResizing.value = true
  document.body.style.cursor = 'row-resize'
  document.body.style.userSelect = 'none'

  const onMove = (e: MouseEvent): void => {
    const dy = e.clientY - startY
    const ratio = startRatio + dy / sidebarHeight
    layersHeightRatio.value = Math.max(0.15, Math.min(0.7, ratio))
  }
  const onUp = (): void => {
    isLayersResizing.value = false
    document.body.style.cursor = ''
    document.body.style.userSelect = ''
    saveLayersHeightRatio(layersHeightRatio.value)
    document.removeEventListener('mousemove', onMove)
    document.removeEventListener('mouseup', onUp)
  }
  document.addEventListener('mousemove', onMove)
  document.addEventListener('mouseup', onUp)
}

// ─── Add element dialog state ──────────────────────────────────────────

const showAddElementDialog = ref(false)
const openAddElementDialog = (): void => {
  showAddElementDialog.value = true
}

// ─── Lifecycle: fetch pages on mount ──────────────────────────────────

const loadPages = async (): Promise<void> => {
  if (!props.workspaceId || !effectiveItemId.value) return
  pagesLoading.value = true
  pagesError.value = null
  try {
    const { pages: fetched } = await listDesignPages(
      props.workspaceId,
      effectiveItemId.value,
    )
    pages.value = fetched
    // Pick the active page in this priority:
    //   1. The store's activeDesignPageId (set by AppLayout's URL restore
    //      watcher when the page reloads with ?pageId=Z) — wins over
    //      the local activePageId so the reload restores the user's
    //      last-clicked tab even if the component instance is fresh.
    //   2. The local activePageId (preserved across re-renders within
    //      the same item switch via the watch below).
    //   3. The first fetched page (default for new users).
    const storePageId = workspacesStore.activeDesignPageId
    if (
      storePageId &&
      fetched.some((p) => p.id === storePageId) &&
      storePageId !== activePageId.value
    ) {
      activePageId.value = storePageId
    } else if (
      !activePageId.value ||
      !fetched.some((p) => p.id === activePageId.value)
    ) {
      activePageId.value = fetched[0]?.id ?? ''
    }
  } catch (err) {
    pagesError.value = err instanceof Error ? err.message : String(err)
    pages.value = []
    activePageId.value = ''
  } finally {
    pagesLoading.value = false
  }
}

onMounted(() => {
  void loadPages()
})

watch(
  () => [props.workspaceId, effectiveItemId.value] as const,
  () => {
    void loadPages()
  },
)

// watch(activePageId) → fetch elements for the new page (mirrors
// KanbanView's loadColumns pattern).
watch(activePageId, (pageId) => {
  // Mirror to the store FIRST so AppLayout's design handlers
  // (handleDesignUpdateElement / handleDesignDeleteElement) always
  // see the latest selection, even if the early-return below fires
  // (no item, no workspace, empty page). The store ref starts at ''
  // and clears in onUnmounted (below).
  workspacesStore.setActiveDesignPage(pageId ?? '')
  selectedIds.value = new Set()
  // Nudge offsets are per-element; fresh page means every cached
  // offset is for an element that no longer exists.
  nudgeOffsets.clear()
  if (!pageId) return
  if (!props.workspaceId || !effectiveItemId.value) return
  void workspacesStore.fetchDesignElements(
    props.workspaceId,
    effectiveItemId.value,
    pageId,
  )
})

// ─── Keyboard shortcuts ────────────────────────────────────────────────

// True while the user is holding the Space bar. Drives the body's
// cursor (grab / grabbing) and gates the pointer-drag pan handler
// on the canvas container.
const isSpacePressed = ref(false)

const handleKeydown = (event: KeyboardEvent): void => {
  // Skip when the user is typing in an input/textarea/contenteditable
  // — don't steal keys from the W×H inputs, the PropertiesPanel
  // form fields, etc.
  const target = event.target as HTMLElement | null
  if (
    target &&
    (target.tagName === 'INPUT' ||
      target.tagName === 'TEXTAREA' ||
      target.isContentEditable)
  ) {
    return
  }

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
    // Esc exits Preview first (more useful than clearing selection
    // — the user is trying to get back to editing). Only clear the
    // selection if we're already in Edit mode.
    if (isPreviewMode.value) {
      isPreviewMode.value = false
      return
    }
    selectedIds.value = new Set()
    // Also close the add-element dialog if it's open.
    if (showAddElementDialog.value) {
      showAddElementDialog.value = false
    }
    return
  }

  // Cmd/Ctrl+P toggles Preview/Edit mode. Plain P (no modifier) is a
  // common type-to-pan shortcut in design tools — not used here, but
  // we intentionally don't bind it so the future pan-tool doesn't
  // conflict. Cmd+P conflicts with browser Print on some platforms;
  // users can use the toolbar button as a fallback.
  if (
    (event.key === 'p' || event.key === 'P') &&
    (event.ctrlKey || event.metaKey) &&
    !event.shiftKey &&
    !event.altKey
  ) {
    event.preventDefault()
    togglePreviewMode()
    return
  }

  // NEW (Chunk 6 of grouped-layers plan): Cmd/Ctrl+G groups the
  // current selection into a new `group` at the union bbox. Figma
  // convention. The composable enforces the 2+ selection rule
  // silently (mirrors Figma's Cmd+G). Cmd+Shift+G is reserved for
  // the deferred Chunk 9 "ungroup" feature — bound to a no-op for
  // now so the future handler isn't accidentally consumed by
  // browser/OS shortcuts.
  if (
    (event.key === 'g' || event.key === 'G') &&
    (event.ctrlKey || event.metaKey) &&
    !event.altKey
  ) {
    event.preventDefault()
    if (event.shiftKey) {
      // TODO: implement ungroupSelection in Chunk 9 of the
      // grouped-layers plan. For now: silent no-op so users don't
      // get a silent failure if they try it.
      return
    }
    void designHandlers.groupSelection()
    return
  }

  // Fit-to-viewport shortcuts — F (Figma convention) or Shift+1.
  // Both ignored when modifier keys (Ctrl/Cmd/Alt) are held to avoid
  // colliding with browser / OS shortcuts.
  if (
    (event.key === 'f' || event.key === 'F' || (event.key === '1' && event.shiftKey)) &&
    !event.ctrlKey &&
    !event.metaKey &&
    !event.altKey
  ) {
    event.preventDefault()
    zoomFit()
  }

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
      // The element's "effective" position is the cached `el.x`
      // plus the accumulated nudge delta (since the last time
      // `elements.value` was fresh). Without this, the second
      // arrow press would read the stale `el.x` and re-emit
      // the same x, freezing the element.
      const off = nudgeOffsets.get(id) ?? { x: 0, y: 0 }
      const baseX = el.x + off.x
      const baseY = el.y + off.y
      // Clamp so the element stays visible on the canvas. We
      // allow a 10px sliver off-canvas (matches the resize min
      // size — partial overlap is fine, but the element must
      // not disappear entirely).
      let ndx = dx
      let ndy = dy
      if (baseX + ndx < -el.width + 10) ndx = -el.width + 10 - baseX
      if (baseX + ndx > canvasWidth.value - 10) ndx = canvasWidth.value - 10 - baseX
      if (baseY + ndy < -el.height + 10) ndy = -el.height + 10 - baseY
      if (baseY + ndy > canvasHeight.value - 10) ndy = canvasHeight.value - 10 - baseY
      const newX = baseX + ndx
      const newY = baseY + ndy
      nudgeOffsets.set(id, { x: newX - el.x, y: newY - el.y })
      void workspacesStore.updateDesignElementGeometry(
        props.workspaceId,
        effectiveItemId.value,
        activePageId.value,
        id,
        { x: newX, y: newY },
      )
    }
    return
  }
}

const handleKeyup = (event: KeyboardEvent): void => {
  // Release Space. Don't gate on target — if focus moved to an input
  // mid-press, we still want to clear the body cursor on Space-up.
  if (event.key === ' ' && isSpacePressed.value) {
    isSpacePressed.value = false
    document.body.style.cursor = ''
  }
}

const handleWindowBlur = (): void => {
  // Defensive: if focus is lost (window blur / tab switch) while
  // Space is held, the keyup event may never fire. Reset so we
  // don't leave the cursor stuck on "grab".
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
  // NOTE: we intentionally do NOT clear `activeDesignPageId` here.
  //
  // Why: AppLayout's main-content v-else-if chain renders TWO
  // <DesignView> instances for the same design item — one in the
  // single-column branch (no chat open) and one inside the
  // 3-column branch (chat open). Both use the same
  // `:key="'design-' + activeWorkspaceItem.id"`, but Vue treats them
  // as distinct components because they're at different v-else-if
  // positions. Toggling the 💬 chat button swaps branches and
  // triggers an unmount → mount cycle on every chat toggle.
  //
  // Pre-fix behavior: the unmount hook cleared `activeDesignPageId`
  // to ''. The freshly-mounted DesignView then ran `loadPages()`,
  // saw the empty store value, and fell back to `fetched[0]?.id` —
  // the FIRST page. Result: clicking 💬 while on (say) "Kanban
  // Mode" visually jumped back to "AI Chat View", the first tab.
  //
  // The clear was originally added (Task 1.2 of design-element-
  // drag-and-drop) to defend against `useDesignHandlers` routing
  // PATCH/PUT/DELETE to a stale page after navigating away from
  // the design view. But `useDesignHandlers` only fires from
  // DesignView's own mutations — when no DesignView is mounted, no
  // patch can be triggered, so the stale value is harmless. And
  // cross-item navigation is already handled correctly inside
  // `loadPages()`: if the store page id doesn't match any page in
  // the freshly-fetched list, the second branch defaults to
  // `fetched[0]?.id` (the new item's first page).
  //
  // Leaving the value alone is strictly an improvement: the chat
  // toggle now preserves the user's last-clicked tab, AND
  // navigating away and back to the same design item restores the
  // last-clicked tab instead of resetting to the first page.
})

// ─── Handlers ──────────────────────────────────────────────────────────

const handleCanvasClick = (event: MouseEvent): void => {
  // In Preview mode, canvas clicks are user-typed values inside
  // iframes or pan gestures — neither should clear the selection.
  // The iframes' `pointer-events: auto` (set in DesignElement.vue
  // for Preview) means clicks on element bodies never reach this
  // handler anyway, but we guard the canvas-background case too so
  // panning doesn't deselect during a Preview session.
  if (isPreviewMode.value) return
  // If we just finished a pan-drag (Space + drag), swallow the
  // click so it doesn't deselect the active element. The browser
  // dispatches a synthetic click after pointerup; without this
  // guard, every pan ends with selection-clear.
  if (isPanning.value) return
  // Only clear selection when clicking the canvas itself (not an
  // element child). The DesignElement child events fire before this
  // and they stopPropagation on their pointerdown — so this handler
  // is only called for the canvas background.
  if ((event.target as HTMLElement | null)?.closest('[data-design-element]')) {
    return
  }
  selectedIds.value = new Set()
}

// True while the user is mid-drag with Space held. Gates the
// canvas-click deselection guard above.
const isPanning = ref(false)

// Pointer-drag pan. Fires on the canvas scroll container; only
// does anything when Space is held. Mutates scrollLeft / scrollTop
// directly (NOT a CSS transform — the inner div already has
// `transform: scale()` and combining the two would compound).
// setPointerCapture ensures move events keep firing even if the
// pointer leaves the container mid-drag.
const startCanvasPan = (event: PointerEvent): void => {
  if (!isSpacePressed.value) return
  // Primary button only — middle / right clicks do different things
  // (autoscroll, context menu) on some browsers.
  if (event.button !== 0) return
  const target = event.currentTarget as HTMLElement | null
  if (!target) return
  target.setPointerCapture(event.pointerId)
  isPanning.value = true
  document.body.style.cursor = 'grabbing'

  // Snapshot the scroll position + pointer position at drag start.
  // The move handler subtracts the cursor delta from the original
  // scroll position so the canvas appears to follow the cursor.
  const startScrollLeft = target.scrollLeft
  const startScrollTop = target.scrollTop
  const startClientX = event.clientX
  const startClientY = event.clientY

  const onMove = (e: PointerEvent): void => {
    // cursor delta in screen-px = scroll delta in scroll-px
    // (no zoom division needed — scrollLeft / scrollTop are in
    // unscaled coords; the inner div's scale() does not affect them).
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

// NEW: chat-toggle click handler (top-right 💬 button in the
// canvas header bar). Emits the openChat event upward with the
// active page's {pageId, pageName} — AppLayout (the only
// listener) finds or creates the per-page chat task
// (named "Design Chat: <pageName>") and switches to the
// 3-column layout. The button itself has no local state; the
// chat panel's visibility is owned by AppLayout (it shows when
// activeTaskId is set for this design item, hides when
// activeTaskId is cleared).
//
// 2026-07-28 per-page scoping: the active page drives the chat
// lookup. When `activePage.value` is null (pages not loaded yet
// or no page selected), we emit empty values and AppLayout will
// short-circuit — better to skip than to create a chat task
// with an empty name that would orphan future migrations.
const handleOpenChat = (): void => {
  const page = activePage.value
  emit('openChat', {
    pageId: page?.id ?? '',
    pageName: page?.name ?? '',
  })
}

// Compute the next available placeholder name for a new design
// page. Mirrors the macOS / Figma convention: the very first
// untitled page is `"Untitled"` (no suffix), every subsequent one is
// `"Untitled N"` where `N` is `max(existing numbers) + 1`.
//
// Why high-water-mark + 1 and NOT "smallest unused slot"? If the
// user already has pages named "Untitled 5" and "Untitled 9",
// picking "Untitled 1" would feel arbitrary and out of sequence
// when they scan the tab strip — they'd expect the next number to
// be 10, not 1. macOS Finder behaves the same way: opening
// multiple new documents produces "Untitled", "Untitled 2",
// "Untitled 3" (skipping 1) when 1 is already taken by an older
// session.
//
// The `UNIQUE(workspace_item_id, name)` constraint on `design_pages`
// means we MUST never collide with an existing name. Tracking the
// unnumbered `"Untitled"` separately is necessary because that
// row occupies "slot 0" — if we ignored it, a second click would
// try to POST another `"Untitled"` and the backend would 409.
const UNTITLEDBASE_NAME = 'Untitled'
const UNTITLEDPATTERN = /^Untitled (\d+)$/
const computeNextUntitledName = (
  existingPages: ReadonlyArray<{ name: string }>,
): string => {
  let hasUnnumbered = false
  let maxNumbered = 0
  for (const p of existingPages) {
    if (p.name === UNTITLEDBASE_NAME) {
      hasUnnumbered = true
      continue
    }
    const match = UNTITLEDPATTERN.exec(p.name)
    if (match && match[1]) {
      const n = Number.parseInt(match[1], 10)
      if (Number.isFinite(n) && n > 0 && n > maxNumbered) {
        maxNumbered = n
      }
    }
  }
  // Very first page: no unnumbered, no numbered → "Untitled".
  // Everything else: take maxNumbered + 1. If only an unnumbered
  // "Untitled" exists (maxNumbered === 0), return "Untitled 1"
  // because we can't collide with the existing literal.
  if (!hasUnnumbered && maxNumbered === 0) return UNTITLEDBASE_NAME
  return `${UNTITLEDBASE_NAME} ${maxNumbered + 1}`
}

// Add a new design page.
//
// Owns the API call + local state mutation directly (NOT a bounce
// through AppLayout). The previous design emitted `addPage` upward,
// AppLayout called api.createDesignPage, and DesignView's local
// `pages.value` was never updated — the new tab silently didn't
// appear until the user refreshed the page. Same fix pattern as
// `commitPageSize` below: call the API, mutate the local array,
// surface errors via the notification store.
//
// Returns the new page id for test convenience.
const handleAddPage = async (): Promise<string | undefined> => {
  if (!props.workspaceId || !effectiveItemId.value) return undefined
  if (addPageInFlight.value) return undefined
  addPageInFlight.value = true
  try {
    const newPage = await createDesignPageApi(
      props.workspaceId,
      effectiveItemId.value,
      computeNextUntitledName(pages.value),
    )
    pages.value = [...pages.value, newPage]
    // New page becomes active so the user immediately sees the empty
    // canvas they can start populating.
    activePageId.value = newPage.id
    return newPage.id
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    useNotificationStore().notifyError('Failed to add page', message)
    return undefined
  } finally {
    addPageInFlight.value = false
  }
}

// In-flight guard for the + Page button. Prevents a double-click from
// POSTing two duplicate pages back-to-back while the first request is
// still in flight. The disabled state is exposed via the + Page
// button's `:disabled` attribute so the user sees the lock.
const addPageInFlight = ref<boolean>(false)

const handleSelectPage = (pageId: string): void => {
  if (pageId !== activePageId.value) {
    activePageId.value = pageId
  }
  emit('selectPage', pageId)
}

// Delete a design page.
//
// Owns the API call + local state mutation directly (NOT a bounce
// through AppLayout). The previous design emitted `deletePage`
// upward, AppLayout called api.deleteDesignPage, and DesignView's
// local `pages.value` was never updated — the deleted tab silently
// stayed in place until the user refreshed the page.
//
// Active-page fallback: if the user deletes the page they're
// currently viewing, switch to a sensible next page. We pick the
// page BEFORE the deleted one in the current order; if there is no
// such page, fall back to the new first page; if there are no pages
// left, leave `activePageId` empty (the empty-state UI handles
// this). Native `confirm()` dialog matches the existing
// deleteElement flow in `useDesignHandlers.ts`.
const handleDeletePage = async (pageId: string): Promise<void> => {
  if (!props.workspaceId || !effectiveItemId.value) return
  if (deletePageInFlight.value) return
  if (
    !confirm(
      'Delete this page? This removes the page, its elements, and their on-disk HTML files.',
    )
  ) {
    return
  }
  deletePageInFlight.value = true
  const wasActive = activePageId.value === pageId
  try {
    await deleteDesignPageApi(
      props.workspaceId,
      effectiveItemId.value,
      pageId,
    )
    const idx = pages.value.findIndex((p) => p.id === pageId)
    pages.value = pages.value.filter((p) => p.id !== pageId)
    if (wasActive) {
      // Prefer the page that was at the same index before deletion
      // (i.e. the next page in the old order), falling back to the
      // previous page if we deleted the last tab. This mirrors how
      // VS Code / Figma behave when closing a tab.
      const remaining = pages.value
      if (remaining.length === 0) {
        activePageId.value = ''
      } else {
        const nextIdx = idx >= remaining.length ? remaining.length - 1 : idx
        activePageId.value = remaining[nextIdx]?.id ?? ''
      }
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    useNotificationStore().notifyError('Failed to delete page', message)
  } finally {
    deletePageInFlight.value = false
  }
}

// In-flight guard for the per-page × button. Prevents a double-click
// from issuing two DELETE calls back-to-back while the first is in
// flight (which could fire two confirm dialogs in quick succession
// and confuse the user).
const deletePageInFlight = ref<boolean>(false)

// Figma-style multi-select toggle. Plain click (additive=false)
// replaces the selection with just this element. Shift+click
// (additive=true) adds or removes membership without disturbing the
// rest of the selection.
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

// Keep the legacy handler name around as an alias so LayersPanel's
// `@select="handleElementSelect"` (which emits a plain elementId with
// no additive flag) still works — LayersPanel gets the additive flag
// from the Shift state on the row click and emits a structured
// payload instead.
const handleElementSelect = (elementId: string): void => {
  handleElementToggle(elementId, false)
}

const handleElementUpdate = (patch: Partial<DesignElementApi>): void => {
  if (selectedIds.value.size === 0) return
  // When multiple elements are selected, apply the patch to every one
  // of them (Figma semantics — editing the X/Y in the PropertiesPanel
  // moves the whole selection together).
  if (selectedIds.value.size === 1) {
    const id = selectedIds.value.values().next().value as string
    emit('updateElement', id, patch)
    return
  }
  for (const id of selectedIds.value) {
    emit('updateElement', id, patch)
  }
}

const handleElementHtmlChanged = (html: string): void => {
  if (selectedIds.value.size !== 1) return
  // HTML body editing only applies to a single selected element —
  // there's no sensible "merge HTML across 3 elements" semantic.
  const id = selectedIds.value.values().next().value as string
  emit('htmlChanged', id, html)
}

const handleElementDelete = (elementId: string): void => {
  emit('deleteElement', elementId)
  // Remove the deleted id from the selection Set (don't clear the
  // whole selection — if the user multi-selected and deleted one,
  // the others should remain selected for further action).
  if (selectedIds.value.has(elementId)) {
    const next = new Set(selectedIds.value)
    next.delete(elementId)
    selectedIds.value = next
  }
}

const handleReorderElements = (orderedElementIds: string[]): void => {
  emit('reorderElements', orderedElementIds)
}

// LayersPanel emits a structured payload so Shift+click can be
// distinguished from a plain click. Both call into handleElementToggle.
const handleLayerSelect = (payload: { elementId: string; additive: boolean }): void => {
  handleElementToggle(payload.elementId, payload.additive)
}

// Chunk 2: group drag. When the user drags any element that's part of
// a multi-selection, DesignElement emits `groupDrag` with the cursor
// delta (design-px, zoom-adjusted). We translate that into N individual
// `updateDesignElementGeometry` calls — one per selected id — using
// the LOCAL element list as the source of truth (it's already filtered
// to the active page, so no need to re-query).
//
// The direct-store path bypasses the AppLayout round-trip on purpose:
// a 3-element drag would otherwise generate 3 emits per pointermove ×
// the store's throttle. Direct calls keep latency at one round-trip
// per 50ms for the WHOLE selection.
const handleGroupDrag = (delta: { dx: number; dy: number }): void => {
  if (selectedIds.value.size === 0) return
  if (!props.workspaceId || !effectiveItemId.value) return
  if (!activePageId.value) return
  const pageId = activePageId.value
  const itemId = effectiveItemId.value
  const workspaceId = props.workspaceId

  // ─── Snap (Chunk 3) ───────────────────────────────────────────────
  // Compute the union bbox of the selection at the cursor's current
  // position. computeSnapDelta treats the union as a single moving
  // bbox; elements NOT in the selection are the snap targets.
  // The function returns the snap correction + the guides to render.
  const selected = elements.value.filter((e) => selectedIds.value.has(e.id))
  if (selected.length > 0) {
    const minX = Math.min(...selected.map((e) => e.x + delta.dx))
    const minY = Math.min(...selected.map((e) => e.y + delta.dy))
    const maxX = Math.max(...selected.map((e) => e.x + delta.dx + e.width))
    const maxY = Math.max(...selected.map((e) => e.y + delta.dy + e.height))
    const unionBbox = {
      id: '__union__',
      x: minX,
      y: minY,
      width: maxX - minX,
      height: maxY - minY,
    }
    const others = elements.value.filter((e) => !selectedIds.value.has(e.id))
    const snapResult = computeSnapDelta(
      [unionBbox, ...others],
      '__union__',
      0,
      0,
      { width: canvasWidth.value, height: canvasHeight.value },
    )
    snapGuides.value = snapResult.guides
    const finalDx = delta.dx + snapResult.dx
    const finalDy = delta.dy + snapResult.dy
    // Clamp so elements can't be dragged entirely off-canvas. Allow
    // a 10px sliver off-canvas (matches the resize min size) but
    // prevent the element from disappearing entirely.
    const clampX = (el: typeof selected[number], dx: number): number => {
      const newX = el.x + dx
      if (newX < -el.width + 10) return -el.width + 10 - el.x
      if (newX > canvasWidth.value - 10) return canvasWidth.value - 10 - el.x
      return dx
    }
    const clampY = (el: typeof selected[number], dy: number): number => {
      const newY = el.y + dy
      if (newY < -el.height + 10) return -el.height + 10 - el.y
      if (newY > canvasHeight.value - 10) return canvasHeight.value - 10 - el.y
      return dy
    }
    for (const el of selected) {
      const clampedDx = clampX(el, finalDx)
      const clampedDy = clampY(el, finalDy)
      void workspacesStore.updateDesignElementGeometry(
        workspaceId,
        itemId,
        pageId,
        el.id,
        {
          x: Math.round(el.x + clampedDx),
          y: Math.round(el.y + clampedDy),
        },
      )
    }
    return
  }

  // No selection (shouldn't normally reach here given the size check
  // above, but defensive).
  for (const id of selectedIds.value) {
    const el = elements.value.find((e) => e.id === id)
    if (!el) continue
    void workspacesStore.updateDesignElementGeometry(
      workspaceId,
      itemId,
      pageId,
      id,
      {
        x: Math.round(el.x + delta.dx),
        y: Math.round(el.y + delta.dy),
      },
    )
  }
}

// Clear snap guides when the drag ends. DesignElement emits `dragEnd`
// on pointerup; we listen via @drag-end on each <DesignElement>. This
// is a no-op if no drag is in flight.
const clearSnapGuides = (): void => {
  snapGuides.value = []
}

const handleCreateElement = (
  body: { name: string; type: DesignElementApi['type']; html: string },
): void => {
  emit('createElement', body)
}

const handlePropertiesDelete = (elementId: string): void => {
  handleElementDelete(elementId)
}

const handlePropertiesUpdate = (patch: Partial<DesignElementApi>): void => {
  handleElementUpdate(patch)
}

const handlePropertiesHtmlChanged = (html: string): void => {
  handleElementHtmlChanged(html)
}

// ─── Canvas viewport size (from active page) ───────────────────────────

const canvasWidth = computed(() => activePage.value?.width ?? 1440)
const canvasHeight = computed(() => activePage.value?.height ?? 1024)

// ─── Zoom (transform: scale on the canvas wrapper) ────────────────────
//
// Pure-view state; doesn't change page dimensions or element
// positions. Persists per design item in localStorage so a user
// who zooms to 75% on one design item doesn't affect another item.
// Range 0.1× to 4.0× covers everything from "see the whole page when
// it overflows" to "pixel-peep the navbar".
const ZOOM_KEY_PREFIX = 'design-view-zoom-'
const ZOOM_DEFAULT = 1.0
const ZOOM_MIN = 0.1
const ZOOM_MAX = 4.0
const ZOOM_STEP = 0.1        // each toolbar button click
const ZOOM_WHEEL_STEP = 0.05 // each Ctrl+wheel notch (Shift = ×4)

const loadZoom = (itemId: string): number => {
  try {
    const raw = localStorage.getItem(ZOOM_KEY_PREFIX + itemId)
    if (!raw) return ZOOM_DEFAULT
    const n = Number(raw)
    if (!Number.isFinite(n)) return ZOOM_DEFAULT
    return Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, n))
  } catch {
    return ZOOM_DEFAULT
  }
}
const saveZoom = (itemId: string, n: number): void => {
  try {
    localStorage.setItem(ZOOM_KEY_PREFIX + itemId, String(n))
  } catch {
    /* no-op — localStorage may be disabled */
  }
}

const zoom = ref<number>(ZOOM_DEFAULT)
const setZoom = (next: number): void => {
  const clamped = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, next))
  // Snap to nearest 1% so the displayed percentage is clean.
  const snapped = Math.round(clamped * 100) / 100
  zoom.value = snapped
  if (effectiveItemId.value) saveZoom(effectiveItemId.value, snapped)
}
const zoomIn = (): void => setZoom(zoom.value + ZOOM_STEP)
const zoomOut = (): void => setZoom(zoom.value - ZOOM_STEP)
const zoomReset = (): void => setZoom(1.0)

// Fit-to-viewport: compute the zoom level that makes the entire page
// fit inside the scroll container with a small margin, then scroll
// the container so the page is centered. Mirrors Figma's Shift+1
// ("Zoom to fit"). Picked up by the keyboard shortcut (F / Shift+1)
// and the toolbar button. Reads the live DOM dimensions so resizing
// the window refits.
const ZOOM_FIT_MARGIN = 48 // px of padding around the fitted canvas

const zoomFit = (): void => {
  if (!activePage.value) return
  const container = document.querySelector<HTMLElement>(
    '[data-testid="design-canvas-scroll-container"]',
  )
  if (!container) return
  const cw = container.clientWidth - ZOOM_FIT_MARGIN
  const ch = container.clientHeight - ZOOM_FIT_MARGIN
  if (cw <= 0 || ch <= 0) return
  const zoomX = cw / canvasWidth.value
  const zoomY = ch / canvasHeight.value
  const fit = Math.min(zoomX, zoomY)
  setZoom(fit)
  // Center after the scale change so the page appears centered.
  // The scroll math mirrors the Ctrl+wheel handler.
  requestAnimationFrame(() => {
    const scaledW = canvasWidth.value * zoom.value
    const scaledH = canvasHeight.value * zoom.value
    container.scrollLeft = (scaledW - container.clientWidth) / 2
    container.scrollTop = (scaledH - container.clientHeight) / 2
  })
}

// Ctrl+wheel zooms in/out at the cursor position. The plain wheel
// is left alone (it scrolls the canvas container as usual — matches
// Figma / Miro / VS Code). Shift wheel zooms ×4 faster.
const handleCanvasWheel = (event: WheelEvent): void => {
  if (!event.ctrlKey && !event.metaKey) return
  event.preventDefault()
  const direction = event.deltaY < 0 ? 1 : -1
  const speed = event.shiftKey ? 4 : 1
  const next = zoom.value + direction * ZOOM_WHEEL_STEP * speed

  // Anchor the zoom at the cursor position so zoom-in feels natural
  // (the point under the cursor stays under the cursor after the
  // scale). Compute the cursor's offset from the canvas origin in
  // CONTENT coordinates (accounting for current scroll), then adjust
  // scrollTop / scrollLeft so the same content point is under the
  // cursor after the new scale is applied.
  const container = event.currentTarget as HTMLElement | null
  if (!container) {
    setZoom(next)
    return
  }
  const rect = container.getBoundingClientRect()
  const cursorX = event.clientX - rect.left + container.scrollLeft
  const cursorY = event.clientY - rect.top + container.scrollTop
  const before = zoom.value
  setZoom(next)
  const after = zoom.value
  if (before === after) return
  const ratio = after / before
  container.scrollLeft = cursorX * ratio - (event.clientX - rect.left)
  container.scrollTop = cursorY * ratio - (event.clientY - rect.top)
}

// Restore zoom on design-item change (different localStorage key).
watch(
  () => effectiveItemId.value,
  (newId) => {
    zoom.value = newId ? loadZoom(newId) : ZOOM_DEFAULT
  },
  { immediate: true },
)

// ─── Page-size inputs (debounced 600ms) ─────────────────────────────────
//
// Two `<input type="number">` fields in the canvas header let the
// user resize the active page. The backend validates the ranges
// (width 320-4096, height 240-4096); out-of-range is rejected
// with 400. Inputs share a single 600ms debounce so changing both
// then pausing issues exactly one PATCH request.

// String forms for the `<input type="number">`. Use empty string
// when no page is active so the input is blank (not "0").
const pageWidthInput = computed(() =>
  activePage.value ? String(activePage.value.width) : '',
)
const pageHeightInput = computed(() =>
  activePage.value ? String(activePage.value.height) : '',
)

let pageSizeDebounceTimer: number | null = null

const handlePageSizeChange = (): void => {
  if (!activePage.value) return
  if (!props.workspaceId || !effectiveItemId.value) return
  if (pageSizeDebounceTimer !== null) {
    clearTimeout(pageSizeDebounceTimer)
  }
  pageSizeDebounceTimer = window.setTimeout(() => {
    pageSizeDebounceTimer = null
    void commitPageSize()
  }, 600)
}

const commitPageSize = async (): Promise<void> => {
  if (!activePage.value) return
  const widthInput = document.querySelector<HTMLInputElement>(
    '[data-testid="design-page-width-input"]',
  )
  const heightInput = document.querySelector<HTMLInputElement>(
    '[data-testid="design-page-height-input"]',
  )
  if (!widthInput || !heightInput) return
  const width = Number(widthInput.value)
  const height = Number(heightInput.value)
  if (!Number.isFinite(width) || !Number.isFinite(height)) return
  if (width < 320 || width > 4096 || height < 240 || height > 4096) {
    useNotificationStore().notifyError(
      'Invalid page size',
      `Width must be 320-4096, height 240-4096 (got ${width}×${height})`,
    )
    // Reset the inputs to the current valid page size.
    widthInput.value = String(activePage.value.width)
    heightInput.value = String(activePage.value.height)
    return
  }
  try {
    const updated = await workspacesStore.updateDesignPage(
      props.workspaceId,
      effectiveItemId.value,
      activePage.value.id,
      { width, height },
    )
    // Mutate the pages array in-place so the canvasWidth/Height
    // computeds re-derive and the canvas div re-renders.
    const idx = pages.value.findIndex((p) => p.id === updated.id)
    if (idx !== -1) pages.value[idx] = updated
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    useNotificationStore().notifyError('Failed to resize page', message)
    // Reset the inputs to the current (unchanged) page size.
    widthInput.value = String(activePage.value.width)
    heightInput.value = String(activePage.value.height)
  }
}

onUnmounted(() => {
  if (pageSizeDebounceTimer !== null) {
    clearTimeout(pageSizeDebounceTimer)
  }
})
</script>

<template>
  <section
    class="design-view flex flex-col h-full min-h-0"
    :data-design-item-id="item.id"
    data-testid="design-view"
  >
    <!--
      NEW (2026-07-14): Top-level action bar. Always renders
      regardless of pages state (loading / error / empty / canvas)
      so the chat toggle is reachable even before the user has
      added a page — the primary flow is "ask the LLM to draw me
      a login form" via the chat, then the page appears. Without
      this top-level bar, the chat toggle was buried inside the
      canvas header which only renders when pages.length > 0, so
      the empty state had no chat access (the bug the user
      reported on 2026-07-14).

      Layout: [item name | flex spacer | 💬 Chat button]. The
      item name is small + dim so it doesn't compete with the
      page tabs for attention; the chat button is the only
      always-visible action.
    -->
    <div
      class="px-3 py-2 flex items-center gap-3 shrink-0"
      style="border-bottom: 1px solid var(--color-border); background-color: var(--semantic-sidebar-bg);"
      data-testid="design-toolbar"
    >
      <div
        class="text-xs font-medium truncate"
        style="color: var(--semantic-text-dim);"
        :title="item.name"
      >
        {{ item.name }}
      </div>
      <div class="flex-1" />
      <button
        type="button"
        class="px-2.5 py-1 rounded text-xs font-medium flex items-center gap-1.5 transition-opacity duration-150 hover:opacity-100"
        style="
          background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
          color: var(--color-bg);
        "
        data-testid="design-open-chat-button"
        aria-label="Open design chat"
        title="Open design chat"
        @click="handleOpenChat"
      >
        <span aria-hidden="true">💬</span>
        <span>Chat</span>
      </button>
    </div>

    <!-- ─── Tabs row ─────────────────────────────────────────────── -->
    <DesignPageTabs
      :pages="pages"
      :active-page-id="activePageId"
      :workspace-id="workspaceId"
      :item-id="itemId || item.id"
      @select-page="handleSelectPage"
      @add-page="handleAddPage"
      @delete-page="handleDeletePage"
    />

    <!-- ─── Loading state for pages ───────────────────────────────── -->
    <div
      v-if="pagesLoading"
      class="flex-1 flex items-center justify-center text-sm"
      style="color: var(--semantic-text-dim);"
      data-testid="design-pages-loading"
    >
      Loading pages…
    </div>

    <!-- ─── Error state for pages ─────────────────────────────────── -->
    <div
      v-else-if="pagesError"
      class="flex-1 flex items-center justify-center text-sm"
      style="color: rgb(248, 113, 113);"
      data-testid="design-pages-error"
    >
      Failed to load pages: {{ pagesError }}
    </div>

    <!-- ─── Empty state (no pages) ────────────────────────────────── -->
    <div
      v-else-if="pages.length === 0"
      class="flex-1 flex items-center justify-center"
      data-testid="design-pages-empty"
    >
      <div class="text-center">
        <div class="text-3xl mb-2" style="color: var(--semantic-text-dim);" aria-hidden="true">▤</div>
        <div class="text-sm mb-4" style="color: var(--semantic-text-dim);">
          No pages yet
        </div>
        <button
          type="button"
          class="px-3 py-1.5 rounded-lg text-sm font-medium"
          style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);"
          @click="handleAddPage"
        >
          + Add the first page
        </button>
      </div>
    </div>

    <!-- ─── Main split (canvas + right sidebar) ──────────────────── -->
    <div v-else class="flex-1 flex min-h-0">
      <!-- Canvas column -->
      <div
        class="flex-1 flex flex-col min-w-0 min-h-0"
        data-testid="design-canvas-column"
      >
        <!-- Canvas header bar -->
        <div
          class="px-3 py-2 flex items-center gap-3 shrink-0"
          style="border-bottom: 1px solid var(--color-border); background-color: var(--semantic-sidebar-bg);"
          data-testid="design-canvas-header"
        >
          <button
            v-if="!isPreviewMode"
            type="button"
            class="px-2 py-1 rounded text-xs font-medium"
            style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);"
            data-testid="design-add-element-button"
            @click="openAddElementDialog"
          >
            + Element
          </button>
          <div
            v-if="activePage"
            class="text-xs flex-1 truncate"
            style="color: var(--semantic-text);"
            :title="activePage.name"
          >
            {{ activePage.name }}
          </div>
          <div
            v-else
            class="text-xs flex-1"
            style="color: var(--semantic-text-dim);"
          >
            (no page selected)
          </div>
          <div
            v-if="activePage && !isPreviewMode"
            class="flex items-center gap-1 text-xs shrink-0"
            style="color: var(--semantic-text-dim);"
            data-testid="design-page-size"
          >
            <input
              type="number"
              min="320"
              max="4096"
              step="10"
              class="w-16 px-1.5 py-0.5 rounded text-xs"
              style="background-color: var(--semantic-card-bg); color: var(--semantic-text); border: 1px solid var(--color-border);"
              :value="pageWidthInput"
              aria-label="Page width"
              data-testid="design-page-width-input"
              @change="handlePageSizeChange"
            />
            <span aria-hidden="true">×</span>
            <input
              type="number"
              min="240"
              max="4096"
              step="10"
              class="w-16 px-1.5 py-0.5 rounded text-xs"
              style="background-color: var(--semantic-card-bg); color: var(--semantic-text); border: 1px solid var(--color-border);"
              :value="pageHeightInput"
              aria-label="Page height"
              data-testid="design-page-height-input"
              @change="handlePageSizeChange"
            />
          </div>
          <div class="text-xs" style="color: var(--semantic-text-dim);">
            {{ elements.length }} element{{ elements.length === 1 ? '' : 's' }}
          </div>
          <!--
            Preview/Edit mode toggle. When active, each element's iframe
            gets `pointer-events: auto` and the edit chrome is suppressed
            — the user can type into form fields and click buttons inside
            the rendered HTML without selecting elements. Keyboard shortcut:
            Cmd/Ctrl+P toggles, Esc exits. See `isPreviewMode` ref above.
          -->
          <button
            type="button"
            class="px-2 py-0.5 rounded text-xs font-medium transition-colors"
            :style="isPreviewMode
              ? 'background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg); border: none;'
              : 'color: var(--semantic-text); border: 1px solid var(--color-border); opacity: 0.8;'"
            :title="isPreviewMode
              ? 'Exit Preview mode (shortcut: Esc)'
              : 'Preview the mockup — type into inputs, click buttons (shortcut: Cmd/Ctrl+P)'"
            :aria-label="isPreviewMode ? 'Exit Preview mode' : 'Enter Preview mode'"
            :aria-pressed="isPreviewMode"
            data-testid="design-preview-toggle"
            @click="togglePreviewMode"
          >
            <span aria-hidden="true">{{ isPreviewMode ? '■ ' : '▶ ' }}</span>Preview
          </button>
          <div
            class="flex items-center gap-1 shrink-0"
            data-testid="design-zoom-toolbar"
          >
            <button
              type="button"
              class="px-1.5 py-0.5 rounded text-xs font-medium hover:opacity-100 opacity-80"
              style="color: var(--semantic-text); border: 1px solid var(--color-border);"
              aria-label="Zoom out"
              data-testid="design-zoom-out"
              @click="zoomOut"
            >−</button>
            <button
              type="button"
              class="px-2 py-0.5 rounded text-xs font-medium hover:opacity-100 opacity-80 min-w-[3.5rem] text-center"
              style="color: var(--semantic-text); border: 1px solid var(--color-border);"
              :title="`Reset zoom (currently ${Math.round(zoom * 100)}%)`"
              aria-label="Reset zoom"
              data-testid="design-zoom-reset"
              @click="zoomReset"
            >{{ Math.round(zoom * 100) }}%</button>
            <button
              type="button"
              class="px-1.5 py-0.5 rounded text-xs font-medium hover:opacity-100 opacity-80"
              style="color: var(--semantic-text); border: 1px solid var(--color-border);"
              aria-label="Fit page to viewport (shortcut: F or Shift+1)"
              title="Fit page to viewport (F or Shift+1)"
              data-testid="design-zoom-fit"
              @click="zoomFit"
            >⛶</button>
            <button
              type="button"
              class="px-1.5 py-0.5 rounded text-xs font-medium hover:opacity-100 opacity-80"
              style="color: var(--semantic-text); border: 1px solid var(--color-border);"
              aria-label="Zoom in"
              data-testid="design-zoom-in"
              @click="zoomIn"
            >+</button>
          </div>
        </div>

        <!-- Canvas viewport -->
        <div
          class="flex-1 overflow-auto min-h-0"
          style="background-color: var(--color-bg-m2);"
          data-testid="design-canvas-scroll-container"
          @click="handleCanvasClick"
          @wheel="handleCanvasWheel"
          @pointerdown="startCanvasPan"
        >
          <div
            class="relative mx-auto my-6 origin-top-left"
            :style="{
              width: `${canvasWidth}px`,
              height: `${canvasHeight}px`,
              transform: `scale(${zoom})`,
              backgroundColor: 'var(--semantic-card-bg)',
              boxShadow: '0 4px 20px rgba(0, 0, 0, 0.3)',
              backgroundImage:
                'linear-gradient(45deg, rgba(127,127,127,0.04) 25%, transparent 25%, transparent 75%, rgba(127,127,127,0.04) 75%), linear-gradient(45deg, rgba(127,127,127,0.04) 25%, transparent 25%, transparent 75%, rgba(127,127,127,0.04) 75%)',
              backgroundSize: '20px 20px',
              backgroundPosition: '0 0, 10px 10px',
            }"
            data-testid="design-canvas"
            @click.stop
          >
            <DesignElement
              v-for="element in elements"
              :key="element.id"
              :element="element"
              :selected="isSingleSelect && activeElements[0]?.id === element.id"
              :selected-ids="Array.from(selectedIds)"
              :readonly="false"
              :zoom="zoom"
              :workspace-id="workspaceId"
              :item-id="itemId || item.id"
              :page-id="activePageId"
              :preview-mode="isPreviewMode"
              @select="(id) => handleElementToggle(id, false)"
              @update="handleElementUpdate"
              @group-drag="handleGroupDrag"
              @drag-end="clearSnapGuides"
              @html-changed="handleElementHtmlChanged"
              @delete="handleElementDelete"
            />
            <!--
              Snap guides (Chunk 3): SVG overlay rendered ABOVE the
              elements (z-index higher in DOM order) but BELOW the
              resize handles (which are inside each DesignElement).
              `pointer-events-none` so the SVG never intercepts the
              cursor — the canvas's own pointer handlers stay alive.
              1px violet lines: vertical = x-axis guides at a fixed
              position, full canvas height; horizontal = y-axis guides,
              full canvas width. The SVG is sized to the canvas
              (canvasWidth × canvasHeight) so we can draw the lines
              in design-px coordinates without scaling math.
            -->
            <svg
              v-if="snapGuides.length > 0"
              class="absolute inset-0 pointer-events-none"
              :width="canvasWidth"
              :height="canvasHeight"
              data-testid="design-snap-guides"
              aria-hidden="true"
            >
              <line
                v-for="(guide, idx) in snapGuides.filter((g) => g.axis === 'x')"
                :key="`x-${idx}`"
                :x1="guide.position"
                :y1="0"
                :x2="guide.position"
                :y2="canvasHeight"
                stroke="var(--color-violet)"
                stroke-width="1"
              />
              <line
                v-for="(guide, idx) in snapGuides.filter((g) => g.axis === 'y')"
                :key="`y-${idx}`"
                :x1="0"
                :y1="guide.position"
                :x2="canvasWidth"
                :y2="guide.position"
                stroke="var(--color-violet)"
                stroke-width="1"
              />
            </svg>
            <div
              v-if="elements.length === 0"
              class="absolute inset-0 flex items-center justify-center text-sm pointer-events-none"
              style="color: var(--semantic-text-dim);"
              data-testid="design-canvas-empty"
            >
              <div class="text-center">
                <div class="text-3xl mb-2" aria-hidden="true">▢</div>
                <div>Click "+ Element" to add your first element</div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Resize handle (canvas ↔ right sidebar) -->
      <div
        class="shrink-0 w-2 cursor-col-resize relative flex items-center justify-center transition-colors"
        :class="
          isSidebarResizing
            ? '!bg-[var(--color-violet)]/60'
            : 'bg-[var(--color-violet)]/15 hover:bg-[var(--color-violet)]/40'
        "
        data-testid="design-sidebar-resize-handle"
        title="Drag to resize"
        @mousedown="startSidebarResize"
      >
        <svg
          width="14"
          height="2"
          viewBox="0 0 14 2"
          fill="currentColor"
          class="text-[var(--color-violet)] opacity-70"
          aria-hidden="true"
        >
          <circle cx="3" cy="1" r="1" />
          <circle cx="7" cy="1" r="1" />
          <circle cx="11" cy="1" r="1" />
        </svg>
      </div>

      <!-- Right sidebar (Layers + Properties) -->
      <div
        class="shrink-0 flex flex-col h-full min-h-0"
        :style="{ width: `${sidebarWidth}px` }"
        data-testid="design-right-sidebar"
      >
        <!-- Layers (top, flexible height by layersHeightRatio) -->
        <div
          class="min-h-0 overflow-hidden"
          :style="{ height: `${layersHeightRatio * 100}%` }"
        >
          <LayersPanel
            :elements="elements"
            :selected-ids="Array.from(selectedIds)"
            :readonly="isPreviewMode"
            @select="handleLayerSelect"
            @reorder="handleReorderElements"
            @delete="handleElementDelete"
          />
        </div>

        <!-- Horizontal resize handle between Layers and Properties -->
        <div
          class="shrink-0 h-2 cursor-row-resize transition-colors"
          :class="
            isLayersResizing
              ? '!bg-[var(--color-violet)]/60'
              : 'bg-[var(--color-violet)]/15 hover:bg-[var(--color-violet)]/40'
          "
          data-testid="design-layers-resize-handle"
          title="Drag to resize"
          @mousedown="startLayersResize"
        />

        <!-- Properties (bottom, fills remaining height) -->
        <div class="flex-1 min-h-0 overflow-hidden">
          <PropertiesPanel
            :elements="activeElements"
            :readonly="false"
            :preview-mode="isPreviewMode"
            @update="handlePropertiesUpdate"
            @html-changed="handlePropertiesHtmlChanged"
            @delete="handlePropertiesDelete"
          />
        </div>
      </div>
    </div>

    <!-- ─── Add element dialog ───────────────────────────────────── -->
    <AddDesignElementDialog
      :show="showAddElementDialog"
      :page-id="activePageId"
      :readonly="false"
      @create="handleCreateElement"
      @close="showAddElementDialog = false"
    />
  </section>
</template>

<style scoped>
.design-view :deep(.overflow-auto)::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}
.design-view :deep(.overflow-auto)::-webkit-scrollbar-track {
  background: transparent;
}
.design-view :deep(.overflow-auto)::-webkit-scrollbar-thumb {
  background: var(--color-border);
  border-radius: 4px;
}
.design-view :deep(.overflow-auto)::-webkit-scrollbar-thumb:hover {
  background: var(--semantic-text-dim);
}
</style>