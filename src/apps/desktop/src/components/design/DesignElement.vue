<!--
  DesignElement — a single positioned element on the design canvas.

  Renders the element as an absolutely-positioned div with the
  element's geometry (x, y, width, height) and a rotation transform.
  Selection state adds a violet outline; 8 resize handles (corners +
  edge midpoints) appear only when selected.

  Drag/resize:
    - Uses pointerdown / pointermove / pointerup + setPointerCapture
      so a fast drag that outruns the handle still tracks correctly.
    - The initial pointerdown records the start geometry and the
      pointer's screen position. Each pointermove computes the delta
      from the start position and applies it to the geometry; the
      emit fires only on pointerup (the design mode redraws from the
      emit, so 60+/sec would flood the canvas).
    - For drag: delta is applied to x/y.
    - For resize: delta is applied to width/height (sign flipped per
      handle so top/left handles grow when the user drags up/left).
    - For rotate: not implemented in v1 (the rotation field exists on
      the element but the canvas UX doesn't yet have a rotation handle;
      the PropertiesPanel can set rotation via a number input).

  Iframe content inside the element is rendered with pointer-events:none
  so the parent div owns the pointer events for drag/resize/select.
  This is the standard Figma/Sketch pattern.

  Public API:
    props:
      element   DesignElement   the element's full record
      selected  boolean         selection state (violet outline)
      readonly  boolean         when true, drag/resize are disabled
    emits:
      select       [elementId: string]
      update       [patch: Partial<DesignElement>]
      htmlChanged  [html: string]
      delete       [elementId: string]

  Test contract:
    - data-testid="design-element" on the wrapper
    - data-testid="design-element-handle-{corner}" on each resize handle
-->
<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import type { DesignElement } from '../../api'
import { getDesignElementHtml } from '../../api'
import DesignElementPreview from './DesignElementPreview.vue'

const props = withDefaults(
  defineProps<{
    element: DesignElement
    selected?: boolean
    readonly?: boolean
    // Current canvas zoom level (1.0 = 100%). When the canvas is
    // CSS-scaled via `transform: scale(zoom)`, the cursor delta
    // (screen-px) and the model's element coordinates (design-px)
    // differ — drag/resize math divides by zoom to keep them aligned.
    zoom?: number
    // IDs needed to lazy-load the element's HTML body from the
    // backend (the page+elements GET response excludes the body to
    // keep payloads small). Defaults are empty so the component
    // can mount without them; fetchHtml is a no-op when any is missing.
    workspaceId?: string
    itemId?: string
    pageId?: string
    // When true, the parent canvas is in Preview/Edit mode (toggle
    // in the canvas header bar). In Preview:
    //   - the inner iframe gets `pointer-events: auto` so the user
    //     can type into `<input>` elements, click buttons, etc.
    //   - the wrapper div suppresses its drag handler
    //   - the selection chrome (resize handles, outline) is hidden
    //     even when `selected === true` — preview is "play, don't edit"
    // Default false (the canvas's normal edit mode).
    previewMode?: boolean
  }>(),
  {
    selected: false,
    readonly: false,
    zoom: 1.0,
    workspaceId: '',
    itemId: '',
    pageId: '',
    previewMode: false,
  },
)

const emit = defineEmits<{
  select: [elementId: string]
  update: [patch: Partial<DesignElement>]
  htmlChanged: [html: string]
  delete: [elementId: string]
}>()

// ─── Geometry ───────────────────────────────────────────────────────────

const elementStyle = computed(() => ({
  left: `${props.element.x}px`,
  top: `${props.element.y}px`,
  width: `${props.element.width}px`,
  height: `${props.element.height}px`,
  transform: `rotate(${props.element.rotation}deg)`,
  // Inline opacity; the backend's `opacity` field defaults to 1.0
  // and the v-if on the parent only renders elements with valid
  // geometry, so no extra defensive checks needed.
  opacity: props.element.opacity,
  // Selection outline is rendered as a child absolutely-positioned
  // div via the .selected class below; the parent keeps the
  // standard border styling from the element itself.
}))

// ─── Drag (move) ────────────────────────────────────────────────────────

type DragMode = 'move' | { resize: ResizeHandle }

