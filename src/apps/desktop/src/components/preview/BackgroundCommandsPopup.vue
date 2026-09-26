<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { useIntervalFn } from '@vueuse/core'
import {
  ApiError,
  getBackgroundProcessLog,
  getBackgroundProcesses,
  type BackgroundProcess,
} from '../../api'
import { formatRelativeTime } from '../../helpers/relativeTime'
import { useSseBus } from '../../helpers/sseBus'

const props = defineProps<{
  sessionId: string
}>()

const LOG_POLL_MS = 2000
const LOG_MAX_BYTES = 20480

const processes = ref<BackgroundProcess[]>([])
const listError = ref<string | null>(null)
const show = ref(false)
const expandedPid = ref<number | null>(null)
const logContent = ref<Record<number, string>>({})
const logLoading = ref<Record<number, boolean>>({})
const logError = ref<Record<number, string | null>>({})
const logTruncated = ref<Record<number, boolean>>({})
const logTotalBytes = ref<Record<number, number>>({})

const runningCount = computed(() => processes.value.filter((p) => p.running).length)

let offBg: (() => void) | null = null
let offQueue: (() => void) | null = null
let offResync: (() => void) | null = null
let disposed = false

const findProcess = (pid: number): BackgroundProcess | undefined =>
  processes.value.find((p) => p.pid === pid)

const formatStartedAt = (startedAt: number): string => {
  // Backend `started_at` is unix SECONDS (see background_processes_list.zig
  // fixtures: 1700000000). formatRelativeTime accepts unix-MS strings or
  // SQLite datetime strings, so convert seconds -> ms string.
  if (!startedAt) return 'now'
  return formatRelativeTime(String(startedAt * 1000))
}

const fullDateTitle = (startedAt: number): string => {
  if (!startedAt) return ''
  return new Date(startedAt * 1000).toLocaleString()
}

const fetchList = async (): Promise<void> => {
  const sid = props.sessionId
  if (!sid) return
  try {
    const data = await getBackgroundProcesses(sid)
    if (disposed || props.sessionId !== sid) return
    processes.value = data.processes ?? []
    listError.value = null
    // A list refresh can flip the expanded row to completed — stop its
    // 2s tail poll (the log stays visible, just no longer live).
    if (expandedPid.value !== null) {
      const proc = findProcess(expandedPid.value)
      if (proc && !proc.running) stopLogTimer()
    }
  } catch (err) {
    if (disposed || props.sessionId !== sid) return
    console.error('[BackgroundCommands] list fetch failed:', err)
    listError.value = 'Failed to load background commands'
  }
}

const fetchLog = async (pid: number): Promise<void> => {
  const sid = props.sessionId
  if (!sid) return
  logLoading.value = { ...logLoading.value, [pid]: true }
  try {
    const data = await getBackgroundProcessLog(sid, pid, LOG_MAX_BYTES)
    if (disposed || props.sessionId !== sid) return
    logContent.value = { ...logContent.value, [pid]: data.content ?? '' }
    logTruncated.value = { ...logTruncated.value, [pid]: data.truncated }
    logTotalBytes.value = { ...logTotalBytes.value, [pid]: data.total_bytes }
    logError.value = { ...logError.value, [pid]: null }
  } catch (err) {
    if (disposed || props.sessionId !== sid) return
    console.error('[BackgroundCommands] log fetch failed:', err)
    if (err instanceof ApiError && err.status === 404) {
      logError.value = { ...logError.value, [pid]: 'process not found' }
    } else {
      logError.value = { ...logError.value, [pid]: 'Failed to load log' }
    }
  } finally {
    if (!disposed && props.sessionId === sid) {
      logLoading.value = { ...logLoading.value, [pid]: false }
    }
  }
}

