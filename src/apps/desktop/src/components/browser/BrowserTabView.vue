<script setup lang="ts">
/**
 * The browser tab body: a launcher + record for the in-app browser pane.
 *
 * Blank (no `url`): an address bar. Enter/Open normalizes the input — a
 * refused scheme shows an inline error and spawns nothing — then navigates
 * the tab and drives the pane (or the fallbacks below).
 *
 * With a `url`: a read-only URL row, a status line, and "Open in system
 * browser" as the escape hatch. There is deliberately NO separate-window
 * affordance: when the pane is available the page already shows below the
 * strip (this card is only visible while the pane is not covering it) and
 * the window code path survives only as an invisible automatic fallback
 * (used when the pane is unavailable but the window bridge exists).
 *
 * Pane/window status is fetched on demand only (mount, active-tab change,
 * after an action) — never polled.
 */
import { computed, inject, onMounted, ref, watch } from 'vue'

import { normalizeAddressInput } from '../../helpers/browserUrl'
import {
  browserBridgeAvailable,
  browserPaneAvailable,
  browserPaneStatus,
  browserStatus,
  openBrowserWindow,
  showBrowserPane,
} from '../../helpers/browserBridge'
import { useTabsStore } from '../../stores/tabs'
import { BrowserPaneKey, type BrowserPaneApi } from '../../composables/useBrowserPane'

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
/** False when this document has no shell bridge (plain browser / old shell). */
const bridgeReady = ref(browserBridgeAvailable())
/** True when the shell offers the in-app pane (Linux only for now). */
const paneReady = ref(browserPaneAvailable())
/** What the last pane-status reply reported (the standalone fallback below). */
const paneStatusVisible = ref(false)

/**
 * The layout-owned pane api: the single owner of show/hide + rect reporting
 * (see composables/useBrowserPane). In the app this is provided by AppLayout;
 * standalone (tests, plain browser) there is no provider, so visibility falls
 * back to the status reply above and the host handoff is a no-op.
 */
/**
 * The pane's rect comes from AppLayout's `<main>` (the content area), not from
 * this view: an element inside the pane's own area collapses while the native
 * view covers it, which is how the pane once reported a 0-width rect and ended
 * up covering the entire window. The ref below stays only so the card can hide
 * itself while the pane is up.
 */
const paneApi = inject<BrowserPaneApi | null>(BrowserPaneKey, null)
/** The card hides while the native view covers it. */
const paneVisible = computed(() => paneApi?.paneVisible.value ?? paneStatusVisible.value)

async function refreshStatus(): Promise<void> {
  const current = tab.value
  const currentUrl = url.value
  if (!current) {
    alive.value = false
    paneStatusVisible.value = false
    return
  }
  try {
    const [st, pane] = await Promise.all([browserStatus(current.id), browserPaneStatus()])
    // The tab may have moved on while the shell answered.
    if (tab.value?.id !== current.id || url.value !== currentUrl) return
    bridgeReady.value = st.available
    alive.value = st.alive
    paneReady.value = pane.available && pane.supported
    paneStatusVisible.value = pane.visible
  } catch {
    if (tab.value?.id !== current.id || url.value !== currentUrl) return
    bridgeReady.value = browserBridgeAvailable()
    alive.value = false
    paneReady.value = browserPaneAvailable()
    paneStatusVisible.value = false
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
  if (browserPaneAvailable()) {
    // The pane shows the page below the strip — no window.
    try {
      await showBrowserPane(current.id, r.url)
    } catch {
      /* the bridge never throws, but the tab target is already applied */
    }
    await refreshStatus()
    return
  }
  if (!browserBridgeAvailable()) {
    // No shell to ask: hand the address to the system browser rather than
    // navigating the tab and leaving the user with nothing.
    systemOpen(r.url)
    return
  }
  try {
    await openBrowserWindow(current.id, r.url)
  } catch {
    /* the bridge never throws, but the tab target is already applied */
  }
  await refreshStatus()
}

/**
 * The status line follows whichever surface actually shows the page: the
 * pane when the shell offers it, otherwise the separate window.
 */
const statusText = computed(() => {
  if (paneReady.value) return paneVisible.value ? 'pane visible' : 'pane hidden'
  return alive.value ? '1 window open' : 'no window open'
})

/**
 * Invisible-automatic-fallback made visible: with no pane but a window
 * bridge (an older shell, a platform before its pane patch), the only
 * in-app surface is the separate window, so the fallback button opens it.
 * With no bridge at all there is no fallback — the system browser below is
 * the primary action instead. Never disabled, never a no-op.
 */
async function openFallbackWindow(): Promise<void> {
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

function systemOpen(target: string): void {
  if (!target) return
  try {
    window.open(target, '_blank', 'noopener')
  } catch {
    /* popup blocked — never throw out of a click handler */
  }
}

function openInSystem(): void {
  systemOpen(url.value)
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

    <div
      v-else
      data-testid="browser-pane-body"
      ref="paneHost"
      class="flex-1 flex flex-col items-center justify-start overflow-hidden"
    >
      <div v-if="!paneVisible" class="w-full max-w-xl flex flex-col gap-4 px-6 py-10 overflow-auto">
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
          {{ statusText }}
        </p>
        <p
          v-if="paneReady"
          data-testid="browser-pane-note"
          class="text-sm"
          :style="{ color: 'var(--semantic-text-muted)' }"
        >
          The page renders in the pane inside this window.
        </p>
        <p
          v-if="!paneReady && !bridgeReady"
          data-testid="browser-bridge-missing"
          class="text-sm"
          :style="{ color: 'var(--semantic-text-muted)' }"
        >
          This page has no shell bridge, so a Nalar browser window cannot be opened from here —
          opening in your system browser instead. Use the Nalar desktop app for an in-app window.
        </p>
        <div class="flex gap-2">
          <button
            v-if="!paneReady && bridgeReady"
            type="button"
            data-testid="browser-open-fallback"
            class="rounded-lg px-4 py-2 text-sm font-medium"
            :style="{ backgroundColor: 'var(--color-violet)', color: '#fff' }"
            @click="openFallbackWindow"
          >
            Open browser window
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
  </div>
</template>
