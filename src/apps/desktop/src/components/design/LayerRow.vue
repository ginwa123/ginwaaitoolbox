<!--
  LayerRow — recursive row for LayersPanel's tree render.

  One row per `DesignElement`. Indents by `depth * 16px`. If the
  element has children (`node.children.length > 0`), renders a ▶/▼
  chevron before the type icon to toggle collapse. When expanded,
  recursively renders each child as a `<LayerRow>` with `depth + 1`.

  Why a separate component:
  - Tests can mount `LayerRow` in isolation for tree behaviour.
  - LayersPanel stays focused on top-level wiring + the tree builder.
  - The recursive self-reference is clean (Vue 3 supports it via
    `defineOptions({ name: 'LayerRow' })`).

  Public API:
    props:
      node           LayerTreeNode    this row + its children
      depth          number           0 for top-level, +1 per nesting
      selectedIds    string[]         multi-aware selection array
      readonly       boolean          when true, hide up/down/delete
      collapsedIds   Set<string>      shared collapse state from parent
    emits:
      select           [{ elementId: string; additive: boolean }]
      delete           [string]                       (elementId)
      toggleCollapse   [string]                       (elementId)
      moveUp           [string]                       (elementId)
      moveDown         [string]                       (elementId)

  Test contract:
    data-testid="design-layer-${elementId}" on the row div
    data-testid="design-layer-toggle-${elementId}" on the chevron button
    data-testid="design-layer-reorder-up-${elementId}" on the up button
    data-testid="design-layer-reorder-down-${elementId}" on the down button
    data-testid="design-layer-delete-${elementId}" on the × button
-->
<script setup lang="ts">
import { computed } from 'vue'
import type { DesignElement } from '../../api'

/**
 * One node in the design-page layers tree. Each `DesignElement` can
 * have N nested children (when its `parent_id` points to a `group`
 * or `frame` element). The tree is built in `LayersPanel.vue` via
 * the `layerTree` computed.
 */
export interface LayerTreeNode {
  element: DesignElement
  children: LayerTreeNode[]
}

// Vue 3 requires either a script-level `name: 'LayerRow'` declaration
// OR `defineOptions({ name: 'LayerRow' })` in <script setup> for the
// recursive `<LayerRow>` usage in the template to type-check under
// vue-tsc. Without this, vue-tsc reports:
//
//   "Component LayerRow is not registered in any module"
//
// which silently passes in `bunx vitest run` but FAILS the strict
// type-check in `bun run build`. See
// `.nalar/memories/nalar-frontend-patterns.md` §"bun run build is
// the type-check" for the bun/Node vue-tsc split.
defineOptions({ name: 'LayerRow' })

const props = defineProps<{
  node: LayerTreeNode
  depth: number
  selectedIds: string[]
  readonly: boolean
  /**
   * Shared collapse state from the parent. The parent owns a
   * `ref(new Set<string>())` and passes the Set down by reference.
   * Vue 3 reactivity requires the parent to REPLACE the Set (not
   * mutate it) to trigger re-renders — LayerRow just READS it.
   */
  collapsedIds: Set<string>
}>()

const emit = defineEmits<{
  select: [payload: { elementId: string; additive: boolean }]
  delete: [elementId: string]
  toggleCollapse: [elementId: string]
  moveUp: [elementId: string]
  moveDown: [elementId: string]
  contextmenu: [payload: { event: MouseEvent; targetIds: string[] }]
}>()

// Computed flags for the row's visual state.
const isSelected = computed(() =>
  props.selectedIds.includes(props.node.element.id),
)
const isCollapsed = computed(() =>
  props.collapsedIds.has(props.node.element.id),
)
const hasChildren = computed(() => props.node.children.length > 0)

// Type icon — same mapping as the original LayersPanel. Kept here so
// the row is self-contained (no need to forward a helper from parent).
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

const handleSelect = (event: MouseEvent): void => {
  // Figma parity: Shift OR Ctrl/Cmd click toggles membership in the
  // multi-selection. Plain click replaces the selection. Alt-click
  // is intentional left unhandled (Linux/macOS window menu shortcut)
  // so it falls through to the plain-click path.
  const additive = event.shiftKey || event.ctrlKey || event.metaKey
  emit('select', {
    elementId: props.node.element.id,
    additive,
  })
}

const handleContextMenu = (event: MouseEvent): void => {
  // Figma parity: right-click on a row that IS in the multi-selection
  // (regardless of shift) opens the menu against the full selection.
  // Right-click on an unselected row replaces the selection with that
  // single id and opens the menu against just that id.
  const isInSelection = props.selectedIds.includes(props.node.element.id)
  if (isInSelection) {
    emit('contextmenu', {
      event,
      targetIds: [...props.selectedIds],
    })
  } else {
    emit('select', { elementId: props.node.element.id, additive: false })
    emit('contextmenu', {
      event,
      targetIds: [props.node.element.id],
    })
  }
}

