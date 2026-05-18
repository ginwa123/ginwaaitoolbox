<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse command from <command>...</command>
const command = computed(() => {
  const match = props.content.match(/<command>([\s\S]*?)<\/command>/)
  return match ? match[1] : null
})

// Parse stdout from <stdout>...</stdout>
const stdout = computed(() => {
  const match = props.content.match(/<stdout>([\s\S]*?)<\/stdout>/)
  return match ? match[1] : ''
})

// Parse stderr from <stderr>...</stderr>
const stderr = computed(() => {
  const match = props.content.match(/<stderr>([\s\S]*?)<\/stderr>/)
  return match ? match[1] : ''
})

// Parse exit_code from <exit_code>...</exit_code>
const exitCode = computed(() => {
  const match = props.content.match(/<exit_code>(.*?)<\/exit_code>/)
  return match?.[1] != null ? parseInt(match[1], 10) : null
})

// Parse truncated from <truncated>...</truncated>
const isTruncated = computed(() => {
  const match = props.content.match(/<truncated>([\s\S]*?)<\/truncated>/)
  if (!match || !match[1]) return false
  return match[1].trim() === 'true'
})

// Parse timeout from <timeout>...</timeout>
const isTimeout = computed(() => {
  const match = props.content.match(/<timeout>([\s\S]*?)<\/timeout>/)
  if (!match || !match[1]) return false
  return match[1].trim() === 'true'
})

// Parse stdout_lines from <stdout_lines>...</stdout_lines>
const stdoutLines = computed(() => {
  const match = props.content.match(/<stdout_lines>(.*?)<\/stdout_lines>/)
  return match?.[1] != null ? parseInt(match[1], 10) : 0
})

// Parse stderr_lines from <stderr_lines>...</stderr_lines>
const stderrLines = computed(() => {
  const match = props.content.match(/<stderr_lines>(.*?)<\/stderr_lines>/)
  return match?.[1] != null ? parseInt(match[1], 10) : 0
})

// Parse is_self from <is_self>...</is_self>
const isSelf = computed(() => {
  const match = props.content.match(/<is_self>([\s\S]*?)<\/is_self>/)
  if (!match || !match[1]) return false
  return match[1].trim() === 'true'
})

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
      <span v-if="hasStderr || isTruncated || hasWarning" class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <!-- stdout section -->
      <div v-if="stdout" class="border-b border-dashed border-[var(--color-border)] last:border-b-0">
        <div class="px-2 py-0.5 text-[0.65rem] text-blue-600 font-medium bg-black/[0.02]">
          stdout
          <span class="text-[var(--semantic-text-muted)] ml-1">{{ stdoutLines }}L</span>
        </div>
        <pre class="p-2 m-0 bg-black/[0.02] whitespace-pre-wrap break-all leading-relaxed text-[var(--semantic-text)] text-xs hover:bg-violet-500/5">{{ stdout || '(empty)' }}</pre>
      </div>

      <!-- stderr section -->
      <div v-if="hasStderr" class="border-b border-dashed border-[var(--color-border)] last:border-b-0">
        <div class="px-2 py-0.5 text-[0.65rem] text-red-600 font-medium bg-black/[0.02]">
          stderr
          <span class="text-[var(--semantic-text-muted)] ml-1">{{ stderrLines }}L</span>
        </div>
        <pre class="p-2 m-0 bg-black/[0.02] whitespace-pre-wrap break-all leading-relaxed text-[var(--semantic-text)] text-xs hover:bg-violet-500/5">{{ stderr }}</pre>
      </div>
    </div>
  </div>
</template>