<script setup lang="ts">
import LlmConfigModal, { type LlmConfigModalValue } from './LlmConfigModal.vue'

defineProps<{
  modelValue: LlmConfigModalValue
  errors?: { name?: string; model?: string; base_url?: string; api_key?: string }
  mode: 'add' | 'edit'
}>()

const emit = defineEmits<{
  'update:modelValue': [value: LlmConfigModalValue]
  cancel: []
  save: []
}>()
</script>

<template>
  <LlmConfigModal
    :model-value="modelValue"
    :errors="errors"
    :title="mode === 'add' ? 'Add profile' : 'Edit profile'"
    :name-editable="mode === 'add'"
    @update:model-value="(v) => emit('update:modelValue', v)"
    @cancel="emit('cancel')"
    @save="emit('save')"
  />
</template>
