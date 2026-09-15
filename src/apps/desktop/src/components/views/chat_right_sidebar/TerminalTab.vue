<script setup lang="ts">
import { onMounted, onUnmounted, ref, watch } from 'vue'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'
import {
  createTerminalSession,
  deleteTerminalSession,
  getTerminalOutput,
  resizeTerminal,
  sendTerminalInput,
} from '../../../api'

const props = defineProps<{
  cwd: string
}>()

const POLL_MS = 300

const container = ref<HTMLElement | null>(null)
const sessionId = ref<string | null>(null)
const pid = ref<number | null>(null)
const status = ref('connecting…')
const exited = ref(false)

let term: Terminal | null = null
let fit: FitAddon | null = null
let pollTimer: ReturnType<typeof setInterval> | null = null
let pollInFlight = false
let cursor = 0
let lastCols = 0
let lastRows = 0
let disposed = false
let resizeObserver: ResizeObserver | null = null
let ws: WebSocket | null = null
let wsOpened = false

const wsUrl = (id: string) => {
  const proto = window.location.protocol === 'https:' ? 'wss' : 'ws'
  return `${proto}://${window.location.host}/api/terminal/ws?id=${encodeURIComponent(id)}`
}

const stopPoll = () => {
  if (pollTimer !== null) {
    clearInterval(pollTimer)
    pollTimer = null
  }
}

const startPollFallback = (reason: string) => {
  // REST fallback when the socket can't connect or drops: clear and
  // replay from the buffer start (cursor unknown in WS mode).
  stopPoll()
  closeWs()
  term?.clear()
  cursor = 0
  status.value = reason
  pollTimer = setInterval(pollOnce, POLL_MS)
  void pollOnce()
}

const closeWs = () => {
  const socket = ws
  ws = null
  wsOpened = false
  if (socket && socket.readyState !== WebSocket.CLOSED) {
    try {
      socket.close()
    } catch {
      // Already gone — nothing to do.
    }
  }
}

const handleWsMessage = (event: MessageEvent) => {
  const data = event.data
  if (typeof data === 'string') {
    try {
      const msg = JSON.parse(data) as { type?: string; exit_code?: number | null }
      if (msg.type === 'exit') {
        exited.value = true
        status.value =
          msg.exit_code === null || msg.exit_code === undefined
            ? 'shell exited'
            : `shell exited (code ${msg.exit_code}) — Reconnect for a new one`
        stopPoll()
        closeWs()
      }
    } catch {
      // Non-JSON text — ignore.
    }
    return
  }
  const bytes =
    data instanceof ArrayBuffer
      ? new Uint8Array(data)
      : ArrayBuffer.isView(data)
        ? new Uint8Array(data.buffer as ArrayBuffer, data.byteOffset, data.byteLength)
        : null
  if (bytes) {
    term?.write(new TextDecoder().decode(bytes).replace(/\n/g, '\r\n'))
  } else if (data instanceof Blob) {
    void data.text().then((text) => {
      if (!disposed) term?.write(text.replace(/\n/g, '\r\n'))
    })
  }
}

const connectWs = () => {
  const id = sessionId.value
  if (!id || disposed) return
  closeWs()
  let socket: WebSocket
  try {
    socket = new WebSocket(wsUrl(id))
  } catch {
    startPollFallback('socket unavailable — polling')
    return
  }
  socket.binaryType = 'arraybuffer'
  ws = socket
  socket.onopen = () => {
    if (disposed || ws !== socket) return
    wsOpened = true
    stopPoll()
    status.value = 'connected'
  }
  socket.onmessage = (event) => {
    if (ws !== socket) return
    handleWsMessage(event)
  }
  socket.onerror = () => {
    if (ws !== socket) return
    if (!wsOpened) startPollFallback('socket failed — polling')
  }
  socket.onclose = () => {
    if (ws !== socket || disposed) return
    if (!wsOpened) {
      startPollFallback('socket failed — polling')
    } else {
      wsOpened = false
      if (!exited.value) startPollFallback('socket closed — polling')
    }
  }
}

const sendInput = (data: string) => {
  const id = sessionId.value
  if (!id || exited.value) return
  if (ws && wsOpened && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify({ type: 'input', data }))
      return
    } catch {
      // Fall through to REST.
    }
  }
  sendTerminalInput(id, data).catch(() => {
    status.value = 'input failed — retrying…'
  })
}

