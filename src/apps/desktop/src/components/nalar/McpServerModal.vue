<script setup lang="ts">
import { computed, ref, watch } from 'vue'

import { testMcpServer, type McpTestResult } from '../../api'
import LlmConfigModal, { type LlmConfigModalValue } from './LlmConfigModal.vue'
import McpHeadersEditor, { type McpHeader } from './McpHeadersEditor.vue'

/**
 * MCP server modal value — discriminated by `transport`:
 * - 'http'   → uses `url` + `headers`
 * - 'stdio'  → uses `command` + `args` + `env` + `cwd`
 *
 * The UI shows both branches under a transport toggle at the top of
 * the form. The wire shape sent to the backend is the union shape
 * declared in `McpServer` (api/index.ts).
 */
export interface McpServerModalValue {
  name: string
  transport: 'http' | 'stdio'
  url: string
  headers: McpHeader[]
  command: string
  args: string[]
  env: string[]
  cwd: string
}

const props = withDefaults(defineProps<{
  modelValue: McpServerModalValue
  errors?: { name?: string; url?: string; command?: string }
  mode: 'add' | 'edit'
  initialTransport?: 'http' | 'stdio'
}>(), {
  // Default to 'http' for backward compat with legacy callers that
  // never passed an initialTransport.
  initialTransport: 'http',
})

const emit = defineEmits<{
  'update:modelValue': [value: McpServerModalValue]
  cancel: []
  save: []
}>()

// Local edit-state for the stdio textareas (parsed on save). Keeping
// them as raw strings until the user clicks Save means the wire shape
// (newline-separated) round-trips without a parse→stringify roundtrip.
const argsText = ref((props.modelValue.args ?? []).join('\n'))
const envText = ref((props.modelValue.env ?? []).join('\n'))
const cwdLocal = ref(props.modelValue.cwd ?? '')

// If the parent passes a new modelValue (e.g. user picked a different
// server to edit), re-seed the local textareas from it.
watch(
  () => props.modelValue,
  (v) => {
    argsText.value = (v.args ?? []).join('\n')
    envText.value = (v.env ?? []).join('\n')
    cwdLocal.value = v.cwd ?? ''
    // Editing any field invalidates a previous test result — the
    // server may now be misconfigured even though the prior probe
    // succeeded. Clearing prevents stale "looks good!" badges from
    // lulling the user into saving a broken config.
    testResult.value = null
  },
)

// Track which transport the form is currently showing. Initialized from
// props.initialTransport so the parent can default new entries to either
// branch (legacy callers default to 'http').
const transport = ref<'http' | 'stdio'>(
  props.modelValue.transport ?? props.initialTransport,
)

// Adapt HTTP shape <-> LlmConfigModal's contract (URL lives in
// base_url; the LlmConfig fields we don't use are filled with safe
// dummy values — the backend never reads them for MCP entries).
const adapted = computed<LlmConfigModalValue>(() => ({
  name: props.modelValue.name,
  config: {
    model: '',           // not used by MCP
    base_url: props.modelValue.url ?? '',
    thinking: 'auto',
    temperature: 'auto',
    url_style: 'openai',
    api_key: '',
    max_capacity_tokens: null,
    compaction_threshold_percent: null,
    thinking_budget_tokens: null,
    reasoning_effort: null,
  },
}))

const errorForModal = computed(() => ({
  name: props.errors?.name,
  base_url: props.errors?.url,
}))

// True iff a stdio entry's required fields are present.
const stdioValid = computed(() => props.modelValue.command.trim().length > 0)

// ─── Test button state ─────────────────────────────────────────────────────
// `testResult` carries the last probe response (or null = "no probe
// yet"). `testing` is the loading flag — true while the HTTP call is
// in-flight so the button shows a spinner + "Testing…" label. The
// button itself is only enabled when `stdioValid` is true (we can't
// test a missing command) AND `!testing` (don't fire concurrent
// probes).
const testResult = ref<McpTestResult | null>(null)
const testing = ref(false)

// Re-derive whether Test is enabled from the local textareas too —
// the v-model value of `argsText` / `envText` / `cwdLocal` is what
// gets sent on Test, not `modelValue.args` (which the parent only
// refreshes on Save).
const stdioTestValid = computed(() => {
  if (transport.value !== 'stdio') return false
  if (props.modelValue.command.trim().length === 0) return false
  return true
})

