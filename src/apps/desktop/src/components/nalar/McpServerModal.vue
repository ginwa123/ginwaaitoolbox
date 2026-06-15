<script setup lang="ts">
import { computed } from 'vue'

import LlmConfigModal, { type LlmConfigModalValue } from './LlmConfigModal.vue'
import McpHeadersEditor, { type McpHeader } from './McpHeadersEditor.vue'

// The MCP server shape is { name, url, headers }, NOT a LlmConfig.
// We adapt it to the LlmConfigModal's contract by treating `url` as
// the LLM `base_url` (same field, same validation) and dropping the
// other LLM fields.
export interface McpServerModalValue {
  name: string
  url: string
  headers: McpHeader[]
}

const props = defineProps<{
  modelValue: McpServerModalValue
  errors?: { name?: string; url?: string }
  mode: 'add' | 'edit'
}>()

const emit = defineEmits<{
  'update:modelValue': [value: McpServerModalValue]
  cancel: []
  save: []
}>()

// Adapt server shape <-> LlmConfigModal's shape (uses base_url slot for URL).
const adapted = computed<LlmConfigModalValue>(() => ({
  name: props.modelValue.name,
  config: {
    model: '',           // not used by MCP
    base_url: props.modelValue.url,
    thinking: 'auto',
    temperature: 'auto',
    url_style: 'openai',
    api_key: '',
  },
}))

function updateFromModal(v: LlmConfigModalValue) {
  emit('update:modelValue', {
    name: v.name,
    url: v.config.base_url,
    headers: props.modelValue.headers,
  })
}

function updateHeaders(h: McpHeader[]) {
  emit('update:modelValue', { ...props.modelValue, headers: h })
}

const errorForModal = computed(() => ({
  name: props.errors?.name,
  base_url: props.errors?.url,
}))
</script>

<template>
  <LlmConfigModal
    :model-value="adapted"
    :errors="errorForModal"
    :title="mode === 'add' ? 'Add MCP server' : 'Edit MCP server'"
    :name-editable="mode === 'add'"
    extra-slot-name="extra"
    @update:model-value="updateFromModal"
    @cancel="emit('cancel')"
    @save="emit('save')"
  >
    <template #extra>
      <McpHeadersEditor
        :model-value="modelValue.headers"
        @update:model-value="updateHeaders"
      />
    </template>
  </LlmConfigModal>
</template>
