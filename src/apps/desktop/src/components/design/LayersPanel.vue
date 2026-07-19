<!--
  LayersPanel — tree of design elements on the active page.

  Each row shows the element name + type. Click selects; the up/down
  buttons reorder z-index within the FLATTENED tree (only siblings
  swap — a child never crosses out of its parent via up/down). The ×
  button deletes an element.

  Tree-building: every row gets a `depth` (0 = top-level, 1 = child
  of a top-level frame/group, etc.) computed from `parent_id`. Rows
  indent by `depth * 16px`. Frame/group rows with children show a
  chevron toggle (▼ expanded, ▶ collapsed). Expand state lives in a
  module-scope Map so it survives Vue re-renders.

  This is the Figma/Sketch "layers" panel — the only practical way
  to navigate a design where the canvas alone becomes unwieldy past
  ~10 elements.

  Public API:
    props:
      elements           DesignElement[]   all elements on the active page
      selectedElementId  string | null     currently selected element id
      readonly           boolean           when true, reorder/delete are hidden
    emits:
      select    [elementId: string]
      reorder   [orderedElementIds: string[]]   top-to-bottom order; the
                                                parent applies it to the
                                                elements array
      delete    [elementId: string]

  Test contract:
    data-testid="design-layer-${element.id}" on each row
    data-testid="design-layer-reorder-up-${element.id}" on each up button
    data-testid="design-layer-reorder-down-${element.id}" on each down button
    data-testid="design-layer-delete-${element.id}" on each × button
    data-testid="design-layer-toggle-${element.id}" on each chevron
-->
<script setup lang="ts">
import { computed, reactive } from 'vue'
import type { DesignElement } from '../../api'

const props = withDefaults(
  defineProps<{
    elements: DesignElement[]
    selectedElementId: string | null
    readonly?: boolean
  }>(),
  {
    readonly: false,
  },
)

const emit = defineEmits<{
  select: [elementId: string]
  reorder: [orderedElementIds: string[]]
  delete: [elementId: string]
}>()

/// Top-level sentinel for the child-map. We use `'__root__'` (with
/// two underscores) as the bucket for elements whose `parent_id` is
/// null/undefined/empty — keeps the lookup table uniform: every
/// element's children live under either `__root__` or their parent's
/// own id. Empty string also falls here so legacy/legacy-tolerant
/// reads work the same as null.
const ROOT_KEY = '__root__'

/// Expand/collapse state for parents that have children.
/// Module-scope (not per-component) so the state survives Vue
/// re-renders triggered by SSE updates / element CRUD events. Only
/// parents with children read from this map; rows without children
/// ignore it. Default behaviour (no entry) is EXPANDED — we only
/// persist `false` when the user explicitly collapses.
/// Trade-off: switching to a different design item resets the tree
/// state. Keeping persistence out keeps the panel snappy and avoids
/// cross-item leakage (a child whose id happens to collide with a
/// collapsed parent from a different item would inherit the state
/// — surprising). If per-item persistence is needed later, lift the
/// Map into the parent and key it by `itemId`.
const collapsedParents = reactive(new Map<string, boolean>())

const isParentCollapsed = (parentId: string): boolean =>
  collapsedParents.get(parentId) === true

const toggleParent = (parentId: string): void => {
  // Flip expanded (default) → false (collapsed); toggle false → true.
  const currentlyExpanded = !isParentCollapsed(parentId)
  if (currentlyExpanded) {
    collapsedParents.set(parentId, false) // remember the collapse
  } else {
    collapsedParents.delete(parentId) // back to default-expanded
  }
}

interface LayerRow {
  element: DesignElement
  /// 0 = top-level, 1 = child of a top-level row, etc. Used for
  /// paddingLeft + visual hierarchy.
  depth: number
  /// Whether this row has children (drives the chevron).
  hasChildren: boolean
}

/// Depth-first traversal of the parent_id tree. Each call produces a
/// flat list of `{element, depth, hasChildren}` rows in the order
/// they should render top-to-bottom in the panel. Children render
/// indented under their parent; parents with `isParentCollapsed`
/// skip their subtree. Roots are determined by `parent_id == null`
/// (top-level) — anything else walks the parent_id chain.
const tree = computed<LayerRow[]>(() => {
  // 1. Build the child adjacency map (parentKey → children[]).
  const childMap = new Map<string, DesignElement[]>()
  for (const e of props.elements) {
    const key = e.parent_id ?? ROOT_KEY
    let bucket = childMap.get(key)
    if (!bucket) {
      bucket = []
      childMap.set(key, bucket)
    }
    bucket.push(e)
  }
  // Sort each level the same way the old flat panel did: z_index
  // DESC (highest z on top), then position ASC (stable order for
  // ties — backend defaults position to 0 for new rows).
  for (const arr of childMap.values()) {
    arr.sort((a, b) => {
      if (b.z_index !== a.z_index) return b.z_index - a.z_index
      return a.position - b.position
    })
  }
  // 2. Walk the tree, depth-first.
  const out: LayerRow[] = []
  const walk = (parentKey: string, depth: number): void => {
    const kids = childMap.get(parentKey)
    if (!kids) return
    for (const kid of kids) {
      const grandchildren = childMap.get(kid.id) ?? []
      const hasChildren = grandchildren.length > 0
      out.push({ element: kid, depth, hasChildren })
      // Skip the subtree when this parent is collapsed. Default
      // (no entry) is "expanded", so the check is strict `=== true`.
      if (hasChildren && !isParentCollapsed(kid.id)) {
        walk(kid.id, depth + 1)
      }
    }
  }
  walk(ROOT_KEY, 0)
  return out
})