async function onTest() {
  if (!stdioTestValid.value || testing.value) return
  testing.value = true
  testResult.value = null
  try {
    // Send the CURRENT textarea contents (not modelValue.args, which
    // is only updated on Save) so the user tests what they see.
    const args = argsText.value
      .split('\n')
      .map((s) => s.trim())
      .filter((s) => s.length > 0)
    const env = envText.value
      .split('\n')
      .map((s) => s.trim())
      .filter((s) => s.length > 0)
    testResult.value = await testMcpServer({
      transport: 'stdio',
      command: props.modelValue.command.trim(),
      args,
      env,
      cwd: cwdLocal.value.trim(),
    })
  } catch (err) {
    // `testMcpServer` always returns a `McpTestResult`; this catch
    // only fires for unexpected exceptions (network down, etc.).
    testResult.value = {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    }
  } finally {
    testing.value = false
  }
}

function setTransport(next: 'http' | 'stdio') {
  transport.value = next
  // Emit so the parent stays in sync.
  emit('update:modelValue', { ...props.modelValue, transport: next })
}

function updateFromModal(v: LlmConfigModalValue) {
  emit('update:modelValue', {
    ...props.modelValue,
    name: v.name,
    url: v.config.base_url,
    headers: props.modelValue.headers,
  })
}

function updateHeaders(h: McpHeader[]) {
  emit('update:modelValue', { ...props.modelValue, headers: h })
}

function updateCommand(e: Event) {
  const value = (e.target as HTMLInputElement).value
  emit('update:modelValue', { ...props.modelValue, command: value })
}

function onSave() {
  // Parse stdio textareas into arrays (drop empty lines).
  const args = argsText.value
    .split('\n')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
  const env = envText.value
    .split('\n')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
  // Push the parsed arrays back into modelValue so the parent saves
  // the canonical shape.
  emit('update:modelValue', {
    ...props.modelValue,
    args,
    env,
    cwd: cwdLocal.value.trim(),
  })
  if (transport.value === 'stdio' && !stdioValid.value) {
    // Don't emit save — the parent will see the same modelValue with
    // command still empty and apply its own validation.
    return
  }
  emit('save')
}

defineExpose({ onSave })
</script>

