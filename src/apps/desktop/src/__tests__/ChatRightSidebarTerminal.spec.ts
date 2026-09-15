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

// ─── API fakes ─────────────────────────────────────────────────────────────

const apiState = {
  outputs: [] as Array<{ data: string; cursor: number; exited: boolean; exit_code: number | null }>,
}

vi.mock('../api', () => ({
  createTerminalSession: vi.fn(async (cwd: string) => ({ id: 'term-1', pid: 111, cwd })),
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

const firstSocket = () => {
  const socket = FakeWebSocket.instances[0]!
  expect(socket).toBeDefined()
  return socket
}

const encode = (text: string) => new TextEncoder().encode(text)

describe('ChatRightSidebar terminal tab (Phase 3: WS primary)', () => {
  beforeEach(() => {
    // jsdom 29 dropped localStorage from its default globals.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    FakeTerminal.instances = []
    FakeWebSocket.instances = []
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

  it('opens a socket after create and writes binary output', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    expect(createTerminalSession).toHaveBeenCalledWith('/tmp/toolbox', {
      cols: 80,
      rows: 24,
    })
    const socket = firstSocket()
    expect(socket.url).toContain('/api/terminal/ws?id=term-1')

    socket.serverOpen()
    socket.serverMessage(encode('hello'))
    await flush()
    expect(firstTerm().written.join('')).toContain('hello')
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('connected')
    // Socket primary: no REST polling while the socket is open.
    expect(getTerminalOutput).not.toHaveBeenCalled()
  })

  it('sends typed input as socket JSON (not REST)', async () => {
    mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    const socket = firstSocket()
    socket.serverOpen()
    firstTerm().dataHandler?.('ls\n')
    await flush()
    expect(socket.sent).toContain(JSON.stringify({ type: 'input', data: 'ls\n' }))
    expect(sendTerminalInput).not.toHaveBeenCalled()
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

  it('kill closes the socket and deletes the session', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    const socket = firstSocket()
    socket.serverOpen()
    await wrapper.find('[data-testid="terminal-kill"]').trigger('click')
    await flush()
    expect(socket.closed).toBe(true)
    expect(deleteTerminalSession).toHaveBeenCalledWith('term-1')
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('killed')

    await wrapper.find('[data-testid="terminal-reconnect"]').trigger('click')
    await flush()
    expect(createTerminalSession).toHaveBeenCalledTimes(2)
  })
})
