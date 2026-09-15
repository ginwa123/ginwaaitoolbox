import { mount } from '@vue/test-utils'
import { describe, expect, it, beforeEach } from 'vitest'

import ChatRightSidebar from '../components/views/chat_right_sidebar/ChatRightSidebar.vue'
import TerminalTab from '../components/views/chat_right_sidebar/TerminalTab.vue'
import { makeLocalStorageStub } from './helpers'

const mountSidebar = () =>
  mount(ChatRightSidebar, {
    props: { cwd: '/tmp/toolbox', open: true, width: 280 },
  })

describe('ChatRightSidebar terminal tab (Phase 1 mock)', () => {
  beforeEach(() => {
    // jsdom 29 dropped localStorage from its default globals.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('defaults to the Changes panel', () => {
    const wrapper = mountSidebar()
    expect(wrapper.find('[data-testid="chat-right-sidebar-tab-changes"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="chat-right-sidebar-tab-terminal"]').exists()).toBe(true)
    // Diff panel still mounted; terminal mock is hidden.
    expect(wrapper.find('[data-testid="terminal-tab"]').exists()).toBe(false)
  })

  it('switches to the Terminal mock when the Terminal tab is clicked', async () => {
    const wrapper = mountSidebar()
    await wrapper.find('[data-testid="chat-right-sidebar-tab-terminal"]').trigger('click')
    const terminal = wrapper.find('[data-testid="terminal-tab"]')
    expect(terminal.exists()).toBe(true)
    expect(terminal.text()).toContain('Phase 1 mock')
    expect(wrapper.find('[data-testid="terminal-cwd"]').text()).toContain('/tmp/toolbox')
  })

  it('persists the active panel across mounts', async () => {
    const first = mountSidebar()
    await first.find('[data-testid="chat-right-sidebar-tab-terminal"]').trigger('click')
    expect(localStorage.getItem('nalar-right-sidebar-panel')).toBe('terminal')

    const second = mountSidebar()
    expect(second.find('[data-testid="terminal-tab"]').exists()).toBe(true)
  })
})

describe('TerminalTab mock behavior', () => {
  it('echoes input locally without executing', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    const input = wrapper.find('[data-testid="terminal-input"]')
    await input.setValue('ls -la')
    await wrapper.find('form').trigger('submit.prevent')
    const output = wrapper.find('[data-testid="terminal-output"]').text()
    expect(output).toContain('$ ls -la')
    expect(output).toContain('not executed')
  })

  it('clears output back to the welcome lines', async () => {
    const wrapper = mount(TerminalTab, { props: { cwd: '/tmp/toolbox' } })
    const input = wrapper.find('[data-testid="terminal-input"]')
    await input.setValue('echo hi')
    await wrapper.find('form').trigger('submit.prevent')
    expect(wrapper.find('[data-testid="terminal-output"]').text()).toContain('$ echo hi')

    await wrapper.find('[data-testid="terminal-clear"]').trigger('click')
    const output = wrapper.find('[data-testid="terminal-output"]').text()
    expect(output).not.toContain('$ echo hi')
    expect(output).toContain('Phase 1 mock')
  })
})
