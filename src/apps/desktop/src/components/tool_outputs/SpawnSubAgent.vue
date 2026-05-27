<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse agents from <agent> tags
interface AgentResult {
  name: string
  success: boolean
  response: string | null
  error: string | null
  sessionId: string | null
}

const agents = computed((): AgentResult[] => {
  const results: AgentResult[] = []
  const agentRegex = /<agent name="([^"]*)" success="([^"]*)">([\s\S]*?)<\/agent>/g
  let match

  while ((match = agentRegex.exec(props.content)) !== null) {
    const name = match[1]
    const success = match[2] === 'true'
    const agentContent = match[3]

    // Extract session_id, response or error
    const sessionIdMatch = agentContent.match(/<session_id>([\s\S]*?)<\/session_id>/)
    const responseMatch = agentContent.match(/<response>([\s\S]*?)<\/response>/)
    const errorMatch = agentContent.match(/<error>([\s\S]*?)<\/error>/)

    results.push({
      name,
      success,
      sessionId: sessionIdMatch ? sessionIdMatch[1].trim() : null,
      response: responseMatch ? responseMatch[1].trim() : null,
      error: errorMatch ? errorMatch[1].trim() : null,
    })
  }

  return results
})

// Parse summary
const summary = computed(() => {
  const match = props.content.match(/<summary succeeded="(\d+)" failed="(\d+)" \/>/)
  if (match) {
    return {
      succeeded: parseInt(match[1], 10),
      failed: parseInt(match[2], 10),
    }
  }
  return null
})

// Success count
const successCount = computed(() => {
  return agents.value.filter(a => a.success).length
})

// Failure count
const failedCount = computed(() => {
  return agents.value.filter(a => !a.success).length
})

// Expanded agents set
const expandedAgents = ref<Set<number>>(new Set())

const toggleAgent = (idx: number) => {
  const newSet = new Set(expandedAgents.value)
  if (newSet.has(idx)) {
    newSet.delete(idx)
  } else {
    newSet.add(idx)
  }
  expandedAgents.value = newSet
}

const toggle = () => {
  if (agents.value.length > 0) {
    isExpanded.value = !isExpanded.value
  }
}

// Copy agent response
const copyResponse = async (e: Event, response: string) => {
  e.stopPropagation()
  await navigator.clipboard.writeText(response)
}

// Count of agents
const agentCount = computed(() => agents.value.length)
</script>

<template>
  <div 
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': failedCount > 0 }"
  >
    <!-- Header -->
    <div 
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">spawn_sub_agent</span>
      <span class="flex-1 truncate text-left text-[var(--color-violet)] font-medium" :title="agentCount + ' sub-agent(s)'">
        {{ agentCount }} sub-agent{{ agentCount !== 1 ? 's' : '' }}
      </span>
      <!-- Summary badges -->
      <span v-if="summary" class="flex items-center gap-1.5">
        <span v-if="summary.succeeded > 0" class="text-green-500 font-semibold">
          ✓ {{ summary.succeeded }}
        </span>
        <span v-if="summary.failed > 0" class="text-red-500 font-semibold">
          ✗ {{ summary.failed }}
        </span>
      </span>
      <span v-if="agentCount > 0 || agents.length > 0" class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <div class="divide-y divide-[var(--color-border)]">
        <div 
          v-for="(agent, idx) in agents" 
          :key="idx"
          class="overflow-hidden"
        >
          <!-- Agent header -->
          <div 
            class="group flex items-center gap-1 px-2 py-1.5 cursor-pointer select-none hover:bg-violet-500/5"
            :class="{ 'bg-red-500/5': !agent.success }"
            @click="toggleAgent(idx)"
          >
            <span 
              class="w-2 h-2 rounded-full shrink-0"
              :class="agent.success ? 'bg-green-500' : 'bg-red-500'"
            ></span>
            <span class="text-[var(--semantic-text)] font-medium text-xs">{{ agent.name }}</span>
            <span v-if="agent.sessionId" class="text-[var(--semantic-text-muted)] text-xs font-mono truncate max-w-[120px]" :title="agent.sessionId">
              {{ agent.sessionId }}
            </span>
            <span class="flex-1"></span>
            <span 
              v-if="agent.success" 
              class="text-xs text-green-500"
            >
              success
            </span>
            <span 
              v-else 
              class="text-xs text-red-500"
            >
              failed
            </span>
            <button 
              v-if="agent.response && expandedAgents.has(idx)"
              class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
              @click.stop="copyResponse($event, agent.response!)" 
              title="Copy response"
            >
              ⎘
            </button>
            <span class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
              {{ expandedAgents.has(idx) ? '−' : '+' }}
            </span>
          </div>

          <!-- Expanded agent response/error -->
          <div v-if="expandedAgents.has(idx) && agent.response" class="px-3 py-2 bg-black/[0.02]">
            <pre 
              class="whitespace-pre-wrap break-all text-xs leading-relaxed max-h-64 overflow-y-auto"
              style="color: var(--semantic-text);"
            >{{ agent.response }}</pre>
          </div>
          <div v-if="expandedAgents.has(idx) && agent.error" class="px-3 py-2 bg-red-500/5">
            <pre 
              class="whitespace-pre-wrap break-all text-xs leading-relaxed text-red-500"
            >{{ agent.error }}</pre>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
