<!--
  LayersPanel — vertical list of design elements on the active page,
  ordered top-to-bottom from highest z-index to lowest.

  Each row shows the element name + type. Click selects; the up/down
  buttons reorder z-index (the parent emits `reorder` with the new
  ordered list of element ids). The × button deletes an element.

  This is the Figma/Sketch "layers" panel — a tree of all elements on
  the page, used to navigate a design with many elements where the
  canvas alone becomes hard to manage.

  Chunk 7 (grouped-layers plan): elements are now a TREE, not a flat
  list. Elements with `parent_id` set are nested under their parent.
  Tree render happens via the recursive `<LayerRow>` component; the
  panel itself owns the `layerTree` computed + `collapsedIds` state
  + per-parent move-up/move-down logic.

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
    data-testid="design-layer-${elementId}" on each row (delegated
    to LayerRow)
    data-testid="design-layer-toggle-${elementId}" on each chevron
    data-testid="design-layer-reorder-up-${elementId}" on each up button
    data-testid="design-layer-reorder-down-${elementId}" on each down button
    data-testid="design-layer-delete-${elementId}" on each × button
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import type { DesignElement } from '../../api'
import LayerRow, { type LayerTreeNode } from './LayerRow.vue'
import DesignContextMenu from './DesignContextMenu.vue'
import { useDesignContextMenu } from '../../composables/useDesignContextMenu'

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
  // NEW: right-click on a layer row → context menu. Parent wires
  // the Group / Select all / Bring / Send / Delete actions to the
  // appropriate handlers (useDesignHandlers, store actions).
  group: [targetIds: string[]]
  ungroup: [elementId: string]
  selectAll: []
  bringToFront: [targetIds: string[]]
  bringForward: [targetIds: string[]]
  sendBackward: [targetIds: string[]]
  sendToBack: [targetIds: string[]]
  contextMenuDelete: [targetIds: string[]]
}>()

const contextMenu = useDesignContextMenu()

function handleLayerContextMenu(payload: { event: MouseEvent; targetIds: string[] }): void {
  // Preview mode / readonly: silently ignore right-clicks (no menu).
  if (props.readonly) return
  contextMenu.open(payload.event, payload.targetIds)
}

/**
 * Build a tree of nested `LayerTreeNode`s from a flat `DesignElement[]`.
 *
 * Algorithm:
 *   1. Walk all elements; create a `LayerTreeNode` for each.
 *   2. Bucket them by `parent_id` (or `null` for top-level).
 *   3. For each node, look up its children by its own id and assign.
 *   4. Sort each bucket by z_index DESC then position ASC (matches
 *      the legacy flat sort).
 *   5. Return the top-level bucket (parent_id === null).
 *
 * Why a fresh Map<string, LayerTreeNode> for each pass instead of
 * mutating `elements` directly: each `LayerTreeNode.children` must
 * reference the SAME `LayerTreeNode` instance that the loop just
 * created (not a fresh one), otherwise the tree would lose the
 * upward link to the parent.
 */
const layerTree = computed<LayerTreeNode[]>(() => {
  const byParent = new Map<string | null, LayerTreeNode[]>()
  const nodes = new Map<string, LayerTreeNode>()
  for (const e of props.elements) {
    const node: LayerTreeNode = { element: e, children: [] }
    nodes.set(e.id, node)
    // The backend's `listElements` returns `COALESCE(de.parent_id, '')`
    // — so a top-level element (parent_id IS NULL) arrives as
    // `parent_id === ""` (empty string), NOT null/undefined. Treat
    // empty string the same as nullish so top-level rows land in the
    // `null` bucket instead of a separate `""` bucket that the final
    // `byParent.get(null) ?? []` returns empty. See the regression
    // test in LayersPanel.spec.ts for the wire shape.
    const pid = e.parent_id || null
    if (!byParent.has(pid)) byParent.set(pid, [])
    byParent.get(pid)!.push(node)
  }
  for (const node of nodes.values()) {
    node.children = byParent.get(node.element.id) ?? []
  }
  for (const [, children] of byParent) {
    children.sort((a, b) => {
      if (b.element.z_index !== a.element.z_index) {
        return b.element.z_index - a.element.z_index
      }
      return a.element.position - b.element.position
    })
  }
  return byParent.get(null) ?? []
})

/**
 * Per-element collapse state. A `Set` because collapse is binary
 * per-id. Held as `ref(new Set)` so a replacement (not a mutation)
 * triggers Vue 3 reactivity. The Set is passed DOWN to `<LayerRow>`
 * by reference (read-only in the child).
 */
const collapsedIds = ref<Set<string>>(new Set())

const toggleCollapse = (elementId: string): void => {
  // Replace the Set so downstream consumers see the change. Mutating
  // in place would NOT trigger the row's `isCollapsed` computed to
  // re-evaluate because Vue 3 doesn't observe Set mutations.
  const next = new Set(collapsedIds.value)
  if (next.has(elementId)) next.delete(elementId)
  else next.add(elementId)
  collapsedIds.value = next
}

