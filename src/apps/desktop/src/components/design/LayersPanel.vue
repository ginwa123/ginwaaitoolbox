<!--
  LayersPanel — vertical list of design elements on the active page,
  ordered top-to-bottom from highest z-index to lowest.

  Each row shows the element name + type. Click selects; the up/down
  buttons reorder z-index (the parent emits `reorder` with the new
  ordered list of element ids). The × button deletes an element.

  This is the Figma/Sketch "layers" panel — a tree of all elements on
  the page, used to navigate a design with many elements where the
  canvas alone becomes hard to manage.

  Public API:
    props:
      elements           DesignElement[]   all elements on the active page
      selectedElementId  string | null     currently selected element id
      readonly           boolean           when true, reorder/delete are hidden
    emits:
      select    [elementId: string]
      reorder   [orderedElementIds: string[]]   the new top-to-bottom order
      delete    [elementId: string]

  Test contract:
    data-testid="design-layer-${elementId}" on each row
    data-testid="design-layer-reorder-up-${elementId}" on each up button
    data-testid="design-layer-reorder-down-${elementId}" on each down button
    data-testid="design-layer-delete-${elementId}" on each × button
-->
<script setup lang="ts">
import { computed } from 'vue'
import type { DesignElement } from '../../api'

const props = withDefaults(
  defineProps<{
    elements: DesignElement[]
    // Multi-aware; a row highlights if its id is in the set.
    selectedIds: string[]
    readonly?: boolean
  }>(),
  {
    readonly: false,
  },
)

const emit = defineEmits<{
  // Structured payload so the parent can distinguish Shift+click
  // (additive = true) from a plain click (additive = false). The
  // parent handles the actual Set vs replace logic.
  select: [payload: { elementId: string; additive: boolean }]
  reorder: [orderedElementIds: string[]]
  delete: [elementId: string]
}>()

// Layers are sorted top-to-bottom by z_index DESCENDING (highest z
// first), then by position ASCENDING (stable order for ties). The
// backend stores z_index explicitly; elements without a z_index
// default to 0 on the server, so a stable secondary sort avoids
// jitter on first-load.
const layers = computed<DesignElement[]>(() => {
  return props.elements
    .slice()
    .sort((a, b) => {
      if (b.z_index !== a.z_index) return b.z_index - a.z_index
      return a.position - b.position
    })
})

const indexOf = (elementId: string): number => {
  return layers.value.findIndex((e) => e.id === elementId)
}

// Move the element at the given current index up by one (toward the
// top of the layers panel, which is higher z-index). Swaps with the
// element at index - 1 and emits the new ordered list.
const handleMoveUp = (elementId: string): void => {
  if (props.readonly) return
  const idx = indexOf(elementId)
  if (idx <= 0) return // already at top
  const next = layers.value.slice()
  // Bounds-checked above (idx >= 1), so non-null assertions are safe.
  const above = next[idx - 1]!
  const current = next[idx]!
  next[idx - 1] = current
  next[idx] = above
  // Emit top-to-bottom order; the parent will re-order the elements
  // array (preserving the bottom-to-top order of the layers panel).
  emit('reorder', next.map((e) => e.id))
}

const handleMoveDown = (elementId: string): void => {
  if (props.readonly) return
  const idx = indexOf(elementId)
  if (idx === -1 || idx >= layers.value.length - 1) return // already at bottom
  const next = layers.value.slice()
  // Bounds-checked above (idx < layers.length - 1), so non-null assertions are safe.
  const current = next[idx]!
  const below = next[idx + 1]!
  next[idx + 1] = current
  next[idx] = below
  emit('reorder', next.map((e) => e.id))
}

const handleSelect = (elementId: string, event: MouseEvent): void => {
  emit('select', { elementId, additive: event.shiftKey })
}

const handleDelete = (elementId: string, event: MouseEvent): void => {
  event.stopPropagation()
  if (props.readonly) return
  emit('delete', elementId)
}

// Type icon emoji — small visual cue for the type. Falls back to a
// generic shape icon for unknown types.
const typeIcon = (type: DesignElement['type']): string => {
  switch (type) {
    case 'rectangle': return '▭'
    case 'ellipse':   return '◯'
    case 'text':      return 'T'
    case 'image':     return '🖼'
    case 'frame':     return '◳'
    case 'group':     return '◫'
    default:          return '◇'
  }
}
</script>

<template>
  <div
    class="layers-panel flex flex-col h-full min-h-0"
    data-testid="layers-panel"
  >
    <div
      class="px-3 py-2 text-xs font-semibold shrink-0"
      style="color: var(--semantic-text-dim); border-bottom: 1px solid var(--color-border);"
    >
      Layers ({{ elements.length }})
    </div>
    <div
      v-if="elements.length === 0"
      class="flex-1 flex items-center justify-center p-4 text-xs"
      style="color: var(--semantic-text-dim);"
      data-testid="layers-panel-empty"
    >
      No elements on this page yet
    </div>
    <div
      v-else
      class="flex-1 overflow-y-auto"
      style="scrollbar-width: thin;"
    >
      <div
        v-for="(element, idx) in layers"
        :key="element.id"
        class="flex items-center gap-2 px-2 py-1.5 text-sm cursor-pointer transition-colors"
        :style="selectedIds.includes(element.id)
          ? 'background-color: var(--semantic-active-bg); color: var(--semantic-text);'
          : 'color: var(--semantic-text-dim);'"
        :data-testid="`design-layer-${element.id}`"
        :data-layer-index="idx"
        @click="(e) => handleSelect(element.id, e)"
      >
        <span
          class="text-base font-mono w-4 text-center shrink-0"
          aria-hidden="true"
          style="color: var(--color-violet);"
        >{{ typeIcon(element.type) }}</span>
        <span class="flex-1 truncate">{{ element.name || '(unnamed)' }}</span>
        <div
          v-if="!readonly"
          class="flex items-center gap-0.5 shrink-0"
          @click.stop
        >
          <button
            type="button"
            class="w-5 h-5 flex items-center justify-center text-xs rounded hover:bg-[var(--color-violet)]/30 disabled:opacity-30 disabled:cursor-not-allowed"
            :disabled="idx === 0"
            :data-testid="`design-layer-reorder-up-${element.id}`"
            :aria-label="`Move ${element.name} up`"
            @click="handleMoveUp(element.id)"
          >▲</button>
          <button
            type="button"
            class="w-5 h-5 flex items-center justify-center text-xs rounded hover:bg-[var(--color-violet)]/30 disabled:opacity-30 disabled:cursor-not-allowed"
            :disabled="idx === layers.length - 1"
            :data-testid="`design-layer-reorder-down-${element.id}`"
            :aria-label="`Move ${element.name} down`"
            @click="handleMoveDown(element.id)"
          >▼</button>
          <button
            type="button"
            class="w-5 h-5 flex items-center justify-center text-xs rounded hover:bg-[var(--color-violet)]/30"
            :data-testid="`design-layer-delete-${element.id}`"
            :aria-label="`Delete ${element.name}`"
            @click="(e) => handleDelete(element.id, e)"
          >×</button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.layers-panel :deep(div.overflow-y-auto)::-webkit-scrollbar {
  width: 6px;
}
.layers-panel :deep(div.overflow-y-auto)::-webkit-scrollbar-track {
  background: transparent;
}
.layers-panel :deep(div.overflow-y-auto)::-webkit-scrollbar-thumb {
  background: var(--color-border);
  border-radius: 3px;
}
</style>