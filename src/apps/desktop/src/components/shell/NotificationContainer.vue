<!--
  NotificationContainer.vue

  Mounts once at the AppLayout root. Reads the notification store
  and renders an ErrorNotification for each entry. The wrapping
  <div> is `pointer-events-none` so the empty area in front of
  the toasts does NOT block clicks on the page underneath;
  individual toasts re-enable pointer events (`pointer-events-auto`
  on the ErrorNotification root) so the × button is clickable.

  Layout:
    - `fixed bottom-6 right-6` — bottom-right corner, 1.5rem inset
    - `flex flex-col-reverse` — newest toasts at the bottom of the
      stack (closest to the user's natural read direction); older
      toasts slide up as new ones arrive
    - `z-50` — above the main content but below modals (which use
      higher z-indexes)
    - `aria-live="polite"` + `aria-atomic="false"` — screen readers
      announce new toasts without re-reading the entire stack

  This component is intentionally pure: it owns no state, just
  reflects the store. The store handles auto-dismiss timers.
-->
<script setup lang="ts">
import { useNotificationStore } from '../../stores/notifications'
import ErrorNotification from '../preview/ErrorNotification.vue'

const store = useNotificationStore()
</script>

<template>
  <div
    class="fixed bottom-6 right-6 z-50 flex flex-col-reverse gap-2 pointer-events-none"
    aria-live="polite"
    aria-atomic="false"
  >
    <ErrorNotification
      v-for="n in store.notifications"
      :key="n.id"
      :message="n.message"
      :details="n.details"
      @dismiss="store.dismiss(n.id)"
    />
  </div>
</template>
