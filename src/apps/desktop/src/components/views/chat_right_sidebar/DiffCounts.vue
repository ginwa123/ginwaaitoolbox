<script setup lang="ts">
/**
 * `+N / -N` for one file row — the GitHub/GitLab line-count chip.
 *
 * Shared by the sidebar's PR list and its worktree lists so the two can
 * never drift apart in colour, size, or spacing. The numbers are the same
 * ones the center diff header shows (`SidebarDiffView`), so a row and the
 * diff it opens always agree.
 *
 * `null` means UNKNOWN, and it renders nothing at all. That distinction is
 * the whole reason the prop is nullable rather than defaulting to 0: a
 * failed diff fetch must not read as "this file is unchanged", which is
 * what `+0 -0` would say.
 */
defineProps<{
  added: number | null
  removed: number | null
}>()
</script>

<template>
  <span
    v-if="added !== null && removed !== null"
    class="shrink-0 font-mono text-micro tabular-nums flex items-center gap-1"
    :title="`+${added} / -${removed} lines`"
    data-testid="diff-counts"
  >
    <span style="color: var(--color-green)">+{{ added }}</span>
    <span style="color: var(--color-red)">-{{ removed }}</span>
  </span>
</template>
