<!--
  DesignPageTabs — vertical page list in the LEFT sidebar of DesignView
  (Figma / Sketch convention).

  Renders one button per page (with the active page highlighted by a
  3px violet LEFT edge) plus a "+ Page" button at the bottom. Pure
  presentation — emits `selectPage` / `addPage` / `deletePage`
  upward; DesignView decides what to do (call the store action, open
  the AddDesignElementDialog, etc.).

  Layout history. This component used to be a horizontal tab strip
  rendered at the TOP of DesignView (`flex items-center overflow-x-auto`
  with a 2px bottom border on the active tab). After the user's
  request "move pages list from top to left" (see plan
  docs/superpowers/plans/2026-08-06-design-pages-left-sidebar.md), the
  wrapper class changed to `flex flex-col overflow-y-auto` and the
  active accent moved to the left edge.

  The component name stays `DesignPageTabs` (renaming would force
  churn across imports + spec files for no functional benefit). The
  data-testid set is preserved for back-compat:
    - root container: design-page-tabs
    - per-page tab:   design-page-tab-${pageId}
    - per-page ×:     design-delete-page-${pageId}
    - + Page button:  design-add-page

  Public API:
    props:
      pages         DesignPage[]       all pages in this design item
      activePageId  string             id of the currently displayed page
      workspaceId   string             parent workspace id (for tests)
      itemId        string             parent design item id (for tests)
    emits:
      selectPage    [pageId: string]
      addPage       []
      deletePage    [pageId: string]
-->
<script setup lang="ts">
import type { DesignPage } from '../../api'

const props = defineProps<{
  pages: DesignPage[]
  activePageId: string
  workspaceId: string
  itemId: string
}>()

const emit = defineEmits<{
  selectPage: [pageId: string]
  addPage: []
  deletePage: [pageId: string]
}>()

const handleSelect = (pageId: string): void => {
  if (pageId === props.activePageId) return
  emit('selectPage', pageId)
}

const handleDelete = (pageId: string, event: MouseEvent): void => {
  // Stop propagation so clicking the × inside a tab doesn't also
  // re-select that page.
  event.stopPropagation()
  emit('deletePage', pageId)
}
</script>

<template>
  <div
    class="flex flex-col overflow-y-auto"
    style="background-color: var(--semantic-sidebar-bg); border-right: 1px solid var(--color-border);"
    data-testid="design-page-tabs"
  >
    <button
      v-for="page in pages"
      :key="page.id"
      type="button"
      class="px-3 py-2 text-sm font-medium flex items-center gap-2 transition-colors hover:bg-[var(--semantic-active-bg)] text-left w-full min-w-0"
      :style="page.id === activePageId
        ? 'border-left: 3px solid var(--color-violet); color: var(--semantic-text); padding-left: calc(0.75rem - 3px);'
        : 'border-left: 3px solid transparent; color: var(--semantic-text-dim); padding-left: calc(0.75rem - 3px);'"
      :data-testid="`design-page-tab-${page.id}`"
      :data-active-page-id="page.id === activePageId ? page.id : undefined"
      @click="handleSelect(page.id)"
    >
      <span class="flex-1 truncate min-w-0">{{ page.name }}</span>
      <span
        v-if="pages.length > 1"
        role="button"
        aria-label="Delete page"
        class="text-xs opacity-60 hover:opacity-100 shrink-0"
        style="color: inherit;"
        :data-testid="`design-delete-page-${page.id}`"
        @click="(e) => handleDelete(page.id, e)"
      >×</span>
    </button>
    <button
      type="button"
      class="px-3 py-2 text-sm whitespace-nowrap transition-colors hover:bg-[var(--semantic-active-bg)] text-left w-full border-left: 3px solid transparent;"
      style="color: var(--semantic-text-dim); padding-left: calc(0.75rem - 3px);"
      data-testid="design-add-page"
      @click="emit('addPage')"
    >
      + Page
    </button>
  </div>
</template>
