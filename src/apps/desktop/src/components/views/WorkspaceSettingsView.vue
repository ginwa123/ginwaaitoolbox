<script setup lang="ts">
// Workspace settings shell — `/app/:workspaceId/settings`.
//
// The open section lives in the URL, not in a local `ref`. A view that only
// exists in component state is unreachable by refresh, by Back/Forward, and
// by a shared link; the repo rule is that every view switch syncs the
// browser URL. `activeSection` below is a writable computed over `?section=`,
// copied from `components/NalarSettings.vue`'s `activeTab` — same read
// order (URL → localStorage → default), same `router.replace` on write, same
// "strip the default from the query" cleanup.
//
// The query key is `section`, not `tab`: `?tab=` belongs to browser tab-mode
// (`helpers/tabTarget.ts`, `stores/tabs.ts`), and reusing it here would make
// "which browser tab" and "which settings section" the same value.
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useSecretsStore } from '../../stores/secrets'
import { useWorkspacesStore } from '../../stores/workspaces'
import SecretsSection from '../workspace/SecretsSection.vue'

type Section = 'overview' | 'secrets'

const SECTION_IDS: readonly string[] = ['overview', 'secrets']
const DEFAULT_SECTION: Section = 'overview'
/** Same key the tab strip persists to, read as the fallback below the URL. */
const SECTION_STORAGE_KEY = 'workspace-settings-active-section'

const SECTIONS: ReadonlyArray<{ id: Section; label: string }> = [
  { id: 'overview', label: 'Overview' },
  { id: 'secrets', label: 'Secrets' },
]

const route = useRoute()
const router = useRouter()
const secretsStore = useSecretsStore()
const workspacesStore = useWorkspacesStore()

function readStoredSection(): Section | null {
  try {
    const saved = localStorage.getItem(SECTION_STORAGE_KEY)
    return saved && SECTION_IDS.includes(saved) ? (saved as Section) : null
  } catch {
    return null // storage unavailable (private mode / no stub)
  }
}

// `route`/`router` are undefined when this mounts without a router (unit
// tests), so a local ref backs the setter and keeps the render reactive
// even where there is nothing to write to.
const activeSectionLocal = ref<Section>(readStoredSection() ?? DEFAULT_SECTION)

const activeSection = computed<Section>({
  get() {
    if (route) {
      const raw = route.query.section
      const section = Array.isArray(raw) ? raw[0] : raw
      if (typeof section === 'string' && SECTION_IDS.includes(section)) return section as Section
      return readStoredSection() ?? DEFAULT_SECTION
    }
    return activeSectionLocal.value
  },
  set(next) {
    activeSectionLocal.value = next
    try {
      localStorage.setItem(SECTION_STORAGE_KEY, next)
    } catch {
      /* private mode */
    }
    if (!router || !route) return
    const rest = { ...route.query }
    // The default section is stripped from the URL to keep it clean; every
    // other param (e.g. `?focus=`) is carried through untouched.
    if (next === DEFAULT_SECTION) delete rest.section
    else rest.section = next
    void router.replace({ query: rest })
  },
})

function selectSection(next: Section): void {
  activeSection.value = next
}

/**
 * The workspace this settings page belongs to.
 *
 * Read from the route param, not from `parseAppPath`: `/app/{ws}/settings`
 * is not one of the shapes `helpers/appUrl.ts` knows, and that file is not
 * on this task's edit surface. Falls back to the active workspace so the
 * page still works if it is ever mounted without the param.
 */
const workspaceId = computed<string>(() => {
  const fromPath = route?.params?.workspaceId
  if (typeof fromPath === 'string' && fromPath.length > 0) return fromPath
  return workspacesStore.activeWorkspace?.id ?? ''
})

const workspaceName = computed<string>(() => {
  if (workspacesStore.activeWorkspace?.id === workspaceId.value) {
    return workspacesStore.activeWorkspace.name
  }
  return workspaceId.value || 'this workspace'
})

const itemCount = computed<number>(() => {
  const ws = workspacesStore.activeWorkspace
  if (!ws || ws.id !== workspaceId.value) return 0
  return ws.items?.length ?? 0
})

