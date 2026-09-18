<script setup lang="ts">
import { onMounted, onUnmounted, ref, watch } from 'vue'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'
import {
  ApiError,
  createTerminalSession,
  deleteTerminalSession,
  getTerminalOutput,
  resizeTerminal,
  sendTerminalInput,
} from '../../../api'

const props = defineProps<{
  cwd: string
  /** Per-chat persistence key. With it, session ids survive tab/chat
   * switches via localStorage and re-attach on return; without it
   * sessions are deleted on unmount. */
  sessionKey?: string
}>()

const POLL_MS = 300
const MAX_TERMINALS = 20

interface TermSession {
  id: string
  pid: number
  label: string
}

const container = ref<HTMLElement | null>(null)
const sessions = ref<TermSession[]>([])
const activeId = ref<string | null>(null)
const status = ref('connecting…')
const exitedIds = ref<Set<string>>(new Set())

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
let sessionCounter = 0
const mountedAt = Date.now()
// Mount-time cwd resolution grace: with a git worktree the value
// resolves as '' -> session dir -> worktree dir on every mount. Flips
// inside this window are resolution, not scope changes — dropping
// sessions here is what wiped restored terms on every chat return
// ("always a new term" with worktrees).

const hasSessionKey = () => (props.sessionKey ?? '').length > 0
const storageKey = () => `nalar-terminal-sessions:${props.sessionKey}`

interface StoredSession {
  id: string
  label: string
}

const loadStored = (): StoredSession[] => {
  if (!hasSessionKey()) return []
  try {
    const raw = localStorage.getItem(storageKey())
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed
      .filter(
        (s): s is StoredSession =>
          !!s &&
          typeof (s as StoredSession).id === 'string' &&
          (s as StoredSession).id.length > 0 &&
          typeof (s as StoredSession).label === 'string',
      )
      .slice(0, 10)
  } catch {
    return []
  }
}

const saveStored = () => {
  if (!hasSessionKey()) return
  try {
    localStorage.setItem(
      storageKey(),
      JSON.stringify(sessions.value.map((s) => ({ id: s.id, label: s.label })).slice(0, 10)),
    )
  } catch {
    // Storage full/blocked — persistence degrades to this tab's lifetime.
  }
}

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

const markExited = (id: string, exitCode: number | null | undefined) => {
  exitedIds.value.add(id)
  if (id !== activeId.value) return
  status.value =
    exitCode === null || exitCode === undefined
      ? 'shell exited'
      : `shell exited (code ${exitCode}) — Reconnect for a new one`
  stopPoll()
  closeWs()
}

const handleWsMessage = (event: MessageEvent) => {
  const data = event.data
  if (typeof data === 'string') {
    try {
      const msg = JSON.parse(data) as { type?: string; exit_code?: number | null }
      if (msg.type === 'exit' && activeId.value) markExited(activeId.value, msg.exit_code)
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
  const id = activeId.value
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
      if (activeId.value && !exitedIds.value.has(activeId.value)) {
        startPollFallback('socket closed — polling')
      }
    }
  }
}

const sendInput = (data: string) => {
  const id = activeId.value
  if (!id || (id && exitedIds.value.has(id))) return
  if (ws && wsOpened && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify({ type: 'input', data }))
      return
    } catch {
      // Fall through to REST.
    }
  }
  sendTerminalInput(id, data)
    .then(() => {
      // Immediate poll after input: the echo would otherwise wait up
      // to POLL_MS for the next tick (the "slow typing" feel on the
      // REST fallback path). pollInFlight dedupes overlap.
      void pollOnce()
    })
    .catch(() => {
      status.value = 'input failed — retrying…'
    })
}

const fitAndResize = async () => {
  const id = activeId.value
  if (!term || !fit || !id || exitedIds.value.has(id)) return
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
    await resizeTerminal(id, cols, rows)
  } catch {
    // Resize is best-effort; the session keeps running at its old size.
  }
}

const pollOnce = async () => {
  const id = activeId.value
  if (pollInFlight || !id || disposed) return
  pollInFlight = true
  try {
    const out = await getTerminalOutput(id, cursor)
    if (id !== activeId.value) return // switched mid-poll — drop stale bytes
    cursor = out.cursor
    if (out.data) term?.write(out.data.replace(/\n/g, '\r\n'))
    if (out.exited) markExited(id, out.exit_code)
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) {
      // Session vanished server-side (restart / idle reclaim after
      // 30min untouched): drop it and start fresh instead of retrying
      // a dead id forever.
      const goneId = activeId.value
      if (goneId && !disposed) {
        stopPoll()
        closeWs()
        sessions.value = sessions.value.filter((s) => s.id !== goneId)
        exitedIds.value.delete(goneId)
        saveStored()
        status.value = 'Terminal was reclaimed (idle) — starting a new one…'
        if (sessions.value.length === 0) {
          void newSession()
          return
        }
        const next = sessions.value[0]!
        term?.clear()
        cursor = 0
        activeId.value = next.id
        status.value = 'connecting…'
        connectWs()
        return
      }
    }
    // Transient poll failure (server restart, session reaped): keep the
    // timer running so a recreated session resumes; surface one line.
    status.value = 'connection lost — retrying…'
  } finally {
    pollInFlight = false
  }
}