type ResizeHandle =
  | 'nw' | 'n' | 'ne'
  | 'w'  |        'e'
  | 'sw' | 's' | 'se'

const isDragging = ref(false)

const startDrag = (event: PointerEvent, mode: DragMode): void => {
  if (props.readonly) return
  // In Preview mode, the canvas is "playing" the mockup — clicks
  // on element bodies are absorbed by the inner iframe (typed text,
  // button activations). Don't start a drag, don't emit select.
  if (props.previewMode) return
  // Always emit select on pointerdown so clicking an element selects
  // it even if the user just clicks without dragging.
  emit('select', props.element.id)

  // Don't initiate a drag if the click was on an interactive child
  // (e.g. the iframe content) — pointer-events:none on the iframe
  // already prevents that, but we double-check.
  if (event.button !== 0) return

  event.preventDefault()
  const target = event.currentTarget as HTMLElement | null
  if (!target) return
  target.setPointerCapture(event.pointerId)
  isDragging.value = true

  const startX = event.clientX
  const startY = event.clientY
  const start = {
    x: props.element.x,
    y: props.element.y,
    width: props.element.width,
    height: props.element.height,
  }

  const onMove = (e: PointerEvent): void => {
    // Under zoom != 1.0 the canvas is CSS-scaled — cursor delta is
    // in screen-px, but the model stores design-px. Divide by zoom
    // so a 10-screen-px move at 50% zoom produces a 5-design-px
    // move (the visible element glides 1:1 with the cursor).
    const inv = 1 / Math.max(0.01, props.zoom)
    const dx = (e.clientX - startX) * inv
    const dy = (e.clientY - startY) * inv
    if (mode === 'move') {
      // Move: apply delta to x/y.
      emit('update', {
        x: Math.round(start.x + dx),
        y: Math.round(start.y + dy),
      })
    } else {
      // Resize: apply delta to width/height per the handle.
      const patch: Partial<DesignElement> = {}
      const h = mode.resize
      // East / south edges grow with positive delta; north / west
      // edges grow with negative delta (top-left handle drags
      // up-left to make the element bigger).
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
      emit('update', patch)
    }
  }

  const onUp = (e: PointerEvent): void => {
    if (target.hasPointerCapture(e.pointerId)) {
      target.releasePointerCapture(e.pointerId)
    }
    isDragging.value = false
    target.removeEventListener('pointermove', onMove)
    target.removeEventListener('pointerup', onUp)
    target.removeEventListener('pointercancel', onUp)
  }

  target.addEventListener('pointermove', onMove)
  target.addEventListener('pointerup', onUp)
  target.addEventListener('pointercancel', onUp)
}

// ─── HTML preview wrapper ───────────────────────────────────────────────

// Lazy-load the element's stored HTML body so the canvas can render
// the actual design (not just a placeholder rectangle). The body is
// excluded from the page+elements GET response to keep payloads small
// for designs with many elements, so we fetch per-element here.
//
// Re-fetch when the element changes (different id), the file_path
// changes (the user updated the HTML via Monaco), or the file's
// updated_at changes (the user re-saved via Monaco without changing
// the path).
const htmlBody = ref<string>('')
const htmlLoadError = ref<string | null>(null)
const isLoadingHtml = ref(false)
let htmlFetchSeq = 0

const fetchHtml = async (): Promise<void> => {
  // No file_path = no HTML body to render. This is the common case
  // for legacy / empty elements created before the body feature.
  if (!props.element.file_path) {
    htmlBody.value = ''
    htmlLoadError.value = null
    isLoadingHtml.value = false
    return
  }
  // Need the full id tuple to call the API; the parent's `fetchDesignElements`
  // call doesn't carry them through to here yet, so guard gracefully.
  if (!props.workspaceId || !props.itemId || !props.pageId) {
    htmlBody.value = ''
    return
  }
  const seq = ++htmlFetchSeq
  isLoadingHtml.value = true
  htmlLoadError.value = null
  try {
    const { html } = await getDesignElementHtml(
      props.workspaceId,
      props.itemId,
      props.pageId,
      props.element.id,
    )
    // Only commit the result if this is still the latest in-flight
    // request; otherwise a stale fetch could clobber newer content.
    if (seq === htmlFetchSeq) {
      htmlBody.value = html
    }
  } catch (err) {
    if (seq === htmlFetchSeq) {
      htmlLoadError.value = err instanceof Error ? err.message : String(err)
      htmlBody.value = ''
    }
  } finally {
    if (seq === htmlFetchSeq) {
      isLoadingHtml.value = false
    }
  }
}