const fitAndResize = async () => {
  if (!term || !fit || !sessionId.value || exited.value) return
  try {
    fit.fit()
  } catch {
    return
  }
  const { cols, rows } = term
  if (cols === lastCols && rows === lastRows) return
  lastCols = cols
  lastRows = rows
  if (ws && wsOpened && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify({ type: 'resize', cols, rows }))
      return
    } catch {
      // Fall through to REST.
    }
  }
  try {
    await resizeTerminal(sessionId.value, cols, rows)
  } catch {
    // Resize is best-effort; the session keeps running at its old size.
  }
}

const pollOnce = async () => {
  if (pollInFlight || !sessionId.value || disposed) return
  pollInFlight = true
  try {
    const out = await getTerminalOutput(sessionId.value, cursor)
    cursor = out.cursor
    if (out.data) term?.write(out.data.replace(/\n/g, '\r\n'))
    if (out.exited) {
      exited.value = true
      status.value =
        out.exit_code === null
          ? 'shell exited'
          : `shell exited (code ${out.exit_code}) — Reconnect for a new one`
      stopPoll()
    }
  } catch {
    // Transient poll failure (server restart, session reaped): keep the
    // timer running so a recreated session resumes; surface one line.
    status.value = 'connection lost — retrying…'
  } finally {
    pollInFlight = false
  }
}

const ensureSession = async () => {
  if (disposed || sessionId.value) return
  status.value = 'connecting…'
  exited.value = false
  cursor = 0
  try {
    fit?.fit()
    const cols = term?.cols ?? 80
    const rows = term?.rows ?? 24
    lastCols = cols
    lastRows = rows
    const session = await createTerminalSession(props.cwd, { cols, rows })
    if (disposed) {
      // Unmounted while creating — clean up immediately, no leak.
      await deleteTerminalSession(session.id).catch(() => {})
      return
    }
    sessionId.value = session.id
    pid.value = session.pid
    connectWs()
  } catch (err) {
    status.value =
      err instanceof Error ? `failed to start: ${err.message}` : 'failed to start shell'
  }
}

const dropSession = async () => {
  stopPoll()
  closeWs()
  const id = sessionId.value
  sessionId.value = null
  pid.value = null
  if (id) {
    await deleteTerminalSession(id).catch(() => {})
  }
}

const reconnect = async () => {
  await dropSession()
  term?.clear()
  await ensureSession()
}

const kill = async () => {
  await dropSession()
  exited.value = true
  status.value = 'session killed — Reconnect for a new one'
}

const clear = () => term?.clear()

onMounted(() => {
  term = new Terminal({
    fontSize: 12,
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
    cursorBlink: true,
    scrollback: 5000,
    theme: { background: '#0f0e0c', foreground: '#c5c9c5', cursor: '#c5c9c5' },
  })
  fit = new FitAddon()
  term.loadAddon(fit)
  if (container.value) {
    term.open(container.value)
    term.onData((data) => sendInput(data))
    resizeObserver = new ResizeObserver(() => {
      void fitAndResize()
    })
    resizeObserver.observe(container.value)
  }
  void ensureSession()
})

watch(
  () => props.cwd,
  async (next, prev) => {
    if (next === prev || disposed) return
    await dropSession()
    term?.clear()
    await ensureSession()
  },
)

onUnmounted(() => {
  disposed = true
  stopPoll()
  closeWs()
  resizeObserver?.disconnect()
  resizeObserver = null
  const id = sessionId.value
  sessionId.value = null
  if (id) void deleteTerminalSession(id).catch(() => {})
  term?.dispose()
  term = null
  fit = null
})
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
        {{ pid !== null ? `zsh — ${pid} ●` : 'zsh — …' }}
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
        title="Reconnect (new shell)"
        data-testid="terminal-reconnect"
        @click="reconnect"
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
        title="Kill session"
        data-testid="terminal-kill"
        @click="kill"
      >
        ✂
      </button>
    </div>
    <div ref="container" class="flex-1 min-h-0 px-1" data-testid="terminal-xterm" />
    <div
      class="px-3 h-6 shrink-0 flex items-center text-[11px] truncate"
      style="color: var(--semantic-text-dim); border-top: 1px solid var(--color-border)"
      data-testid="terminal-status"
    >
      {{ status }}
    </div>
  </div>
</template>
