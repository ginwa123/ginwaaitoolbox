<script setup lang="ts">
import { computed, ref } from 'vue'
import { parseBash } from '../tool_outputs/_shared/toolOutputParser'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)
const parsed = computed(() => parseBash(props.content))

const command = computed(() => parsed.value.command)
const stdout = computed(() => parsed.value.stdout)
const stderr = computed(() => parsed.value.stderr)
const exitCode = computed(() => parsed.value.exitCode)
const isTruncated = computed(() => parsed.value.truncated)
const isTimeout = computed(() => parsed.value.timedOut)
const stdoutLines = computed(() => parsed.value.stdoutLines)
const stderrLines = computed(() => parsed.value.stderrLines)
const isSelf = computed(() => parsed.value.isSelf)

// Has stderr content (not empty and not "No errors.")
const hasStderr = computed(() => {
  return stderr.value && stderr.value.trim() !== '' && stderr.value.trim() !== 'No errors.'
})

// Status for styling
const hasWarning = computed(() => isSelf.value || isTimeout.value)
const hasError = computed(() => exitCode.value !== null && exitCode.value !== 0)

const toggle = () => {
  if (!hasWarning.value && !hasError.value && !isTruncated.value) {
    isExpanded.value = !isExpanded.value
  } else {
    isExpanded.value = !isExpanded.value
  }
}

const copyCommand = async (e: Event) => {
  e.stopPropagation()
  if (command.value) {
    await navigator.clipboard.writeText(command.value)
  }
}

const copyStdout = async (e: Event) => {
  e.stopPropagation()
  if (stdout.value) {
    await navigator.clipboard.writeText(stdout.value)
  }
}

const copyStderr = async (e: Event) => {
  e.stopPropagation()
  if (stderr.value) {
    await navigator.clipboard.writeText(stderr.value)
  }
}
</script>

<template>
  <div 
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-orange-500/50 opacity-85': hasWarning && !hasError, 'border-red-500/50 opacity-85': hasError }"
  >
    <!-- Header -->
    <div 
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      :class="{ 'cursor-default': !hasStderr && !isTruncated }"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">bash</span>
      <span class="flex-1 truncate text-left text-[var(--semantic-text-dim)]" :title="command || ''">
        $ {{ command || 'unknown' }}
      </span>
      
      <!-- Exit code badge -->
      <span 
        v-if="exitCode !== null"
        class="text-[0.65rem] font-medium"
        :class="exitCode === 0 ? 'text-green-500' : 'text-red-500'"
      >
        {{ exitCode }}
      </span>

      <!-- Truncated badge -->
      <span v-if="isTruncated" class="text-yellow-500 text-[0.65rem]">
        truncated
      </span>

      <!-- Timeout badge -->
      <span v-if="isTimeout" class="text-orange-500 text-[0.65rem]">
        timeout
      </span>

      <!-- Self-kill badge -->
      <span v-if="isSelf" class="text-orange-500 text-[0.65rem]">
        self-kill
      </span>

      <!-- Toggle indicator -->
      <button 
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
        @click="copyCommand" 
        title="Copy command"
      >
        ⎘
      </button>
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

      <!-- Expanded content -->
      <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
        <!-- stdout section -->
        <div v-if="stdout" class="group relative border-b border-dashed border-[var(--color-border)] last:border-b-0">
          <div class="px-2 py-0.5 text-[0.65rem] text-blue-600 font-medium bg-black/[0.02] flex items-center gap-2">
            <span>stdout</span>
            <span class="text-[var(--semantic-text-muted)]">{{ stdoutLines }}L</span>
            <button
              class="ml-auto opacity-0 group-hover:opacity-100 text-[var(--semantic-text-muted)] hover:!text-blue-500 cursor-pointer text-xs"
              @click="copyStdout"
              title="Copy stdout"
            >
              ⎘
            </button>
          </div>
          <pre class="p-2 m-0 bg-black/[0.02] whitespace-pre-wrap break-all leading-relaxed text-[var(--semantic-text)] text-xs hover:bg-violet-500/5">{{ stdout || '(empty)' }}</pre>
        </div>

        <!-- stderr section -->
        <div v-if="hasStderr" class="group relative border-b border-dashed border-[var(--color-border)] last:border-b-0">
          <div class="px-2 py-0.5 text-[0.65rem] text-red-600 font-medium bg-black/[0.02] flex items-center gap-2">
            <span>stderr</span>
            <span class="text-[var(--semantic-text-muted)]">{{ stderrLines }}L</span>
            <button
              class="ml-auto opacity-0 group-hover:opacity-100 text-[var(--semantic-text-muted)] hover:!text-red-500 cursor-pointer text-xs"
              @click="copyStderr"
              title="Copy stderr"
            >
              ⎘
            </button>
          </div>
          <pre class="p-2 m-0 bg-black/[0.02] whitespace-pre-wrap break-all leading-relaxed text-[var(--semantic-text)] text-xs hover:bg-violet-500/5">{{ stderr }}</pre>
        </div>
      </div>
  </div>
</template>