<template>
  <!-- HTTP branch: delegate to the existing LlmConfigModal. -->
  <div v-if="transport === 'http'" class="space-y-3">
    <div class="flex items-center gap-2 text-xs" data-testid="transport-toggle">
      <button
        type="button"
        data-testid="transport-toggle-http"
        class="px-3 h-7 rounded-md border transition-colors duration-150"
        :style="{
          borderColor: 'var(--color-violet)',
          backgroundColor: 'var(--color-violet)',
          color: 'var(--semantic-bg)',
        }"
        disabled
      >HTTP</button>
      <button
        type="button"
        data-testid="transport-toggle-stdio"
        class="px-3 h-7 rounded-md border transition-colors duration-150"
        style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
        @click="setTransport('stdio')"
      >stdio</button>
    </div>

    <LlmConfigModal
      :model-value="adapted"
      :errors="errorForModal"
      :title="mode === 'add' ? 'Add MCP server' : 'Edit MCP server'"
      :name-editable="mode === 'add'"
      extra-slot-name="extra"
      @update:model-value="updateFromModal"
      @cancel="emit('cancel')"
      @save="onSave"
    >
      <template #extra>
        <McpHeadersEditor
          :model-value="modelValue.headers"
          @update:model-value="updateHeaders"
        />
      </template>
    </LlmConfigModal>
  </div>

  <!-- stdio branch: bespoke centered dialog. The HTTP branch delegates
       to <LlmConfigModal> which provides its own centered wrapper via
       <Teleport>; the stdio branch needs an equivalent wrapper so
       clicking "+ Add server" with the stdio default opens a real
       dialog (with backdrop + close ✕) rather than rendering the form
       inline below the empty state. Matches LlmConfigModal's visual
       shape exactly (header / body / footer). -->
  <Teleport v-else to="body">
    <div
      data-testid="stdio-modal-backdrop"
      class="fixed inset-0 z-50 flex items-center justify-center"
      style="background-color: rgba(0, 0, 0, 0.5);"
      @click.self="emit('cancel')"
    >
      <div
        data-testid="stdio-modal-dialog"
        class="w-full mx-4 max-w-2xl rounded-md flex flex-col"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
        role="dialog"
        aria-modal="true"
      >
        <!-- Header: title + close ✕. -->
        <div
          class="flex items-center justify-between px-5 h-12 border-b shrink-0"
          style="border-color: var(--color-border);"
        >
          <h3 class="text-sm font-semibold" style="color: var(--semantic-text);">
            {{ mode === 'add' ? 'Add MCP server' : 'Edit MCP server' }}
          </h3>
          <button
            type="button"
            data-testid="stdio-close-btn"
            @click="emit('cancel')"
            aria-label="Close"
            class="w-7 h-7 flex items-center justify-center text-sm"
            style="color: var(--semantic-text-muted);"
          >✕</button>
        </div>

        <!-- Body: transport toggle + the stdio fields. -->
        <div class="p-5 space-y-4 overflow-y-auto" style="max-height: 70vh;" data-testid="stdio-form">
          <div class="flex items-center gap-2 text-xs" data-testid="transport-toggle">
            <button
              type="button"
              data-testid="transport-toggle-http"
              class="px-3 h-7 rounded-md border transition-colors duration-150"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
              @click="setTransport('http')"
            >HTTP</button>
            <button
              type="button"
              data-testid="transport-toggle-stdio"
              class="px-3 h-7 rounded-md border transition-colors duration-150"
              :style="{
                borderColor: 'var(--color-violet)',
                backgroundColor: 'var(--color-violet)',
                color: 'var(--semantic-bg)',
              }"
              disabled
            >stdio</button>
          </div>

          <div>
            <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text);">Name</label>
            <input
              type="text"
              :value="modelValue.name"
              :disabled="mode === 'edit'"
              data-testid="name-input"
              class="w-full px-2.5 h-8 rounded-md text-xs border outline-none"
              style="background-color: var(--semantic-content-bg); border-color: var(--color-border); color: var(--semantic-text);"
              @input="(e) => emit('update:modelValue', { ...modelValue, name: (e.target as HTMLInputElement).value })"
            />
          </div>

          <div>
            <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text);">
              Command
              <span style="color: var(--color-red);">*</span>
            </label>
            <input
              type="text"
              :value="modelValue.command"
              placeholder="mcp-hello-world"
              data-testid="command-input"
              class="w-full px-2.5 h-8 rounded-md text-xs font-mono border outline-none"
              style="background-color: var(--semantic-content-bg); border-color: var(--color-border); color: var(--semantic-text);"
              @input="updateCommand"
            />
            <p v-if="errors?.command" class="text-xs mt-1" style="color: var(--color-red);">{{ errors.command }}</p>
          </div>

          <div>
            <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text);">
              Arguments <span style="color: var(--semantic-text-dim);">(one per line)</span>
            </label>
            <textarea
              v-model="argsText"
              rows="3"
              placeholder="server.js&#10;--port&#10;3001"
              data-testid="args-textarea"
              class="w-full px-2.5 py-1.5 rounded-md text-xs font-mono border outline-none resize-y"
              style="background-color: var(--semantic-content-bg); border-color: var(--color-border); color: var(--semantic-text);"
            ></textarea>
          </div>

          <div>
            <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text);">
              Environment <span style="color: var(--semantic-text-dim);">(KEY=VALUE, one per line)</span>
            </label>
            <textarea
              v-model="envText"
              rows="2"
              placeholder="NODE_ENV=production"
              data-testid="env-textarea"
              class="w-full px-2.5 py-1.5 rounded-md text-xs font-mono border outline-none resize-y"
              style="background-color: var(--semantic-content-bg); border-color: var(--color-border); color: var(--semantic-text);"
            ></textarea>
          </div>

          <div>
            <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text);">
              Working directory <span style="color: var(--semantic-text-dim);">(optional)</span>
            </label>
            <input
              v-model="cwdLocal"
              type="text"
              placeholder="/absolute/path"
              data-testid="cwd-input"
              class="w-full px-2.5 h-8 rounded-md text-xs font-mono border outline-none"
              style="background-color: var(--semantic-content-bg); border-color: var(--color-border); color: var(--semantic-text);"
            />
          </div>

          <!-- Test result panel. Shows green pill + tool list on
               success, red banner with the server's error message
               on failure, and a "not yet tested" hint before the
               user clicks Test. Cleared whenever any form field
               changes (watch on modelValue) so stale results don't
               survive a re-edit. -->
          <div
            v-if="testResult"
            data-testid="test-result"
            class="px-3 py-2 rounded-md text-xs border"
            :style="testResult.ok
              ? {
                  borderColor: 'var(--color-green)',
                  backgroundColor: 'rgba(34, 197, 94, 0.08)',
                  color: 'var(--semantic-text)',
                }
              : {
                  borderColor: 'var(--color-red)',
                  backgroundColor: 'rgba(239, 68, 68, 0.08)',
                  color: 'var(--semantic-text)',
                }"
          >
            <div class="flex items-center gap-1.5 font-medium">
              <span v-if="testResult.ok" style="color: var(--color-green);">✓</span>
              <span v-else style="color: var(--color-red);">✗</span>
              <span v-if="testResult.ok">
                Connected — {{ testResult.tools.length }} tool{{ testResult.tools.length === 1 ? '' : 's' }} discovered
              </span>
              <span v-else>Connection failed</span>
            </div>
            <div
              v-if="!testResult.ok"
              data-testid="test-error"
              class="mt-1 font-mono text-[11px]"
              style="color: var(--semantic-text-muted);"
            >{{ testResult.error }}</div>
            <ul
              v-if="testResult.ok && testResult.tools.length > 0"
              data-testid="test-tools"
              class="mt-1.5 font-mono text-[11px] space-y-0.5"
            >
              <li
                v-for="tool in testResult.tools"
                :key="tool.name"
                style="color: var(--semantic-text-muted);"
              >• {{ tool.name }}</li>
            </ul>
          </div>
        </div>

        <!-- Footer: Test + Cancel + Save.
             The Test button is on the LEFT so the primary action
             (Save) stays anchored at the bottom-right. Test is
             disabled when command is empty OR a probe is already
             in flight, so the user can't fire concurrent probes. -->
        <div
          class="flex justify-between gap-2 px-5 h-14 border-t shrink-0 items-center"
          style="border-color: var(--color-border);"
        >
          <button
            type="button"
            data-testid="test-btn"
            class="px-3 h-8 rounded-md text-xs border transition-colors duration-150"
            :style="{
              borderColor: 'var(--color-border)',
              color: testing ? 'var(--semantic-text-dim)' : 'var(--semantic-text)',
              backgroundColor: 'transparent',
              opacity: stdioTestValid && !testing ? 1 : 0.5,
              cursor: stdioTestValid && !testing ? 'pointer' : 'not-allowed',
            }"
            :disabled="!stdioTestValid || testing"
            @click="onTest"
          >{{ testing ? 'Testing…' : 'Test' }}</button>
          <div class="flex gap-2">
            <button
              type="button"
              data-testid="cancel-btn"
              class="px-3 h-8 rounded-md text-xs border"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
              @click="emit('cancel')"
            >Cancel</button>
            <button
              type="button"
              data-testid="save-btn"
              class="px-3 h-8 rounded-md text-xs font-medium border"
              :style="{
                borderColor: 'var(--color-violet)',
                backgroundColor: 'var(--color-violet)',
                color: 'var(--semantic-bg)',
                opacity: stdioValid ? 1 : 0.5,
                cursor: stdioValid ? 'pointer' : 'not-allowed',
              }"
              :disabled="!stdioValid"
              @click="onSave"
            >Save</button>
          </div>
        </div>
        <div
          class="flex justify-end gap-2 px-5 h-14 border-t shrink-0 items-center"
          style="border-color: var(--color-border);"
        >
          <button
            type="button"
            data-testid="cancel-btn"
            class="px-3 h-8 rounded-md text-xs border"
            style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
            @click="emit('cancel')"
          >Cancel</button>
          <button
            type="button"
            data-testid="save-btn"
            class="px-3 h-8 rounded-md text-xs font-medium border"
            :style="{
              borderColor: 'var(--color-violet)',
              backgroundColor: 'var(--color-violet)',
              color: 'var(--semantic-bg)',
              opacity: stdioValid ? 1 : 0.5,
              cursor: stdioValid ? 'pointer' : 'not-allowed',
            }"
            :disabled="!stdioValid"
            @click="onSave"
          >Save</button>
        </div>
      </div>
    </div>
  </Teleport>
</template>
