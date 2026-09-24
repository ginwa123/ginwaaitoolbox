<script setup lang="ts">
/**
 * Right-click menu for git-branch badges (sidebar chat rows + kanban
 * cards). Teleported to body so overflow ancestors never clip it.
 * Hosts resolve the URLs (PR URL via fetchPrInfoCached, branch URL
 * derived from the PR repo base) and wire @open-branch / @open-pr to
 * their window.open calls. Items with an empty URL render disabled.
 */
withDefaults(
  defineProps<{
    x: number
    y: number
    branch?: string
    branchUrl?: string
    prUrl?: string
  }>(),
  { branch: '', branchUrl: '', prUrl: '' },
)

const emit = defineEmits<{
  openBranch: []
  openPr: []
}>()
</script>

<template>
  <Teleport to="body">
    <div
      data-testid="git-branch-menu"
      role="menu"
      class="fixed z-50 py-1 text-xs rounded-lg shadow-lg"
      :style="{
        left: `${x}px`,
        top: `${y}px`,
        backgroundColor: 'var(--semantic-content-bg)',
        border: '1px solid var(--color-border)',
        color: 'var(--semantic-text)',
      }"
      @click.stop
    >
      <div
        v-if="branch"
        class="px-3 pt-1.5 pb-1 font-mono truncate max-w-[16rem] opacity-60"
        data-testid="git-branch-menu-title"
        :title="branch"
      >
        {{ branch }}
      </div>
      <button
        type="button"
        role="menuitem"
        data-testid="open-branch-new-tab-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80 disabled:opacity-40"
        :disabled="!branchUrl"
        :title="branchUrl || 'Branch URL unavailable (no PR found for this branch)'"
        @click="emit('openBranch')"
      >
        <span aria-hidden="true" class="mr-2 opacity-70">&#8599;</span>Open branch in new tab
      </button>
      <button
        type="button"
        role="menuitem"
        data-testid="open-pr-new-tab-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80 disabled:opacity-40"
        :disabled="!prUrl"
        :title="prUrl || 'No pull request found for this branch'"
        @click="emit('openPr')"
      >
        <span aria-hidden="true" class="mr-2 opacity-70">&#8599;</span>Open pull request in new tab
      </button>
    </div>
  </Teleport>
</template>