// 2s tail poll for the expanded row's log. `immediate: false` keeps
// toggleExpand's manual first fetch as the only immediate call, so its
// fetch-then-startLogTimer ordering is preserved verbatim. This is the one
// self-stopping poll: the callback halts itself once the process exits or
// leaves the list, and useIntervalFn's pause() is that same self-stop, so
// stopLogTimer stays a thin wrapper over it. The pid lives in a plain let
// because the callback signature takes no arguments.
let logPollPid: number | null = null
const { pause: pauseLogTimer, resume: resumeLogTimer } = useIntervalFn(
  () => {
    const pid = logPollPid
    if (pid === null) return
    const proc = findProcess(pid)
    if (!proc || !proc.running) {
      stopLogTimer()
      return
    }
    void fetchLog(pid)
  },
  LOG_POLL_MS,
  { immediate: false },
)

const stopLogTimer = (): void => {
  pauseLogTimer()
  logPollPid = null
}

const startLogTimer = (pid: number): void => {
  stopLogTimer()
  logPollPid = pid
  resumeLogTimer()
}

const toggleExpand = (pid: number): void => {
  if (expandedPid.value === pid) {
    expandedPid.value = null
    stopLogTimer()
    return
  }
  expandedPid.value = pid
  void fetchLog(pid)
  const proc = findProcess(pid)
  if (proc?.running) startLogTimer(pid)
  else stopLogTimer()
}

const refreshLog = (pid: number): void => {
  void fetchLog(pid)
}

const handleClose = (): void => {
  show.value = false
}

const refreshList = (): void => {
  void fetchList()
}

const unsubscribeAll = (): void => {
  if (offBg) {
    offBg()
    offBg = null
  }
  if (offQueue) {
    offQueue()
    offQueue = null
  }
  if (offResync) {
    offResync()
    offResync = null
  }
}

const subscribePush = (): void => {
  unsubscribeAll()
  // The global bus is installed once by App.vue; component specs and
  // isolated mounts may not have it — never throw from here.
  try {
    const bus = useSseBus()
    const sid = props.sessionId
    // Primary: dedicated background-process lifecycle events
    // (`background_process_created` on spawn, `background_process_completed`
    // on exit — see background_process_events.zig). No polling.
    offBg = bus.on('backgroundProcess', (event) => {
      if (disposed) return
      if (event.session_id !== sid && event.session_id !== props.sessionId) return
      refreshList()
    })
    // Fallback: completion also queues a message (`queue_queued` via
    // insertQueueMessage), so ANY queue event for this session refreshes
    // too — covers backends that predate the new channel.
    offQueue = bus.on('queue', (event) => {
      if (disposed) return
      if (event.session_id !== sid && event.session_id !== props.sessionId) return
      refreshList()
    })
    // Missed events during leader-takeover / return-from-hidden:
    // re-fetch from REST (same pattern as ChatView loadChatHistory).
    if (bus.onResync) {
      offResync = bus.onResync(() => {
        if (disposed) return
        if (!props.sessionId || props.sessionId !== sid) return
        refreshList()
      })
    }
  } catch (err) {
    console.warn('[BackgroundCommands] SSE bus unavailable (push refresh skipped):', err)
  }
}

const resetForSession = (sid: string): void => {
  processes.value = []
  listError.value = null
  expandedPid.value = null
  logContent.value = {}
  logLoading.value = {}
  logError.value = {}
  logTruncated.value = {}
  logTotalBytes.value = {}
  stopLogTimer()
  if (!sid) {
    unsubscribeAll()
    return
  }
  // Push-driven: immediate fetch on mount/session-switch, then SSE only.
  // Manual refresh (dialog Refresh button) + resync cover missed events.
  void fetchList()
  subscribePush()
}

watch(
  () => props.sessionId,
  (newSid, oldSid) => {
    if (newSid === oldSid) return
    resetForSession(newSid)
  },
)

onMounted(() => {
  disposed = false
  resetForSession(props.sessionId)
})

onUnmounted(() => {
  disposed = true
  stopLogTimer()
  unsubscribeAll()
})
</script>

