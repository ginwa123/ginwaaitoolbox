<script setup lang="ts">
import { ref, watch } from 'vue'

const props = defineProps<{
  cwd: string
}>()

interface TermLine {
  id: number
  text: string
  kind: 'cmd' | 'out' | 'sys'
}

let nextId = 1
const welcome = (cwd: string): TermLine[] => [
  { id: nextId++, text: `Connected (mock) — ${cwd || '(no cwd)'}`, kind: 'sys' },
  { id: nextId++, text: 'Phase 1 mock: input echoes locally, nothing executes.', kind: 'sys' },
  {
    id: nextId++,
    text: 'PTY backend lands in Phase 2 — reconnect/kill stay disabled.',
    kind: 'sys',
  },
]

const lines = ref<TermLine[]>(welcome(props.cwd))
const input = ref('')

watch(
  () => props.cwd,
  (cwd) => {
    lines.value = welcome(cwd)
  },
)

const submit = () => {
  const cmd = input.value.trim()
  if (!cmd) return
  lines.value.push({ id: nextId++, text: `$ ${cmd}`, kind: 'cmd' })
  lines.value.push({
    id: nextId++,
    text: `mock: '${cmd}' not executed — backend lands in Phase 2`,
    kind: 'out',
  })
  input.value = ''
}

const clear = () => {
  lines.value = welcome(props.cwd)
}
</script>

<template>
  <div class="flex flex-col h-full min-h-0" data-testid="terminal-tab">
    <div
      class="flex items-center gap-2 px-3 h-9 shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <span
        class="text-xs rounded px-2 py-0.5"
        style="background: var(--semantic-active-bg); color: var(--semantic-text)"
        data-testid="terminal-session-pill"
      >
        zsh — mock ●
      </span>
      <span
        class="text-[11px] truncate flex-1"
        style="color: var(--semantic-text-dim)"
        data-testid="terminal-cwd"
        :title="cwd"
      >
        📂 {{ cwd || '(no cwd)' }}
      </span>
      <button
        type="button"
        class="text-[11px] rounded px-2 py-0.5 hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        title="Reconnect (disabled in Phase 1 mock)"
        disabled
        data-testid="terminal-reconnect"
      >
        ⟲
      </button>
      <button
        type="button"
        class="text-[11px] rounded px-2 py-0.5 hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        title="Clear terminal"
        data-testid="terminal-clear"
        @click="clear"
      >
        🧹
      </button>
      <button
        type="button"
        class="text-[11px] rounded px-2 py-0.5 hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        title="Kill session (disabled in Phase 1 mock)"
        disabled
        data-testid="terminal-kill"
      >
        ✂
      </button>
    </div>
    <div
      class="flex-1 min-h-0 overflow-y-auto px-3 py-2 font-mono text-xs leading-relaxed"
      data-testid="terminal-output"
    >
      <div v-for="line in lines" :key="line.id" :data-kind="line.kind">
        <span v-if="line.kind === 'cmd'" style="color: var(--semantic-text)">{{ line.text }}</span>
        <span v-else style="color: var(--semantic-text-dim)">{{ line.text }}</span>
      </div>
    </div>
    <form
      class="flex items-center gap-2 px-3 h-10 shrink-0"
      style="border-top: 1px solid var(--color-border)"
      @submit.prevent="submit"
    >
      <span class="font-mono text-xs" style="color: var(--semantic-text-dim)">$</span>
      <input
        v-model="input"
        type="text"
        class="flex-1 min-w-0 bg-transparent outline-none font-mono text-xs"
        style="color: var(--semantic-text)"
        placeholder="Type a command (mock — nothing executes)"
        aria-label="Terminal input (mock)"
        data-testid="terminal-input"
      />
    </form>
  </div>
</template>