// Fetch per workspace, and only when there IS one. `reset()` on every id
// change is what stops one workspace's secrets (or its failure banner) from
// being painted under another workspace's header.
watch(
  workspaceId,
  (id) => {
    secretsStore.reset()
    if (id) void secretsStore.fetchSecrets(id)
  },
  { immediate: true },
)

/**
 * Hand a new credential to the store, which forwards it to the API and
 * keeps nothing. This handler deliberately does not stash the payload on
 * any reactive state — the emit already delivered it and the component has
 * already cleared its inputs.
 */
async function handleAdd(payload: { name: string; value: string }): Promise<void> {
  if (!workspaceId.value) return
  await secretsStore.createSecret(workspaceId.value, payload.name, payload.value)
}

async function handleRotate(payload: { id: string; name: string; value: string }): Promise<void> {
  if (!workspaceId.value) return
  await secretsStore.rotateSecret(workspaceId.value, payload.id, payload.value)
}

/** The section emits the NAME; the store needs the id, so match on it. */
async function handleDelete(name: string): Promise<void> {
  const target = secretsStore.secrets.find((s) => s.name === name)
  if (!target || !workspaceId.value) return
  await secretsStore.deleteSecret(workspaceId.value, target.id)
}

function handleRetry(): void {
  if (workspaceId.value) void secretsStore.fetchSecrets(workspaceId.value)
}
</script>

<template>
  <div class="h-full overflow-y-auto" data-testid="workspace-settings-view">
    <div class="mx-auto w-full max-w-3xl px-6 py-8 space-y-6">
      <header class="space-y-1">
        <h1 class="text-title-lg font-semibold" style="color: var(--semantic-text)">
          Workspace settings
        </h1>
        <p class="text-dense" style="color: var(--semantic-text-muted)">
          Configuration for {{ workspaceName }}.
        </p>
      </header>

      <div role="tablist" class="flex gap-1 border-b" style="border-color: var(--color-border)">
        <button
          v-for="section in SECTIONS"
          :key="section.id"
          type="button"
          role="tab"
          :data-tab-id="section.id"
          :data-active="activeSection === section.id ? 'true' : 'false'"
          :aria-selected="activeSection === section.id"
          class="px-3 h-9 text-dense font-medium border-b-2 -mb-px transition-colors duration-150"
          :style="
            activeSection === section.id
              ? { color: 'var(--color-violet)', borderBottomColor: 'var(--color-violet)' }
              : { color: 'var(--semantic-text-muted)', borderBottomColor: 'transparent' }
          "
          @click="selectSection(section.id)"
        >
          {{ section.label }}
        </button>
      </div>

      <section
        v-if="activeSection === 'overview'"
        data-testid="overview-section"
        role="tabpanel"
        class="px-4 py-4 rounded-md space-y-2"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
      >
        <div class="flex items-baseline justify-between gap-4">
          <span class="text-dense" style="color: var(--semantic-text-muted)">Workspace</span>
          <span class="text-body font-mono" style="color: var(--semantic-text)">{{
            workspaceName
          }}</span>
        </div>
        <div class="flex items-baseline justify-between gap-4">
          <span class="text-dense" style="color: var(--semantic-text-muted)">Workspace ID</span>
          <span class="text-body font-mono" style="color: var(--semantic-text)">{{
            workspaceId || '—'
          }}</span>
        </div>
        <div class="flex items-baseline justify-between gap-4">
          <span class="text-dense" style="color: var(--semantic-text-muted)">Items</span>
          <span class="text-body font-mono" style="color: var(--semantic-text)">{{
            itemCount
          }}</span>
        </div>
      </section>

      <section v-else data-testid="secrets-section" role="tabpanel">
        <SecretsSection
          :secrets="secretsStore.secrets"
          :loading="secretsStore.loading"
          :loaded="secretsStore.loaded"
          :error="secretsStore.error"
          :saving="secretsStore.saving"
          @add="handleAdd"
          @rotate="handleRotate"
          @delete="handleDelete"
          @retry="handleRetry"
        />
      </section>
    </div>
  </div>
</template>