<template>
  <!-- Pill — hidden when nothing is running (cleaner composer footer). -->
  <button
    v-if="runningCount > 0"
    data-testid="bg-commands-pill"
    @click="show = true"
    class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs transition-all duration-200 hover:scale-105"
    style="
      background-color: var(--semantic-card-bg);
      border: 1px solid var(--color-border);
      cursor: pointer;
    "
    :title="`${runningCount} background command${runningCount !== 1 ? 's' : ''} running — click to view output`"
  >
    <span class="bg-running-dot" aria-hidden="true"></span>
    <span>⌨️</span>
    <span style="color: var(--semantic-text)">{{ runningCount }}</span>
    <span style="color: var(--semantic-text-dim)">running</span>
  </button>

  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="show"
        data-testid="bg-commands-dialog"
        class="fixed inset-0 z-50 flex items-center justify-center"
        @click.self="handleClose"
      >
        <!-- Backdrop -->
        <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" @click="handleClose" />

        <!-- Modal Content -->
        <div
          class="relative w-full max-w-lg mx-4 max-h-[80vh] flex flex-col rounded-xl shadow-2xl"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
        >
          <!-- Header -->
          <div
            class="flex items-center justify-between px-5 py-4 shrink-0"
            style="border-bottom: 1px solid var(--color-border)"
          >
            <div class="flex items-center gap-2">
              <span class="text-xl">⌨️</span>
              <h3 class="text-base font-semibold" style="color: var(--semantic-text)">
                Background commands
              </h3>
              <span
                class="px-2 py-0.5 text-xs rounded-full"
                style="background-color: var(--semantic-active-bg); color: var(--semantic-text-dim)"
              >
                {{ processes.length }}
              </span>
            </div>
            <div class="flex items-center gap-1">
              <button
                data-testid="bg-list-refresh"
                class="p-1.5 rounded-lg transition-colors hover:opacity-70 text-xs"
                style="color: var(--semantic-text-dim)"
                aria-label="Refresh background commands"
                title="Refresh (list updates automatically via SSE)"
                @click="refreshList"
              >
                ↻ Refresh
              </button>
              <button
                @click="handleClose"
                class="p-1.5 rounded-lg transition-colors hover:opacity-70"
                style="color: var(--semantic-text-dim)"
                aria-label="Close background commands"
              >
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </div>
          </div>

          <!-- Body -->
          <div class="flex-1 overflow-y-auto p-3">
            <div
              v-if="listError"
              data-testid="bg-list-error"
              class="text-center py-4 text-sm"
              style="color: var(--color-red)"
            >
              {{ listError }}
            </div>
            <div v-else-if="processes.length === 0" data-testid="bg-empty" class="text-center py-8">
              <span class="text-3xl mb-2 block">📭</span>
              <p class="text-sm" style="color: var(--semantic-text-dim)">
                No background commands for this session
              </p>
            </div>

            <div v-else class="space-y-2">
              <div
                v-for="proc in processes"
                :key="proc.pid"
                data-testid="bg-process-row"
                :data-pid="proc.pid"
                class="w-full text-left p-3 rounded-lg"
                style="
                  background-color: var(--semantic-active-bg);
                  border: 1px solid var(--color-border);
                "
              >
                <button
                  @click="toggleExpand(proc.pid)"
                  class="w-full flex items-start gap-3 text-left"
                  :aria-expanded="expandedPid === proc.pid"
                >
                  <span
                    v-if="proc.running"
                    class="bg-running-dot mt-1.5 shrink-0"
                    aria-hidden="true"
                  ></span>
                  <span v-else class="mt-1.5 shrink-0 text-xs" aria-hidden="true">⚪</span>
                  <div class="flex-1 min-w-0">
                    <p
                      class="text-sm font-mono truncate"
                      style="color: var(--semantic-text)"
                      :title="proc.command"
                    >
                      {{ proc.command }}
                    </p>
                    <p
                      class="text-xs mt-0.5"
                      style="color: var(--semantic-text-dim)"
                      :title="fullDateTitle(proc.started_at)"
                    >
                      pid {{ proc.pid }} · started {{ formatStartedAt(proc.started_at) }}
                    </p>
                  </div>
                  <span
                    data-testid="bg-status-badge"
                    :data-running="proc.running"
                    class="px-2 py-0.5 text-xs rounded-full shrink-0"
                    :style="
                      proc.running
                        ? 'background-color: var(--color-green); color: #fff;'
                        : 'background-color: var(--semantic-active-bg); color: var(--semantic-text-dim); border: 1px solid var(--color-border);'
                    "
                  >
                    {{ proc.running ? 'running' : proc.status || 'completed' }}
                  </span>
                  <svg
                    class="w-4 h-4 mt-1 shrink-0 transition-transform"
                    :class="{ 'rotate-90': expandedPid === proc.pid }"
                    style="color: var(--semantic-text-dim)"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 5l7 7-7 7"
                    />
                  </svg>
                </button>

                <!-- Expandable log tail -->
                <div v-if="expandedPid === proc.pid" class="mt-2">
                  <div class="flex items-center justify-between mb-1">
                    <span v-if="proc.running" class="text-[11px]" style="color: var(--color-green)">
                      ● live — auto-refreshing
                    </span>
                    <span v-else class="text-[11px]" style="color: var(--semantic-text-dim)">
                      log tail
                      <span v-if="logTruncated[proc.pid]">
                        (truncated, showing last {{ LOG_MAX_BYTES }} bytes)</span
                      >
                      <span v-else-if="logTotalBytes[proc.pid] !== undefined">
                        ({{ logTotalBytes[proc.pid] }} bytes)</span
                      >
                    </span>
                    <button
                      data-testid="bg-log-refresh"
                      :data-pid="proc.pid"
                      @click.stop="refreshLog(proc.pid)"
                      class="px-2 py-0.5 text-[11px] rounded-md transition-colors hover:opacity-70"
                      style="
                        background-color: var(--semantic-card-bg);
                        border: 1px solid var(--color-border);
                        color: var(--semantic-text-dim);
                      "
                    >
                      Refresh
                    </button>
                  </div>
                  <div
                    v-if="logLoading[proc.pid] && !logContent[proc.pid]"
                    class="text-xs py-2"
                    style="color: var(--semantic-text-dim)"
                  >
                    Loading log…
                  </div>
                  <div
                    v-else-if="logError[proc.pid]"
                    data-testid="bg-log-error"
                    class="text-xs py-2"
                    style="color: var(--color-red)"
                  >
                    {{ logError[proc.pid] }}
                  </div>
                  <pre
                    v-else
                    data-testid="bg-log-content"
                    :data-pid="proc.pid"
                    class="bg-log-pre text-xs font-mono whitespace-pre-wrap break-words overflow-y-auto"
                    style="
                      background-color: var(--semantic-card-bg);
                      border: 1px solid var(--color-border);
                      color: var(--semantic-text);
                    "
                    >{{ logContent[proc.pid] ?? '' }}</pre>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.modal-enter-active,
.modal-leave-active {
  transition: opacity 0.2s ease;
}

.modal-enter-from,
.modal-leave-to {
  opacity: 0;
}

.modal-enter-active > div:last-child,
.modal-leave-active > div:last-child {
  transition: transform 0.2s ease;
}

.modal-enter-from > div:last-child,
.modal-leave-to > div:last-child {
  transform: scale(0.95);
}

.bg-running-dot {
  width: 8px;
  height: 8px;
  border-radius: 9999px;
  background-color: var(--color-green);
  animation: bg-pulse 1.4s ease-in-out infinite;
  flex-shrink: 0;
}

@keyframes bg-pulse {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.35;
  }
}

@media (prefers-reduced-motion: reduce) {
  .bg-running-dot {
    animation: none;
  }
}

.bg-log-pre {
  border-radius: 8px;
  padding: 8px 10px;
  max-height: 220px;
}
</style>
