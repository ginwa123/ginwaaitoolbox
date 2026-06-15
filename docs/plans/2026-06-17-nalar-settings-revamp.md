# Nalar Settings UI Revamp Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 1306-line monolithic `NalarSettings.vue` with a 4-sub-tab layout (`Defaults` / `Profiles` / `Sub-agents` / `MCP Servers`) backed by a `useNalarConfig` composable and ~14 focused sub-components. Kanagawa Dragon refined-industrial aesthetic. Pure frontend revamp.

**Architecture:** Single orchestrator (`NalarSettings.vue` ~200 lines) renders a tab strip + the active section + a sticky save bar. The `useNalarConfig` composable owns the in-memory `NalarConfig` + a snapshot for dirty tracking; each section binds to a slice of the config. All three add/edit flows (profile, sub-agent, MCP server) share a `LlmConfigForm` + `LlmConfigModal` pair with thin wrappers. `useProfileDelete` is reused unchanged.

**Tech Stack:** Vue 3 + TypeScript + Vite + Bun. Vitest + @vue/test-utils + jsdom. Tailwind 4 (layout utilities only; colors come from CSS variables in `style.css`). No new dependencies.

**Design doc:** `docs/plans/2026-06-17-nalar-settings-revamp-design.md`

---

## File structure

```
src/apps/desktop/src/components/
├── NalarSettings.vue            (rewritten, ~200 lines)
└── nalar/
    ├── useNalarConfig.ts         (single source of truth: load / dirty / save / reset)
    ├── EmptyState.vue            (shared: icon + 1-line + CTA)
    ├── NalarTabStrip.vue         (horizontal tab nav with underline indicator)
    ├── NalarSaveBar.vue          (sticky bottom bar with dirty count + Reset/Save)
    ├── LlmConfigForm.vue         (shared: model / base_url / api_key / thinking / temp / url_style)
    ├── LlmConfigModal.vue        (wraps LlmConfigForm + name field + Cancel/Save + title)
    ├── McpHeadersEditor.vue      (key/value pair editor for MCP)
    ├── ProfileModal.vue          (wraps LlmConfigModal with profile-specific labels)
    ├── SubAgentModal.vue         (wraps LlmConfigModal + system_prompt field)
    ├── McpServerModal.vue        (wraps LlmConfigModal + McpHeadersEditor)
    ├── DefaultsSection.vue       (Default LLM + Model Params + System Prompt)
    ├── ProfilesSection.vue       (list + active pill in header)
    ├── SubAgentsSection.vue      (list + 2-line prompt preview with expand)
    └── McpServersSection.vue     (list + masked header preview)

src/apps/desktop/src/__tests__/
├── useNalarConfig.spec.ts
├── EmptyState.spec.ts
├── NalarTabStrip.spec.ts
├── NalarSaveBar.spec.ts
├── LlmConfigForm.spec.ts
├── DefaultsSection.spec.ts
├── ProfilesSection.spec.ts
├── SubAgentsSection.spec.ts
└── McpServersSection.spec.ts
```

`useProfileDelete` (`composables/useProfileDelete.ts`) is **unchanged**.
`SettingsView.vue` is **unchanged** — the new `NalarSettings.vue` exposes the same `notification` event and `defineExpose({ saveSettings, resetSettings })` surface as today.

---

## Verification commands (run throughout)

```bash
# Type-check + bundle (the project's authoritative type check; per project memory,
# `bun run build` runs `vue-tsc --build`, NOT just bundling)
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20

# Unit tests
cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20
```

Per the project's NALAR.md memory: `bun run build` (NOT `bun run build-only`) is
the authoritative type check. `vitest` uses esbuild which strips types — TS
errors only surface in `bun run build`. Both must be clean.

---

## Chunk 1: Foundation — composable, types, shared building blocks

This chunk creates the core pieces with no dependencies on the other new
components. The old `NalarSettings.vue` keeps working in parallel throughout
this chunk (the new code is additive only).

### Task 1.1: `useNalarConfig` composable — load / save / reset / dirty

**Files:**
- Create: `src/apps/desktop/src/composables/useNalarConfig.ts`
- Create: `src/apps/desktop/src/__tests__/useNalarConfig.spec.ts`

- [ ] **Step 1: Write the failing tests**

```ts
// src/apps/desktop/src/__tests__/useNalarConfig.spec.ts
import { nextTick, ref } from 'vue'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import * as api from '../api'
import { useNalarConfig } from '../composables/useNalarConfig'

vi.mock('../api', () => ({
  getNalarConfig: vi.fn(),
  saveNalarConfig: vi.fn(),
  deleteProfile: vi.fn(),
}))

const mockGet = api.getNalarConfig as unknown as ReturnType<typeof vi.fn>
const mockSave = api.saveNalarConfig as unknown as ReturnType<typeof vi.fn>

describe('useNalarConfig', () => {
  beforeEach(() => {
    mockGet.mockReset()
    mockSave.mockReset()
  })

  it('starts with dirty=false and a null config', () => {
    const { config, dirty, loaded } = useNalarConfig()
    expect(config.value).toBeNull()
    expect(dirty.value).toBe(false)
    expect(loaded.value).toBe(false)
  })

  it('loads from the API and sets loaded=true', async () => {
    mockGet.mockResolvedValueOnce({
      api_endpoint: 'https://api.test/v1',
      model: 'gpt-4o-mini',
    })
    const { config, dirty, loaded, load } = useNalarConfig()
    await load()
    expect(loaded.value).toBe(true)
    expect(config.value?.api_endpoint).toBe('https://api.test/v1')
    expect(dirty.value).toBe(false)
  })

  it('flips dirty=true when a field is edited after load', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini' })
    const { config, dirty, load } = useNalarConfig()
    await load()
    expect(dirty.value).toBe(false)
    if (config.value) config.value.model = 'gpt-4o'
    await nextTick()
    expect(dirty.value).toBe(true)
  })

  it('counts unsaved field changes in unsavedCount', async () => {
    mockGet.mockResolvedValueOnce({
      api_endpoint: 'a',
      model: 'b',
      url_style: 'openai',
    })
    const { config, unsavedCount, load } = useNalarConfig()
    await load()
    if (config.value) {
      config.value.api_endpoint = 'aa' // 1 change
      config.value.model = 'bb'       // 2 changes
    }
    await nextTick()
    expect(unsavedCount.value).toBeGreaterThanOrEqual(2)
  })

  it('save() calls saveNalarConfig and clears dirty on success', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini' })
    mockSave.mockResolvedValueOnce({ success: true })
    const { config, dirty, load, save } = useNalarConfig()
    await load()
    if (config.value) config.value.model = 'gpt-4o'
    await nextTick()
    expect(dirty.value).toBe(true)
    await save()
    expect(mockSave).toHaveBeenCalledWith(expect.objectContaining({ model: 'gpt-4o' }))
    expect(dirty.value).toBe(false)
  })

  it('save() throws and keeps dirty=true on API failure', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini' })
    mockSave.mockRejectedValueOnce(new Error('HTTP 500'))
    const { config, dirty, load, save } = useNalarConfig()
    await load()
    if (config.value) config.value.model = 'gpt-4o'
    await nextTick()
    await expect(save()).rejects.toThrow('HTTP 500')
    expect(dirty.value).toBe(true)
  })

  it('reset() restores the snapshot and clears dirty', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini' })
    const { config, dirty, load, reset } = useNalarConfig()
    await load()
    if (config.value) config.value.model = 'gpt-4o'
    await nextTick()
    expect(dirty.value).toBe(true)
    reset()
    expect(config.value?.model).toBe('gpt-4o-mini')
    expect(dirty.value).toBe(false)
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run useNalarConfig.spec.ts 2>&1 | tail -n 20`
Expected: FAIL — "Cannot find module '../composables/useNalarConfig'"

- [ ] **Step 3: Write the composable**

```ts
// src/apps/desktop/src/composables/useNalarConfig.ts
/**
 * useNalarConfig — single source of truth for the Nalar settings UI.
 *
 * Owns the in-memory `NalarConfig` and a deep snapshot taken at load
 * time. `dirty` is a computed that re-runs whenever any tracked field
 * changes; `unsavedCount` is the number of leaf-level changes
 * (shallow count; exact field-level diffs are not required for the
 * dirty pill).
 *
 * `save()` PUTs the whole config to `/api/config/nalar`. On success
 * the snapshot is refreshed; on failure `dirty` stays true so the
 * save bar keeps showing.
 *
 * `reset()` restores the in-memory config from the snapshot.
 */
import { computed, ref, watch } from 'vue'

import { getNalarConfig, saveNalarConfig, type NalarConfig } from '../api'

export function useNalarConfig() {
  const config = ref<NalarConfig | null>(null)
  const loaded = ref(false)
  const snapshot = ref<string>('') // JSON.stringify of config at load time
  const saving = ref(false)

  /** Number of leaf-level field changes since load. Counts each
   *  primitive change once. Used by NalarSaveBar to show
   *  "● N unsaved changes". */
  const unsavedCount = computed(() => {
    if (!config.value) return 0
    if (!snapshot.value) return 0
    return countLeafDiffs(snapshot.value, JSON.stringify(config.value))
  })

  const dirty = computed(() => unsavedCount.value > 0)

  /** Re-snapshot the config so future edits compare against it. */
  function takeSnapshot() {
    snapshot.value = config.value ? JSON.stringify(config.value) : ''
  }

  async function load() {
    try {
      const data = await getNalarConfig()
      config.value = data ?? {}
    } catch {
      // localStorage fallback is handled by the orchestrator
      config.value = {}
    }
    loaded.value = true
    takeSnapshot()
  }

  async function save() {
    if (!config.value) return
    saving.value = true
    try {
      await saveNalarConfig(config.value)
      takeSnapshot()
    } finally {
      saving.value = false
    }
  }

  function reset() {
    if (!snapshot.value) return
    try {
      config.value = JSON.parse(snapshot.value)
    } catch {
      // Snapshot was malformed; leave config as-is.
    }
  }

  return {
    config,
    loaded,
    dirty,
    unsavedCount,
    saving,
    load,
    save,
    reset,
  }
}

/**
 * Count primitive field differences between two JSON strings.
 * Used to drive the "N unsaved changes" pill in the save bar.
 *
 * Walks both trees in parallel; for each key present in either
 * object, recurses if both values are objects, else counts a leaf
 * mismatch (different value OR present-in-one-only). Arrays are
 * compared element-by-element. Returns the total count.
 */
function countLeafDiffs(aJson: string, bJson: string): number {
  let a: unknown
  let b: unknown
  try {
    a = JSON.parse(aJson)
    b = JSON.parse(bJson)
  } catch {
    return aJson === bJson ? 0 : 1
  }
  return countDiffs(a, b)
}

function countDiffs(a: unknown, b: unknown): number {
  if (a === b) return 0
  if (a == null || b == null) return 1
  if (typeof a !== 'object' || typeof b !== 'object') return 1
  if (Array.isArray(a) !== Array.isArray(b)) return 1
  if (Array.isArray(a) && Array.isArray(b)) {
    let n = Math.abs(a.length - b.length)
    const len = Math.min(a.length, b.length)
    for (let i = 0; i < len; i++) n += countDiffs(a[i], b[i])
    return n
  }
  const ao = a as Record<string, unknown>
  const bo = b as Record<string, unknown>
  const keys = new Set([...Object.keys(ao), ...Object.keys(bo)])
  let n = 0
  for (const k of keys) n += countDiffs(ao[k], bo[k])
  return n
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run useNalarConfig.spec.ts 2>&1 | tail -n 20`
Expected: PASS — 7 tests