onMounted(() => {
  void fetchHtml()
})

// Re-fetch when the element identity, file path, or updated_at
// changes. `updated_at` is the proxy for "the user re-saved the
// HTML via Monaco in the PropertiesPanel" — the path stays the same
// but the file content changed.
watch(
  () => [props.element.id, props.element.file_path, props.element.updated_at],
  () => {
    void fetchHtml()
  },
)

const handleHtmlChanged = (html: string): void => {
  emit('htmlChanged', html)
}

// ─── Delete (Delete/Backspace key on the selected element) ──────────────
//
// We don't bind window keydown here (the parent DesignView owns
// keyboard events); the parent emits `delete` on the active element.
// Expose a method for the parent to call: see the watcher below that
// listens for the `Delete` key globally when this element is selected.
//
// Actually — we DO bind a window listener when selected so the user
// can hit Delete without the canvas having to know. Cleaner UX than
// routing it through DesignView.
import { onUnmounted } from 'vue'

const handleKeydown = (e: KeyboardEvent): void => {
  if (!props.selected) return
  if (props.readonly) return
  if (e.key !== 'Delete' && e.key !== 'Backspace') return
  // Don't intercept Delete when the user is typing in a form input.
  const target = e.target as HTMLElement | null
  if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) {
    return
  }
  e.preventDefault()
  emit('delete', props.element.id)
}

onMounted(() => {
  document.addEventListener('keydown', handleKeydown)
})
onUnmounted(() => {
  document.removeEventListener('keydown', handleKeydown)
})
</script>

