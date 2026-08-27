import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'

import McpServerModal, { type McpServerModalValue } from '../components/nalar/McpServerModal.vue'

const baseStdioServer: McpServerModalValue = {
  name: 'hello',
  transport: 'stdio',
  command: 'mcp-hello-world',
  args: [],
  env: [],
  cwd: '',
  url: '',
  headers: [],
}

const baseHttpServer: McpServerModalValue = {
  name: 'context7',
  transport: 'http',
  url: 'https://mcp.context7.com/mcp',
  headers: [],
  command: '',
  args: [],
  env: [],
  cwd: '',
}

/**
 * The HTTP branch delegates to <LlmConfigModal>, which uses
 * <Teleport to="body">. Use `document.body.querySelector` to assert
 * elements rendered by the teleported child (NOT `wrapper.find` —
 * teleported nodes are outside the wrapper's DOM tree).
 *
 * Mount with `attachTo: document.body` so the wrapper and its
 * teleport-target coexist on the same body.
 */
function mountModal(value: McpServerModalValue, mode: 'add' | 'edit' = 'add') {
  return mount(McpServerModal, {
    props: { modelValue: value, mode },
    attachTo: document.body,
  })
}

describe('McpServerModal — stdio transport', () => {
  afterEach(() => {
    document.body.innerHTML = ''
  })

  it('shows transport toggle with stdio branch active by default when transport=stdio', () => {
    const wrapper = mountModal(baseStdioServer)
    expect(wrapper.find('[data-testid="transport-toggle-stdio"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="transport-toggle-http"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="command-input"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="args-textarea"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="env-textarea"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="cwd-input"]').exists()).toBe(true)
    // URL field (HTTP branch) must be hidden — LlmConfigModal uses
    // 'base-url-input' for the URL slot, teleported to document.body.
    expect(document.body.querySelector('[data-testid="base-url-input"]')).toBeNull()
  })

  it('shows URL + headers fields when transport=http', () => {
    const wrapper = mountModal(baseHttpServer)
    expect(document.body.querySelector('[data-testid="base-url-input"]')).not.toBeNull()
    expect(wrapper.find('[data-testid="command-input"]').exists()).toBe(false)
  })

  it('switching to HTTP hides the command field', async () => {
    const wrapper = mountModal(baseStdioServer)
    expect(wrapper.find('[data-testid="command-input"]').exists()).toBe(true)
    await wrapper.find('[data-testid="transport-toggle-http"]').trigger('click')
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="command-input"]').exists()).toBe(false)
    expect(document.body.querySelector('[data-testid="base-url-input"]')).not.toBeNull()
  })

  it('rejects save when command is empty in stdio mode', async () => {
    const wrapper = mountModal({ ...baseStdioServer, command: '' })
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    expect(wrapper.emitted('save')).toBeFalsy()
  })

  it('parses args textarea (newline-separated) on save', async () => {
    const wrapper = mountModal(baseStdioServer)
    await wrapper.find('[data-testid="args-textarea"]').setValue('server.js\n--port\n3001')
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    // Modal emits the parsed args array back via update:modelValue
    // BEFORE the save event. The parent (NalarSettings.vue) sees
    // the parsed array on the modelValue and can persist it.
    const updates = wrapper.emitted('update:modelValue') ?? []
    const last = updates[updates.length - 1]?.[0] as McpServerModalValue | undefined
    expect(last).toBeTruthy()
    expect(last!.args).toEqual(['server.js', '--port', '3001'])
  })

  it('parses env textarea (KEY=VALUE per line) on save', async () => {
    const wrapper = mountModal(baseStdioServer)
    await wrapper.find('[data-testid="env-textarea"]').setValue('NODE_ENV=production\nDEBUG=1')
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    const updates = wrapper.emitted('update:modelValue') ?? []
    const last = updates[updates.length - 1]?.[0] as McpServerModalValue | undefined
    expect(last).toBeTruthy()
    expect(last!.env).toEqual(['NODE_ENV=production', 'DEBUG=1'])
  })
})