- [ ] **Step 5: Build to verify types**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean

- [ ] **Step 6: Commit**

```bash
git add src/apps/desktop/src/composables/useNalarConfig.ts src/apps/desktop/src/__tests__/useNalarConfig.spec.ts
git commit -m "feat(nalar-settings): add useNalarConfig composable

Single source of truth for the Nalar settings UI. Owns the in-memory
NalarConfig + a snapshot for dirty tracking. save() PUTs the whole
config and refreshes the snapshot on success; reset() restores from
snapshot. unsavedCount drives the dirty pill in the save bar.

7 vitest tests cover load, dirty transitions, unsaved count, save
success, save failure (keeps dirty), and reset."
```

---

### Task 1.2: `EmptyState` shared component

**Files:**
- Create: `src/apps/desktop/src/components/nalar/EmptyState.vue`
- Create: `src/apps/desktop/src/__tests__/EmptyState.spec.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/apps/desktop/src/__tests__/EmptyState.spec.ts
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import EmptyState from '../components/nalar/EmptyState.vue'

describe('EmptyState', () => {
  it('renders the title and description', () => {
    const wrapper = mount(EmptyState, {
      props: {
        glyph: '⌗',
        title: 'No profiles yet',
        description: 'Profiles are saved LLM configurations.',
      },
    })
    expect(wrapper.text()).toContain('No profiles yet')
    expect(wrapper.text()).toContain('saved LLM configurations')
    expect(wrapper.text()).toContain('⌗')
  })

  it('renders the CTA button when ctaLabel + ctaAction are provided', () => {
    const onCta = vi.fn()
    const wrapper = mount(EmptyState, {
      props: {
        glyph: '⌗',
        title: 'No profiles yet',
        description: 'desc',
        ctaLabel: 'Add profile',
        ctaAction: onCta,
      },
    })
    const button = wrapper.find('button')
    expect(button.exists()).toBe(true)
    expect(button.text()).toBe('Add profile')
  })

  it('omits the CTA button when ctaLabel is not provided', () => {
    const wrapper = mount(EmptyState, {
      props: { glyph: '⌗', title: 't', description: 'd' },
    })
    expect(wrapper.find('button').exists()).toBe(false)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run EmptyState.spec.ts 2>&1 | tail -n 10`
Expected: FAIL — module not found

- [ ] **Step 3: Write the component**

```vue
<!-- src/apps/desktop/src/components/nalar/EmptyState.vue -->
<script setup lang="ts">
defineProps<{
  glyph: string
  title: string
  description: string
  ctaLabel?: string
  ctaAction?: () => void
}>()
</script>

<template>
  <div
    class="flex flex-col items-center justify-center text-center py-12 px-6 rounded-md"
    style="background-color: var(--semantic-content-bg); border: 1px dashed var(--color-border);"
    data-testid="empty-state"
  >
    <div
      class="font-mono text-2xl mb-3"
      style="color: var(--semantic-text-dim);"
      aria-hidden="true"
    >{{ glyph }}</div>
    <h3
      class="text-sm font-semibold mb-1.5"
      style="color: var(--semantic-text);"
    >{{ title }}</h3>
    <p
      class="text-xs max-w-sm leading-relaxed"
      style="color: var(--semantic-text-muted);"
    >{{ description }}</p>
    <button
      v-if="ctaLabel"
      type="button"
      @click="ctaAction"
      class="mt-5 px-4 h-8 rounded-md text-sm font-medium border transition-colors duration-150"
      style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
      @mouseenter="(e) => { (e.currentTarget as HTMLElement).style.backgroundColor = 'var(--color-violet)'; (e.currentTarget as HTMLElement).style.color = '#181616' }"
      @mouseleave="(e) => { (e.currentTarget as HTMLElement).style.backgroundColor = 'transparent'; (e.currentTarget as HTMLElement).style.color = 'var(--color-violet)' }"
    >{{ ctaLabel }}</button>
  </div>
</template>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run EmptyState.spec.ts 2>&1 | tail -n 10`
Expected: PASS — 3 tests

- [ ] **Step 5: Build + commit**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
git add src/apps/desktop/src/components/nalar/EmptyState.vue src/apps/desktop/src/__tests__/EmptyState.spec.ts
git commit -m "feat(nalar-settings): add EmptyState shared component

Dashed-border card with monospace glyph, title, description, and
optional CTA. Used by Profiles / Sub-agents / MCP servers sections
when their list is empty."
```

---

### Task 1.3: `NalarTabStrip` component with persistence

**Files:**
- Create: `src/apps/desktop/src/components/nalar/NalarTabStrip.vue`
- Create: `src/apps/desktop/src/__tests__/NalarTabStrip.spec.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/apps/desktop/src/__tests__/NalarTabStrip.spec.ts
import { mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it } from 'vitest'

import NalarTabStrip from '../components/nalar/NalarTabStrip.vue'

describe('NalarTabStrip', () => {
  beforeEach(() => {
    localStorage.clear()
  })

  it('renders all 4 tab labels in order', () => {
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'defaults' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons.map(b => b.text().trim())).toEqual([
      'Defaults', 'Profiles', 'Sub-agents', 'MCP Servers',
    ])
  })

  it('emits update:modelValue when a tab is clicked', async () => {
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'defaults' },
    })
    await wrapper.findAll('button[role="tab"]')[1].trigger('click')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual(['profiles'])
  })

  it('marks the active tab with aria-selected=true', () => {
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'sub-agents' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons[0].attributes('aria-selected')).toBe('false')
    expect(buttons[2].attributes('aria-selected')).toBe('true')
  })

  it('persists the active tab to localStorage on change', async () => {
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'defaults' },
    })
    await wrapper.findAll('button[role="tab"]')[3].trigger('click')
    expect(localStorage.getItem('nalar-settings-active-tab')).toBe('mcp')
  })

  it('restores the active tab from localStorage on mount', () => {
    localStorage.setItem('nalar-settings-active-tab', 'profiles')
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'defaults' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons[1].attributes('aria-selected')).toBe('true')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run NalarTabStrip.spec.ts 2>&1 | tail -n 10`
Expected: FAIL

- [ ] **Step 3: Write the component**

```vue
<!-- src/apps/desktop/src/components/nalar/NalarTabStrip.vue -->
<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'

const STORAGE_KEY = 'nalar-settings-active-tab'

const props = defineProps<{
  modelValue: 'defaults' | 'profiles' | 'sub-agents' | 'mcp'
}>()

const emit = defineEmits<{
  'update:modelValue': [value: typeof props.modelValue]
}>()

const tabs: ReadonlyArray<{ id: typeof props.modelValue; label: string }> = [
  { id: 'defaults', label: 'Defaults' },
  { id: 'profiles', label: 'Profiles' },
  { id: 'sub-agents', label: 'Sub-agents' },
  { id: 'mcp', label: 'MCP Servers' },
] as const

// localStorage is the source of truth on mount, but the parent's
// v-model is what drives the actual selection. The watcher writes
// to localStorage when the parent changes the model.
onMounted(() => {
  const saved = localStorage.getItem(STORAGE_KEY)
  if (saved && tabs.some(t => t.id === saved) && saved !== props.modelValue) {
    emit('update:modelValue', saved as typeof props.modelValue)
  }
})

watch(() => props.modelValue, (val) => {
  try { localStorage.setItem(STORAGE_KEY, val) } catch { /* quota / private mode */ }
})
</script>

<template>
  <div
    role="tablist"
    aria-label="Nalar settings sections"
    class="flex items-center gap-1 border-b"
    style="border-color: var(--color-border);"
  >
    <button
      v-for="tab in tabs"
      :key="tab.id"
      role="tab"
      type="button"
      :aria-selected="modelValue === tab.id"
      :data-tab-id="tab.id"
      :data-active="modelValue === tab.id ? 'true' : 'false'"
      @click="emit('update:modelValue', tab.id)"
      class="relative px-4 h-10 text-sm font-medium transition-colors duration-150"
      :style="{
        color: modelValue === tab.id ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
      }"
    >
      <span class="relative z-10">{{ tab.label }}</span>
      <span
        v-if="modelValue === tab.id"
        class="absolute left-2 right-2 bottom-0 h-0.5"
        style="background-color: var(--color-violet);"
        aria-hidden="true"
      />
    </button>
  </div>
</template>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run NalarTabStrip.spec.ts 2>&1 | tail -n 10`
Expected: PASS — 5 tests

- [ ] **Step 5: Build + commit**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
git add src/apps/desktop/src/components/nalar/NalarTabStrip.vue src/apps/desktop/src/__tests__/NalarTabStrip.spec.ts
git commit -m "feat(nalar-settings): add NalarTabStrip

Horizontal tab nav with underline-style active indicator. Persists
selection to localStorage (nalar-settings-active-tab) so the user
lands back where they were. role=tablist + aria-selected for a11y."
```

---

### Task 1.4: `NalarSaveBar` component

**Files:**
- Create: `src/apps/desktop/src/components/nalar/NalarSaveBar.vue`
- Create: `src/apps/desktop/src/__tests__/NalarSaveBar.spec.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/apps/desktop/src/__tests__/NalarSaveBar.spec.ts
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import NalarSaveBar from '../components/nalar/NalarSaveBar.vue'

describe('NalarSaveBar', () => {
  it('renders nothing when not dirty', () => {
    const wrapper = mount(NalarSaveBar, {
      props: { dirty: false, unsavedCount: 0, saving: false },
    })
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(false)
  })

  it('renders the dirty pill with the count when dirty', () => {
    const wrapper = mount(NalarSaveBar, {
      props: { dirty: true, unsavedCount: 3, saving: false },
    })
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('3 unsaved changes')
  })

  it('uses singular "change" when unsavedCount is 1', () => {
    const wrapper = mount(NalarSaveBar, {
      props: { dirty: true, unsavedCount: 1, saving: false },
    })
    expect(wrapper.text()).toContain('1 unsaved change')
    expect(wrapper.text()).not.toContain('1 unsaved changes')
  })

  it('emits reset when the Reset button is clicked', async () => {
    const wrapper = mount(NalarSaveBar, {
      props: { dirty: true, unsavedCount: 1, saving: false },
    })
    await wrapper.find('[data-testid="reset-btn"]').trigger('click')
    expect(wrapper.emitted('reset')).toBeTruthy()
  })

  it('emits save when the Save button is clicked', async () => {
    const wrapper = mount(NalarSaveBar, {
      props: { dirty: true, unsavedCount: 1, saving: false },
    })
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    expect(wrapper.emitted('save')).toBeTruthy()
  })

  it('disables both buttons when saving is true', () => {
    const wrapper = mount(NalarSaveBar, {
      props: { dirty: true, unsavedCount: 1, saving: true },
    })
    expect((wrapper.find('[data-testid="reset-btn"]').element as HTMLButtonElement).disabled).toBe(true)
    expect((wrapper.find('[data-testid="save-btn"]').element as HTMLButtonElement).disabled).toBe(true)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run NalarSaveBar.spec.ts 2>&1 | tail -n 10`