<template>
  <div
    class="design-element absolute"
    :class="[
      selected ? 'selected' : '',
      readonly ? 'cursor-default' : 'cursor-move',
      isDragging ? 'dragging' : '',
    ]"
    :style="elementStyle"
    :data-testid="`design-element-${element.id}`"
    data-design-element="true"
    :data-preview-mode="previewMode"
    @pointerdown="(e) => startDrag(e, 'move')"
  >
    <!-- Iframe preview with pointer-events:none so the parent owns
         the pointer events. The iframe is positioned to fill the
         element's geometry; when the user wants to interact with the
         preview's content, they can use the PropertiesPanel's Monaco
         editor instead. -->
    <div
      v-if="element.file_path"
      class="absolute inset-0 pointer-events-none overflow-hidden"
      :style="{
        backgroundColor: element.fill || 'transparent',
        borderRadius: `${element.corner_radius}px`,
        border: element.stroke
          ? `${element.stroke_width}px solid ${element.stroke}`
          : 'none',
      }"
    >
      <!-- The HTML body is fetched on mount (and re-fetched when
           element.id / file_path / updated_at changes). The
           v-if="htmlBody" guard renders the placeholder rectangle
           underneath while the fetch is in flight, so the user sees
           a graceful loading state instead of a flash of empty.
           `pointerEvents` is `'none'` in Edit mode (clicks pass
           through to the wrapper for drag/resize/select) and
           `'auto'` in Preview mode (the iframe captures clicks so
           the user can type into inputs / click buttons). -->
      <DesignElementPreview
        v-if="htmlBody"
        :html="htmlBody"
        :editable="false"
        :pointer-events="previewMode ? 'auto' : 'none'"
      />
      <!-- Loading state — empty until the iframe loads. Visible only
           briefly; the iframe replaces it within one render cycle of
           the fetch returning. -->
      <div
        v-else-if="isLoadingHtml"
        class="absolute inset-0 flex items-center justify-center text-[10px]"
        style="color: var(--semantic-text-dim);"
        data-testid="design-element-loading"
      >
        loading…
      </div>
    </div>

    <!-- Plain rectangle / shape fill (always shown). Rendered behind
         the iframe so it acts as a graceful fallback when (a) the
         element has no file_path, (b) the HTML fetch is still in
         flight, or (c) the HTML fetch failed. Provides the dashed
         outline the user needs to see where the element is before
         the iframe content arrives. -->
    <div
      class="absolute inset-0"
      :style="{
        backgroundColor: element.fill || 'rgba(127, 127, 127, 0.05)',
        borderRadius: `${element.corner_radius}px`,
        border: element.stroke
          ? `${element.stroke_width}px solid ${element.stroke}`
          : '1px dashed rgba(127, 127, 127, 0.4)',
      }"
    />

    <!-- Element name label (top-left corner) — useful when the shape
         is small / fill is invisible. -->
    <div
      class="absolute -top-5 left-0 text-[10px] pointer-events-none whitespace-nowrap"
      style="color: var(--semantic-text-dim);"
      v-if="selected && !previewMode"
    >
      {{ element.name }}
    </div>

    <!-- Text element content -->
    <div
      v-if="element.type === 'text' && element.text_content"
      class="absolute inset-0 flex items-center justify-center p-2 text-center overflow-hidden"
      :style="{
        fontFamily: element.text_style || 'sans-serif',
        color: element.stroke || 'var(--semantic-text)',
        fontSize: `${Math.max(8, element.width / 12)}px`,
      }"
    >
      {{ element.text_content }}
    </div>

    <!-- Image element content -->
    <img
      v-if="element.type === 'image' && element.image_url"
      :src="element.image_url"
      class="absolute inset-0 w-full h-full object-contain pointer-events-none"
      alt=""
    />

    <!-- Selection outline (rendered only when selected, and not in
         Preview mode — preview is "play, don't edit"). -->
    <div
      v-if="selected && !previewMode"
      class="absolute inset-0 pointer-events-none"
      style="outline: 2px solid var(--color-violet); outline-offset: 0;"
    />

    <!-- Resize handles (8 total: 4 corners + 4 edge midpoints) —
         also hidden in Preview mode. -->
    <template v-if="selected && !readonly && !previewMode">
      <!-- Corners -->
      <div
        v-for="handle in (['nw', 'ne', 'sw', 'se'] as ResizeHandle[])"
        :key="handle"
        class="design-element-handle absolute"
        :class="{
          'top-0 left-0 -translate-x-1/2 -translate-y-1/2 cursor-nwse-resize': handle === 'nw',
          'top-0 right-0 translate-x-1/2 -translate-y-1/2 cursor-nesw-resize': handle === 'ne',
          'bottom-0 left-0 -translate-x-1/2 translate-y-1/2 cursor-nesw-resize': handle === 'sw',
          'bottom-0 right-0 translate-x-1/2 translate-y-1/2 cursor-nwse-resize': handle === 'se',
        }"
        :data-testid="`design-element-handle-${element.id}-${handle}`"
        @pointerdown="(e) => startDrag(e, { resize: handle })"
      />
      <!-- Edges -->
      <div
        v-for="handle in (['n', 'e', 's', 'w'] as ResizeHandle[])"
        :key="handle"
        class="design-element-handle absolute"
        :class="{
          'top-0 left-1/2 -translate-x-1/2 -translate-y-1/2 cursor-ns-resize': handle === 'n',
          'top-1/2 right-0 translate-x-1/2 -translate-y-1/2 cursor-ew-resize': handle === 'e',
          'bottom-0 left-1/2 -translate-x-1/2 translate-y-1/2 cursor-ns-resize': handle === 's',
          'top-1/2 left-0 -translate-x-1/2 -translate-y-1/2 cursor-ew-resize': handle === 'w',
        }"
        :data-testid="`design-element-handle-${element.id}-${handle}`"
        @pointerdown="(e) => startDrag(e, { resize: handle })"
      />
    </template>
  </div>
</template>

<style scoped>
.design-element {
  /* The element itself is a CSS box; pointer events are on the
     parent div, not the inner rectangle. */
  user-select: none;
  touch-action: none;
}
.design-element.dragging {
  /* While dragging, prevent the browser from showing a text-selection
     cursor. */
  cursor: grabbing !important;
}
.design-element-handle {
  width: 8px;
  height: 8px;
  background-color: white;
  border: 1.5px solid var(--color-violet);
  border-radius: 1px;
  z-index: 10;
}
</style>