const handleDelete = (event: MouseEvent): void => {
  // Stop propagation so the click doesn't also fire `select`.
  event.stopPropagation()
  if (props.readonly) return
  emit('delete', props.node.element.id)
}

const handleMoveUp = (event: MouseEvent): void => {
  event.stopPropagation()
  if (props.readonly) return
  emit('moveUp', props.node.element.id)
}

const handleMoveDown = (event: MouseEvent): void => {
  event.stopPropagation()
  if (props.readonly) return
  emit('moveDown', props.node.element.id)
}

const handleChevronClick = (event: MouseEvent): void => {
  // Stop propagation so the chevron click doesn't also fire
  // `select` on the parent row.
  event.stopPropagation()
  emit('toggleCollapse', props.node.element.id)
}
</script>

<template>
  <!-- The row itself. paddingLeft scales by depth so children
       visually nest under their parent. -->
  <div
    class="flex items-center gap-2 px-2 py-1.5 text-sm cursor-pointer transition-colors"
    :style="{
      paddingLeft: `${depth * 16}px`,
      backgroundColor: isSelected
        ? 'var(--semantic-active-bg)'
        : 'transparent',
      color: isSelected
        ? 'var(--semantic-text)'
        : 'var(--semantic-text-dim)',
    }"
    :data-testid="`design-layer-${node.element.id}`"
    @click="handleSelect"
    @contextmenu="handleContextMenu"
  >
    <!-- Chevron (only when the node has children). Spacer span on
         leaf nodes keeps the type icon vertically aligned. -->
    <button
      v-if="hasChildren"
      type="button"
      class="w-4 h-4 flex items-center justify-center text-xs shrink-0"
      :data-testid="`design-layer-toggle-${node.element.id}`"
      :aria-label="isCollapsed ? 'Expand' : 'Collapse'"
      @click="handleChevronClick"
    >{{ isCollapsed ? '▶' : '▼' }}</button>
    <span
      v-else
      class="w-4 h-4 shrink-0"
      aria-hidden="true"
    ></span>

    <!-- Type icon. -->
    <span
      class="text-base font-mono w-4 text-center shrink-0"
      aria-hidden="true"
      style="color: var(--color-violet);"
    >{{ typeIcon(node.element.type) }}</span>

    <!-- Element name (or "(unnamed)" placeholder for legacy rows). -->
    <span class="flex-1 truncate">{{ node.element.name || '(unnamed)' }}</span>

    <!-- Action buttons (reorder + delete). Hidden in readonly. -->
    <div
      v-if="!readonly"
      class="flex items-center gap-0.5 shrink-0"
      @click.stop
    >
      <button
        type="button"
        class="w-5 h-5 flex items-center justify-center text-xs rounded hover:bg-[var(--color-violet)]/30 disabled:opacity-30 disabled:cursor-not-allowed"
        :data-testid="`design-layer-reorder-up-${node.element.id}`"
        :aria-label="`Move ${node.element.name} up`"
        @click="handleMoveUp"
      >▲</button>
      <button
        type="button"
        class="w-5 h-5 flex items-center justify-center text-xs rounded hover:bg-[var(--color-violet)]/30 disabled:opacity-30 disabled:cursor-not-allowed"
        :data-testid="`design-layer-reorder-down-${node.element.id}`"
        :aria-label="`Move ${node.element.name} down`"
        @click="handleMoveDown"
      >▼</button>
      <button
        type="button"
        class="w-5 h-5 flex items-center justify-center text-xs rounded hover:bg-[var(--color-violet)]/30"
        :data-testid="`design-layer-delete-${node.element.id}`"
        :aria-label="`Delete ${node.element.name}`"
        @click="handleDelete"
      >×</button>
    </div>
  </div>

  <!-- Recursive children. Only render when the parent is expanded
       AND the node has children. The template-side guard avoids
       emitting an empty fragment. -->
  <template v-if="hasChildren && !isCollapsed">
    <LayerRow
      v-for="child in node.children"
      :key="child.element.id"
      :node="child"
      :depth="depth + 1"
      :selected-ids="selectedIds"
      :collapsed-ids="collapsedIds"
      :readonly="readonly"
      @select="(p) => emit('select', p)"
      @delete="(id) => emit('delete', id)"
      @toggle-collapse="(id) => emit('toggleCollapse', id)"
      @move-up="(id) => emit('moveUp', id)"
      @move-down="(id) => emit('moveDown', id)"
      @contextmenu="(p) => emit('contextmenu', p)"
    />
  </template>
</template>