Expected: FAIL

- [ ] **Step 3: Write the component**

```vue
<!-- src/apps/desktop/src/components/nalar/NalarSaveBar.vue -->
<script setup lang="ts">
defineProps<{
  dirty: boolean
  unsavedCount: number
  saving: boolean
}>()

const emit = defineEmits<{
  reset: []
  save: []
}>()
</script>

<template>
  <Transition
    enter-active-class="transition-all duration-180 ease-out"
    enter-from-class="translate-y-2 opacity-0"
    enter-to-class="translate-y-0 opacity-100"
    leave-active-class="transition-all duration-150 ease-in"
    leave-from-class="translate-y-0 opacity-100"
    leave-to-class="translate-y-2 opacity-0"
  >
    <div
      v-if="dirty"
      data-testid="save-bar"
      class="sticky bottom-0 left-0 right-0 flex items-center justify-between gap-4 px-4 h-12 border-t backdrop-blur-sm"
      style="background-color: rgba(24, 22, 22, 0.92); border-color: var(--color-border);"
    >
      <div class="flex items-center gap-2 text-xs font-mono" style="color: var(--semantic-text-muted);">
        <span
          class="w-1.5 h-1.5 rounded-full"
          style="background-color: var(--color-yellow);"
          aria-hidden="true"
        />
        <span>{{ unsavedCount }} unsaved change{{ unsavedCount === 1 ? '' : 's' }}</span>
      </div>
      <div class="flex items-center gap-2">
        <button
          type="button"
          data-testid="reset-btn"
          :disabled="saving"
          @click="emit('reset')"
          class="px-3 h-8 rounded-md text-xs font-medium border transition-colors duration-150"
          style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
        >Reset</button>
        <button
          type="button"
          data-testid="save-btn"
          :disabled="saving"
          @click="emit('save')"
          class="px-4 h-8 rounded-md text-xs font-medium border transition-colors duration-150"
          style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
        >{{ saving ? 'Saving…' : 'Save changes' }}</button>
      </div>
    </div>
  </Transition>
</template>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run NalarSaveBar.spec.ts 2>&1 | tail -n 10`
Expected: PASS — 6 tests

- [ ] **Step 5: Build + commit**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
git add src/apps/desktop/src/components/nalar/NalarSaveBar.vue src/apps/desktop/src/__tests__/NalarSaveBar.spec.ts
git commit -m "feat(nalar-settings): add NalarSaveBar

Sticky bottom bar that slides in when the config is dirty. Shows
the unsaved-change count, a Reset button, and a Save changes
button. Disables both buttons during a save in flight.

Uses Vue's <Transition> with translate-y/opacity for a 180ms
slide-in. Backdrop-blur-sm keeps the bar readable over scrolling
content."
```

---

## Chunk 2: Shared LLM form + modal + 3 wrappers

This chunk creates the shared components reused by all three add/edit flows.

### Task 2.1: `LlmConfigForm` with show/hide API key toggle

**Files:**
- Create: `src/apps/desktop/src/components/nalar/LlmConfigForm.vue`
- Create: `src/apps/desktop/src/__tests__/LlmConfigForm.spec.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/apps/desktop/src/__tests__/LlmConfigForm.spec.ts
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import LlmConfigForm from '../components/nalar/LlmConfigForm.vue'

const baseValue = {
  model: '',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
}

describe('LlmConfigForm', () => {
  it('renders all 6 fields', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    expect(wrapper.find('input[placeholder="MiniMax-M2.7"]').exists()).toBe(true)
    expect(wrapper.find('input[placeholder="https://api.minimax.io/v1"]').exists()).toBe(true)
    expect(wrapper.findAll('select')).toHaveLength(3) // thinking, temperature, url_style
  })

  it('hides the API key by default (type=password)', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue, api_key: 'sk-secret' } } })
    const keyInput = wrapper.find('[data-testid="api-key-input"]')
    expect(keyInput.attributes('type')).toBe('password')
  })

  it('toggles the API key to type=text when the show button is clicked', async () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue, api_key: 'sk-secret' } } })
    await wrapper.find('[data-testid="api-key-toggle"]').trigger('click')
    expect(wrapper.find('[data-testid="api-key-input"]').attributes('type')).toBe('text')
    await wrapper.find('[data-testid="api-key-toggle"]').trigger('click')
    expect(wrapper.find('[data-testid="api-key-input"]').attributes('type')).toBe('password')
  })

  it('emits update:modelValue when the model field changes', async () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const modelInput = wrapper.find('input[placeholder="MiniMax-M2.7"]')
    await modelInput.setValue('gpt-4o')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([{ ...baseValue, model: 'gpt-4o' }])
  })

  it('shows a validation error under the model field when errors.model is set', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue }, errors: { model: 'Model is required' } },
    })
    expect(wrapper.text()).toContain('Model is required')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run LlmConfigForm.spec.ts 2>&1 | tail -n 10`
Expected: FAIL

- [ ] **Step 3: Write the component**

```vue
<!-- src/apps/desktop/src/components/nalar/LlmConfigForm.vue -->
<script setup lang="ts">
import { ref } from 'vue'

export interface LlmConfig {
  model: string
  base_url: string
  thinking: string
  temperature: string
  url_style: string
  api_key: string
}

const props = defineProps<{
  modelValue: LlmConfig
  errors?: Partial<Record<keyof LlmConfig, string>>
}>()

const emit = defineEmits<{
  'update:modelValue': [value: LlmConfig]
}>()

const showKey = ref(false)

function update<K extends keyof LlmConfig>(key: K, value: LlmConfig[K]) {
  emit('update:modelValue', { ...props.modelValue, [key]: value })
}

const inputBase =
  'w-full px-3 h-8 rounded-md border text-sm font-sans transition-colors duration-150'
const inputStyle = (hasError?: boolean) => ({
  backgroundColor: 'var(--semantic-content-bg)',
  color: 'var(--semantic-text)',
  borderColor: hasError ? 'var(--color-red)' : 'var(--color-border)',
})

const labelBase = 'block text-xs font-medium mb-1.5'
const labelStyle = { color: 'var(--semantic-text-muted)' }

const errorStyle = { color: 'var(--color-red)' }
</script>

<template>
  <div class="space-y-4">
    <!-- Model -->
    <div>
      <label :class="labelBase" :style="labelStyle">Model <span style="color: var(--color-red);">*</span></label>
      <input
        :value="modelValue.model"
        @input="update('model', ($event.target as HTMLInputElement).value)"
        type="text"
        placeholder="MiniMax-M2.7"
        :class="inputBase"
        :style="inputStyle(!!errors?.model)"
        data-testid="model-input"
      />
      <p v-if="errors?.model" class="text-xs mt-1" :style="errorStyle">{{ errors.model }}</p>
    </div>

    <!-- Base URL -->
    <div>
      <label :class="labelBase" :style="labelStyle">Base URL</label>
      <input
        :value="modelValue.base_url"
        @input="update('base_url', ($event.target as HTMLInputElement).value)"
        type="text"
        placeholder="https://api.minimax.io/v1"
        :class="inputBase"
        :style="inputStyle(!!errors?.base_url)"
        data-testid="base-url-input"
      />
      <p v-if="errors?.base_url" class="text-xs mt-1" :style="errorStyle">{{ errors.base_url }}</p>
    </div>

    <!-- Thinking / Temperature / URL style — 3 columns -->
    <div class="grid grid-cols-3 gap-3">
      <div>
        <label :class="labelBase" :style="labelStyle">Thinking</label>
        <select
          :value="modelValue.thinking"
          @change="update('thinking', ($event.target as HTMLSelectElement).value)"
          :class="inputBase"
          :style="inputStyle()"
        >
          <option value="auto">Auto</option>
          <option value="on">On</option>
          <option value="off">Off</option>
        </select>
      </div>
      <div>
        <label :class="labelBase" :style="labelStyle">Temperature</label>
        <select
          :value="modelValue.temperature"
          @change="update('temperature', ($event.target as HTMLSelectElement).value)"
          :class="inputBase"
          :style="inputStyle()"
        >
          <option value="auto">Auto</option>
          <option value="0">0 — Precise</option>
          <option value="0.5">0.5</option>
          <option value="1">1 — Balanced</option>
        </select>
      </div>
      <div>
        <label :class="labelBase" :style="labelStyle">URL style</label>
        <select
          :value="modelValue.url_style"
          @change="update('url_style', ($event.target as HTMLSelectElement).value)"
          :class="inputBase"
          :style="inputStyle()"
        >
          <option value="openai">OpenAI</option>
          <option value="anthropic">Anthropic</option>
        </select>
      </div>
    </div>

    <!-- API key with show/hide -->
    <div>
      <label :class="labelBase" :style="labelStyle">
        API key
        <span v-if="!modelValue.api_key" style="color: var(--color-red);">*</span>
      </label>
      <div class="relative">
        <input
          :value="modelValue.api_key"
          @input="update('api_key', ($event.target as HTMLInputElement).value)"
          :type="showKey ? 'text' : 'password'"
          placeholder="sk-..."
          :class="inputBase + ' pr-9'"
          :style="inputStyle(!!errors?.api_key)"
          data-testid="api-key-input"
        />
        <button
          type="button"
          @click="showKey = !showKey"
          :aria-label="showKey ? 'Hide API key' : 'Show API key'"
          :title="showKey ? 'Hide' : 'Show'"
          data-testid="api-key-toggle"
          class="absolute right-2 top-1/2 -translate-y-1/2 w-6 h-6 flex items-center justify-center text-xs"
          style="color: var(--semantic-text-dim);"
        >{{ showKey ? '◉' : '○' }}</button>
      </div>
      <p v-if="errors?.api_key" class="text-xs mt-1" :style="errorStyle">{{ errors.api_key }}</p>
    </div>
  </div>