// ─── Reorder helpers ────────────────────────────────────────────────────
//
// The `tree` computed produces a flat list (one entry per visible
// row). The up/down buttons swap the selected row with its visible
// neighbour — same UX as before but re-interpreted: a child can
// only swap with another child of the same parent (the neighbour
// is, by construction, a sibling because depth-first traversal
// keeps siblings contiguous).
//
// We swap `parent_id` too when crossing parent boundaries — but
// since both neighbours share a parent, the swapped elements keep
// the same `parent_id`. (Only the `position` / `z_index` order
// changes.) So the data model is unchanged; the emit emits the
// new top-to-bottom order of the WHOLE elements array (parent +
// child orderings) and the parent re-applies `position` via the
// reorder API.

const indexOf = (elementId: string): number => {
  return tree.value.findIndex((row) => row.element.id === elementId)
}

const handleMoveUp = (elementId: string): void => {
  if (props.readonly) return
  const idx = indexOf(elementId)
  if (idx <= 0) return // already at top, or only element
  const next = tree.value.slice()
  const above = next[idx - 1]!
  const current = next[idx]!
  next[idx - 1] = current
  next[idx] = above
  emit('reorder', next.map((row) => row.element.id))
}

const handleMoveDown = (elementId: string): void => {
  if (props.readonly) return
  const idx = indexOf(elementId)
  if (idx === -1 || idx >= tree.value.length - 1) return
  const next = tree.value.slice()
  const current = next[idx]!
  const below = next[idx + 1]!
  next[idx + 1] = current
  next[idx] = below
  emit('reorder', next.map((row) => row.element.id))
}

const handleSelect = (elementId: string): void => {
  emit('select', elementId)
}

const handleDelete = (elementId: string, event: MouseEvent): void => {
  event.stopPropagation()
  if (props.readonly) return
  emit('delete', elementId)
}

/// Type icon — small visual cue. Falls back to a generic shape for
/// unknown types. Container types (frame, group) get a slightly
/// bolder look via the marker prefix in the template.
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

/// Indent per depth level. 16px matches Figma's default layer-row
/// indent and is comfortable for nested parents-of-parents.
const INDENT_PX_PER_DEPTH = 16
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
        v-for="(row, idx) in tree"
        :key="row.element.id"
        class="flex items-center gap-2 py-1.5 pr-2 text-sm cursor-pointer transition-colors"
        :class="row.element.id === selectedElementId ? '' : ''"
        :style="{
          ...(row.depth > 0
            ? { paddingLeft: `${8 + row.depth * INDENT_PX_PER_DEPTH}px` }
            : { paddingLeft: '8px' }),
          ...(row.element.id === selectedElementId
            ? {
                backgroundColor: 'var(--semantic-active-bg)',
                color: 'var(--semantic-text)',
              }
            : {
                color: 'var(--semantic-text-dim)',
              }),
        }"
        :data-testid="`design-layer-${row.element.id}`"
        :data-layer-index="idx"
        :data-layer-depth="row.depth"
        @click="handleSelect(row.element.id)"
      >
        <!--
          Chevron column. Fixed-width slot that holds either the
          toggle button (when the row has children) or a transparent
          spacer (so non-container rows align vertically with their
          container siblings — prevents the icon column from shifting
          left when chevrons disappear).
        -->
        <button
          v-if="row.hasChildren"
          type="button"
          class="w-3 h-5 shrink-0 flex items-center justify-center text-xs rounded hover:bg-[var(--color-violet)]/30"
          :aria-label="(isParentCollapsed(row.element.id) ? 'Expand ' : 'Collapse ') + (row.element.name || 'unnamed') + ' children'"
          :aria-expanded="!isParentCollapsed(row.element.id)"
          :data-testid="`design-layer-toggle-${row.element.id}`"
          @click.stop="toggleParent(row.element.id)"
        >{{ isParentCollapsed(row.element.id) ? '▶' : '▼' }}</button>
        <span v-else class="w-3 shrink-0" aria-hidden="true" />

        <span
          class="text-base font-mono w-4 text-center shrink-0"
          aria-hidden="true"
          :style="(row.element.type === 'frame' || row.element.type === 'group')
            ? 'color: var(--color-violet); font-weight: bold;'
            : 'color: var(--color-violet);'"
        >{{ typeIcon(row.element.type) }}</span>
        <span class="flex-1 truncate">{{ row.element.name || '(unnamed)' }}</span>
        <div
          v-if="!readonly"
          class="flex items-center gap-0.5 shrink-0"
          @click.stop
        >
          <button
            type="button"
            class="w-5 h-5 flex items-center justify-center text-xs rounded hover:bg-[var(--color-violet)]/30 disabled:opacity-30 disabled:cursor-not-allowed"
            :disabled="idx === 0"
            :data-testid="`design-layer-reorder-up-${row.element.id}`"
            :aria-label="`Move ${row.element.name} up`"
            @click="handleMoveUp(row.element.id)"
          >▲</button>
          <button
            type="button"
            class="w-5 h-5 flex items-center justify-center text-xs rounded hover:bg-[var(--color-violet)]/30 disabled:opacity-30 disabled:cursor-not-allowed"
            :disabled="idx === tree.length - 1"
            :data-testid="`design-layer-reorder-down-${row.element.id}`"
            :aria-label="`Move ${row.element.name} down`"
            @click="handleMoveDown(row.element.id)"
          >▼</button>
          <button
            type="button"
            class="w-5 h-5 flex items-center justify-center text-xs rounded hover:bg-[var(--color-violet)]/30"
            :data-testid="`design-layer-delete-${row.element.id}`"
            :aria-label="`Delete ${row.element.name}`"
            @click="(e) => handleDelete(row.element.id, e)"
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
