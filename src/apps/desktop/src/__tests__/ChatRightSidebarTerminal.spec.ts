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

describe('ChatRightSidebar terminal tab (Phase 2)', () => {
  beforeEach(() => {
    // jsdom 29 dropped localStorage from its default globals.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    FakeTerminal.instances = []
    apiState.outputs = []
    vi.clearAllMocks()
  })

  it('keeps both panels mounted and switches visibility', async () => {
    const wrapper = mountSidebar()
    await flush()
    // Terminal stays mounted (v-show) so the PTY survives tab switches.
    expect(wrapper.find('[data-testid="terminal-tab"]').exists()).toBe(true)
    await wrapper.find('[data-testid="chat-right-sidebar-tab-terminal"]').trigger('click')
    expect(localStorage.getItem('nalar-right-sidebar-panel')).toBe('terminal')
  })

  it('creates a session on mount and writes polled output', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    apiState.outputs.push({ data: 'hello', cursor: 5, exited: false, exit_code: null })
    await flush()
    expect(createTerminalSession).toHaveBeenCalledWith('/tmp/toolbox', {
      cols: 80,
      rows: 24,
    })
    expect(getTerminalOutput).toHaveBeenCalled()
    const term = FakeTerminal.instances[0]!
    expect(term).toBeDefined()
    expect(term.written.join('')).toContain('hello')
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('connected')
  })

  it('forwards typed input to the session', async () => {
    mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    const term = FakeTerminal.instances[0]!
    expect(term).toBeDefined()
    term.dataHandler?.('ls\n')
    await flush()
    expect(sendTerminalInput).toHaveBeenCalledWith('term-1', 'ls\n')
  })

  it('shows the exited state when the shell ends', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    apiState.outputs.push({ data: '', cursor: 0, exited: true, exit_code: 0 })
    await flush(10)
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('code 0')
  })

  it('kill deletes the session and reconnect starts a new one', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    await flush()
    await wrapper.find('[data-testid="terminal-kill"]').trigger('click')
    await flush()
    expect(deleteTerminalSession).toHaveBeenCalledWith('term-1')
    expect(wrapper.find('[data-testid="terminal-status"]').text()).toContain('killed')

    await wrapper.find('[data-testid="terminal-reconnect"]').trigger('click')
    await flush()
    expect(createTerminalSession).toHaveBeenCalledTimes(2)
  })

  it('clear empties the visible buffer', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    apiState.outputs.push({ data: 'hello', cursor: 5, exited: false, exit_code: null })
    await flush()
    const term = FakeTerminal.instances[0]!
    expect(term).toBeDefined()
    expect(term.written.join('')).toContain('hello')
    await wrapper.find('[data-testid="terminal-clear"]').trigger('click')
    expect(term.cleared).toBeGreaterThan(0)
    expect(term.written).toEqual([])
  })
})