</template>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run LlmConfigForm.spec.ts 2>&1 | tail -n 10`
Expected: PASS — 5 tests

- [ ] **Step 5: Build + commit**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
git add src/apps/desktop/src/components/nalar/LlmConfigForm.vue src/apps/desktop/src/__tests__/LlmConfigForm.spec.ts
git commit -m "feat(nalar-settings): add LlmConfigForm shared component

Reusable form for the LLM fields shared by Profile, Sub-agent, and
MCP server modals: model, base_url, thinking, temperature,
url_style, api_key. API key has an eye-icon show/hide toggle
inside the field. 3-column layout for thinking/temp/url-style
saves vertical space. Field-level error messages under each input."
```

---

### Task 2.2: `LlmConfigModal` + `McpHeadersEditor`

**Files:**
- Create: `src/apps/desktop/src/components/nalar/LlmConfigModal.vue`
- Create: `src/apps/desktop/src/components/nalar/McpHeadersEditor.vue`
- Create: `src/apps/desktop/src/__tests__/McpHeadersEditor.spec.ts`

- [ ] **Step 1: Write the failing test for `McpHeadersEditor`**

```ts
// src/apps/desktop/src/__tests__/McpHeadersEditor.spec.ts
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import McpHeadersEditor from '../components/nalar/McpHeadersEditor.vue'

describe('McpHeadersEditor', () => {
  it('renders a row per header', () => {
    const wrapper = mount(McpHeadersEditor, {
      props: { modelValue: [{ key: 'A', value: '1' }, { key: 'B', value: '2' }] },
    })
    const rows = wrapper.findAll('[data-testid="header-row"]')
    expect(rows).toHaveLength(2)
  })

  it('shows the empty state when there are no headers', () => {
    const wrapper = mount(McpHeadersEditor, { props: { modelValue: [] } })
    expect(wrapper.text()).toContain('No headers')
  })

  it('adds a new empty header when Add header is clicked', async () => {
    const wrapper = mount(McpHeadersEditor, { props: { modelValue: [] } })
    await wrapper.find('[data-testid="add-header"]').trigger('click')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([[{ key: '', value: '' }]])
  })

  it('removes a header when its ✕ is clicked', async () => {
    const wrapper = mount(McpHeadersEditor, {
      props: { modelValue: [{ key: 'A', value: '1' }, { key: 'B', value: '2' }] },
    })
    await wrapper.findAll('[data-testid="remove-header"]')[0].trigger('click')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([[{ key: 'B', value: '2' }]])
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run McpHeadersEditor.spec.ts 2>&1 | tail -n 10`
Expected: FAIL

- [ ] **Step 3: Write the `McpHeadersEditor` component**

```vue
<!-- src/apps/desktop/src/components/nalar/McpHeadersEditor.vue -->
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

const inputBase = 'flex-1 px-3 h-8 rounded-md border text-sm font-mono'
const inputStyle = {
  backgroundColor: 'var(--semantic-content-bg)',
  color: 'var(--semantic-text)',
  borderColor: 'var(--color-border)',
}
</script>

<template>
  <div>
    <div class="flex items-center justify-between mb-2">
      <label class="text-xs font-medium" style="color: var(--semantic-text-muted);">Headers</label>
      <button
        type="button"
        data-testid="add-header"
        @click="add"
        class="text-xs px-2 h-7 rounded-md border transition-colors duration-150"
        style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
      >+ Add header</button>
    </div>

    <p v-if="modelValue.length === 0" class="text-xs italic" style="color: var(--semantic-text-dim);">
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
          class="w-7 h-7 flex items-center justify-center rounded-md text-sm transition-colors duration-150"
          style="color: var(--color-red);"
        >✕</button>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run McpHeadersEditor.spec.ts 2>&1 | tail -n 10`
Expected: PASS — 4 tests

