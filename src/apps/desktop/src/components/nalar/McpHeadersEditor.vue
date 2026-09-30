<script setup lang="ts">
export interface McpHeader { key: string; value: string }

const props = defineProps<{ modelValue: McpHeader[] }>()
const emit = defineEmits<{ 'update:modelValue': [value: McpHeader[]] }>()

function update(idx: number, field: 'key' | 'value', val: string) {
  const next = props.modelValue.map((h, i) => i === idx ? { ...h, [field]: val } : h)
  emit('update:modelValue', next)
}
function add() {
  emit('update:modelValue', [...props.modelValue, { key: '', value: '' }])
}
function remove(idx: number) {
  emit('update:modelValue', props.modelValue.filter((_, i) => i !== idx))
}

const inputBase = 'flex-1 px-3 h-8 rounded-md border text-body font-mono'
const inputStyle = {
  backgroundColor: 'var(--semantic-content-bg)',
  color: 'var(--semantic-text)',
  borderColor: 'var(--color-border)',
}
</script>

<template>
  <div>
    <div class="flex items-center justify-between mb-2">
      <label class="text-dense font-medium" style="color: var(--semantic-text-muted);">Headers</label>
      <button
        type="button"
        data-testid="add-header"
        @click="add"
        class="text-dense px-2 h-7 rounded-md border transition-colors duration-150"
        style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
      >+ Add header</button>
    </div>

    <p v-if="modelValue.length === 0" class="text-dense italic" style="color: var(--semantic-text-dim);">
      No headers. Click "Add header" for API keys.
    </p>

    <div v-else class="space-y-2">
      <div
        v-for="(h, idx) in modelValue"
        :key="idx"
        data-testid="header-row"
        class="flex gap-2 items-center"
      >
        <input
          :value="h.key"
          @input="update(idx, 'key', ($event.target as HTMLInputElement).value)"
          type="text"
          placeholder="Header-Name"
          :class="inputBase"
          :style="inputStyle"
        />
        <input
          :value="h.value"
          @input="update(idx, 'value', ($event.target as HTMLInputElement).value)"
          type="text"
          placeholder="value"
          :class="inputBase"
          :style="inputStyle"
        />
        <button
          type="button"
          data-testid="remove-header"
          @click="remove(idx)"
          aria-label="Remove header"
          class="w-7 h-7 flex items-center justify-center rounded-md text-body transition-colors duration-150"
          style="color: var(--color-red);"
        >✕</button>
      </div>
    </div>
  </div>
</template>
