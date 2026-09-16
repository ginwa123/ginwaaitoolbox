import { mount } from '@vue/test-utils'
import { describe, expect, it, beforeEach, vi } from 'vitest'

import ChatRightSidebar from '../components/views/chat_right_sidebar/ChatRightSidebar.vue'
import TerminalTab from '../components/views/chat_right_sidebar/TerminalTab.vue'
import { makeLocalStorageStub } from './helpers'

// ─── xterm fakes (jsdom has no layout/canvas for the real renderer) ─────────
// vi.mock factories hoist above class declarations, so the fakes live
// in vi.hoisted (otherwise "Cannot access before initialization").

const { FakeTerminal, FakeFitAddon } = vi.hoisted(() => {
  class FakeTerminal {
    static instances: FakeTerminal[] = []
    cols = 80
    rows = 24
    written: string[] = []
    cleared = 0
    disposed = false
    dataHandler: ((data: string) => void) | null = null

    constructor() {
      FakeTerminal.instances.push(this)
    }

    loadAddon() {}
    open() {}
    write(data: string) {
      this.written.push(data)
    }
    clear() {
      this.cleared += 1
      this.written = []
    }
    onData(cb: (data: string) => void) {
      this.dataHandler = cb
    }
    dispose() {
      this.disposed = true
    }
  }

  class FakeFitAddon {
    fitted = 0
    fit() {
      this.fitted += 1
    }
  }

  return { FakeTerminal, FakeFitAddon }
})

vi.mock('@xterm/xterm', () => ({ Terminal: FakeTerminal }))
vi.mock('@xterm/addon-fit', () => ({ FitAddon: FakeFitAddon }))

// ─── WebSocket fake ─────────────────────────────────────────────────────────

const { FakeWebSocket } = vi.hoisted(() => {
  type Handler = ((event: never) => void) | null
  class FakeWebSocket {
    static instances: FakeWebSocket[] = []
    static CONNECTING = 0
    static OPEN = 1
    static CLOSING = 2
    static CLOSED = 3

    url: string
    readyState = 0
    binaryType = ''
    sent: string[] = []
    closed = false
    onopen: Handler = null
    onmessage: Handler = null
    onerror: Handler = null
    onclose: Handler = null

    constructor(url: string) {
      this.url = url
      FakeWebSocket.instances.push(this)
    }

    send(data: string) {
      this.sent.push(data)
    }
    close() {
      this.closed = true
      this.readyState = FakeWebSocket.CLOSED
    }
    serverOpen() {
      this.readyState = FakeWebSocket.OPEN
      this.onopen?.(undefined as never)
    }
    serverMessage(data: unknown) {
      this.onmessage?.({ data } as never)
    }
    serverError() {
      this.onerror?.(undefined as never)
    }
    serverClose() {
      this.readyState = FakeWebSocket.CLOSED
      this.onclose?.(undefined as never)
    }
  }

  return { FakeWebSocket }
})

vi.stubGlobal('WebSocket', FakeWebSocket)

// ─── API fakes (incrementing session ids for multi-session tests) ──────────

const apiState = {
  nextId: 0,
  outputs: [] as Array<{ data: string; cursor: number; exited: boolean; exit_code: number | null }>,
}

vi.mock('../api', () => ({
  createTerminalSession: vi.fn(async (cwd: string) => {
    apiState.nextId += 1
    return { id: `term-${apiState.nextId}`, pid: 100 + apiState.nextId, cwd }
  }),
  sendTerminalInput: vi.fn(async () => ({ ok: true, bytes: 3 })),
  getTerminalOutput: vi.fn(async () => {
    return apiState.outputs.shift() ?? { data: '', cursor: 0, exited: false, exit_code: null }
  }),
  resizeTerminal: vi.fn(async (_id: string, cols: number, rows: number) => ({
    ok: true,
    cols,
    rows,
  })),
  deleteTerminalSession: vi.fn(async () => ({ ok: true })),
}))

import {
  createTerminalSession,
  sendTerminalInput,
  getTerminalOutput,
  deleteTerminalSession,
} from '../api'