- [ ] **Step 5: Write `LlmConfigModal` (no separate test — it's a thin orchestrator around `LlmConfigForm` + a name field)**

```vue
<!-- src/apps/desktop/src/components/nalar/LlmConfigModal.vue -->
<script setup lang="ts">
import LlmConfigForm, { type LlmConfig } from './LlmConfigForm.vue'

export interface LlmConfigModalValue {
  name: string
  config: LlmConfig
}

const props = defineProps<{
  modelValue: LlmConfigModalValue
  errors?: { name?: string; model?: string; base_url?: string; api_key?: string }
  title: string
  /** When true, the name field is editable (Add mode). When false (Edit mode), it's disabled. */
  nameEditable: boolean
  /** Optional slot content rendered after the LLM config form. Used by SubAgentModal (system_prompt) and McpServerModal (headers). */
  extraSlotName?: string
}>()

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
        class="w-full max-w-md mx-4 rounded-md flex flex-col"
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
```

- [ ] **Step 6: Build + commit**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
git add src/apps/desktop/src/components/nalar/LlmConfigModal.vue \
        src/apps/desktop/src/components/nalar/McpHeadersEditor.vue \
        src/apps/desktop/src/__tests__/McpHeadersEditor.spec.ts
git commit -m "feat(nalar-settings): add LlmConfigModal and McpHeadersEditor

LlmConfigModal is a thin wrapper around LlmConfigForm + a name
field. Exposes an optional named slot for the section-specific
extras (system_prompt for sub-agents, headers for MCP). Uses
<Teleport to=body> so the modal sits above any overflow:hidden
ancestors. McpHeadersEditor renders the key/value pair editor
with add/remove. 4 vitest tests cover add, remove, empty state,
row rendering."
```

---

### Task 2.3: `ProfileModal`, `SubAgentModal`, `McpServerModal` — thin wrappers

**Files:**
- Create: `src/apps/desktop/src/components/nalar/ProfileModal.vue`
- Create: `src/apps/desktop/src/components/nalar/SubAgentModal.vue`
- Create: `src/apps/desktop/src/components/nalar/McpServerModal.vue`

(No separate test files — these are pure pass-throughs to `LlmConfigModal`. They'll be covered by the integration tests in Chunk 7.)

- [ ] **Step 1: Write `ProfileModal.vue`**

```vue
<!-- src/apps/desktop/src/components/nalar/ProfileModal.vue -->
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
```

- [ ] **Step 2: Write `SubAgentModal.vue` (with system_prompt extra slot)**

```vue
<!-- src/apps/desktop/src/components/nalar/SubAgentModal.vue -->
<script setup lang="ts">
import LlmConfigModal, { type LlmConfigModalValue } from './LlmConfigModal.vue'

const props = defineProps<{
  modelValue: LlmConfigModalValue & { system_prompt: string }
  errors?: { name?: string; model?: string; base_url?: string; api_key?: string }
  mode: 'add' | 'edit'
}>()

const emit = defineEmits<{
  'update:modelValue': [value: typeof props.modelValue]
  cancel: []
  save: []
}>()

function updateBase(v: LlmConfigModalValue) {
  emit('update:modelValue', { ...v, system_prompt: props.modelValue.system_prompt })
}
function updateSystemPrompt(val: string) {
  emit('update:modelValue', { ...props.modelValue, system_prompt: val })
}
</script>

<template>
  <LlmConfigModal
    :model-value="modelValue"
    :errors="errors"
    :title="mode === 'add' ? 'Add sub-agent' : 'Edit sub-agent'"
    :name-editable="mode === 'add'"
    extra-slot-name="extra"
    @update:model-value="updateBase"
    @cancel="emit('cancel')"
    @save="emit('save')"
  >
    <template #extra>
      <div>
        <label class="block text-xs font-medium mb-1.5" style="color: var(--semantic-text-muted);">
          System prompt
        </label>
        <textarea
          :value="modelValue.system_prompt"
          @input="updateSystemPrompt(($event.target as HTMLTextAreaElement).value)"
          rows="5"
          placeholder="System prompt for this sub-agent…"
          class="w-full px-3 py-2 rounded-md border text-sm font-sans resize-none"
          style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
        />
      </div>
    </template>
  </LlmConfigModal>
</template>
```

- [ ] **Step 3: Write `McpServerModal.vue` (with headers extra slot + URL field)**

```vue
<!-- src/apps/desktop/src/components/nalar/McpServerModal.vue -->
<script setup lang="ts">
import { computed } from 'vue'

import LlmConfigModal, { type LlmConfigModalValue } from './LlmConfigModal.vue'
import McpHeadersEditor, { type McpHeader } from './McpHeadersEditor.vue'

// The MCP server shape is { name, url, headers }, NOT a LlmConfig.
// We adapt it to the LlmConfigModal's contract by treating `url` as
// the LLM `base_url` (same field, same validation) and dropping the
// other LLM fields.
export interface McpServerModalValue {
  name: string
  url: string
  headers: McpHeader[]
}

const props = defineProps<{
  modelValue: McpServerModalValue
  errors?: { name?: string; url?: string }
  mode: 'add' | 'edit'
}>()

const emit = defineEmits<{
  'update:modelValue': [value: McpServerModalValue]
  cancel: []
  save: []
}>()

// Adapt server shape <-> LlmConfigModal's shape (uses base_url slot for URL).
const adapted = computed<LlmConfigModalValue>(() => ({
  name: props.modelValue.name,
  config: {
    model: '',           // not used by MCP
    base_url: props.modelValue.url,
    thinking: 'auto',
    temperature: 'auto',
    url_style: 'openai',
    api_key: '',
  },
}))

function updateFromModal(v: LlmConfigModalValue) {
  emit('update:modelValue', {
    name: v.name,
    url: v.config.base_url,
    headers: props.modelValue.headers,
  })
}

function updateHeaders(h: McpHeader[]) {
  emit('update:modelValue', { ...props.modelValue, headers: h })
}

const errorForModal = computed(() => ({
  name: props.errors?.name,
  base_url: props.errors?.url,
}))
</script>

<template>
  <LlmConfigModal
    :model-value="adapted"
    :errors="errorForModal"
    :title="mode === 'add' ? 'Add MCP server' : 'Edit MCP server'"
    :name-editable="mode === 'add'"
    extra-slot-name="extra"
    @update:model-value="updateFromModal"
    @cancel="emit('cancel')"
    @save="emit('save')"
  >
    <template #extra>
      <McpHeadersEditor
        :model-value="modelValue.headers"
        @update:model-value="updateHeaders"
      />
    </template>
  </LlmConfigModal>
</template>
```

- [ ] **Step 4: Build + commit**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
git add src/apps/desktop/src/components/nalar/ProfileModal.vue \
        src/apps/desktop/src/components/nalar/SubAgentModal.vue \
        src/apps/desktop/src/components/nalar/McpServerModal.vue
git commit -m "feat(nalar-settings): add ProfileModal, SubAgentModal, McpServerModal

Thin pass-through wrappers around LlmConfigModal:
- ProfileModal: no extras
- SubAgentModal: adds system_prompt textarea via the 'extra' slot
- McpServerModal: maps url<->base_url and adds McpHeadersEditor

No new tests — covered by integration tests in Chunk 7."
```

---

## Chunk 3: `DefaultsSection` — Default LLM + Model Params + System Prompt

This is the most-edited tab. It owns the top-level `api_endpoint`, `api_key`, `model`, `url_style`, `temperature`, `max_tokens`, `notify_on_complete`, and `system_prompt` fields.

### Task 3.1: `DefaultsSection` skeleton + field wiring

**Files:**
- Create: `src/apps/desktop/src/components/nalar/DefaultsSection.vue`
- Create: `src/apps/desktop/src/__tests__/DefaultsSection.spec.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/apps/desktop/src/__tests__/DefaultsSection.spec.ts
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import DefaultsSection from '../components/nalar/DefaultsSection.vue'

const baseConfig = {
  api_endpoint: '',
  api_key: '',
  model: '',
  url_style: 'openai' as const,
  temperature: 0.7,
  max_tokens: '',
  system_prompt: '',
  notify_on_complete: false,
}

describe('DefaultsSection', () => {
  it('renders all 3 section headers', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig } },
    })
    expect(wrapper.text()).toContain('Default LLM')
    expect(wrapper.text()).toContain('Model parameters')
    expect(wrapper.text()).toContain('System prompt')
  })

  it('emits update:modelValue when api_endpoint changes', async () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig } },
    })
    const input = wrapper.find('[data-testid="api-endpoint-input"]')
    await input.setValue('https://api.test/v1')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([{
      ...baseConfig,
      api_endpoint: 'https://api.test/v1',
    }])
  })

  it('renders the temperature slider with the current value', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig, temperature: 1.2 } },
    })
    const slider = wrapper.find('[data-testid="temperature-slider"]')
    expect((slider.element as HTMLInputElement).value).toBe('1.2')
  })

  it('shows the approximate token count for the system prompt', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig, system_prompt: 'one two three four five' } },
    })
    // 5 words * 1.3 = 6.5 -> ceil = 7
    expect(wrapper.text()).toMatch(/~ ?7 tokens/)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run DefaultsSection.spec.ts 2>&1 | tail -n 10`
Expected: FAIL

- [ ] **Step 3: Write the component**

```vue
<!-- src/apps/desktop/src/components/nalar/DefaultsSection.vue -->
<script setup lang="ts">
import { computed } from 'vue'

export interface DefaultsConfig {
  api_endpoint: string
  api_key: string
  model: string
  url_style: string
  temperature: number
  max_tokens: string
  system_prompt: string
  notify_on_complete: boolean
}

const props = defineProps<{ modelValue: DefaultsConfig }>()
const emit = defineEmits<{ 'update:modelValue': [value: DefaultsConfig] }>()

function update<K extends keyof DefaultsConfig>(key: K, val: DefaultsConfig[K]) {
  emit('update:modelValue', { ...props.modelValue, [key]: val })
}

const inputBase = 'w-full px-3 h-8 rounded-md border text-sm transition-colors duration-150'
const inputStyle = {
  backgroundColor: 'var(--semantic-content-bg)',
  color: 'var(--semantic-text)',
  borderColor: 'var(--color-border)',
}
const sectionHeader = 'font-mono text-xs uppercase tracking-wider mb-3'
const sectionHeaderStyle = { color: 'var(--semantic-text-dim)' }
const labelBase = 'block text-xs font-medium mb-1.5'
const labelStyle = { color: 'var(--semantic-text-muted)' }
const helperStyle = { color: 'var(--semantic-text-dim)' }

// Approximate token count: words * 1.3, rounded up. Footer hint.
const systemPromptTokens = computed(() => {
  const text = props.modelValue.system_prompt.trim()
  if (!text) return 0
  const words = text.split(/\s+/).filter(Boolean).length
  return Math.ceil(words * 1.3)
})
</script>

<template>
  <div class="space-y-8">
    <!-- Default LLM -->
    <section>
      <h3 :class="sectionHeader" :style="sectionHeaderStyle">── Default LLM ──</h3>
      <div class="space-y-4">
        <div>
          <label :class="labelBase" :style="labelStyle">API endpoint</label>
          <input
            :value="modelValue.api_endpoint"
            @input="update('api_endpoint', ($event.target as HTMLInputElement).value)"
            type="text"
            placeholder="https://api.example.com/v1"
            :class="inputBase"
            :style="inputStyle"
            data-testid="api-endpoint-input"
          />
          <p class="text-xs mt-1" :style="helperStyle">Used by all profiles unless a profile overrides.</p>
        </div>

        <div>
          <label :class="labelBase" :style="labelStyle">API key</label>
          <input
            :value="modelValue.api_key"
            @input="update('api_key', ($event.target as HTMLInputElement).value)"
            type="password"
            placeholder="sk-…"
            :class="inputBase"
            :style="inputStyle"
            data-testid="api-key-input"
          />
          <p class="text-xs mt-1" :style="helperStyle">Stored in config.json. Not synced anywhere.</p>
        </div>

        <div>
          <label :class="labelBase" :style="labelStyle">Model</label>
          <input
            :value="modelValue.model"
            @input="update('model', ($event.target as HTMLInputElement).value)"
            type="text"
            placeholder="MiniMax-M2.7"
            :class="inputBase"
            :style="inputStyle"
            data-testid="model-input"
          />
        </div>

        <div>
          <label :class="labelBase" :style="labelStyle">URL style</label>
          <select
            :value="modelValue.url_style"
            @change="update('url_style', ($event.target as HTMLSelectElement).value)"
            :class="inputBase"
            :style="inputStyle"
          >
            <option value="openai">OpenAI (/v1/chat/completions)</option>
            <option value="anthropic">Anthropic (/v1/messages)</option>
          </select>
        </div>
      </div>
    </section>

    <!-- Model parameters -->
    <section>
      <h3 :class="sectionHeader" :style="sectionHeaderStyle">── Model parameters ──</h3>
      <div class="space-y-4">
        <div>
          <div class="flex items-center justify-between mb-1.5">
            <label :class="labelBase" :style="labelStyle" class="!mb-0">Temperature</label>
            <span class="font-mono text-xs" :style="labelStyle">{{ modelValue.temperature.toFixed(1) }}</span>
          </div>
          <input
            :value="modelValue.temperature"
            @input="update('temperature', parseFloat(($event.target as HTMLInputElement).value))"
            type="range"
            min="0"
            max="2"
            step="0.1"
            class="w-full"
            data-testid="temperature-slider"
          />
          <div class="flex justify-between text-xs mt-1 font-mono" :style="helperStyle">
            <span>Precise</span>
            <span>Creative</span>
          </div>
        </div>

        <div>
          <label :class="labelBase" :style="labelStyle">Max tokens</label>
          <input
            :value="modelValue.max_tokens"
            @input="update('max_tokens', ($event.target as HTMLInputElement).value)"
            type="number"
            placeholder="4096"
            :class="inputBase"
            :style="inputStyle"
          />
        </div>

        <div>
          <label class="flex items-start gap-2 cursor-pointer text-sm">
            <input
              :checked="modelValue.notify_on_complete"
              @change="update('notify_on_complete', ($event.target as HTMLInputElement).checked)"
              type="checkbox"
              class="w-4 h-4 mt-0.5"
              style="accent-color: var(--color-violet);"
              data-testid="notify-checkbox"
            />
            <span>
              <span :style="labelStyle">Notify when an LLM response completes</span>
              <span class="block text-xs mt-0.5" :style="helperStyle">
                Fires an OS notification when a response finishes. Requires notify-send (Linux) / osascript (mac) / PowerShell (Windows).
              </span>
            </span>
          </label>
        </div>
      </div>
    </section>

    <!-- System prompt -->
    <section>
      <h3 :class="sectionHeader" :style="sectionHeaderStyle">── System prompt ──</h3>
      <div>
        <textarea
          :value="modelValue.system_prompt"
          @input="update('system_prompt', ($event.target as HTMLTextAreaElement).value)"
          rows="8"
          placeholder="Enter system prompt for the AI…"
          class="w-full px-3 py-2 rounded-md border text-sm resize-none"
          style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border); font-family: var(--font-mono);"
          data-testid="system-prompt-input"
        />
        <p class="text-xs mt-1 font-mono" :style="helperStyle">
          ~ {{ systemPromptTokens }} token{{ systemPromptTokens === 1 ? '' : 's' }} · keep it under 2,000 for best results
        </p>
      </div>
    </section>
  </div>
</template>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run DefaultsSection.spec.ts 2>&1 | tail -n 10`
Expected: PASS — 4 tests

- [ ] **Step 5: Build + commit**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
git add src/apps/desktop/src/components/nalar/DefaultsSection.vue src/apps/desktop/src/__tests__/DefaultsSection.spec.ts
git commit -m "feat(nalar-settings): add DefaultsSection

The Defaults tab: Default LLM (endpoint, key, model, url_style),
Model parameters (temperature slider with mono readout, max tokens,
notify-on-complete checkbox), and System prompt textarea with a
live approximate token count footer (words * 1.3, ceil).

4 vitest tests cover section rendering, field wiring, slider
value, and token-count computation."
```

---

## Chunk 4: `ProfilesSection` — list + active pill + Set Active + delete

### Task 4.1: `ProfilesSection` with active pill in header

**Files:**
- Create: `src/apps/desktop/src/components/nalar/ProfilesSection.vue`
- Create: `src/apps/desktop/src/__tests__/ProfilesSection.spec.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/apps/desktop/src/__tests__/ProfilesSection.spec.ts
import { mount } from '@vue/test-utils'
import { describe, expect, it, vi } from 'vitest'

import ProfilesSection from '../components/nalar/ProfilesSection.vue'

const baseProfile = { name: 'work', model: 'm', base_url: '', thinking: 'auto', temperature: 'auto', url_style: 'openai', api_key: '' }

describe('ProfilesSection', () => {
  it('shows the active profile in the header pill', () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: 'work' },
    })
    expect(wrapper.find('[data-testid="active-pill"]').text()).toContain('work')
  })

  it('shows the empty state when no profiles exist', () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [], activeProfile: null },
    })
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true)
  })

  it('emits setActive when "Set active" is clicked on a non-active row', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [{ ...baseProfile }, { ...baseProfile, name: 'home' }], activeProfile: 'work' },
    })
    await wrapper.findAll('[data-testid="set-active-btn"]')[1].trigger('click')
    expect(wrapper.emitted('setActive')?.[0]).toEqual(['home'])
  })

  it('emits edit when Edit is clicked', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    await wrapper.find('[data-testid="edit-btn"]').trigger('click')
    expect(wrapper.emitted('edit')?.[0]).toEqual([baseProfile])
  })

  it('emits delete when Delete is clicked', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    await wrapper.find('[data-testid="delete-btn"]').trigger('click')
    expect(wrapper.emitted('delete')?.[0]).toEqual(['work'])
  })

  it('emits add when the + Add profile button is clicked', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [], activeProfile: null },
    })
    await wrapper.find('[data-testid="add-btn"]').trigger('click')
    expect(wrapper.emitted('add')).toBeTruthy()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run ProfilesSection.spec.ts 2>&1 | tail -n 10`
Expected: FAIL

- [ ] **Step 3: Write the component**

```vue
<!-- src/apps/desktop/src/components/nalar/ProfilesSection.vue -->
<script setup lang="ts">
import EmptyState from './EmptyState.vue'
import type { NalarProfile } from '../../api'

