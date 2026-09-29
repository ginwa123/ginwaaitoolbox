<script setup lang="ts">
import { ref } from 'vue'

import EmptyState from './EmptyState.vue'
import type { SubAgent } from '../../api'

defineProps<{ modelValue: SubAgent[] }>()
const emit = defineEmits<{
  edit: [sa: SubAgent]
  delete: [name: string]
  add: []
}>()

// Map of sub-agent name -> expanded state.
const expanded = ref<Record<string, boolean>>({})

function toggle(name: string) {
  expanded.value = { ...expanded.value, [name]: !expanded.value[name] }
}
</script>

<template>
  <div class="space-y-4">
    <p class="text-dense leading-relaxed max-w-2xl" style="color: var(--semantic-text-muted);">
      Sub-agents are named LLM configurations the agent can spawn via the
      <code style="font-family: var(--font-mono);">spawn_sub_agent</code>
      tool. Top-level sub-agents apply to every profile unless a profile overrides them.
    </p>

    <div class="flex justify-end">
      <button
        type="button"
        data-testid="add-btn"
        @click="emit('add')"
        class="px-3 h-8 rounded-md text-dense font-medium border transition-colors duration-150"
        style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
      >+ Add sub-agent</button>
    </div>

    <EmptyState
      v-if="modelValue.length === 0"
      data-testid="empty-state"
      glyph="◌"
      title="No sub-agents yet"
      description="Sub-agents are specialized LLM configs the agent can hand off work to. Useful for parallel research, reviews, or domain-specific personas."
      cta-label="+ Add sub-agent"
      :cta-action="() => emit('add')"
    />

    <ul v-else class="space-y-2" data-testid="subagent-list">
      <li
        v-for="sa in modelValue"
        :key="sa.name"
        class="px-4 py-3 rounded-md"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="flex-1 min-w-0">
            <div class="text-body font-medium" style="color: var(--semantic-text);">{{ sa.name }}</div>
            <div class="text-dense font-mono mt-0.5 truncate" style="color: var(--semantic-text-dim);">
              {{ sa.model }} · {{ sa.base_url || '—' }}
            </div>
          </div>
          <div class="flex items-center gap-1.5 shrink-0">
            <button
              type="button"
              data-testid="edit-btn"
              @click="emit('edit', sa)"
              class="px-2.5 h-7 rounded-md text-dense border transition-colors duration-150"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
            >Edit</button>
            <button
              type="button"
              data-testid="delete-btn"
              @click="emit('delete', sa.name)"
              class="px-2.5 h-7 rounded-md text-dense transition-colors duration-150"
              style="color: var(--color-red);"
              aria-label="Delete sub-agent"
            >⌫</button>
          </div>
        </div>

        <p
          v-if="sa.system_prompt"
          data-testid="prompt-preview"
          class="text-dense mt-2"
          :class="expanded[sa.name] ? '' : 'line-clamp-2'"
          style="color: var(--semantic-text-muted); white-space: pre-wrap;"
        >{{ sa.system_prompt }}</p>
        <button
          v-if="sa.system_prompt && sa.system_prompt.length > 100"
          type="button"
          data-testid="expand-prompt"
          @click="toggle(sa.name)"
          class="text-meta mt-1 font-mono"
          style="color: var(--semantic-text-dim);"
        >{{ expanded[sa.name] ? 'Show less' : 'Show more' }}</button>
      </li>
    </ul>
  </div>
</template>
