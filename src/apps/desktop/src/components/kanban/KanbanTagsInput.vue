<!--
  KanbanTagsInput — chip input for free-form task tags.

  Visual layout:
    ┌─────────────────────────────────────────────┐
    │ [bug ✕]  [urgent ✕]  [frontend ✕]           │
    │ Add tags (letters, digits, hyphens)...      │
    └─────────────────────────────────────────────┘

  Behavior:
    - Add a tag: type in the input, press Enter OR comma
      → append chip, clear input.
    - Remove a tag: click the chip's ✕
      → remove chip, emit update.
    - Backspace on an EMPTY input: remove the LAST chip
      → emit update.
    - Duplicate prevention (case-insensitive): typing an
      existing tag is a silent no-op.
    - Char whitelist: typing a forbidden char (space, slash,
      punctuation) shows a brief error and refuses the input.
    - Length cap: tags over 50 chars are refused.
    - Color: deterministic via djb2 hash of the lowercase tag
      → 1 of 6 colors. Same tag = same color across views.

  Public API:
    props:
      modelValue  string[]  (v-model — current tag list)
      testId?     string    (data-testid prefix for testing)
    emits:
      update:modelValue [tags: string[]]

  Plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md (Task 10)
-->
<script setup lang="ts">
import { ref, computed } from 'vue'

const props = withDefaults(
  defineProps<{
    modelValue: string[]
    testId?: string
  }>(),
  {
    testId: 'kanban-tags-input',
  },
)

const emit = defineEmits<{
  'update:modelValue': [tags: string[]]
}>()

// What the user is typing. Local state — we don't v-model the inner
// input itself (chip add/remove is a discrete event).
const draftInput = ref<string>('')
// Transient error message (char whitelist / length cap / duplicate).
const errorMessage = ref<string | null>(null)

// Allowed chars: a-z, A-Z, 0-9, underscore, hyphen. Matches the
// backend's tags_validation.zig whitelist.
const TAG_CHAR_WHITELIST = /^[a-zA-Z0-9_-]$/
const TAG_LENGTH_CAP = 50

// 6-color palette indexed by deterministic djb2 hash of the
// lowercase tag. Same algorithm as WorkspaceItemTaskCard so the
// dialog chips and card chips share colors.
const TAG_PALETTE = [
  { bg: 'rgba(139, 92, 246, 0.18)', border: 'rgba(139, 92, 246, 0.45)', text: '#a78bfa' },
  { bg: 'rgba(59, 130, 246, 0.18)', border: 'rgba(59, 130, 246, 0.45)', text: '#60a5fa' },
  { bg: 'rgba(34, 197, 94, 0.18)', border: 'rgba(34, 197, 94, 0.45)', text: '#4ade80' },
  { bg: 'rgba(245, 158, 11, 0.18)', border: 'rgba(245, 158, 11, 0.45)', text: '#fbbf24' },
  { bg: 'rgba(249, 115, 22, 0.18)', border: 'rgba(249, 115, 22, 0.45)', text: '#fb923c' },
  { bg: 'rgba(239, 68, 68, 0.18)', border: 'rgba(239, 68, 68, 0.45)', text: '#f87171' },
] as const

function tagColor(tag: string): { bg: string; border: string; text: string } {
  let hash = 5381
  for (const c of tag.toLowerCase()) {
    hash = ((hash << 5) + hash + c.charCodeAt(0)) >>> 0
  }
  // The `% TAG_PALETTE.length` keeps the index in range; the
  // explicit fallback guards against the empty-palette case (which
  // never happens because PALETTE is a const array, but TS's
  // strict mode flags the indexed access as `T | undefined`).
  const idx = hash % TAG_PALETTE.length
  return TAG_PALETTE[idx] ?? TAG_PALETTE[0]
}

function tagChipStyle(tag: string): Record<string, string> {
  const c = tagColor(tag)
  return {
    backgroundColor: c.bg,
    border: `1px solid ${c.border}`,
    color: c.text,
  }
}

// Sanitize the draft: strip leading/trailing whitespace. Returns
// the cleaned string (NOT mutate draftInput).
function cleanDraft(): string {
  return draftInput.value.replace(/^\s+|\s+$/g, '')
}

