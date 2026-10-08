<!--
  WorkspaceMemoriesSection — the Memories section of workspace settings.

  Local (per-cwd) memories live at `<item-path>/.pabrik/memories/`, one
  directory per workspace item — there is no workspace-level memories
  endpoint. This section picks the item, then reuses
  WorkspaceItemMemoriesView (the same component the item views use) so
  the workspace page and the item page can never disagree about what is
  stored where.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import WorkspaceItemMemoriesView from '../views/WorkspaceItemMemoriesView.vue'

const props = defineProps<{
  /** Route workspace id. */
  workspaceId: string
}>()

const workspacesStore = useWorkspacesStore()

const pathedItems = computed(() => {
  const ws = workspacesStore.workspaces.find((w) => w.id === props.workspaceId)
  return (ws?.items ?? []).filter((item) => !!item.path)
})

const selectedItemId = ref<string | null>(null)

const selectedItem = computed(() => {
  const items = pathedItems.value
  if (items.length === 0) return null
  return items.find((item) => item.id === selectedItemId.value) ?? items[0] ?? null
})

function pick(id: string): void {
  selectedItemId.value = id
}
</script>

<template>
  <div class="flex h-full flex-col gap-4" data-testid="workspace-memories-section">
    <div>
      <h2 class="text-lead font-semibold" style="color: var(--semantic-text)">Memories</h2>
      <p class="text-body mt-1" style="color: var(--semantic-text-muted)">
        Notes stored with this workspace's items, at
        <code>.pabrik/memories/</code> under each item's folder.
      </p>
    </div>

    <div
      v-if="pathedItems.length === 0"
      class="text-body"
      style="color: var(--semantic-text-muted)"
    >
      This workspace has no items with a folder yet — memories appear here once an item has a path.
    </div>

    <template v-else>
      <label class="flex items-center gap-3 text-body" style="color: var(--semantic-text)">
        <span class="shrink-0" style="color: var(--semantic-text-muted)">Item</span>
        <select
          :value="selectedItem?.id ?? ''"
          aria-label="Workspace item"
          data-testid="workspace-memories-item-picker"
          class="px-2 py-1.5 rounded-md text-dense"
          style="
            background-color: var(--semantic-content-bg);
            color: var(--semantic-text);
            border: 1px solid var(--color-border);
          "
          @change="pick(($event.target as HTMLSelectElement).value)"
        >
          <option v-for="item in pathedItems" :key="item.id" :value="item.id">
            {{ item.name }}
          </option>
        </select>
      </label>

      <div v-if="selectedItem?.path" :key="selectedItem.id" class="min-h-0 flex-1">
        <WorkspaceItemMemoriesView :cwd="selectedItem.path" :item-name="selectedItem.name" />
      </div>
    </template>
  </div>
</template>
