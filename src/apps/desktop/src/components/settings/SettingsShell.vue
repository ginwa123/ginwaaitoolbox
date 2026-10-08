<!--
  SettingsShell — the one chrome for both settings scopes.

  User scope (`/app/settings`) edits `~/.config/pabrik/` (profiles, MCP,
  tools, general, web search, evals). Workspace scope
  (`/app/:workspaceId/settings`) edits one workspace (overview, secrets,
  skills, memories). The path IS the scope — no `?scope=` param — and the
  open section rides in `?section=` via `useSettingsSection`, so refresh,
  Back/Forward and shared links restore the view (repo rule: every view
  switch syncs the browser URL).

  Content stays with the callers: the shell renders the scope switcher +
  sidebar + toast and hands the active section + a `notify` function to
  its default slot.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useSettingsSection } from '../../composables/useSettingsSection'
import UiIcon from '../ui/UiIcon.vue'
import type { UiIconName } from '../ui/icons'

export type SettingsScope = 'user' | 'workspace'

export interface SettingsSectionItem {
  id: string
  label: string
  icon: UiIconName
}

const USER_SECTIONS: readonly SettingsSectionItem[] = [
  { id: 'pabrik', label: 'Pabrik', icon: 'robot' },
]

const WORKSPACE_SECTIONS: readonly SettingsSectionItem[] = [
  { id: 'overview', label: 'Overview', icon: 'cards' },
  { id: 'secrets', label: 'Secrets', icon: 'key' },
  { id: 'skills', label: 'Skills', icon: 'tools' },
  { id: 'memories', label: 'Memories', icon: 'brain' },
]

const USER_STORAGE_KEY = 'settings-shell-user-section'
const WORKSPACE_STORAGE_KEY = 'settings-shell-workspace-section'

const props = defineProps<{
  scope: SettingsScope
  /** Route workspace id. Empty in user scope. */
  workspaceId: string
}>()

const router = (() => {
  try {
    return useRouter()
  } catch (e) {
    // Router-less mount (unit tests): navigation becomes a no-op. The
    // section state still works through the local-ref fallback in
    // `useSettingsSection`, so the null here can never surface as a
    // wrong section — only as a button that does nothing in tests.
    // Logged so a missing router in production is visible, not silent.
    console.warn('[settings-shell] no router, navigation disabled', e)
    return null
  }
})()
const workspacesStore = useWorkspacesStore()

const sections = computed<readonly SettingsSectionItem[]>(() =>
  props.scope === 'user' ? USER_SECTIONS : WORKSPACE_SECTIONS,
)

const { section, select } = useSettingsSection({
  sections: sections.value.map((s) => s.id),
  defaultSection: sections.value[0]?.id ?? 'pabrik',
  storageKey: props.scope === 'user' ? USER_STORAGE_KEY : WORKSPACE_STORAGE_KEY,
})

const scopeLabel = computed(() =>
  props.scope === 'user' ? 'User — applies everywhere' : 'Workspace — this workspace only',
)

const workspaceName = computed(() => {
  const found = workspacesStore.workspaces.find((w) => w.id === props.workspaceId)
  return found?.name ?? props.workspaceId
})

const workspaceOptions = computed(() =>
  workspacesStore.workspaces.map((w) => ({ id: w.id, name: w.name })),
)

function goUser(): void {
  if (props.scope === 'user' || !router) return
  void router.push({ path: '/app/settings' })
}

function goWorkspace(id: string): void {
  if (!id || !router) return
  if (props.scope === 'workspace' && id === props.workspaceId) return
  void router.push({ path: `/app/${id}/settings` })
}

function goBack(): void {
  if (!router) return
  router.back()
}

// Notification toast state. Section content reports through the `notify`
// slot prop; the shell owns the timer so both scopes share one toast.
const notification = ref<{ message: string; type: 'success' | 'error' } | null>(null)

function notify(message: string, type: 'success' | 'error'): void {
  notification.value = { message, type }
  setTimeout(() => {
    notification.value = null
  }, 3000)
}
</script>