// Validate a tag string against the project's rules. Returns null
// when valid, or a short error string otherwise.
function validateTag(raw: string): string | null {
  const tag = raw.trim()
  if (tag.length === 0) return 'Tag cannot be empty.'
  if (tag.length > TAG_LENGTH_CAP) {
    return `Tag too long (max ${TAG_LENGTH_CAP} characters).`
  }
  for (const c of tag) {
    if (!TAG_CHAR_WHITELIST.test(c)) {
      return 'Only letters, digits, underscores, and hyphens allowed.'
    }
  }
  return null
}

function clearDraftError(): void {
  if (errorMessage.value !== null) errorMessage.value = null
}

function commitDraft(): void {
  clearDraftError()
  const tag = cleanDraft()
  if (!tag) {
    draftInput.value = ''
    return
  }
  const err = validateTag(tag)
  if (err) {
    errorMessage.value = err
    return
  }
  // Case-insensitive duplicate check.
  const tagLower = tag.toLowerCase()
  if (props.modelValue.some((t) => t.toLowerCase() === tagLower)) {
    // Silent no-op — duplicates are common UX for chip inputs.
    draftInput.value = ''
    return
  }
  emit('update:modelValue', [...props.modelValue, tag])
  draftInput.value = ''
}

function removeTag(idx: number): void {
  clearDraftError()
  const next = props.modelValue.slice()
  next.splice(idx, 1)
  emit('update:modelValue', next)
}

function onBackspace(): void {
  // Only remove on Backspace when the input is empty (otherwise
  // let the browser handle the backspace within the input text).
  if (draftInput.value.length === 0 && props.modelValue.length > 0) {
    removeTag(props.modelValue.length - 1)
  }
}

function onInput(): void {
  // Live-clear the error as the user types (re-enables the Submit
  // affordance without forcing them to dismiss the message).
  if (errorMessage.value !== null) clearDraftError()
}

// Whether the input shows an error style (red border). Drives the
// `aria-invalid` attr and the red border class.
const hasError = computed(() => errorMessage.value !== null)

// Expose commitDraft so the host (KanbanTaskDetailDialog) can call
// it imperatively right before reading the modelValue. Without this,
// a draft tag typed just before Save (no Enter/comma pressed) is
// silently dropped — `commitDraft` is only triggered by Enter/comma
// (and `@blur` since the auto-commit addition below).
defineExpose({ commitDraft })
</script>

<template>
  <div>
    <div
      class="flex flex-wrap items-center gap-1.5 px-2 py-1.5 rounded-lg"
      :class="hasError ? 'border border-red-500/60' : 'border border-[--color-border]'"
      style="background-color: var(--semantic-sidebar-bg);"
      :data-testid="`${props.testId}-container`"
    >
      <span
        v-for="(tag, idx) in props.modelValue"
        :key="`${tag}-${idx}`"
        class="inline-flex items-center gap-1 text-[11px] px-1.5 py-0.5 rounded font-medium"
        :style="tagChipStyle(tag)"
        :data-testid="`${props.testId}-chip-${tag}`"
      >
        {{ tag }}
        <button
          type="button"
          @click="removeTag(idx)"
          class="inline-flex items-center justify-center w-3 h-3 rounded-full hover:bg-black/20 focus:outline-none"
          :aria-label="`Remove tag ${tag}`"
          :data-testid="`${props.testId}-remove-${tag}`"
        >
          <svg class="w-2 h-2" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>
      </span>
      <input
        v-model="draftInput"
        @keydown.enter.prevent="commitDraft"
        @keydown.,.prevent="commitDraft"
        @keydown.backspace="onBackspace"
        @blur="commitDraft"
        @input="onInput"
        type="text"
        :placeholder="props.modelValue.length === 0 ? 'Add tags (letters, digits, hyphens)…' : ''"
        :data-testid="`${props.testId}-field`"
        class="flex-1 min-w-[120px] bg-transparent outline-none text-sm"
        style="color: var(--semantic-text);"
      />
    </div>
    <div
      v-if="hasError"
      class="mt-1 text-[11px]"
      style="color: rgb(248, 113, 113);"
      :data-testid="`${props.testId}-error`"
      role="alert"
    >
      {{ errorMessage }}
    </div>
  </div>
</template>
