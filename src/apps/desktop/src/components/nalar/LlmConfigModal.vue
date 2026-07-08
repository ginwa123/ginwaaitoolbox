<script setup lang="ts">
import LlmConfigForm, { type LlmConfig } from './LlmConfigForm.vue'

export interface LlmConfigModalValue {
  name: string
  config: LlmConfig
}

const props = withDefaults(
  defineProps<{
    modelValue: LlmConfigModalValue
    errors?: {
      name?: string
      model?: string
      base_url?: string
      api_key?: string
      /** Plan 2026-07-07-compaction-inline: per-profile compaction
       *  errors. Not currently set by the backend (null is always
       *  valid; > 100 is caught at the HTTP layer), but accepted
       *  by the form so the errors prop type is future-proof. */
      max_capacity_tokens?: string
      compaction_threshold_percent?: string
    }
    title: string
    /** When true, the name field is editable (Add mode). When false (Edit mode), it's disabled. */
    nameEditable: boolean
    /** Optional slot name to render after the LLM config form (e.g. 'extra'). */
    extraSlotName?: string
    /** Tailwind max-width class for the dialog. Default `max-w-md` (28rem). */
    maxWidthClass?: 'max-w-md' | 'max-w-lg' | 'max-w-xl' | 'max-w-2xl' | 'max-w-3xl'
  }>(),
  { maxWidthClass: 'max-w-md' },
)

const emit = defineEmits<{
  'update:modelValue': [value: LlmConfigModalValue]
  cancel: []
  save: []
}>()

function updateName(val: string) {
  emit('update:modelValue', { ...props.modelValue, name: val })
}
function updateConfig(cfg: LlmConfig) {
  emit('update:modelValue', { ...props.modelValue, config: cfg })
}
</script>

<template>
  <Teleport to="body">
    <div
      class="fixed inset-0 z-50 flex items-center justify-center"
      style="background-color: rgba(0, 0, 0, 0.5);"
      @click.self="emit('cancel')"
    >
      <div
        :class="['w-full mx-4 rounded-md flex flex-col', props.maxWidthClass]"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
        role="dialog"
        aria-modal="true"
      >
        <div
          class="flex items-center justify-between px-5 h-12 border-b shrink-0"
          style="border-color: var(--color-border);"
        >
          <h3 class="text-sm font-semibold" style="color: var(--semantic-text);">{{ title }}</h3>
          <button
            type="button"
            @click="emit('cancel')"
            aria-label="Close"
            class="w-7 h-7 flex items-center justify-center text-sm"
            style="color: var(--semantic-text-muted);"
          >✕</button>
        </div>

        <div class="p-5 space-y-4 overflow-y-auto" style="max-height: 70vh;">
          <!-- Name -->
          <div>
            <label class="block text-xs font-medium mb-1.5" style="color: var(--semantic-text-muted);">
              Name <span style="color: var(--color-red);">*</span>
            </label>
            <input
              :value="modelValue.name"
              @input="updateName(($event.target as HTMLInputElement).value)"
              type="text"
              :disabled="!nameEditable"
              class="w-full px-3 h-8 rounded-md border text-sm"
              style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              data-testid="name-input"
            />
            <p v-if="errors?.name" class="text-xs mt-1" style="color: var(--color-red);">{{ errors.name }}</p>
          </div>

          <!-- LLM config -->
          <LlmConfigForm
            :model-value="modelValue.config"
            :errors="errors"
            @update:model-value="updateConfig"
          />

          <!-- Optional extras (system_prompt, headers, ...) -->
          <slot v-if="extraSlotName" :name="extraSlotName" />
        </div>

        <div
          class="flex justify-end gap-2 px-5 h-14 border-t shrink-0 items-center"
          style="border-color: var(--color-border);"
        >
          <button
            type="button"
            data-testid="modal-cancel"
            @click="emit('cancel')"
            class="px-4 h-8 rounded-md text-sm border transition-colors duration-150"
            style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
          >Cancel</button>
          <button
            type="button"
            data-testid="modal-save"
            @click="emit('save')"
            class="px-4 h-8 rounded-md text-sm font-medium border transition-colors duration-150"
            style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
          >Save</button>
        </div>
      </div>
    </div>
  </Teleport>
</template>