<template>
  <!-- Fullscreen Settings Overlay -->
  <div
    class="fixed inset-0 z-50 flex"
    style="background-color: var(--semantic-content-bg)"
    data-testid="settings-shell"
    :data-scope="props.scope"
  >
    <!-- Settings Sidebar -->
    <div
      class="h-full flex flex-col shrink-0"
      style="
        width: 240px;
        background-color: var(--semantic-sidebar-bg);
        border-right: 1px solid var(--color-border);
      "
    >
      <!-- Settings Header -->
      <div
        class="h-14 flex items-center px-4 shrink-0"
        style="border-bottom: 1px solid var(--color-border)"
      >
        <button
          class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80 mr-3"
          style="color: var(--semantic-text-muted)"
          title="Back"
          data-testid="settings-back"
          @click="goBack"
        >
          <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M15 19l-7-7 7-7"
            />
          </svg>
        </button>
        <h1 class="text-title-sm font-semibold" style="color: var(--semantic-text)">Settings</h1>
      </div>

      <!-- Scope switcher -->
      <div class="px-3 pt-3 shrink-0">
        <div
          class="flex rounded-lg p-0.5"
          role="tablist"
          aria-label="Settings scope"
          data-testid="settings-scope-switch"
          style="
            background-color: var(--semantic-content-bg);
            border: 1px solid var(--color-border);
          "
        >
          <button
            type="button"
            role="tab"
            :aria-selected="props.scope === 'user'"
            data-testid="settings-scope-user"
            class="flex-1 px-2 py-1.5 rounded-md text-dense font-medium transition-all duration-200"
            :style="
              props.scope === 'user'
                ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);'
                : 'color: var(--semantic-text-muted);'
            "
            @click="goUser"
          >
            User
          </button>
          <button
            type="button"
            role="tab"
            :aria-selected="props.scope === 'workspace'"
            data-testid="settings-scope-workspace"
            class="flex-1 px-2 py-1.5 rounded-md text-dense font-medium transition-all duration-200"
            :style="
              props.scope === 'workspace'
                ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);'
                : 'color: var(--semantic-text-muted);'
            "
            @click="goWorkspace(workspaceOptions[0]?.id ?? props.workspaceId)"
          >
            Workspace
          </button>
        </div>
        <select
          v-if="props.scope === 'workspace'"
          :value="props.workspaceId"
          aria-label="Workspace"
          data-testid="settings-workspace-picker"
          class="w-full mt-2 px-2 py-1.5 rounded-md text-dense"
          style="
            background-color: var(--semantic-content-bg);
            color: var(--semantic-text);
            border: 1px solid var(--color-border);
          "
          @change="goWorkspace(($event.target as HTMLSelectElement).value)"
        >
          <option v-for="ws in workspaceOptions" :key="ws.id" :value="ws.id">
            {{ ws.name }}
          </option>
        </select>
      </div>

      <!-- Settings Menu -->
      <nav class="flex-1 py-4 px-3 overflow-y-auto" aria-label="Settings sections">
        <p
          class="px-3 mb-2 text-dense uppercase tracking-wide"
          style="color: var(--semantic-text-muted)"
          data-testid="settings-scope-label"
        >
          {{ scopeLabel }}
        </p>
        <button
          v-for="item in sections"
          :key="item.id"
          :data-testid="`settings-nav-${item.id}`"
          :data-tab-id="item.id"
          :data-active="section === item.id ? 'true' : 'false'"
          role="tab"
          :aria-selected="section === item.id"
          class="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-body font-medium transition-all duration-200 mb-1"
          :style="
            section === item.id
              ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);'
              : 'color: var(--semantic-text-muted);'
          "
          @click="select(item.id)"
        >
          <UiIcon :name="item.icon" size-class="w-4.5 h-4.5" />
          <span>{{ item.label }}</span>
          <span
            v-if="props.scope === 'workspace'"
            class="ml-auto text-dense"
            style="color: var(--semantic-text-muted)"
            :data-testid="`settings-nav-${item.id}-workspace`"
          >
            {{ workspaceName }}
          </span>
        </button>
      </nav>
    </div>

    <!-- Settings Content -->
    <main class="flex-1 flex flex-col overflow-hidden">
      <div class="flex-1 overflow-y-auto p-6">
        <slot :section="section" :notify="notify" />
      </div>
    </main>

    <!-- Notification Toast -->
    <div
      v-if="notification"
      class="fixed bottom-6 right-6 px-4 py-3 rounded-lg shadow-lg z-50"
      data-testid="settings-notification"
      :style="
        notification.type === 'success'
          ? 'background-color: var(--color-green); color: white;'
          : 'background-color: var(--color-red); color: white;'
      "
    >
      {{ notification.message }}
    </div>
  </div>
</template>