/**
 * Walk the tree to find a node by id. Returns the node + its
 * sibling array (the parent's children) + the node's index within
 * that array. Used by `handleMoveUp` / `handleMoveDown` to swap
 * with the previous / next sibling.
 *
 * For a top-level element, `siblings` is `layerTree` (the top-level
 * array) and `parent` is `null`. For a nested element, `siblings`
 * is the parent's `children` array.
 */
function findNode(
  nodes: LayerTreeNode[],
  elementId: string,
): { node: LayerTreeNode; siblings: LayerTreeNode[]; index: number } | null {
  for (let i = 0; i < nodes.length; i++) {
    if (nodes[i]!.element.id === elementId) {
      return { node: nodes[i]!, siblings: nodes, index: i }
    }
    const found = findNode(nodes[i]!.children, elementId)
    if (found) return found
  }
  return null
}

/**
 * Deep-clone the tree so we can swap siblings without mutating the
 * `layerTree` computed (which is owned by Vue's reactivity and
 * should be treated as immutable). The clone preserves `element`
 * references (no need to copy those — only the tree structure
 * mutates).
 */
function cloneTree(nodes: LayerTreeNode[]): LayerTreeNode[] {
  return nodes.map((n) => ({
    element: n.element,
    children: cloneTree(n.children),
  }))
}

/**
 * Flatten the tree depth-first (parent before its children, then
 * move to the next sibling) into a top-to-bottom id list. This is
 * the wire shape `reorder` emits — the parent re-orders its
 * `elements` array by these ids (or applies z_index deltas, depending
 * on the eventual `PATCH /reorder` endpoint — currently the wire is
 * the same as the pre-Chunk-7 flat wire).
 */
function flattenTopDown(nodes: LayerTreeNode[]): string[] {
  const ids: string[] = []
  for (const n of nodes) {
    ids.push(n.element.id)
    if (n.children.length > 0) ids.push(...flattenTopDown(n.children))
  }
  return ids
}

/**
 * Move the element at `elementId` up by one (toward the top of the
 * panel). In a tree, "up" means swapping with the previous SIBLING
 * within the same parent's children array. For top-level elements,
 * the parent is the panel itself (the top-level `layerTree`).
 *
 * Emits `reorder` with the new top-to-bottom depth-first id list.
 */
const handleMoveUp = (elementId: string): void => {
  if (props.readonly) return
  const found = findNode(layerTree.value, elementId)
  if (!found) return
  if (found.index <= 0) return // already first sibling
  const cloned = cloneTree(layerTree.value)
  const clonedFound = findNode(cloned, elementId)
  if (!clonedFound) return
  const siblings = clonedFound.siblings
  const idx = clonedFound.index
  const above = siblings[idx - 1]!
  const current = siblings[idx]!
  siblings[idx - 1] = current
  siblings[idx] = above
  emit('reorder', flattenTopDown(cloned))
}

const handleMoveDown = (elementId: string): void => {
  if (props.readonly) return
  const found = findNode(layerTree.value, elementId)
  if (!found) return
  if (found.index >= found.siblings.length - 1) return // already last sibling
  const cloned = cloneTree(layerTree.value)
  const clonedFound = findNode(cloned, elementId)
  if (!clonedFound) return
  const siblings = clonedFound.siblings
  const idx = clonedFound.index
  const below = siblings[idx + 1]!
  const current = siblings[idx]!
  siblings[idx + 1] = current
  siblings[idx] = below
  emit('reorder', flattenTopDown(cloned))
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
      <LayerRow
        v-for="node in layerTree"
        :key="node.element.id"
        :node="node"
        :depth="0"
        :selected-ids="selectedIds"
        :collapsed-ids="collapsedIds"
        :readonly="readonly"
        @select="(p) => emit('select', p)"
        @delete="(id) => emit('delete', id)"
        @toggle-collapse="toggleCollapse"
        @move-up="handleMoveUp"
        @move-down="handleMoveDown"
        @contextmenu="handleLayerContextMenu"
      />
    </div>
    <!-- Right-click context menu (full item table lands in Chunk 5;
         this commit renders the empty shell so the composable's
         open/close lifecycle can be exercised). -->
    <DesignContextMenu
      :visible="contextMenu.state.value.visible"
      :x="contextMenu.state.value.x"
      :y="contextMenu.state.value.y"
      :target-ids="contextMenu.state.value.targetIds"
      :elements="elements"
      @group="(ids) => emit('group', ids)"
      @ungroup="(id) => emit('ungroup', id)"
      @select-all="emit('selectAll')"
      @bring-to-front="(ids) => emit('bringToFront', ids)"
      @bring-forward="(ids) => emit('bringForward', ids)"
      @send-backward="(ids) => emit('sendBackward', ids)"
      @send-to-back="(ids) => emit('sendToBack', ids)"
      @delete="(ids) => emit('contextMenuDelete', ids)"
      @close="contextMenu.close()"
    />
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