const switchSession = (id: string) => {
  if (id === activeId.value || disposed) return
  stopPoll()
  closeWs()
  term?.clear()
  cursor = 0
  activeId.value = id
  // Always (re-)attach: the server flushes the buffered history first,
  // then sends the exit event for dead shells — so switching back to
  // an exited session still shows its history, not an empty view.
  status.value = 'connecting…'
  connectWs()
}

const maxLabelNum = () => {
  let max = 0
  for (const s of sessions.value) {
    const m = /(\d+)\s*$/.exec(s.label)
    if (m) max = Math.max(max, parseInt(m[1]!, 10))
  }
  return max
}

const awaitCwd = async (): Promise<string> => {
  // Wait for a STABLE cwd: with a git worktree the value resolves as
  // '' -> session dir -> worktree dir in quick succession. Returning
  // the first non-empty value would spawn the shell in the wrong dir.
  const start = Date.now()
  let stableSince = 0
  let last = ''
  while (!disposed && Date.now() - start < 2000) {
    const cur = props.cwd
    if (cur && cur === last) {
      if (Date.now() - stableSince >= 300) return cur
    } else {
      last = cur
      stableSince = Date.now()
    }
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
  return props.cwd
}

const newSession = async () => {
  if (disposed) return
  if (sessions.value.length >= MAX_TERMINALS) {
    status.value = `Max ${MAX_TERMINALS} terminals — close one to open a new shell`
    return
  }
  status.value = 'connecting…'
  try {
    fit?.fit()
    // effectiveCwd resolves shortly after mount (session load); wait
    // briefly so a fresh shell spawns in the chat dir instead of the
    // server-cwd fallback. Restored sessions skip this (re-attach by
    // id needs no cwd).
    const cwd = await awaitCwd()
    // The wait above can outlive the tab (unmount during the stability
    // window): never spawn into a dead component — leaked creates
    // shift every later test's ids and sockets.
    if (disposed) return
    const session = await createTerminalSession(cwd, {
      cols: term?.cols ?? 80,
      rows: term?.rows ?? 24,
    })
    if (disposed) {
      await deleteTerminalSession(session.id).catch(() => {})
      return
    }
    sessionCounter += 1
    sessions.value.push({ id: session.id, pid: session.pid, label: `term ${sessionCounter}` })
    saveStored()
    switchSession(session.id)
  } catch (err) {
    if (err instanceof ApiError && err.status === 429) {
      status.value = `Max ${MAX_TERMINALS} terminals — close one to open a new shell`
      return
    }
    status.value =
      err instanceof Error ? `failed to start: ${err.message}` : 'failed to start shell'
  }
}

const restoreOrCreate = async () => {
  if (disposed) return
  if (!hasSessionKey()) {
    await newSession()
    return
  }
  const stored = loadStored()
  if (stored.length === 0) {
    await newSession()
    return
  }
  // Validate each stored id (server restarts and LRU eviction drop the
  // in-memory registry). Survivors re-attach below with full scrollback.
  const alive: TermSession[] = []
  for (const s of stored) {
    if (disposed) return
    try {
      await getTerminalOutput(s.id, 0)
      alive.push({ id: s.id, pid: 0, label: s.label })
    } catch {
      // 404/gone (or transient failure) — drop the id.
    }
  }
  if (disposed) return
  sessions.value = alive
  // Continue numbering past the highest restored label (stored labels
  // may be non-sequential after closes — alive.length would collide).
  sessionCounter = Math.max(alive.length, maxLabelNum())
  saveStored()
  if (alive.length === 0) {
    await newSession()
    return
  }
  activeId.value = alive[0]!.id
  status.value = 'connecting…'
  connectWs()
}

const closeSession = async (id: string) => {
  const idx = sessions.value.findIndex((s) => s.id === id)
  if (idx === -1) return
  const wasActive = id === activeId.value
  if (wasActive) {
    stopPoll()
    closeWs()
  }
  sessions.value.splice(idx, 1)
  exitedIds.value.delete(id)
  saveStored()
  await deleteTerminalSession(id).catch(() => {})
  if (disposed) return
  if (sessions.value.length === 0) {
    // Invariant: always keep one session (no empty state to maintain).
    term?.clear()
    await newSession()
    return
  }
  if (wasActive) {
    const next = sessions.value[Math.min(idx, sessions.value.length - 1)]!
    term?.clear()
    cursor = 0
    activeId.value = next.id
    if (exitedIds.value.has(next.id)) {
      status.value = 'shell exited — Reconnect for a new one'
    } else {
      status.value = 'connecting…'
      connectWs()
    }
  }
}

const reconnectActive = async () => {
  const id = activeId.value
  if (!id) {
    await newSession()
    return
  }
  const idx = sessions.value.findIndex((s) => s.id === id)
  stopPoll()
  closeWs()
  sessions.value.splice(idx, 1)
  exitedIds.value.delete(id)
  saveStored()
  await deleteTerminalSession(id).catch(() => {})
  if (disposed) return
  term?.clear()
  await newSession()
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
  // Test hook (dev only): functional_ui tests drive a real browser and
  // assert on the terminal buffer, which xterm renders to <canvas> (no
  // DOM text to query). Exposes the live Terminal for buffer reads;
  // never set in production builds.
  if (import.meta.env.DEV) {
    ;(window as unknown as { __nalarTerm?: Terminal }).__nalarTerm = term
  }
  if (container.value) {
    term.open(container.value)
    term.onData((data) => sendInput(data))
    resizeObserver = new ResizeObserver(() => {
      void fitAndResize()
    })
    resizeObserver.observe(container.value)
  }
  void restoreOrCreate()
})

