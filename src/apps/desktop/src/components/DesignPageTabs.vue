<!--
  DesignPageTabs — horizontal tab strip at the top of DesignView.

  Renders one button per page (with the active page highlighted by a
  violet bottom border) plus a "+ Page" button at the end. Pure
  presentation — emits `selectPage` / `addPage` / `deletePage` upward;
  DesignView decides what to do (call the store action, open the
  AddDesignElementDialog, etc.).

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

  Test contract: each tab has data-testid="design-page-tab-${pageId}"
  so the test can target a specific page button. The "+ Page" button
  has data-testid="design-add-page".
-->
<script setup lang="ts">
import type { DesignPage } from '../api'

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
    class="flex items-center border-b shrink-0 overflow-x-auto"
    style="border-color: var(--color-border); background-color: var(--semantic-sidebar-bg);"
    data-testid="design-page-tabs"
  >
    <button
      v-for="page in pages"
      :key="page.id"
      type="button"
      class="px-3 py-2 text-sm font-medium whitespace-nowrap flex items-center gap-2 transition-colors hover:bg-[var(--semantic-active-bg)]"
      :style="page.id === activePageId
        ? 'border-bottom: 2px solid var(--color-violet); color: var(--semantic-text); margin-bottom: -1px;'
        : 'color: var(--semantic-text-dim); border-bottom: 2px solid transparent; margin-bottom: -1px;'"
      :data-testid="`design-page-tab-${page.id}`"
      @click="handleSelect(page.id)"
    >
      <span>{{ page.name }}</span>
      <span
        v-if="pages.length > 1"
        role="button"
        aria-label="Delete page"
        class="text-xs opacity-60 hover:opacity-100"
        style="color: inherit;"
        :data-testid="`design-delete-page-${page.id}`"
        @click="(e) => handleDelete(page.id, e)"
      >×</span>
    </button>
    <button
      type="button"
      class="px-3 py-2 text-sm whitespace-nowrap transition-colors hover:bg-[var(--semantic-active-bg)]"
      style="color: var(--semantic-text-dim);"
      data-testid="design-add-page"
      @click="emit('addPage')"
    >
      + Page
    </button>
  </div>
</template>