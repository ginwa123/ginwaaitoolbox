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
      selectPage, addPage, deletePage         (tabs)
      selectElement, reorderElements          (layers)
      createElement, updateElement, deleteElement, htmlChanged  (mutations)

  Chunk 8 (AppLayout wiring) wires these to the workspaces store +
  designSse store. For now the internal handlers just emit them.
-->
<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import DesignPageTabs from './DesignPageTabs.vue'
import DesignElement from './DesignElement.vue'
import LayersPanel from './LayersPanel.vue'
import PropertiesPanel from './PropertiesPanel.vue'
import AddDesignElementDialog from './AddDesignElementDialog.vue'
import { useWorkspacesStore, type WorkspaceItem } from '../../stores/workspaces'
import { listDesignPages, type DesignElement as DesignElementApi } from '../../api'

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
  addPage: []
  deletePage: [pageId: string]
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
  openChat: []
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

const selectedElementId = ref<string | null>(null)
const activeElement = computed<DesignElementApi | null>(() => {
  if (!selectedElementId.value) return null
  return elements.value.find((e) => e.id === selectedElementId.value) ?? null
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
    // Default activePageId to the first page; preserve if it still exists.
    if (
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
  selectedElementId.value = null
  if (!pageId) return
  if (!props.workspaceId || !effectiveItemId.value) return
  void workspacesStore.fetchDesignElements(
    props.workspaceId,
    effectiveItemId.value,
    pageId,
  )
})

// ─── Keyboard shortcuts ────────────────────────────────────────────────

const handleKeydown = (event: KeyboardEvent): void => {
  if (event.key === 'Escape') {
    selectedElementId.value = null
    // Also close the add-element dialog if it's open.
    if (showAddElementDialog.value) {
      showAddElementDialog.value = false
    }
  }
}

onMounted(() => {
  document.addEventListener('keydown', handleKeydown)
})
onUnmounted(() => {
  document.removeEventListener('keydown', handleKeydown)
})

// ─── Handlers ──────────────────────────────────────────────────────────

const handleCanvasClick = (event: MouseEvent): void => {
  // Only clear selection when clicking the canvas itself (not an
  // element child). The DesignElement child events fire before this
  // and they stopPropagation on their pointerdown — so this handler
  // is only called for the canvas background.
  if ((event.target as HTMLElement | null)?.closest('[data-design-element]')) {
    return
  }
  selectedElementId.value = null
}

// NEW: chat-toggle click handler (top-right 💬 button in the
// canvas header bar). Emits the openChat event upward —
// AppLayout (the only listener) finds or creates the design's
// chat task and switches to the 3-column layout. The button
// itself has no local state; the chat panel's visibility is
// owned by AppLayout (it shows when activeTaskId is set for
// this design item, hides when activeTaskId is cleared).
const handleOpenChat = (): void => {
  emit('openChat')
}

const handleAddPage = (): void => {
  emit('addPage')
}

const handleSelectPage = (pageId: string): void => {
  if (pageId !== activePageId.value) {
    activePageId.value = pageId
  }
  emit('selectPage', pageId)
}

const handleDeletePage = (pageId: string): void => {
  emit('deletePage', pageId)
}

const handleElementSelect = (elementId: string): void => {
  selectedElementId.value = elementId
  emit('selectElement', elementId)
}

const handleElementUpdate = (patch: Partial<DesignElementApi>): void => {
  if (!selectedElementId.value) return
  emit('updateElement', selectedElementId.value, patch)
}

const handleElementHtmlChanged = (html: string): void => {
  if (!selectedElementId.value) return
  emit('htmlChanged', selectedElementId.value, html)
}

const handleElementDelete = (elementId: string): void => {
  emit('deleteElement', elementId)
  selectedElementId.value = null
}

const handleReorderElements = (orderedElementIds: string[]): void => {
  emit('reorderElements', orderedElementIds)
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
          <div class="text-xs" style="color: var(--semantic-text-dim);">
            {{ elements.length }} element{{ elements.length === 1 ? '' : 's' }}
          </div>
        </div>

        <!-- Canvas viewport -->
        <div
          class="flex-1 overflow-auto min-h-0"
          style="background-color: var(--color-bg-m2);"
          data-testid="design-canvas-scroll-container"
          @click="handleCanvasClick"
        >
          <div
            class="relative mx-auto my-6"
            :style="{
              width: `${canvasWidth}px`,
              height: `${canvasHeight}px`,
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
              :selected="selectedElementId === element.id"
              :readonly="false"
              @select="handleElementSelect"
              @update="handleElementUpdate"
              @html-changed="handleElementHtmlChanged"
              @delete="handleElementDelete"
            />
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
            :selected-element-id="selectedElementId"
            :readonly="false"
            @select="handleElementSelect"
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
            :element="activeElement"
            :readonly="false"
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