watch(
  () => props.cwd,
  async (next, prev) => {
    if (next === prev || disposed) return
    // Initial '' → dir resolution is NOT a scope change: fresh mounts
    // already waited for cwd in newSession, and restored sessions
    // re-attach by id (cwd-independent). Dropping here is what wiped
    // restored sessions on every chat return ("always a new term").
    // Only a real scope change (dir → different dir) restarts shells.
    if (!prev) return
    // Mount-time resolution grace (git worktree '' → session → worktree
    // flips): ignore dir → dir changes inside the grace window, only a
    // settled scope change restarts shells.
    if (Date.now() - mountedAt < 3000) return
    // Cwd scope changed: drop every session and start fresh.
    stopPoll()
    closeWs()
    const ids = sessions.value.map((s) => s.id)
    sessions.value = []
    exitedIds.value = new Set()
    activeId.value = null
    await Promise.all(ids.map((id) => deleteTerminalSession(id).catch(() => {})))
    if (disposed) return
    term?.clear()
    await newSession()
  },
)

onUnmounted(() => {
  disposed = true
  stopPoll()
  closeWs()
  resizeObserver?.disconnect()
  resizeObserver = null
  if (hasSessionKey()) {
    // Persistent mode: the server keeps the shells alive; only record
    // the ids so the next mount re-attaches (LRU eviction bounds the
    // registry server-side).
    saveStored()
  } else {
    const ids = sessions.value.map((s) => s.id)
    for (const id of ids) void deleteTerminalSession(id).catch(() => {})
  }
  sessions.value = []
  activeId.value = null
  if (import.meta.env.DEV) {
    ;(window as unknown as { __nalarTerm?: Terminal }).__nalarTerm = undefined
  }
  term?.dispose()
  term = null
  fit = null
})
</script>

<template>
  <div class="flex flex-col h-full min-h-0" data-testid="terminal-tab">
    <div
      class="flex items-center gap-1 px-2 h-8 shrink-0 overflow-x-auto"
      style="border-bottom: 1px solid var(--color-border)"
      role="tablist"
      aria-label="Terminal sessions"
    >
      <button
        v-for="s in sessions"
        :key="s.id"
        type="button"
        role="tab"
        :aria-selected="s.id === activeId"
        class="flex items-center gap-1 text-[11px] rounded px-2 py-0.5 whitespace-nowrap hover:opacity-80"
        :style="
          s.id === activeId
            ? 'background: var(--semantic-active-bg); color: var(--semantic-text)'
            : 'color: var(--semantic-text-dim)'
        "
        :title="`terminal session ${s.label}`"
        data-testid="terminal-session-chip"
        :data-id="s.id"
        @click="switchSession(s.id)"
      >
        {{ s.label }}{{ exitedIds.has(s.id) ? ' ○' : ' ●' }}
        <span
          class="hover:opacity-100 opacity-60 px-0.5"
          title="Close session"
          data-testid="terminal-session-close"
          :data-id="s.id"
          @click.stop="closeSession(s.id)"
        >
          ✕
        </span>
      </button>
      <button
        type="button"
        class="text-[11px] rounded px-2 py-0.5 hover:opacity-70 whitespace-nowrap disabled:opacity-40 disabled:cursor-not-allowed"
        style="color: var(--semantic-text-dim)"
        :title="
          sessions.length >= MAX_TERMINALS
            ? `Max ${MAX_TERMINALS} terminals`
            : 'New terminal session'
        "
        data-testid="terminal-new"
        :disabled="sessions.length >= MAX_TERMINALS"
        @click="newSession"
      >
        +
      </button>
      <span
        class="text-[11px] whitespace-nowrap"
        style="color: var(--semantic-text-dim)"
        data-testid="terminal-count"
        :title="`${sessions.length} of ${MAX_TERMINALS} terminals`"
      >
        {{ sessions.length }}/{{ MAX_TERMINALS }}
      </span>
      <span
        class="text-[11px] truncate flex-1 text-right"
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
        title="Reconnect active session (new shell)"
        data-testid="terminal-reconnect"
        @click="reconnectActive"
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
        title="Kill active session"
        data-testid="terminal-kill"
        @click="() => activeId && closeSession(activeId)"
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
