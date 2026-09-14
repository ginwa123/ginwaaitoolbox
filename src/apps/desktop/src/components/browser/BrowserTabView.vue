<script setup lang="ts">
/**
 * The browser tab body: a launcher + record for a Nalar-owned webview window.
 *
 * Blank (no `url`): an address bar. Enter/Open normalizes the input — a
 * refused scheme shows an inline error and spawns nothing.
 *
 * With a `url`: a read-only URL row, a status line, one always-enabled
 * primary button whose label follows the shell's status, and an
 * "Open in system browser" escape hatch.
 *
 * Window status is fetched on demand only (mount, active-tab change, after
 * an action) — never polled.
 */
import { computed, onMounted, ref, watch } from 'vue'

import { normalizeAddressInput } from '../../helpers/browserUrl'
import { browserStatus, openBrowserWindow } from '../../helpers/browserBridge'
import { useTabsStore } from '../../stores/tabs'

const emit = defineEmits<{
  (e: 'navigate'): void
}>()

const tabsStore = useTabsStore()

const tab = computed(() => tabsStore.activeTab)
const url = computed(() => (typeof tab.value?.query.url === 'string' ? tab.value.query.url : ''))

const raw = ref('')
const error = ref('')
const alive = ref(false)
const copied = ref(false)

async function refreshStatus(): Promise<void> {
  const current = tab.value
  if (!current) {
    alive.value = false
    return
  }
  try {
    const st = await browserStatus(current.id)
    alive.value = st.alive
  } catch {
    alive.value = false
  }
}

onMounted(() => {
  void refreshStatus()
})

watch(
  () => [tab.value?.id, url.value] as const,
  () => {
    void refreshStatus()
  },
)

async function submitAddress(): Promise<void> {
  const current = tab.value
  if (!current) return
  const r = normalizeAddressInput(raw.value)
  if (!r.ok) {
    error.value = r.reason
    return
  }
  error.value = ''
  tabsStore.navigateBrowserTab(current.id, r.url)
  emit('navigate')
  try {
    await openBrowserWindow(current.id, r.url)
  } catch {
    /* the bridge never throws, but the tab target is already applied */
  }
  await refreshStatus()
}

async function openWindow(): Promise<void> {
  const current = tab.value
  const target = url.value
  if (!current || !target) return
  try {
    await openBrowserWindow(current.id, target)
  } catch {
    /* status refresh below still shows the truth */
  }
  await refreshStatus()
}

function openInSystem(): void {
  const target = url.value
  if (!target) return
  try {
    window.open(target, '_blank', 'noopener')
  } catch {
    /* popup blocked — never throw out of a click handler */
  }
}

async function copyUrl(): Promise<void> {
  const target = url.value
  if (!target) return
  try {
    await navigator.clipboard.writeText(target)
    copied.value = true
    window.setTimeout(() => {
      copied.value = false
    }, 1500)
  } catch {
    /* clipboard unavailable — never throw out of a click handler */
  }
}
</script>

<template>
  <div
    data-testid="browser-tab-view"
    class="flex-1 flex flex-col items-center justify-start overflow-auto px-6 py-10"
    :style="{ backgroundColor: 'var(--semantic-content-bg)', color: 'var(--semantic-text)' }"
  >
    <div v-if="!url" class="w-full max-w-xl flex flex-col gap-3">
      <h2 class="text-lg font-semibold">New tab</h2>
      <p class="text-sm" :style="{ color: 'var(--semantic-text-muted)' }">
        Search or enter address
      </p>
      <div class="flex gap-2">
        <input
          v-model="raw"
          data-testid="browser-address"
          autofocus
          placeholder="Search or enter address"
          class="flex-1 rounded-lg px-3 py-2 text-sm"
          :style="{
            backgroundColor: 'var(--semantic-input-bg, transparent)',
            border: '1px solid var(--color-border)',
            color: 'var(--semantic-text)',
          }"
          @keydown.enter="submitAddress"
        />
        <button
          type="button"
          data-testid="browser-address-open"
          class="rounded-lg px-4 py-2 text-sm font-medium"
          :style="{ backgroundColor: 'var(--color-violet)', color: '#fff' }"
          @click="submitAddress"
        >
          Open
        </button>
      </div>
      <p
        v-if="error"
        data-testid="browser-address-error"
        class="text-sm"
        style="color: var(--color-red)"
      >
        {{ error }}
      </p>
    </div>

    <div v-else class="w-full max-w-xl flex flex-col gap-4">
      <div class="flex items-center gap-2">
        <span
          data-testid="browser-url"
          class="flex-1 truncate rounded-lg px-3 py-2 text-sm"
          :style="{ border: '1px solid var(--color-border)' }"
        >
          {{ url }}
        </span>
        <button
          type="button"
          data-testid="browser-copy-url"
          class="rounded-lg px-3 py-2 text-sm"
          :style="{ border: '1px solid var(--color-border)' }"
          @click="copyUrl"
        >
          {{ copied ? 'Copied' : 'Copy' }}
        </button>
      </div>
      <p
        data-testid="browser-window-status"
        class="text-sm"
        :style="{ color: 'var(--semantic-text-muted)' }"
      >
        {{ alive ? '1 window open' : 'no window open' }}
      </p>
      <div class="flex gap-2">
        <button
          type="button"
          data-testid="browser-open-window"
          class="rounded-lg px-4 py-2 text-sm font-medium"
          :style="{ backgroundColor: 'var(--color-violet)', color: '#fff' }"
          @click="openWindow"
        >
          {{ alive ? 'Open another window' : 'Open browser window' }}
        </button>
        <button
          type="button"
          data-testid="browser-open-system"
          class="rounded-lg px-4 py-2 text-sm"
          :style="{ border: '1px solid var(--color-border)' }"
          @click="openInSystem"
        >
          Open in system browser
        </button>
      </div>
    </div>
  </div>
</template>