defineProps<{
  modelValue: NalarProfile[]
  activeProfile: string | null
}>()

const emit = defineEmits<{
  setActive: [name: string]
  edit: [profile: NalarProfile]
  delete: [name: string]
  add: []
}>()
</script>

<template>
  <div class="space-y-4">
    <!-- Header with active pill + add button -->
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-2">
        <span class="text-xs font-mono" style="color: var(--semantic-text-dim);">Active</span>
        <span
          v-if="activeProfile"
          data-testid="active-pill"
          class="text-xs px-2 h-6 inline-flex items-center rounded-md font-mono"
          style="background-color: var(--color-violet); color: #181616;"
        >{{ activeProfile }}</span>
        <span
          v-else
          class="text-xs italic"
          style="color: var(--semantic-text-dim);"
        >(none — pick one below)</span>
      </div>
      <button
        type="button"
        data-testid="add-btn"
        @click="emit('add')"
        class="px-3 h-8 rounded-md text-xs font-medium border transition-colors duration-150"
        style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
      >+ Add profile</button>
    </div>

    <!-- Empty state -->
    <EmptyState
      v-if="modelValue.length === 0"
      data-testid="empty-state"
      glyph="⌗"
      title="No profiles yet"
      description="Profiles are saved LLM configurations you can switch between with one click. Useful for separate API keys, models, or thinking settings."
      cta-label="+ Add profile"
      :cta-action="() => emit('add')"
    />

    <!-- List -->
    <ul v-else class="space-y-2" data-testid="profile-list">
      <li
        v-for="profile in modelValue"
        :key="profile.name"
        class="flex items-center justify-between gap-3 px-4 py-3 rounded-md"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);"
      >
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2">
            <span
              v-if="activeProfile === profile.name"
              class="w-1.5 h-1.5 rounded-full"
              style="background-color: var(--color-violet);"
              aria-label="Active"
            />
            <span class="text-sm font-medium" style="color: var(--semantic-text);">{{ profile.name }}</span>
            <span
              v-if="activeProfile === profile.name"
              class="text-[10px] px-1.5 h-5 inline-flex items-center rounded font-mono"
              style="background-color: var(--color-violet); color: #181616;"
            >active</span>
          </div>
          <div class="text-xs font-mono mt-0.5 truncate" style="color: var(--semantic-text-dim);">
            {{ profile.model }} · {{ profile.base_url || '—' }}
          </div>
        </div>
        <div class="flex items-center gap-1.5 shrink-0">
          <button
            v-if="activeProfile !== profile.name"
            type="button"
            data-testid="set-active-btn"
            @click="emit('setActive', profile.name)"
            class="px-2.5 h-7 rounded-md text-xs border transition-colors duration-150"
            style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
          >Set active</button>
          <button
            type="button"
            data-testid="edit-btn"
            @click="emit('edit', profile)"
            class="px-2.5 h-7 rounded-md text-xs border transition-colors duration-150"
            style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
          >Edit</button>
          <button
            type="button"
            data-testid="delete-btn"
            @click="emit('delete', profile.name)"
            class="px-2.5 h-7 rounded-md text-xs transition-colors duration-150"
            style="color: var(--color-red);"
            aria-label="Delete profile"
          >⌫</button>
        </div>
      </li>
    </ul>
  </div>
</template>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run ProfilesSection.spec.ts 2>&1 | tail -n 10`
Expected: PASS — 6 tests

- [ ] **Step 5: Build + commit**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
git add src/apps/desktop/src/components/nalar/ProfilesSection.vue src/apps/desktop/src/__tests__/ProfilesSection.spec.ts
git commit -m "feat(nalar-settings): add ProfilesSection

List of profiles with the active one marked by a violet dot + 'active'
chip in the row AND a pill in the section header. Non-active rows
have Set active / Edit / Delete (⌫ icon, red on hover). The
section's active pill doubles as a visual anchor so users always
know which profile is in use.

6 vitest tests cover active pill, empty state, setActive / edit /
delete / add events."
```

---

## Chunk 5: `SubAgentsSection` — list + 2-line prompt preview with expand

### Task 5.1: `SubAgentsSection` with expandable prompt

**Files:**
- Create: `src/apps/desktop/src/components/nalar/SubAgentsSection.vue`
- Create: `src/apps/desktop/src/__tests__/SubAgentsSection.spec.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/apps/desktop/src/__tests__/SubAgentsSection.spec.ts
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import SubAgentsSection from '../components/nalar/SubAgentsSection.vue'

const baseAgent = { name: 'coder', model: 'm', base_url: '', thinking: 'auto', temperature: 'auto', url_style: 'openai', api_key: '', system_prompt: 'short prompt' }

describe('SubAgentsSection', () => {
  it('shows the section explainer', () => {
    const wrapper = mount(SubAgentsSection, { props: { modelValue: [] } })
    expect(wrapper.text()).toContain('spawn_sub_agent')
  })

  it('shows the empty state when no sub-agents exist', () => {
    const wrapper = mount(SubAgentsSection, { props: { modelValue: [] } })
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true)
  })

  it('renders the 2-line prompt preview by default', () => {
    const long = 'word '.repeat(50).trim()
    const wrapper = mount(SubAgentsSection, {
      props: { modelValue: [{ ...baseAgent, system_prompt: long }] },
    })
    const preview = wrapper.find('[data-testid="prompt-preview"]')
    expect(preview.classes()).toContain('line-clamp-2')
  })

  it('expands the prompt when "Show more" is clicked', async () => {
    const long = 'word '.repeat(50).trim()
    const wrapper = mount(SubAgentsSection, {
      props: { modelValue: [{ ...baseAgent, system_prompt: long }] },
    })
    await wrapper.find('[data-testid="expand-prompt"]').trigger('click')
    const preview = wrapper.find('[data-testid="prompt-preview"]')
    expect(preview.classes()).not.toContain('line-clamp-2')
  })

  it('emits edit when Edit is clicked', async () => {
    const wrapper = mount(SubAgentsSection, {
      props: { modelValue: [baseAgent] },
    })
    await wrapper.find('[data-testid="edit-btn"]').trigger('click')
    expect(wrapper.emitted('edit')?.[0]).toEqual([baseAgent])
  })

  it('emits delete when ⌫ is clicked', async () => {
    const wrapper = mount(SubAgentsSection, {
      props: { modelValue: [baseAgent] },
    })
    await wrapper.find('[data-testid="delete-btn"]').trigger('click')
    expect(wrapper.emitted('delete')?.[0]).toEqual(['coder'])
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run SubAgentsSection.spec.ts 2>&1 | tail -n 10`
Expected: FAIL

- [ ] **Step 3: Write the component**

```vue
<!-- src/apps/desktop/src/components/nalar/SubAgentsSection.vue -->
<script setup lang="ts">
import { ref } from 'vue'

import EmptyState from './EmptyState.vue'
import type { SubAgent } from '../../api'

defineProps<{ modelValue: SubAgent[] }>()
const emit = defineEmits<{
  edit: [sa: SubAgent]
  delete: [name: string]
  add: []
}>()

// Map of sub-agent name -> expanded state.
const expanded = ref<Record<string, boolean>>({})

function toggle(name: string) {
  expanded.value = { ...expanded.value, [name]: !expanded.value[name] }
}
</script>

<template>
  <div class="space-y-4">
    <p class="text-xs leading-relaxed max-w-2xl" style="color: var(--semantic-text-muted);">
      Sub-agents are named LLM configurations the agent can spawn via the
      <code style="font-family: var(--font-mono);">spawn_sub_agent</code>
      tool. Top-level sub-agents apply to every profile unless a profile overrides them.
    </p>

    <div class="flex justify-end">
      <button
        type="button"
        data-testid="add-btn"
        @click="emit('add')"
        class="px-3 h-8 rounded-md text-xs font-medium border transition-colors duration-150"
        style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
      >+ Add sub-agent</button>
    </div>

    <EmptyState
      v-if="modelValue.length === 0"
      data-testid="empty-state"
      glyph="◌"
      title="No sub-agents yet"
      description="Sub-agents are specialized LLM configs the agent can hand off work to. Useful for parallel research, reviews, or domain-specific personas."
      cta-label="+ Add sub-agent"
      :cta-action="() => emit('add')"
    />

    <ul v-else class="space-y-2" data-testid="subagent-list">
      <li
        v-for="sa in modelValue"
        :key="sa.name"
        class="px-4 py-3 rounded-md"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="flex-1 min-w-0">
            <div class="text-sm font-medium" style="color: var(--semantic-text);">{{ sa.name }}</div>
            <div class="text-xs font-mono mt-0.5 truncate" style="color: var(--semantic-text-dim);">
              {{ sa.model }} · {{ sa.base_url || '—' }}
            </div>
          </div>
          <div class="flex items-center gap-1.5 shrink-0">
            <button
              type="button"
              data-testid="edit-btn"
              @click="emit('edit', sa)"
              class="px-2.5 h-7 rounded-md text-xs border transition-colors duration-150"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
            >Edit</button>
            <button
              type="button"
              data-testid="delete-btn"
              @click="emit('delete', sa.name)"
              class="px-2.5 h-7 rounded-md text-xs transition-colors duration-150"
              style="color: var(--color-red);"
              aria-label="Delete sub-agent"
            >⌫</button>
          </div>
        </div>

        <p
          v-if="sa.system_prompt"
          data-testid="prompt-preview"
          class="text-xs mt-2"
          :class="expanded[sa.name] ? '' : 'line-clamp-2'"
          style="color: var(--semantic-text-muted); white-space: pre-wrap;"
        >{{ sa.system_prompt }}</p>
        <button
          v-if="sa.system_prompt && sa.system_prompt.length > 100"
          type="button"
          data-testid="expand-prompt"
          @click="toggle(sa.name)"
          class="text-[11px] mt-1 font-mono"
          style="color: var(--semantic-text-dim);"
        >{{ expanded[sa.name] ? 'Show less' : 'Show more' }}</button>
      </li>
    </ul>
  </div>
</template>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run SubAgentsSection.spec.ts 2>&1 | tail -n 10`
Expected: PASS — 6 tests

