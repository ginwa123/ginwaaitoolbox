<!--
  DesignPageRow — single design page row in the workspace sidebar tree.

  Rendered as a nested child of an expanded `design` workspace item
  (parent: <WorkspaceItem>). One row per page; click selects the page
  + activates the design item, hover reveals a × delete button.

  Plan: docs/superpowers/plans/2026-08-06-design-pages-in-workspace-tree.md

  Why this component instead of reusing WorkspaceItemTaskRow?
  WorkspaceItemTaskRow is a 262-line component built around the
  task/routine/pin/drop-indicator mental model. Pages don't have any
  of that — they're just a name + delete. Reusing the task row
  would pull in useTaskActions and 9 conditional template branches
  for state that doesn't exist. A 60-line dedicated component is
  cheaper to read AND to test.

  Why a <div role="button"> instead of a <button> for the row?
  The row contains a nested × delete button. HTML forbids nested
  interactive elements (button-inside-button), so we use a div with
  role="button" + tabindex=0 + keyboard handler (Enter/Space
  activates selectPage). The inner × stays a real <button> for
  proper focus/focus-ring + native form behaviour.

  Public API:
    props:
      page           DesignPage    the page to render
      workspaceId    string        parent workspace id (for emits)
      itemId         string        parent design item id (for emits)
      isActivePage   boolean       true when this page is the active page
    emits:
      selectPage    [page: DesignPage]
      deletePage    [page: DesignPage]
-->
<script setup lang="ts">
import type { DesignPage } from '../../api'

const props = defineProps<{
  page: DesignPage
  workspaceId: string
  itemId: string
  isActivePage: boolean
}>()

const emit = defineEmits<{
  selectPage: [page: DesignPage]
  deletePage: [page: DesignPage]
}>()

const handleSelect = (): void => {
  emit('selectPage', props.page)
}

const handleDelete = (event: Event): void => {
  // Stop propagation so the click doesn't ALSO fire `selectPage`
  // (the outer row handler runs on click — clicking × would
  // otherwise navigate to this page right before deleting it).
  event.stopPropagation()
  emit('deletePage', props.page)
}

const handleKeydown = (event: KeyboardEvent): void => {
  // Enter / Space activate the row (matches the <button> keyboard
  // contract without using a real <button> — see the header comment).
  if (event.key === 'Enter' || event.key === ' ') {
    event.preventDefault()
    handleSelect()
  }
}
</script>

<template>
  <div
    role="button"
    tabindex="0"
    class="flex items-center gap-2 px-3 py-1 rounded text-xs group/page cursor-pointer transition-all duration-200 w-full text-left"
    :style="{
      color: isActivePage ? 'var(--color-aqua)' : 'var(--semantic-text-dim)',
      backgroundColor: isActivePage ? 'var(--semantic-active-bg)' : 'transparent',
    }"
    :data-testid="`design-page-row-${page.id}`"
    :data-active-page="isActivePage ? 'true' : undefined"
    :data-page-id="page.id"
    @click="handleSelect"
    @keydown="handleKeydown"
  >
    <!--
      Subtle 6×6 dot in the same slot as the kanban task's processing
      spinner. For pages, it's a static visual marker (NOT a live
      spinner) — the page is just a child of the design item, not a
      running worker. Same lane as the task row so the visual rhythm
      matches.
    -->
    <span
      class="w-1.5 h-1.5 rounded-full shrink-0"
      style="background-color: currentColor; opacity: 0.5;"
      aria-hidden="true"
    />
    <span class="flex-1 truncate">{{ page.name }}</span>
    <!--
      × delete button (hover-revealed via `group/page`). The Vue 3
      `group/page` modifier (slash syntax) scopes the
      group-hover/page:opacity-100 to this row's hover state, so
      adjacent rows don't reveal each other's × on mouseover.

      Real <button> (not role="button") so focus / focus-ring /
      native form behaviour work as expected.
    -->
    <button
      type="button"
      class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/page:opacity-100 transition-opacity hover:bg-[--semantic-active-bg] hover:text-red-400"
      style="color: var(--semantic-text-dim);"
      title="Delete page"
      aria-label="Delete page"
      :data-testid="`design-page-delete-${page.id}`"
      @click="handleDelete"
    >
      ×
    </button>
  </div>
</template>