const flush = async (rounds = 5) => {
  for (let i = 0; i < rounds; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

const mountSidebar = () =>
  mount(ChatRightSidebar, {
    props: { cwd: '/tmp/toolbox', open: true, width: 280 },
  })

const firstTerm = () => {
  const term = FakeTerminal.instances[0]!
  expect(term).toBeDefined()
  return term
}

const socketFor = (id: string) => {
  const matches = FakeWebSocket.instances.filter((s) => s.url.includes(`id=${id}`))
  expect(matches.length).toBeGreaterThan(0)
  return matches[matches.length - 1]!
}

const chips = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="terminal-session-chip"]')

const encode = (text: string) => new TextEncoder().encode(text)

describe('ChatRightSidebar terminal tab (Phase 4: multi-session)', () => {
  beforeEach(() => {
    // jsdom 29 dropped localStorage from its default globals.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    FakeTerminal.instances = []
    FakeWebSocket.instances = []
    apiState.nextId = 0
    apiState.outputs = []
    vi.clearAllMocks()
  })

  it('keeps both panels mounted and persists the active tab', async () => {
    const wrapper = mountSidebar()
    await flush()
    expect(wrapper.find('[data-testid="terminal-tab"]').exists()).toBe(true)
    await wrapper.find('[data-testid="chat-right-sidebar-tab-terminal"]').trigger('click')
    expect(localStorage.getItem('nalar-right-sidebar-panel')).toBe('terminal')
  })

  it('auto-creates the first session and streams over its socket', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    expect(createTerminalSession).toHaveBeenCalledWith('/tmp/toolbox', {
      cols: 80,
      rows: 24,
    })
    expect(chips(wrapper)).toHaveLength(1)
    const socket = socketFor('term-1')
    socket.serverOpen()
    socket.serverMessage(encode('hello'))
    await flush()
    expect(firstTerm().written.join('')).toContain('hello')
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('connected')
    expect(getTerminalOutput).not.toHaveBeenCalled()
  })

  it('opens a second session with an isolated socket', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    socketFor('term-1').serverOpen()

    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await flush()
    expect(createTerminalSession).toHaveBeenCalledTimes(2)
    expect(chips(wrapper)).toHaveLength(2)
    const socket2 = socketFor('term-2')
    socket2.serverOpen()

    // Input goes to the active (second) socket only.
    firstTerm().dataHandler?.('ls\n')
    await flush()
    expect(socket2.sent).toContain(JSON.stringify({ type: 'input', data: 'ls\n' }))
    expect(socketFor('term-1').sent).toEqual([])
    expect(sendTerminalInput).not.toHaveBeenCalled()
  })

  it('switching sessions clears the view and attaches to that session', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    socketFor('term-1').serverOpen()
    socketFor('term-1').serverMessage(encode('first'))
    await flush()
    expect(firstTerm().written.join('')).toContain('first')

    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await flush()
    socketFor('term-2').serverOpen()

    // Switch back: view cleared, fresh socket for term-1.
    const clearedBefore = firstTerm().cleared
    await chips(wrapper)[0]!.trigger('click')
    await flush()
    expect(firstTerm().cleared).toBeGreaterThan(clearedBefore)
    const socketsForOne = FakeWebSocket.instances.filter((s) => s.url.includes('id=term-1'))
    expect(socketsForOne.length).toBe(2)

    // Input now routes to term-1 again.
    socketsForOne[1]!.serverOpen()
    firstTerm().dataHandler?.('pwd\n')
    await flush()
    expect(socketsForOne[1]!.sent).toContain(JSON.stringify({ type: 'input', data: 'pwd\n' }))
  })

  it('closing a background session deletes it and keeps the active one', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    socketFor('term-1').serverOpen()
    await wrapper.find('[data-testid="terminal-new"]').trigger('click')
    await flush()
    expect(chips(wrapper)).toHaveLength(2)

    // Close term-1 (background): active term-2 untouched.
    const closers = wrapper.findAll('[data-testid="terminal-session-close"]')
    await closers[0]!.trigger('click')
    await flush()
    expect(deleteTerminalSession).toHaveBeenCalledWith('term-1')
    expect(chips(wrapper)).toHaveLength(1)
    expect(createTerminalSession).toHaveBeenCalledTimes(2) // no replacement needed
  })

  it('killing the last session auto-starts a fresh one', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    socketFor('term-1').serverOpen()

    await wrapper.find('[data-testid="terminal-kill"]').trigger('click')
    await flush()
    expect(deleteTerminalSession).toHaveBeenCalledWith('term-1')
    // Invariant: always one session — a replacement is created.
    expect(createTerminalSession).toHaveBeenCalledTimes(2)
    expect(chips(wrapper)).toHaveLength(1)
  })

  it('falls back to REST polling when the socket fails', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    apiState.outputs.push({ data: 'fb', cursor: 2, exited: false, exit_code: null })
    await flush()
    firstSocket().serverError()
    await flush(10)
    expect(getTerminalOutput).toHaveBeenCalled()
    expect(firstTerm().written.join('')).toContain('fb')
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('polling')
  })

  it('REST input triggers an immediate output poll (no 300ms wait)', async () => {
    mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    // Force the REST fallback path.
    firstSocket().serverError()
    await flush(10)
    vi.clearAllMocks()
    // Type: input goes via REST, then an output poll fires immediately
    // (the 300ms interval can't have elapsed during flush).
    firstTerm().dataHandler?.('y')
    await flush()
    expect(sendTerminalInput).toHaveBeenCalledWith('term-1', 'y')
    expect(getTerminalOutput).toHaveBeenCalled()
  })

  it('shows the exited state on the socket exit event', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    const socket = firstSocket()
    socket.serverOpen()
    socket.serverMessage(JSON.stringify({ type: 'exit', exit_code: 0 }))
    await flush(10)
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('code 0')
  })
})

const firstSocket = () => {
  const socket = FakeWebSocket.instances[0]!
  expect(socket).toBeDefined()
  return socket
}
