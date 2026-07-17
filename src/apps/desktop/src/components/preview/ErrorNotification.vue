<!--
  ErrorNotification.vue

  A single toast notification. Renders as a red pill with a ⚠ icon,
  the message, an optional <details> accordion for the long body
  (e.g. full server response), and a × dismiss button.

  The component is purely presentational — it knows nothing about
  the store. The parent (NotificationContainer) is responsible for
  calling `store.dismiss(id)` when `dismiss` is emitted.

  a11y: `role="alert"` so screen readers announce the error
  immediately. The dismiss button has an aria-label.
-->
<script setup lang="ts">
defineProps<{
  message: string
  details?: string
}>()

const emit = defineEmits<{ dismiss: [] }>()
</script>

<template>
  <div
    class="pointer-events-auto px-4 py-3 rounded-lg shadow-lg max-w-md"
    style="background-color: var(--color-red); color: white;"
    role="alert"
  >
    <div class="flex items-start gap-3">
      <span class="text-lg shrink-0">⚠</span>
      <div class="flex-1 min-w-0">
        <div class="font-medium">{{ message }}</div>
        <details v-if="details" class="mt-1 text-xs opacity-90">
          <summary class="cursor-pointer">Details</summary>
          <pre class="mt-1 whitespace-pre-wrap break-all">{{ details }}</pre>
        </details>
      </div>
      <button
        class="shrink-0 text-white opacity-70 hover:opacity-100"
        style="background: none; border: none; font-size: 1.25rem; line-height: 1; cursor: pointer;"
        @click="emit('dismiss')"
        aria-label="Dismiss"
      >×</button>
    </div>
  </div>
</template>