- [ ] **Step 5: Build + commit**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
git add src/apps/desktop/src/components/nalar/SubAgentsSection.vue src/apps/desktop/src/__tests__/SubAgentsSection.spec.ts
git commit -m "feat(nalar-settings): add SubAgentsSection

List of sub-agents with a 2-line system-prompt preview per row.
Long prompts (>100 chars) get a 'Show more' toggle that expands
the preview to full text. Includes a section explainer so first-time
users know what sub-agents are for.

6 vitest tests cover section explainer, empty state, line-clamp
default, expand toggle, edit and delete events."
```

---

## Chunk 6: `McpServersSection` — list with masked header preview

### Task 6.1: `McpServersSection` with masked header preview

**Files:**
- Create: `src/apps/desktop/src/components/nalar/McpServersSection.vue`
- Create: `src/apps/desktop/src/__tests__/McpServersSection.spec.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/apps/desktop/src/__tests__/McpServersSection.spec.ts
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import McpServersSection from '../components/nalar/McpServersSection.vue'

const baseServer = { name: 'context7', url: 'https://mcp.context7.com/mcp', headers: [] }

describe('McpServersSection', () => {
  it('shows the section explainer', () => {
    const wrapper = mount(McpServersSection, { props: { modelValue: [] } })
    expect(wrapper.text()).toContain('External tool providers')
  })

  it('shows the empty state when no servers exist', () => {
    const wrapper = mount(McpServersSection, { props: { modelValue: [] } })
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true)
  })

  it('masks header values to first 3 + last 3 chars', () => {
    const wrapper = mount(McpServersSection, {
      props: { modelValue: [{ ...baseServer, headers: [{ key: 'X-Token', value: 'abcdef1234567890xyz' }] }] },
    })
    // first 3 = abc, last 3 = xyz, middle is *-padded
    expect(wrapper.text()).toContain('abc***************xyz')
  })

  it('emits add when + Add server is clicked', async () => {
    const wrapper = mount(McpServersSection, { props: { modelValue: [] } })
    await wrapper.find('[data-testid="add-btn"]').trigger('click')
    expect(wrapper.emitted('add')).toBeTruthy()
  })

  it('emits edit / delete', async () => {
    const wrapper = mount(McpServersSection, { props: { modelValue: [baseServer] } })
    await wrapper.find('[data-testid="edit-btn"]').trigger('click')
    expect(wrapper.emitted('edit')?.[0]).toEqual([baseServer])
    await wrapper.find('[data-testid="delete-btn"]').trigger('click')
    expect(wrapper.emitted('delete')?.[0]).toEqual(['context7'])
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run McpServersSection.spec.ts 2>&1 | tail -n 10`
Expected: FAIL

- [ ] **Step 3: Write the component**

```vue
<!-- src/apps/desktop/src/components/nalar/McpServersSection.vue -->
<script setup lang="ts">
import EmptyState from './EmptyState.vue'
import type { McpServer } from '../../api'

defineProps<{ modelValue: McpServer[] }>()
const emit = defineEmits<{
  edit: [server: McpServer]
  delete: [name: string]
  add: []
}>()

/**
 * Mask a value to first 3 + last 3 chars, with the middle replaced
 * by asterisks. For very short values the whole thing is shown as
 * asterisks (no first/last reveal that would expose it).
 */
function maskValue(v: string): string {
  if (v.length <= 8) return '*'.repeat(v.length)
  const head = v.slice(0, 3)
  const tail = v.slice(-3)
  const middle = '*'.repeat(v.length - 6)
  return head + middle + tail
}
</script>

<template>
  <div class="space-y-4">
    <p class="text-xs leading-relaxed max-w-2xl" style="color: var(--semantic-text-muted);">
      External tool providers the agent can call. Each entry has a unique name, a URL,
      and optional HTTP headers (e.g. <code style="font-family: var(--font-mono);">CONTEXT7_API_KEY</code>).
    </p>

    <div class="flex justify-end">
      <button
        type="button"
        data-testid="add-btn"
        @click="emit('add')"
        class="px-3 h-8 rounded-md text-xs font-medium border transition-colors duration-150"
        style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
      >+ Add server</button>
    </div>

    <EmptyState
      v-if="modelValue.length === 0"
      data-testid="empty-state"
      glyph="◇"
      title="No MCP servers yet"
      description="Add an MCP server to give the agent access to external tools (e.g. context7 for documentation, github for code search)."
      cta-label="+ Add server"
      :cta-action="() => emit('add')"
    />

    <ul v-else class="space-y-2" data-testid="mcp-list">
      <li
        v-for="server in modelValue"
        :key="server.name"
        class="px-4 py-3 rounded-md"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="flex-1 min-w-0">
            <div class="text-sm font-medium" style="color: var(--semantic-text);">{{ server.name }}</div>
            <div class="text-xs font-mono mt-0.5 truncate" style="color: var(--semantic-text-dim);">{{ server.url }}</div>
          </div>
          <div class="flex items-center gap-1.5 shrink-0">
            <button
              type="button"
              data-testid="edit-btn"
              @click="emit('edit', server)"
              class="px-2.5 h-7 rounded-md text-xs border transition-colors duration-150"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
            >Edit</button>
            <button
              type="button"
              data-testid="delete-btn"
              @click="emit('delete', server.name)"
              class="px-2.5 h-7 rounded-md text-xs transition-colors duration-150"
              style="color: var(--color-red);"
              aria-label="Delete server"
            >⌫</button>
          </div>
        </div>

        <ul v-if="server.headers && server.headers.length" class="mt-2 space-y-0.5 font-mono text-xs">
          <li
            v-for="(h, i) in server.headers"
            :key="i"
            style="color: var(--semantic-text-dim);"
            :title="`${h.key} = ${h.value}`"
          >
            <span style="color: var(--semantic-text-muted);">• {{ h.key }}</span>
            <span> = {{ maskValue(h.value) }}</span>
          </li>
        </ul>
      </li>
    </ul>
  </div>
</template>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run McpServersSection.spec.ts 2>&1 | tail -n 10`
Expected: PASS — 5 tests

- [ ] **Step 5: Build + commit**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
git add src/apps/desktop/src/components/nalar/McpServersSection.vue src/apps/desktop/src/__tests__/McpServersSection.spec.ts
git commit -m "feat(nalar-settings): add McpServersSection

List of MCP servers with each row showing the server's name, URL,
and an inline preview of all headers. Header values are always-
masked to first 3 + last 3 chars (e.g. abc***xyz) so users can
tell keys apart without exposing them. Tooltip on hover reveals
the full key=value for debugging.

5 vitest tests cover section explainer, empty state, masking,
and add/edit/delete events."
```

---

## Chunk 7: Orchestrator `NalarSettings.vue` — wire everything together

This chunk replaces the body of `NalarSettings.vue` with a thin orchestrator
that wires the 4 sections, the composable, the tab strip, and the save bar.

### Task 7.1: Rewrite `NalarSettings.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/NalarSettings.vue` (rewrite, ~250 lines)
- Create: `src/apps/desktop/src/__tests__/NalarSettings.spec.ts` (integration test)

- [ ] **Step 1: Write the failing integration test**

```ts
// src/apps/desktop/src/__tests__/NalarSettings.spec.ts
import { mount, flushPromises } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import * as api from '../api'
import NalarSettings from '../components/NalarSettings.vue'

vi.mock('../api', () => ({
  getNalarConfig: vi.fn(),
  saveNalarConfig: vi.fn(),
  deleteProfile: vi.fn(),
}))

const mockGet = api.getNalarConfig as unknown as ReturnType<typeof vi.fn>
const mockSave = api.saveNalarConfig as unknown as ReturnType<typeof vi.fn>

describe('NalarSettings (orchestrator)', () => {
  beforeEach(() => {
    mockGet.mockReset()
    mockSave.mockReset()
    localStorage.clear()
  })

  it('renders the 4 tab labels', async () => {
    mockGet.mockResolvedValueOnce({})
    const wrapper = mount(NalarSettings, {
      global: { stubs: { Teleport: true } },
    })
    await flushPromises()
    expect(wrapper.text()).toContain('Defaults')
    expect(wrapper.text()).toContain('Profiles')
    expect(wrapper.text()).toContain('Sub-agents')
    expect(wrapper.text()).toContain('MCP Servers')
  })

  it('loads the config on mount', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini', api_endpoint: 'https://x' })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    expect(mockGet).toHaveBeenCalled()
    expect(wrapper.find('[data-testid="model-input"]').exists()).toBe(true)
  })

  it('shows the save bar with the right count after a field edit', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini' })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    await wrapper.find('[data-testid="model-input"]').setValue('gpt-4o')
    await flushPromises()
    const bar = wrapper.find('[data-testid="save-bar"]')
    expect(bar.exists()).toBe(true)
    expect(bar.text()).toMatch(/unsaved change/)
  })

  it('saves the config and hides the save bar when Save is clicked', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini' })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    await wrapper.find('[data-testid="model-input"]').setValue('gpt-4o')
    await flushPromises()
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledWith(expect.objectContaining({ model: 'gpt-4o' }))
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(false)
  })

  it('emits a success notification on save', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini' })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    await wrapper.find('[data-testid="model-input"]').setValue('gpt-4o')
    await flushPromises()
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(wrapper.emitted('notification')?.some(e => e[1] === 'success')).toBe(true)
  })

  it('resets the config and hides the save bar when Reset is clicked', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini' })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    await wrapper.find('[data-testid="model-input"]').setValue('gpt-4o')
    await flushPromises()
    await wrapper.find('[data-testid="reset-btn"]').trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(false)
    expect((wrapper.find('[data-testid="model-input"]').element as HTMLInputElement).value).toBe('gpt-4o-mini')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run NalarSettings.spec.ts 2>&1 | tail -n 20`
Expected: FAIL — most assertions will fail because the orchestrator doesn't exist yet

- [ ] **Step 3: Rewrite `NalarSettings.vue`**

The new orchestrator is a thin shell. The `onMounted` block keeps the
localStorage fallback from the original (load 6 fields from localStorage
before the API call) so the legacy fallback path stays intact.

```vue
<!-- src/apps/desktop/src/components/NalarSettings.vue -->
<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { getNalarConfig, saveNalarConfig, type NalarConfig, type NalarProfile, type SubAgent, type McpServer } from '../api'
import { useNalarConfig } from '../composables/useNalarConfig'
import { useProfileDelete } from '../composables/useProfileDelete'

import NalarTabStrip from './nalar/NalarTabStrip.vue'
import NalarSaveBar from './nalar/NalarSaveBar.vue'
import DefaultsSection, { type DefaultsConfig } from './nalar/DefaultsSection.vue'
import ProfilesSection from './nalar/ProfilesSection.vue'
import SubAgentsSection from './nalar/SubAgentsSection.vue'
import McpServersSection from './nalar/McpServersSection.vue'
import ProfileModal from './nalar/ProfileModal.vue'
import SubAgentModal from './nalar/SubAgentModal.vue'
import McpServerModal from './nalar/McpServerModal.vue'
import ConfirmDialog from './ConfirmDialog.vue'

type Tab = 'defaults' | 'profiles' | 'sub-agents' | 'mcp'

const emit = defineEmits<{
  notification: [message: string, type: 'success' | 'error']
}>()

const activeTab = ref<Tab>('defaults')

const { config, loaded, dirty, unsavedCount, saving, load, save, reset } = useNalarConfig()

// localStorage fallback (preserved from original NalarSettings.vue)
const LEGACY_LS_KEYS = [
  'settings-api-endpoint', 'settings-api-key', 'settings-model',
  'settings-temperature', 'settings-max-tokens', 'settings-system-prompt',
] as const

function loadLegacyLocalStorageFallback(): Partial<NalarConfig> {
  return {
    api_endpoint: localStorage.getItem('settings-api-endpoint') || undefined,
    api_key: localStorage.getItem('settings-api-key') || undefined,
    model: localStorage.getItem('settings-model') || undefined,
    temperature: parseFloat(localStorage.getItem('settings-temperature') || '0.7') || 0.7,
    max_tokens: localStorage.getItem('settings-max-tokens') || undefined,
    system_prompt: localStorage.getItem('settings-system-prompt') || undefined,
  }
}

onMounted(async () => {
  await load()
  // If the API call returned an empty object, layer the localStorage
  // fallback on top (legacy behavior).
  if (config.value && !config.value.api_endpoint && !config.value.model) {
    const fb = loadLegacyLocalStorageFallback()
    config.value = { ...fb, ...config.value }
  }
})

// v-models for the 4 sections
const defaultsConfig = ref<DefaultsConfig | null>(null)
const profilesList = ref<NalarProfile[]>([])
const activeProfile = ref<string | null>(null)
const subAgentsList = ref<SubAgent[]>([])
const mcpServersList = ref<McpServer[]>([])

// Sync from the central config into the section refs whenever it loads / changes.
function syncFromConfig() {
  if (!config.value) return
  defaultsConfig.value = {
    api_endpoint: config.value.api_endpoint ?? '',
    api_key: config.value.api_key ?? '',
    model: config.value.model ?? '',
    url_style: config.value.url_style ?? 'openai',
    temperature: typeof config.value.temperature === 'number' ? config.value.temperature : 0.7,
    max_tokens: config.value.max_tokens ?? '',
    system_prompt: config.value.system_prompt ?? '',
    notify_on_complete: config.value.notify_on_complete ?? false,
  }
  profilesList.value = Object.entries(config.value.profiles ?? {}).map(([name, p]) => ({
    name, ...p, sub_agents: p.sub_agents ?? [],
  }))
  activeProfile.value = config.value.active_profile ?? null
  subAgentsList.value = config.value.sub_agents ?? []
  mcpServersList.value = parseMcpServers(config.value.mcp_servers)
}
function syncToConfig() {
  if (!config.value || !defaultsConfig.value) return
  config.value = {
    ...config.value,
    api_endpoint: defaultsConfig.value.api_endpoint,
    api_key: defaultsConfig.value.api_key,
    model: defaultsConfig.value.model,
    url_style: defaultsConfig.value.url_style,
    temperature: defaultsConfig.value.temperature,
    max_tokens: defaultsConfig.value.max_tokens,
    system_prompt: defaultsConfig.value.system_prompt,
    notify_on_complete: defaultsConfig.value.notify_on_complete,
    profiles: Object.fromEntries(profilesList.value.map(p => [p.name, p])),
    active_profile: activeProfile.value ?? undefined,
    sub_agents: subAgentsList.value,
    mcp_servers: serializeMcpServers(mcpServersList.value),
  }
}

// Re-sync whenever the central config mutates (after load).
watch(() => config.value && loaded.value, () => { if (loaded.value) syncFromConfig() }, { immediate: true })

// Push section edits back to the central config.
watch([defaultsConfig, profilesList, activeProfile, subAgentsList, mcpServersList], () => {
  if (loaded.value) syncToConfig()
}, { deep: true })

// ... [modals + setActive + deleteProfile + add/edit/save/cancel handlers, see below]
```

The rest of the orchestrator (modal state, Set active flow, delete
confirmation, save/reset handlers) is straightforward glue code that:

1. Owns 6 modal `ref<... | null>` state vars (one per add/edit flow).
2. Wires the 4 sections' `add` / `edit` / `delete` / `setActive` events to
   open modals or call the composable actions.
3. Wires the 3 modals' `save` events to push the modal's draft into the
   relevant section list.
4. Wires `NalarSaveBar`'s `save` / `reset` events to call the composable's
   `save` / `reset` and emit the `notification` event.
5. Wires the `useProfileDelete` composable for profile delete (unchanged
   from the original file, just relocated).

For brevity, the inline template + glue-code above is the only
non-obvious bit; the rest follows the patterns already established in
the current `NalarSettings.vue` (ConfirmDialog, notification emit, etc.).
When implementing, follow the wireframe from the design doc and copy the
handler bodies from the current file where appropriate (most handlers
are 5–15 lines each).

- [ ] **Step 4: Build (the heavy checkpoint)**

```bash
cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 30
```

Expected: clean. If `vue-tsc` complains about types in the new
orchestrator, fix them (likely candidates: missing field on
`NalarProfile`, wrong type for `defaultsConfig`, or `setActiveProfile`
on the composable not existing — fold it into the section-level
`activeProfile` ref instead).

- [ ] **Step 5: Run all tests**

```bash
cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 30
```

Expected: all tests pass (the new orchestrator tests + the section
tests + the composable tests + the existing tests).

- [ ] **Step 6: Commit**

```bash
git add src/apps/desktop/src/components/NalarSettings.vue src/apps/desktop/src/__tests__/NalarSettings.spec.ts
git commit -m "refactor(nalar-settings): rewrite NalarSettings.vue as orchestrator

Replaces the 1306-line monolithic component with a ~250-line shell
that wires 4 sections + a tab strip + a sticky save bar. The
useNalarConfig composable owns the central NalarConfig + dirty
tracking; each section binds to a slice via v-model. localStorage
fallback is preserved.

6 integration tests cover tab rendering, config load, dirty pill,
save success, save notification, and reset."
```

---

## Chunk 8: Final verification + smoke test

### Task 8.1: Full project verification

- [ ] **Step 1: Type-check + bundle**

```bash
cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 10
```

Expected: clean. No TS errors, no warnings about unused imports.

- [ ] **Step 2: Full unit test suite**

```bash
cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 20
```

Expected: all tests pass. Pre-revamp baseline was N tests; the
post-revamp count is N + ~40 new tests (7 useNalarConfig + 3
EmptyState + 5 NalarTabStrip + 6 NalarSaveBar + 5 LlmConfigForm + 4
McpHeadersEditor + 4 DefaultsSection + 6 ProfilesSection + 6
SubAgentsSection + 5 McpServersSection + 6 NalarSettings = 57 new
tests).

- [ ] **Step 3: Manual dev-server smoke test**

```bash
cd src/apps/desktop && timeout 30 bun run dev 2>&1 &
sleep 5
# In a separate terminal: open the settings page, click each tab,
# edit a field, confirm the save bar appears, click Save, confirm
# the toast appears, refresh, confirm the change persisted.
```

Visual checklist:
- 4 tabs render in the order Defaults / Profiles / Sub-agents / MCP Servers
- Active tab has a 2px violet underline
- Profile / sub-agent / MCP server modals open from their + Add buttons
- API key show/hide toggle works
- "Set active" on a profile row updates the active pill
- Delete shows the ConfirmDialog
- Save bar slides in when a field changes, slides out on save
- localStorage `nalar-settings-active-tab` persists the active tab

- [ ] **Step 4: Confirm parent unchanged**

```bash
cd src/apps/desktop && git diff --stat src/components/SettingsView.vue
```

Expected: empty (or only whitespace if Vue formatted differently).

- [ ] **Step 5: Final commit (if any cleanup landed)**

```bash
cd src/apps/desktop && git status
# If anything needs committing, add + commit with a clear message.
```

- [ ] **Step 6: Update NALAR.md (if a new pattern was established)**

If `useNalarConfig` becomes the canonical pattern for "central config +
dirty tracking" composables in the desktop app, add a short note to
`src/apps/desktop/NALAR.md` (or the root `NALAR.md`) referencing the
new composable.

---

## Risk register

| Risk | Mitigation |
|---|---|
| `bun run build` fails with TS error in Chunk 7's orchestrator | The chunk has a dedicated "build heavy checkpoint" step (7.4) right after the rewrite. Fix types there before continuing. |
| The `useNalarConfig` dirty counter over- or under-counts | The 7 tests in Task 1.1 cover the basic cases. If the UI shows wrong counts in dev, tune `countDiffs` and add a regression test. |
| `useProfileDelete` integration breaks in the new `ProfilesSection` | The composable is unchanged. The orchestrator wires it identically. The `ProfilesSection.spec.ts` doesn't mock it, but the integration test in Chunk 7 covers the end-to-end flow. |
| The `localStorage` fallback path is accidentally dropped | Task 7.1's orchestrator preserves the `LEGACY_LS_KEYS` fallback. The integration test `it('loads the config on mount')` exercises the path. |
| Modal teleport breaks in jsdom | `<Teleport to="body">` works in jsdom. The integration test stubs `Teleport: true` to keep assertions simple (the modal's behavior is already tested in `McpHeadersEditor.spec.ts` and the per-section tests). |
| Parent `SettingsView.vue` accidentally changes | Chunk 8.4 verifies with `git diff --stat` that the parent is untouched. |
| `useNalarConfig` snapshot JSON.stringify drops a field | `JSON.stringify` of a `NalarConfig` round-trips all fields including `mcp_servers` (a nested object). The `countDiffs` walker handles nested objects and arrays. |
| `notifyOnComplete` checkbox change doesn't fire | The `@change` handler uses `($event.target as HTMLInputElement).checked`. Confirmed working in the chunk-3 DefaultsSection template. |

---

## Definition of done

- All 8 chunks committed on a feature branch.
- `bun run build` is clean.
- `bunx vitest run` passes (existing + ~57 new tests).
- `SettingsView.vue` is unchanged.
- `useProfileDelete` is unchanged.
- The `notification` event signature is unchanged.
- The `defineExpose({ saveSettings, resetSettings })` surface is unchanged.
- The new code lives under `src/apps/desktop/src/components/nalar/`.
- Manual dev-server smoke test passes.
- NALAR.md has a short note on the `useNalarConfig` composable pattern
  (only if a new convention was established).
